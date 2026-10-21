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
"""Every Swift use of a Vulkan type sits inside `#if canImport(CMpvfxVulkan)`.

Package.swift adds CMpvfxVulkan only when the Vulkan headers are installed, so a use guarded by `os(Linux)` alone
breaks the build on a Linux machine without libvulkan-dev (issue #78). CI installs the headers, so only this scan and
the linux-no-vulkan workflow see that case.
Usage: vulkan-guard.py [mpvfx-swift directory]   (exit 1 and one line per finding when a use is unguarded)
"""
import os
import re
import sys

# Swift sources that may name a Vulkan type; the C targets (CVulkan, CMpvfxVulkan) are only built with the headers.
SCANNED = ("Sources", "tools")
SKIPPED = {"CVulkan", "CMpvfxVulkan"}
VULKAN = re.compile(r"\b(?:VulkanColorRenderer|CMpvfxVulkan|CVulkan|Vk[A-Z]\w*|vk[A-Z]\w*)\b")
GUARD = re.compile(r"^canImport\(CMpvfxVulkan\)(?:\s*&&[^|]*)?$")


OPEN_QUOTE = re.compile(r'(#*)("""|")')
BLOCK = re.compile(r"/\*|\*/")


def block_end(text, i):
    """Index just past the `/* */` comment opening at i; Swift block comments nest."""
    depth = 0
    for m in BLOCK.finditer(text, i):
        depth += 1 if m.group() == "/*" else -1
        if depth == 0:
            return m.end()
    return len(text)


def string_end(text, i, m):
    """Index just past the string literal whose opening delimiter `m` matched at i (raw `#"..."#` included)."""
    hashes, quote = m.group(1), m.group(2)
    close, j = quote + hashes, m.end()
    while j < len(text):
        if text.startswith("\\" + hashes, j):
            j += 1 + len(hashes) + 1  # an escape: the backslash, the raw string's hashes, the escaped character
        elif text.startswith(close, j):
            return j + len(close)
        else:
            j += 1
    return len(text)


def code_only(text):
    """The text with comments and string literals blanked and line breaks kept, so a Vulkan name in a `//` or
    `/* */` comment (also one starting after code or spanning lines) or in a string literal is not a use."""
    out, i = [], 0
    while i < len(text):
        quote = OPEN_QUOTE.match(text, i) if text[i] in '#"' else None
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = len(text) if j < 0 else j
        elif text.startswith("/*", i):
            j = block_end(text, i)
        elif quote:
            j = string_end(text, i, quote)
        else:
            out.append(text[i])
            i += 1
            continue
        out.append(" " + "\n" * text.count("\n", i, j))
        i = j
    return "".join(out)


def directive(line, stack):
    """Apply a `#if` / `#elseif` / `#else` / `#endif` line to the stack of open branches; False for any other line.
    A branch is guarded when its own condition guarantees CMpvfxVulkan (an `#elseif canImport(CMpvfxVulkan)` too)."""
    if line.startswith("#if "):
        stack.append(bool(GUARD.match(line[4:].strip())))
    elif line.startswith("#elseif "):
        if stack:
            stack[-1] = bool(GUARD.match(line[8:].strip()))
    elif line.startswith("#else"):
        if stack:
            stack[-1] = False
    elif line.startswith("#endif"):
        if stack:
            stack.pop()
    else:
        return False
    return True


def scan(text):
    """Line numbers (1-based) of Vulkan uses outside a branch whose condition is `canImport(CMpvfxVulkan)`."""
    stack = []  # one bool per open #if: the current branch guarantees CMpvfxVulkan exists
    out = []
    for n, raw in enumerate(code_only(text).splitlines(), 1):
        line = raw.strip()
        if directive(line, stack) or any(stack):
            continue
        if VULKAN.search(line):
            out.append(n)
    return out


def findings(app):
    rows = []
    for top in SCANNED:
        for d, dirs, files in os.walk(os.path.join(app, top)):
            dirs[:] = sorted(x for x in dirs if x not in SKIPPED and not x.startswith("."))
            for f in sorted(files):
                if not f.endswith(".swift"):
                    continue
                path = os.path.join(d, f)
                with open(path, encoding="utf-8") as fh:
                    for n in scan(fh.read()):
                        rows.append(f"{os.path.relpath(path, app)}:{n}")
    return rows


def main(argv):
    app = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "mpvfx-swift")
    rows = findings(app)
    for r in rows:
        print(f"{r}: Vulkan type used outside #if canImport(CMpvfxVulkan)")
    print(f"vulkan-guard: {len(rows)} finding(s) in {', '.join(SCANNED)}")
    return 1 if rows else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
