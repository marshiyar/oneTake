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
"""Tests for crash_constructs.py: each construct is counted, each look-alike is not, the ratchet only goes down."""
import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
import unittest.mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("crash_constructs", os.path.join(HERE, "crash_constructs.py"))
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)


def kinds(src):
    return [k for k, _ in cc.scan(src)]


class Constructs(unittest.TestCase):
    def test_force_unwrap_forms(self):
        for src in ("let a = b!", "f()!", "a[i]!", "x!.y", "x!.y!.z", "$0!", "let p = q!, r = s!", "`default`!",
                    "self!.go()", "(a ?? b)!", "foo(bar: baz!)", "x! == y", "if x! { }"):
            with self.subTest(src=src):
                self.assertTrue(set(kinds(src)) == {"force-unwrap"}, kinds(src))
        self.assertEqual(kinds("let p = q!, r = s!"), ["force-unwrap", "force-unwrap"])
        self.assertEqual(kinds("x!.y!.z"), ["force-unwrap", "force-unwrap"])

    def test_force_unwrap_after_trailing_closure(self):
        self.assertEqual(kinds("let t = items.first { $0 > 1 }!"), ["force-unwrap"])
        self.assertEqual(kinds("xs.first { $0.key == k }!.value"), ["force-unwrap"])
        self.assertEqual(kinds("xs.first { $0.key == k }!= nil"), [])

    def test_parenthesised_unwrap_after_an_expression_colon(self):
        for src in ("use((maybe)!)", "let v = flag ? a : (maybe)!", 'let d = ["k": (maybe)!]', "f(label: (maybe)!)",
                    "self.init(p: (maybe)!)", "let v = (label: maybe)!", "[k: (maybe)!]", "case .a: (maybe)!"):
            with self.subTest(src=src):
                self.assertEqual(kinds(src), ["force-unwrap"])

    def test_backtick_escaped_keyword_is_an_expression(self):
        self.assertEqual(kinds("let `return`: Int? = 1\n`return`!"), ["force-unwrap"])

    def test_try_and_as_bang(self):
        self.assertEqual(kinds("let d = try! Data(contentsOf: u)"), ["try!"])
        self.assertEqual(kinds("let v = x as! View"), ["as!"])
        self.assertEqual(kinds("let v = (try! f()) as! T"), ["try!", "as!"])

    def test_calls(self):
        self.assertEqual(kinds('fatalError("no")'), ["fatalError"])
        self.assertEqual(kinds('Swift.fatalError("no")'), ["fatalError"])
        self.assertEqual(kinds("precondition(n > 0)"), ["precondition"])
        self.assertEqual(kinds('preconditionFailure ("x")'), ["precondition"])

    def test_line_numbers(self):
        self.assertEqual(cc.scan("let a = 1\n// x!\nlet b = c!\n"), [("force-unwrap", 3)])

    def test_unwrap_inside_interpolation_counts(self):
        self.assertEqual(kinds('let s = "v=\\(v!)"'), ["force-unwrap"])
        self.assertEqual(kinds('let s = "\\(f(a: "x!", b: m[k]!))"'), ["force-unwrap"])
        self.assertEqual(kinds('let s = #"raw \\#(v!) \\(w!)"#'), ["force-unwrap"])
        self.assertEqual(kinds('let s = """\n  a \\(v!)\n  b!\n  """'), ["force-unwrap"])


