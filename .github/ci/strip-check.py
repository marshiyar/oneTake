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
"""strip-check.py [--tolerate GLOB]... <file or directory>...: every shipped program and library is stripped.

Walks the unpacked installers and reads each ELF, PE and Mach-O file's own headers (no nm, dumpbin or otool):
  ELF     stripped when it has no `.symtab` section and no `.debug_*` section (`.dynsym` is what the loader needs
          and stays).
  PE      stripped when the COFF header points at no symbol table and the debug directory has no CodeView entry
          (the entry that names the .pdb); Repro, POGO and VC-feature entries carry no symbols and are allowed.
  Mach-O  stripped when the symbol table has no debug (stab) entries and no local defined symbol (`strip -S -x`; ld64's
          radr://5614542 marker stab is not debug data), and no `__DWARF` segment; exported and undefined symbols are what dyld needs and stay. Fat files: each slice.
Files that are not one of the three formats are skipped. A file matching a --tolerate glob (the Swift and MSVC
runtime DLLs, which this project does not build) is reported but does not fail the check.
Prints one Markdown table row per binary and exits 1 when any file that is not tolerated is unstripped, 2 on bad input.
"""
import argparse, fnmatch, os, struct, sys

N_STAB, N_TYPE, N_EXT, N_SECT = 0xE0, 0x0E, 0x01, 0x0E
LC_SYMTAB, LC_SEGMENT, LC_SEGMENT_64 = 0x2, 0x1, 0x19
IMAGE_DEBUG_TYPE_CODEVIEW = 2


