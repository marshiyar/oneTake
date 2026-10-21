#!/usr/bin/env python3
#===----------------------------------------------------------------------===#
#
# This source file is part of MpVFX.
#
# Copyright (c) 2026 Arshiya Rahgozar.
#
# Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
# http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
# or http://opensource.org/licenses/MIT), at your option.
#
# SPDX-License-Identifier: MIT OR Apache-2.0
#
#===----------------------------------------------------------------------===#
"""Builds the Vulkan and Direct3D 11 compute grade from the Metal kernels' shading body.

    python3 -I scripts/gpu/gen-compute-shaders.py           # regenerate every output
    python3 -I scripts/gpu/gen-compute-shaders.py --check   # exit 1 when a committed output is stale
    python3 -I scripts/gpu/gen-compute-shaders.py --hlsl-spirv-only DIR   # tests: the HLSL kernels as SPIR-V in DIR

One shading body exists: Sources/MpvfxMetal/Shaders/MpvfxColor.metal between "BEGIN BODY" and "MARK: Kernels", written
in a macro dialect (float3, V3, FLOOR, ...). This script splices it between a backend prelude (glsl.inc / hlsl.inc),
the portable math and texture helpers (portable.inc) and the portable kernels, applying a fixed list of textual
rewrites (each must match the expected number of times, so a change of the body cannot slip past silently):
textures become buffer slot numbers, the uniform pointer becomes the global buffer `u`, three identifiers that are
keywords in GLSL or HLSL are renamed, and constant arrays take each language's syntax.

Outputs (committed):
  scripts/gpu/generated/grade_<kernel>.comp       GLSL 450, one compute entry point each
  scripts/gpu/generated/grade.hlsl                HLSL, entry points mpvfx_blur_pass, mpvfx_kuwahara_moments,
                                                  mpvfx_kuwahara_resolve, mpvfx_grade
  Sources/CMpvfxVulkan/mpvfx_grade_spirv.h        SPIR-V words of the GLSL kernels (the Linux app)
  --hlsl-spirv DIR (not committed)                the HLSL kernels compiled by glslang's HLSL front end, which the
                                                  Linux tests run on Vulkan to check the Windows shader source
  Sources/CMpvfxWin32/mpvfx_grade_hlsl.h          the HLSL source as C strings, compiled at run time by d3dcompiler

Every SPIR-V float arithmetic result is decorated NoContraction (no fused multiply-add), matching the CPU reference's
IEEE arithmetic the way the Metal build's `fp contract(off)` does. Needs glslangValidator and spirv-opt (Debian/Ubuntu
packages glslang-tools and spirv-tools). Constants (pi/2 split, Taylor coefficients) are computed
here, not typed; the 8-bit unorm table (k / 255) is a buffer the host fills.
"""
import fractions
import hashlib
import math
import os
import re
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
METAL = os.path.join(ROOT, "Sources/MpvfxMetal/Shaders/MpvfxColor.metal")
HEADER = os.path.join(ROOT, "Sources/MpvfxMetal/Shaders/MpvfxColorShared.h")
GEN = os.path.join(HERE, "generated")
SPIRV_H = os.path.join(ROOT, "Sources/CMpvfxVulkan/mpvfx_grade_spirv.h")
HLSL_H = os.path.join(ROOT, "Sources/CMpvfxWin32/mpvfx_grade_hlsl.h")
KERNELS = [("blur", "kernelBlur", "mpvfx_blur_pass"), ("moments", "kernelMoments", "mpvfx_kuwahara_moments"),
           ("resolve", "kernelResolve", "mpvfx_kuwahara_resolve"), ("grade", "kernelGrade", "mpvfx_grade")]


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def section(text, name):
    m = re.search(r"// BEGIN %s\n(.*?)// END %s\n" % (name, name), text, re.S)
    if not m:
        sys.exit("gen-compute-shaders: section %s missing" % name)
    return m.group(1)


def strip_comments(text):
    out = []
    for line in text.split("\n"):
        i = line.find("//")
        if i >= 0:
            line = line[:i]
        if line.strip():
            out.append(line.rstrip())
    return "\n".join(out) + "\n"


