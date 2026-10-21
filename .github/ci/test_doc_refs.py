#!/usr/bin/env python3
"""Tests of doc_refs.py: each kind of broken reference is found, and what is not a reference is left alone."""
import importlib.util, os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("doc_refs", os.path.join(HERE, "doc_refs.py"))
doc_refs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(doc_refs)


class DocRefsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.saved_root, doc_refs.ROOT = doc_refs.ROOT, self.root
        for rel, lines in {"mpvfx-swift/Sources/Mod/A.swift": 10, "mpvfx-swift/docs/OTHER.md": 1,
                           ".github/ci/x.py": 1}.items():
            path = os.path.join(self.root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write("x\n" * lines)

    def tearDown(self):
        doc_refs.ROOT = self.saved_root
        self.tmp.cleanup()

    def run_on(self, text):
        md = "mpvfx-swift/docs/T.md"
        with open(os.path.join(self.root, md), "w") as f:
            f.write(text)
        findings, warnings, issues, seen = [], [], [], {"paths": 0, "names": 0, "links": 0}
        doc_refs.check_file(md, {"A.swift", "x.py"}, findings, warnings, issues, seen)
        return findings, warnings, issues

    def test_existing_paths_pass_from_root_app_and_own_folder(self):
        f, w, _ = self.run_on("`Sources/Mod/A.swift` `mpvfx-swift/Sources/Mod/` `.github/ci/x.py` `docs/OTHER.md` "
                              "`Sources/*/A.swift` `A.swift` [o](OTHER.md#top) [s](../Sources/Mod/A.swift)\n")
        self.assertEqual((f, w), ([], []))

    def test_missing_path_name_and_link_are_broken(self):
        f, _, _ = self.run_on("`Sources/Mod/Gone.swift` `Gone.swift` [x](MISSING.md) `Sources/*/Gone.swift`\n")
        self.assertEqual(len(f), 4, f)

    def test_line_past_the_end_is_a_warning_only(self):
        f, w, _ = self.run_on("`Sources/Mod/A.swift:5` `Sources/Mod/A.swift:8-40`\n")
        self.assertEqual(f, [])
        self.assertEqual(len(w), 1, w)

    def test_not_references(self):
        text = ("```\n`Sources/Inside/Fence.swift` #999\n```\n"
                "`swift build -c release` `project.json` `mpvfx_media.h` `$HOME/x` `/usr/include/vulkan/vulkan.h` "
                "[web](https://example.com/a) `../mpvfx-agents/x`\n"
                "| `noir` | #000000 #ffffff #1100 |\n")
        f, w, issues = self.run_on(text)
        self.assertEqual((f, w, issues), ([], [], []))

    def test_issue_references_are_collected(self):
        _, _, issues = self.run_on("closes #12, see [#34](https://github.com/marshiyar/oneTake/issues/34) and "
                                   "https://github.com/other/repo/pull/7 and `#if os(Linux)`\n")
        self.assertEqual(sorted(((r or ""), n) for r, n, _ in issues),
                         [("", 12), ("marshiyar/oneTake", 34), ("other/repo", 7)])


if __name__ == "__main__":
    unittest.main(verbosity=2) if "-v" in sys.argv else unittest.main()