def elf(data):
    """(stripped, detail) of an ELF file."""
    cls, endian = data[4], ("<" if data[5] == 1 else ">")
    if cls == 2:
        shoff, = struct.unpack_from(endian + "Q", data, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from(endian + "HHH", data, 0x3A)
    else:
        shoff, = struct.unpack_from(endian + "I", data, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from(endian + "HHH", data, 0x2E)
    if shnum == 0 or shoff == 0:
        return True, "no section headers"

    def section(i):
        base = shoff + i * shentsize
        name, kind = struct.unpack_from(endian + "II", data, base)
        if cls == 2:
            off, size = struct.unpack_from(endian + "QQ", data, base + 0x18)
        else:
            off, size = struct.unpack_from(endian + "II", data, base + 0x10)
        return name, kind, off, size

    _, _, stroff, strsize = section(shstrndx)
    names = data[stroff:stroff + strsize]
    found = []
    for i in range(shnum):
        name_off, kind, _, _ = section(i)
        name = names[name_off:names.index(b"\0", name_off)].decode("ascii", "replace")
        if kind == 2 or name.startswith(".debug_"):
            found.append(name)
    if found:
        return False, "sections " + ", ".join(found[:4]) + (f" (+{len(found) - 4})" if len(found) > 4 else "")
    return True, "no .symtab, no .debug_*"


def pe(data):
    """(stripped, detail) of a PE file."""
    off, = struct.unpack_from("<I", data, 0x3C)
    if data[off:off + 4] != b"PE\0\0":
        return True, "not a PE image"
    coff = off + 4
    nsections, _, symtab, nsyms, optsize = struct.unpack_from("<HIIIH", data, coff + 2)
    opt = coff + 20
    magic, = struct.unpack_from("<H", data, opt)
    dirs = opt + (112 if magic == 0x20B else 96)
    ndirs, = struct.unpack_from("<I", data, dirs - 4)
    sections = []
    for i in range(nsections):
        base = opt + optsize + i * 40
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, base + 8)
        sections.append((vaddr, max(vsize, rawsize), rawptr))

    def file_offset(rva):
        for vaddr, size, rawptr in sections:
            if vaddr <= rva < vaddr + size:
                return rawptr + rva - vaddr
        return None

    problems = []
    if symtab and nsyms:
        problems.append(f"COFF symbol table ({nsyms} symbols)")
    if ndirs > 6:
        dbg_rva, dbg_size = struct.unpack_from("<II", data, dirs + 6 * 8)
        dbg = file_offset(dbg_rva) if dbg_rva else None
        if dbg is not None:
            for e in range(dbg_size // 28):
                kind, size, _, raw = struct.unpack_from("<IIII", data, dbg + e * 28 + 12)
                if kind == IMAGE_DEBUG_TYPE_CODEVIEW:
                    name = ""
                    if raw and data[raw:raw + 4] == b"RSDS":
                        end = data.find(b"\0", raw + 24, raw + size)
                        name = data[raw + 24:end if end > 0 else raw + size].decode("utf-8", "replace")
                    problems.append("CodeView entry" + (f" -> {os.path.basename(name)}" if name else ""))
    if problems:
        return False, "; ".join(problems)
    return True, "no symbol table, no CodeView entry"


def macho_slice(data, base):
    """(stripped, detail) of one Mach-O image at offset `base`."""
    magic, = struct.unpack_from("<I", data, base)
    is64 = magic == 0xFEEDFACF
    endian = "<"
    if magic in (0xCFFAEDFE, 0xCEFAEDFE):   # big-endian on a little-endian reader
        endian, is64 = ">", magic == 0xCFFAEDFE
    ncmds, = struct.unpack_from(endian + "I", data, base + 16)
    cmd_off = base + (32 if is64 else 28)
    stabs = locals_ = exported = undefined = 0
    dwarf = False
    for _ in range(ncmds):
        cmd, size = struct.unpack_from(endian + "II", data, cmd_off)
        if cmd in (LC_SEGMENT, LC_SEGMENT_64):
            segname = data[cmd_off + 8:cmd_off + 24].rstrip(b"\0")
            if segname == b"__DWARF":
                dwarf = True
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from(endian + "IIII", data, cmd_off + 8)
            strings = data[base + stroff:base + stroff + strsize]
            entry = 16 if is64 else 12
            for i in range(nsyms):
                n_strx, = struct.unpack_from(endian + "I", data, base + symoff + i * entry)
                n_type = data[base + symoff + i * entry + 4]
                if n_type & N_STAB:
                    # `strip -S` leaves one marker stab named radr://5614542 (ld64's "this file was stripped" note).
                    if strings[n_strx:strings.find(b"\0", n_strx)] != b"radr://5614542":
                        stabs += 1
                elif (n_type & N_TYPE) == N_SECT:
                    if n_type & N_EXT:
                        exported += 1
                    else:
                        locals_ += 1
                else:
                    undefined += 1
        cmd_off += size
    problems = []
    if dwarf:
        problems.append("__DWARF segment")
    if stabs:
        problems.append(f"{stabs} debug (stab) symbols")
    if locals_:
        problems.append(f"{locals_} local symbols")
    if problems:
        return False, "; ".join(problems)
    return True, f"{exported} exported, {undefined} undefined symbols"


def macho(data):
    magic, = struct.unpack_from(">I", data, 0)
    if magic in (0xCAFEBABE, 0xCAFEBABF):   # fat: every slice
        n, = struct.unpack_from(">I", data, 4)
        results = []
        for i in range(n):
            if magic == 0xCAFEBABE:
                offset, = struct.unpack_from(">I", data, 8 + i * 20 + 8)
            else:
                offset, = struct.unpack_from(">Q", data, 8 + i * 32 + 8)
            results.append(macho_slice(data, offset))
        return all(ok for ok, _ in results), "; ".join(f"slice {i}: {d}" for i, (_, d) in enumerate(results))
    return macho_slice(data, 0)


def inspect(path):
    """(format, stripped, detail) or None when the file is not a program or library."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 64:
        return None
    if data[:4] == b"\x7fELF":
        return ("ELF",) + elf(data)
    if data[:2] == b"MZ":
        off, = struct.unpack_from("<I", data, 0x3C)
        if off + 4 <= len(data) and data[off:off + 4] == b"PE\0\0":
            return ("PE",) + pe(data)
        return None
    magic, = struct.unpack_from(">I", data, 0)
    if magic in (0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xCAFEBABF):
        return ("Mach-O",) + macho(data)
    return None


def files(roots):
    for root in roots:
        if os.path.isdir(root):
            for d, _, names in os.walk(root):
                for n in sorted(names):
                    p = os.path.join(d, n)
                    if os.path.isfile(p) and not os.path.islink(p):
                        yield root, p
        elif os.path.isfile(root):
            yield os.path.dirname(root), root
        else:
            print(f"strip-check: {root} does not exist", file=sys.stderr)
            sys.exit(2)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--tolerate", action="append", default=[], metavar="GLOB",
                    help="file names (fnmatch) that are reported but do not fail the check")
    ap.add_argument("paths", nargs="+")
    args = ap.parse_args()
    rows, failures = [], 0
    for root, path in files(args.paths):
        result = inspect(path)
        if result is None:
            continue
        fmt, ok, detail = result
        shown = os.path.relpath(path, root) if root else path
        if ok:
            verdict = "stripped"
        elif any(fnmatch.fnmatch(os.path.basename(path), g) for g in args.tolerate):
            verdict = "unstripped, tolerated"
        else:
            verdict, failures = "**UNSTRIPPED**", failures + 1
        rows.append((shown, fmt, os.path.getsize(path), verdict, detail))
    if not rows:
        print("strip-check: no program or library found under the given paths", file=sys.stderr)
        sys.exit(2)
    print("| file | format | bytes | verdict | detail |")
    print("|---|---|---:|---|---|")
    for shown, fmt, size, verdict, detail in rows:
        print(f"| `{shown}` | {fmt} | {size:,} | {verdict} | {detail} |")
    print()
    print(f"strip-check: {len(rows)} binaries, {failures} unstripped")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