def enum_defines(header):
    """The C enums of MpvfxColorShared.h as #defines (neither GLSL nor shader model 5 HLSL has enums)."""
    lines = []
    for body in re.findall(r"enum\s+\w+\s*\{(.*?)\};", header, re.S):
        value = -1
        for item in [s.strip() for s in body.replace("\n", " ").split(",") if s.strip()]:
            if "=" in item:
                name, v = [s.strip() for s in item.split("=")]
                value = int(v)
            else:
                name, value = item, value + 1
            lines.append("#define %s %d" % (name, value))
    return "\n".join(lines) + "\n"


def f32(x):
    return struct.unpack("<f", struct.pack("<f", float(x)))[0]


def lit(x):
    return "%.9ef" % f32(x)


def constants():
    """pi/2 as three floats (leading two exact parts of the double), 2/pi, Taylor coefficients."""
    half_pi = math.pi / 2
    p1 = f32(half_pi)
    p2 = f32(half_pi - p1)
    p3 = f32(half_pi - p1 - p2)
    out = ["#define PIO2_1 %s" % lit(p1), "#define PIO2_2 %s" % lit(p2), "#define PIO2_3 %s" % lit(p3),
           "#define TWO_OVER_PI %s" % lit(2 / math.pi)]
    for n in (3, 5, 7, 9, 11):
        out.append("#define SIN_C%d %s" % (n, lit(fractions.Fraction((-1) ** ((n - 1) // 2), math.factorial(n)))))
    for n in (2, 4, 6, 8, 10, 12):
        out.append("#define COS_C%d %s" % (n, lit(fractions.Fraction((-1) ** (n // 2), math.factorial(n)))))
    return "\n".join(out) + "\n"


def rewrite(text, pattern, repl, count, flags=0):
    new, n = re.subn(pattern, repl, text, flags=flags)
    if n != count:
        sys.exit("gen-compute-shaders: %r matched %d times, expected %d (the Metal body changed: update the rewrite)"
                 % (pattern, n, count))
    return new


def function_span(text, name):
    """(start, end) of the top-level function `name` (signature at column 0 through the closing brace at column 0)."""
    m = re.search(r"^[A-Za-z0-9_]+ %s\(.*?^\}\n" % re.escape(name), text, re.S | re.M)
    if not m:
        sys.exit("gen-compute-shaders: function %s not found in the Metal body" % name)
    return m.start(), m.end()


def apply_overrides(b):
    """Replaces Metal functions by their loop forms in portable.inc, while each Metal text has its recorded hash."""
    portable = section(read(os.path.join(HERE, "portable.inc")), "OVERRIDES")
    for m in re.finditer(r"// OVERRIDE (\w+) metal-sha256=([0-9a-f]+)\n(.*?)// END OVERRIDE\n", portable, re.S):
        name, recorded, replacement = m.group(1), m.group(2), m.group(3)
        start, end = function_span(b, name)
        actual = hashlib.sha256(b[start:end].encode()).hexdigest()[:16]
        if actual != recorded:
            sys.exit("gen-compute-shaders: %s changed in MpvfxColor.metal (sha256 %s, recorded %s): update its loop form "
                     "in scripts/gpu/portable.inc to compute the same values, then record the new hash" % (name, actual, recorded))
        b = b[:start] + replacement + b[end:]
    if len(re.findall(r"// OVERRIDE \w+", portable)) != len(re.findall(r"// OVERRIDE \w+ metal-sha256=", portable)):
        sys.exit("gen-compute-shaders: every OVERRIDE line needs metal-sha256=<hash>")
    return b


def body():
    metal = read(METAL)
    m = re.search(r"// BEGIN BODY[^\n]*\n(.*?)// MARK: Kernels", metal, re.S)
    if not m:
        sys.exit("gen-compute-shaders: BEGIN BODY / MARK: Kernels markers missing in MpvfxColor.metal")
    b = m.group(1)
    tex = re.search(r"// MARK: Texture access.*?(?=// MARK: Sampling)", b, re.S)
    if not tex:
        sys.exit("gen-compute-shaders: texture access section missing")
    b = b[:tex.start()] + "@TEXTURES@\n" + b[tex.end():]
    b = strip_comments(apply_overrides(b))
    b = rewrite(b, r"\bTex[123]\b", "int", 15)
    b = rewrite(b, r"constant float\* u\b", "int uArg_", 18)
    b = rewrite(b, r"\bu\b(?!\s*\[)", "uArg_", 32)
    b = rewrite(b, r"rows\.read\(uint\(int\((lower|upper)\)\)\)", r"tex1Read(rows, int(\1))", 2)
    b = rewrite(b, r"secT\.read\(uint\((base(?: \+ \d)?)\)\)", r"tex1Read(secT, \1)", 5)
    b = rewrite(b, r"t\.read\(U3\(r, g, b\)\)", "lutRead3(t, r, g, b)", 1)
    # Direct3D 11 allows division 2.5 ulp from correct, so x / y can land just below an integer for x a multiple of y
    # and floor() then loses a whole step. For integral x and y whose product terms stay exact the remainder is then
    # brought back into [0, y): the value an exactly rounded division gives (so on such devices nothing changes).
    b = rewrite(b, re.escape("inline float glMod(float x, float y) { return x - y * FLOOR(x / y); }"),
                "inline float glMod(float x, float y) {\n"
                "    float r = x - y * FLOOR(x / y);\n"
                "    if (x == FLOOR(x) && y == FLOOR(y) && y > 0.0f && FABS(x) + y <= 16777216.0f) {\n"
                "        if (r < 0.0f) { r += y; } else if (r >= y) { r -= y; }\n"
                "    }\n"
                "    return r;\n"
                "}", 1)
    b = rewrite(b, r"\binput\b", "inColor", 10)
    b = rewrite(b, r"\bpoint\b", "pt", 3)
    b = rewrite(b, r"\bline\b", "lineMask", 2)
    b = rewrite(b, r"\btriangle\b", "tri", 4)
    return b


def const_arrays(text, lang):
    def sub(m):
        name, n, values = m.group(1), m.group(2), " ".join(m.group(3).split())
        if lang == "glsl":
            return "const float %s[%s] = float[%s](%s);" % (name, n, n, values)
        return "static const float %s[%s] = {%s};" % (name, n, values)
    return re.sub(r"constant float (\w+)\[(\d+)\] = \{(.*?)\};", sub, text, flags=re.S)


def compose(lang, kernel_fn=None, entry=None):
    portable = read(os.path.join(HERE, "portable.inc"))
    prelude = strip_comments(read(os.path.join(HERE, lang + ".inc")))
    b = body().replace("@TEXTURES@\n", strip_comments(section(portable, "TEXTURES")))
    parts = [prelude, enum_defines(read(HEADER)), constants(),
             strip_comments(section(portable, "MATH")), b, strip_comments(section(portable, "KERNELS"))]
    if lang == "glsl":
        parts.append("void main() { %s(ivec2(gl_GlobalInvocationID.xy)); }\n" % kernel_fn)
    else:
        for _, fn, ep in KERNELS:
            parts.append("[numthreads(16, 8, 1)] void %s(uint3 id : SV_DispatchThreadID) { %s(int2(id.xy)); }\n" % (ep, fn))
    text = const_arrays("".join(parts), lang)
    banner = "// Generated by scripts/gpu/gen-compute-shaders.py from MpvfxColor.metal; edit the sources, not this file.\n"
    if lang == "glsl":  # the #version line must come first
        first, rest = text.split("\n", 1)
        return first + "\n" + banner + rest
    return banner + text


# SPIR-V instructions by name; their numbers come from spirv-as (the SPIR-V tools' own grammar), not from this file.
FLOAT_OP_NAMES = ["OpFNegate", "OpFAdd", "OpFSub", "OpFMul", "OpFDiv", "OpFRem", "OpFMod", "OpVectorTimesScalar",
                  "OpMatrixTimesScalar", "OpVectorTimesMatrix", "OpMatrixTimesVector", "OpMatrixTimesMatrix", "OpOuterProduct", "OpDot"]
# Instructions that precede the type declarations (logical layout: preamble, debug, annotations), each with valid
# operand syntax for the assembler.
LEADING = {"OpCapability": "OpCapability Shader", "OpExtension": 'OpExtension "x"',
           "OpExtInstImport": '%e = OpExtInstImport "GLSL.std.450"', "OpMemoryModel": "OpMemoryModel Logical GLSL450",
           "OpEntryPoint": 'OpEntryPoint GLCompute %m "main"', "OpExecutionMode": "OpExecutionMode %m LocalSize 1 1 1",
           "OpExecutionModeId": "OpExecutionModeId %m LocalSizeId %a %a %a", "OpString": '%s = OpString "x"',
           "OpSourceExtension": 'OpSourceExtension "x"', "OpSource": "OpSource GLSL 450",
           "OpSourceContinued": 'OpSourceContinued "x"', "OpName": 'OpName %m "m"', "OpMemberName": 'OpMemberName %t 0 "m"',
           "OpModuleProcessed": 'OpModuleProcessed "x"', "OpDecorate": "OpDecorate %m NoContraction",
           "OpMemberDecorate": "OpMemberDecorate %t 0 Offset 0", "OpDecorationGroup": "%g = OpDecorationGroup",
           "OpGroupDecorate": "OpGroupDecorate %g %m", "OpGroupMemberDecorate": "OpGroupMemberDecorate %g %t 0",
           "OpDecorateId": "OpDecorateId %m UniformId %a", "OpDecorateString": 'OpDecorateString %m UserSemantic "x"',
           "OpMemberDecorateString": 'OpMemberDecorateString %t 0 UserSemantic "x"'}
LEADING_NAMES = list(LEADING)


def spirv_opcodes(tmp):
    """{name: opcode} for the names above and the NoContraction decoration value, read back from spirv-as output."""
    names = FLOAT_OP_NAMES + LEADING_NAMES
    def line(i, n):
        if n not in FLOAT_OP_NAMES:
            return LEADING[n]
        return "%%r%d = %s %%t %%a%s" % (i, n, "" if n == "OpFNegate" else " %b")
    asm = [line(i, n) for i, n in enumerate(names)]
    path = os.path.join(tmp, "ops.spvasm")
    with open(path, "w", encoding="utf-8") as f:
        f.write("OpDecorate %r0 NoContraction\n" + "\n".join(asm) + "\n")
    r = subprocess.run(["spirv-as", path, "-o", path + ".spv"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("gen-compute-shaders: spirv-as failed: %s" % r.stderr)
    words = load_words(path + ".spv")[5:]
    ops, i = [], 0
    while i < len(words):
        ops.append((words[i] & 0xFFFF, words[i:i + (words[i] >> 16)]))
        i += words[i] >> 16
    table = {"OpDecorate": ops[0][0], "NoContraction": ops[0][1][2]}
    for name, (op, _) in zip(names, ops[1:]):
        table[name] = op
    return table


def load_words(path):
    with open(path, "rb") as f:
        data = f.read()
    return list(struct.unpack("<%dI" % (len(data) // 4), data))


def no_contraction(words, table):
    """Adds `OpDecorate %r NoContraction` for every float arithmetic result, after the existing annotations."""
    float_ops = {table[n] for n in FLOAT_OP_NAMES}
    leading = {table[n] for n in LEADING_NAMES}
    decorate, no_contract = table["OpDecorate"], table["NoContraction"]
    ins, i = [], 5
    while i < len(words):
        ins.append((words[i] & 0xFFFF, words[i:i + (words[i] >> 16)]))
        i += words[i] >> 16
    already = {w[1] for op, w in ins if op == decorate and len(w) >= 3 and w[2] == no_contract}
    results = [w[2] for op, w in ins if op in float_ops and w[2] not in already]
    at = next(k for k, (op, _) in enumerate(ins) if op not in leading)
    out = list(words[:5])
    for k, (_, w) in enumerate(ins):
        if k == at:
            for r in results:
                out += [(3 << 16) | decorate, r, no_contract]
        out += w
    return out, len(results)


def compile_spirv(source, lang, entry, tmp):
    src = os.path.join(tmp, "k." + ("comp" if lang == "glsl" else "hlsl"))
    with open(src, "w", encoding="utf-8") as f:
        f.write(source)
    raw, opt = os.path.join(tmp, "raw.spv"), os.path.join(tmp, "opt.spv")
    cmd = ["glslangValidator", "-V", "--target-env", "vulkan1.0", "-S", "comp", "-o", raw, src]
    if lang == "hlsl":
        cmd[1:1] = ["-D", "-e", entry, "-DMPVFX_VK=1"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("gen-compute-shaders: glslangValidator failed for %s %s:\n%s%s" % (lang, entry, r.stdout, r.stderr))
    # Dead functions out (each kernel carries the whole body); no other transformation.
    r = subprocess.run(["spirv-opt", "--eliminate-dead-functions", raw, "-o", opt], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("gen-compute-shaders: spirv-opt failed: %s" % r.stderr)
    words, n = no_contraction(load_words(opt), spirv_opcodes(tmp))
    with open(raw, "wb") as f:
        f.write(struct.pack("<%dI" % len(words), *words))
    r = subprocess.run(["spirv-val", "--target-env", "vulkan1.0", raw], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("gen-compute-shaders: spirv-val rejected %s %s: %s%s" % (lang, entry, r.stdout, r.stderr))
    return words, n


def c_words(name, words):
    rows = [", ".join("0x%08x" % w for w in words[i:i + 8]) for i in range(0, len(words), 8)]
    return "static const uint32_t %s[%d] = {\n    %s\n};\n" % (name, len(words), ",\n    ".join(rows))


def c_lines(text):
    def esc(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')
    return ",\n    ".join('"%s\\n"' % esc(line) for line in text.split("\n") if line)


def outputs():
    out = {}
    hlsl = compose("hlsl")
    out[os.path.join(GEN, "grade.hlsl")] = hlsl
    spirv = ["// Generated by scripts/gpu/gen-compute-shaders.py (SPIR-V 1.0 words, every float operation NoContraction);",
             "// regenerate, do not edit. Sources: scripts/gpu/generated/grade_<kernel>.comp.",
             "#pragma once", "#include <stdint.h>", ""]
    with tempfile.TemporaryDirectory() as tmp:
        for short, fn, entry in KERNELS:
            glsl = compose("glsl", fn)
            out[os.path.join(GEN, "grade_%s.comp" % short)] = glsl
            words, _ = compile_spirv(glsl, "glsl", "main", tmp)
            spirv.append(c_words("mpvfx_spirv_glsl_%s" % short, words))
            # The Windows source must compile too; with --hlsl-spirv DIR its Vulkan build is kept for the tests that run
            # it on lavapipe (MPVFX_HLSL_SPIRV_DIR), not embedded: glslang inlines every call, so it is megabytes.
            words, _ = compile_spirv(hlsl, "hlsl", entry, tmp)
            if HLSL_SPIRV_DIR:
                os.makedirs(HLSL_SPIRV_DIR, exist_ok=True)
                with open(os.path.join(HLSL_SPIRV_DIR, "hlsl_%s.spv" % short), "wb") as f:
                    f.write(struct.pack("<%dI" % len(words), *words))
    out[SPIRV_H] = "\n".join(spirv)
    out[HLSL_H] = ("// Generated by scripts/gpu/gen-compute-shaders.py: scripts/gpu/generated/grade.hlsl as C strings (one per\n"
                   "// line, joined at run time; MSVC caps one string literal at 64 KB). Regenerate, do not edit.\n"
                   "#pragma once\n\nstatic const char *const mpvfx_grade_hlsl_lines[] = {\n    %s\n};\n" % c_lines(hlsl))
    return out


HLSL_SPIRV_DIR = None


def main():
    global HLSL_SPIRV_DIR
    args = sys.argv[1:]
    check = "--check" in args
    if "--hlsl-spirv-only" in args:
        # Tests: only the HLSL kernels' SPIR-V into DIR; nothing in the repository is written.
        out_dir = os.path.abspath(args[args.index("--hlsl-spirv-only") + 1])
        os.makedirs(out_dir, exist_ok=True)
        with tempfile.TemporaryDirectory() as tmp:
            hlsl = compose("hlsl")
            for short, _, entry in KERNELS:
                words, _ = compile_spirv(hlsl, "hlsl", entry, tmp)
                with open(os.path.join(out_dir, "hlsl_%s.spv" % short), "wb") as f:
                    f.write(struct.pack("<%dI" % len(words), *words))
        print("gen-compute-shaders: HLSL kernels compiled to %s" % out_dir)
        return 0
    if "--hlsl-spirv" in args:
        HLSL_SPIRV_DIR = os.path.abspath(args[args.index("--hlsl-spirv") + 1])
    stale = []
    for path, text in outputs().items():
        old = read(path) if os.path.exists(path) else None
        if old == text:
            continue
        stale.append(os.path.relpath(path, ROOT))
        if not check:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
    if check and stale:
        print("gen-compute-shaders: stale outputs (run scripts/gpu/gen-compute-shaders.py): " + ", ".join(stale))
        return 1
    print("gen-compute-shaders: %s" % ("up to date" if not stale else "wrote " + ", ".join(stale)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