class LookAlikes(unittest.TestCase):
    def test_not_equal(self):
        self.assertEqual(kinds("if a != b, c !== d, e!=f, g!==h {}"), [])

    def test_prefix_not(self):
        self.assertEqual(kinds("if !flag && !(a || b), !x.isEmpty { return!y }\n#if !os(macOS)\n#endif"), [])

    def test_implicitly_unwrapped_types(self):
        for src in ("static var current: WindowsShell!", "var v: NSView!", "var m: Foo.Bar!", "func f() -> String!",
                    "var a: [String]!", "var d: [String: Int]!", "var h: (() -> Void)!", "var g: Array<Int>!",
                    "init(view: View!) {}", "@IBOutlet weak var label: NSTextField!"):
            with self.subTest(src=src):
                self.assertEqual(kinds(src), [])

    def test_labeled_tuple_iuo_uses_annotation_context(self):
        for src in ("var pair: (label: Int, other: String)!", "func f(pair: (a: Int, b: Int)!) {}",
                    "func g<T>(_ p: (a: T)!) {}", "init?(p: (x: Int)!) {}", "subscript(p: (x: Int)!) -> Int { 0 }",
                    "func h(a: Int, b: (x: Int)!) {}"):
            with self.subTest(src=src):
                self.assertEqual(kinds(src), [])
        self.assertEqual(kinds("let value = (label: maybe)!"), ["force-unwrap"])

    def test_array_iuo_by_declaration_context(self):
        for src in ("var a: [any P]!", "var b: [() -> Void]!", "var c: [(Int, Int)]!", "let d: [some P]!",
                    "func f(xs: [any P]!) {}"):
            with self.subTest(src=src):
                self.assertEqual(kinds(src), [])
        for src in ("let v = xs[i]!", "use(xs: [a]!)", "let v = flag ? a : [b]!"):
            with self.subTest(src=src):
                self.assertEqual(kinds(src), ["force-unwrap"])

    def test_strings(self):
        for src in ('let s = "Hello!"', 'let s = "a\\"b!"', 'let s = #"no "quote"! \\(v!) here"#',
                    'let s = ##"x"# y!"##', 'let s = """\n  wow! try! x as! y fatalError(\n  """',
                    'let s = "fatalError(\\"x\\")"', "let c: Character = \"!\""):
            with self.subTest(src=src):
                self.assertEqual(kinds(src), [])

    def test_comments(self):
        for src in ("// x! try! as! fatalError(", "/* a! */", "/* outer /* inner! */ still! */",
                    "/// - Precondition: x!\nlet a = 1", "let a = 1 // b!"):
            with self.subTest(src=src):
                self.assertEqual(kinds(src), [])
        self.assertEqual(kinds("/* a /* b */ c! */ d!"), ["force-unwrap"])

    def test_regex_literal(self):
        self.assertEqual(kinds('let r = #/a!b/#'), [])

    def test_regex_escaped_delimiter_and_interpolation(self):
        self.assertEqual(kinds(r'let r = #/a\/#b!c/#'), [])
        self.assertEqual(kinds(r'let r = #/a\#(value!)b/#'), ["force-unwrap"])
        self.assertEqual(kinds(r'let r = ##/a\##(other!)b/##'), ["force-unwrap"])

    def test_own_methods_and_definitions(self):
        self.assertEqual(kinds("func fatalError(_ m: String) -> Never { exit(1) }\nlog.precondition(x)\nmyfatalError(1)"),
                         [])

    def test_identifiers_containing_try_or_as(self):
        self.assertEqual(kinds("retry!.go(); alias!.x"), ["force-unwrap", "force-unwrap"])


