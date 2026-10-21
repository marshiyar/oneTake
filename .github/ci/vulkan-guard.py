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
import os, re, sys

# Swift sources that may name a Vulkan type; the C targets (CVulkan, CMpvfxVulkan) are only built with the headers.
SCANNED = ("Sources", "tools")
SKIPPED = {"CVulkan", "CMpvfxVulkan"}
VULKAN = re.compile(r"\b(?:VulkanColorRenderer|CMpvfxVulkan|CVulkan|Vk[A-Z]\w*|vk[A-Z]\w*)\b")
GUARD = re.compile(r"^canImport\(CMpvfxVulkan\)(?:\s*&&.*)?$")
STRING = re.compile(r'"(?:\\.|[^"\\])*"')


def code_of(line):
    """The line without string literals and `//` comments (enough for the identifiers VULKAN matches)."""
    line = STRING.sub('""', line)
    return line.split("//", 1)[0]


def scan(text):
    """Line numbers (1-based) of Vulkan uses outside the first branch of an `#if canImport(CMpvfxVulkan)`."""
    stack = []  # one bool per open #if: this branch guarantees CMpvfxVulkan exists
    out = []
    in_block_comment = False
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if in_block_comment:
            if "*/" in line:
                in_block_comment = False
                line = line.split("*/", 1)[1]
            else:
                continue
        if line.startswith("/*") and "*/" not in line:
            in_block_comment = True
            continue
        if line.startswith("#if "):
            stack.append(bool(GUARD.match(line[4:].strip())))
            continue
        if line.startswith("#elseif") or line.startswith("#else"):
            if stack:
                stack[-1] = False
            continue
        if line.startswith("#endif"):
            if stack:
                stack.pop()
            continue
        if any(stack):
            continue
        if VULKAN.search(code_of(line)):
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