class Ratchet(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.makedirs(os.path.join(self.root, "mpvfx-swift/Sources/M"))
        os.makedirs(os.path.join(self.root, ".github/ci"))
        self.baseline = os.path.join(self.root, cc.BASELINE_REL)
        self.write("A.swift", "let a = b!\nlet c = try! d()\n")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, text):
        with open(os.path.join(self.root, "mpvfx-swift/Sources/M", name), "w") as f:
            f.write(text)

    def run_main(self, *args):
        self.out = io.StringIO()
        # Under Actions the script also appends to the job summary; a test run must not.
        with contextlib.redirect_stdout(self.out), contextlib.redirect_stderr(self.out), \
                unittest.mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}):
            return cc.main(["--root", self.root, *args])

    def counts(self):
        with open(self.baseline) as f:
            return json.load(f)["counts"]

    def test_init_then_within_baseline(self):
        self.assertEqual(self.run_main("--init"), 0)
        self.assertEqual(self.counts(), {"mpvfx-swift/Sources/M/A.swift": {"force-unwrap": 1, "try!": 1}})
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(self.run_main("--init"), 2, "init never overwrites a baseline")

    def test_rise_fails_and_new_file_fails(self):
        self.run_main("--init")
        self.write("A.swift", "let a = b!\nlet c = try! d()\nlet e = f!\n")
        self.assertEqual(self.run_main(), 1)
        self.write("A.swift", "let a = b!\nlet c = try! d()\n")
        self.write("B.swift", "fatalError()\n")
        self.assertEqual(self.run_main(), 1)

    def test_kinds_ratchet_separately(self):
        self.run_main("--init")
        self.write("A.swift", "let a = b as! T\nlet c = try! d()\n")   # one unwrap traded for an as!
        self.assertEqual(self.run_main(), 1)

    def test_update_lowers_and_refuses_to_raise(self):
        self.run_main("--init")
        self.write("A.swift", "let c = try! d()\n")
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(self.run_main("--update"), 0)
        self.assertEqual(self.counts(), {"mpvfx-swift/Sources/M/A.swift": {"try!": 1}})
        self.write("A.swift", "let c = try! d()\nlet e = try! f()\n")
        self.assertEqual(self.run_main("--update"), 2)
        self.assertEqual(self.counts(), {"mpvfx-swift/Sources/M/A.swift": {"try!": 1}}, "a refused update writes nothing")

    def test_deleted_file_drops_out_on_update(self):
        self.run_main("--init")
        os.remove(os.path.join(self.root, "mpvfx-swift/Sources/M/A.swift"))
        self.assertEqual(self.run_main("--update"), 0)
        self.assertEqual(self.counts(), {})

    def test_bad_baseline(self):
        with open(self.baseline, "w") as f:
            json.dump({"counts": {"x.swift": {"force-unwrap": -1}}}, f)
        self.assertEqual(self.run_main(), 2)

    def test_new_occurrences_against_base(self):
        old = "let a = b!\nlet c = d!\n"
        new = "let z = y!\nlet a = b!\nlet c = d!\n"
        self.assertEqual(cc.new_occurrences(new, cc.scan(new), "force-unwrap", old), [1])
        self.assertEqual(cc.new_occurrences(new, cc.scan(new), "force-unwrap", None), [1, 2, 3])

    def test_base_revision_from_git(self):
        def git(*a):
            subprocess.run(["git", "-C", self.root, *a], check=True, capture_output=True)
        git("init", "-q")
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base")
        self.run_main("--init")
        self.write("A.swift", "let n = m!\nlet a = b!\nlet c = try! d()\n")
        self.assertEqual(cc.new_occurrences(cc.read(self.root, "mpvfx-swift/Sources/M/A.swift"),
                                            cc.scan("let n = m!\nlet a = b!\nlet c = try! d()\n"), "force-unwrap",
                                            cc.base_text(self.root, "HEAD", "mpvfx-swift/Sources/M/A.swift")), [1])
        self.assertEqual(self.run_main("--base", "HEAD"), 1)
        self.assertIn("A.swift:1`", self.out.getvalue())
        self.assertNotIn("A.swift:2`", self.out.getvalue(), "an occurrence the base has is not new")

    def test_base_revision_rejects_baseline_increases_and_allows_rename(self):
        def git(*a):
            subprocess.run(["git", "-C", self.root, *a], check=True, capture_output=True)
        git("init", "-q")
        git("add", "mpvfx-swift/Sources/M/A.swift")
        self.assertEqual(self.run_main("--init"), 0)
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base")

        old = os.path.join(self.root, "mpvfx-swift/Sources/M/A.swift")
        new = os.path.join(self.root, "mpvfx-swift/Sources/M/Renamed.swift")
        os.rename(old, new)
        with open(self.baseline, "w") as f:
            json.dump({"counts": {"mpvfx-swift/Sources/M/Renamed.swift": {"force-unwrap": 1, "try!": 1}}}, f)
        git("add", "-A")
        self.assertEqual(self.run_main("--base", "HEAD"), 0, self.out.getvalue())

        self.write("New.swift", "fatalError()\n")
        with open(self.baseline, "w") as f:
            json.dump({"counts": {"mpvfx-swift/Sources/M/Renamed.swift": {"force-unwrap": 2, "try!": 1},
                                  "mpvfx-swift/Sources/M/New.swift": {"fatalError": 1}}}, f)
        self.assertEqual(self.run_main("--base", "HEAD"), 1)
        output = self.out.getvalue()
        self.assertIn("Renamed.swift`: force-unwrap; base 1, new 2", output)
        self.assertIn("New.swift`: fatalError; base 0, new 1", output)

    def git(self, *a):
        subprocess.run(["git", "-C", self.root, *a], check=True, capture_output=True)

    def commit_base(self, text):
        self.write("A.swift", text)
        self.git("init", "-q")
        self.git("add", "mpvfx-swift/Sources/M/A.swift")
        self.assertEqual(self.run_main("--init"), 0)
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base")

    def set_baseline(self, counts):
        with open(self.baseline, "w") as f:
            json.dump({"counts": {f"mpvfx-swift/Sources/M/{k}": v for k, v in counts.items()}}, f)

    def test_renamed_file_reports_only_occurrences_new_since_the_old_path(self):
        body = "".join(f"let v{i} = value{i} + {i}\n" for i in range(12))
        self.commit_base("let a = b!\n" + body)
        os.remove(os.path.join(self.root, "mpvfx-swift/Sources/M/A.swift"))
        self.write("Renamed.swift", "let a = b!\n" + body + "let z = y!\n")
        self.set_baseline({"Renamed.swift": {"force-unwrap": 1}})
        self.git("add", "-A")
        self.assertEqual(self.run_main("--base", "HEAD"), 1)
        output = self.out.getvalue()
        self.assertIn("force-unwrap 1 -> 2; new occurrence(s):", output)
        self.assertIn("Renamed.swift:14`", output)
        self.assertNotIn("Renamed.swift:1`", output, "an occurrence the old path had is not new")

    def test_split_file_shares_its_base_count(self):
        first = "".join(f"let a{i} = first{i}!\nlet p{i} = alpha + {i}\n" for i in range(4))
        second = "".join(f"let b{i} = second{i}!\nlet q{i} = beta * {i}\n" for i in range(4))
        self.commit_base(first + second)
        os.remove(os.path.join(self.root, "mpvfx-swift/Sources/M/A.swift"))
        self.write("First.swift", first)
        self.write("Second.swift", second)
        self.set_baseline({"First.swift": {"force-unwrap": 4}, "Second.swift": {"force-unwrap": 4}})
        self.git("add", "-A")
        self.assertEqual(self.run_main("--base", "HEAD"), 0, self.out.getvalue())
        self.set_baseline({"First.swift": {"force-unwrap": 5}, "Second.swift": {"force-unwrap": 4}})
        self.assertEqual(self.run_main("--base", "HEAD"), 1)
        self.assertIn("First.swift + mpvfx-swift/Sources/M/Second.swift`: force-unwrap; base 8, new 9",
                      self.out.getvalue())

    def test_copy_of_a_kept_file_gets_no_allowance(self):
        self.assertEqual(cc.parse_name_status("C080\ta.swift\tb.swift\nM\ta.swift\n"), {})
        self.assertEqual(cc.parse_name_status("C080\ta.swift\tb.swift\nR090\ta.swift\tc.swift\n"),
                         {"b.swift": "a.swift", "c.swift": "a.swift"})
        self.assertEqual(cc.parse_name_status("C080\ta.swift\tb.swift\nD\ta.swift\n"), {"b.swift": "a.swift"})


if __name__ == "__main__":
    unittest.main()
