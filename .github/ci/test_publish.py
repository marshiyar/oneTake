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
"""Tests for publish.sh: which release each ref makes (decide), what its notes say, and what pruning deletes.

Each case sources publish.sh in bash inside a temporary directory holding mpvfx-swift/packaging/VERSION (0.1.0), so
no GitHub call is made; pruning runs against a stand-in `gh` on PATH that records what it was asked to delete."""
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PUBLISH = os.path.join(HERE, "publish.sh")
SHA = "0123456789abcdef0123456789abcdef01234567"

DUMP = 'decide; printf "mode=%s\\nchannel=%s\\ntag=%s\\ntitle=%s\\nflags=%s\\n" ' \
       '"$mode" "$channel" "$tag" "$title" "${flags[*]-}"'


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        os.makedirs(os.path.join(self.dir, "mpvfx-swift", "packaging"))
        with open(os.path.join(self.dir, "mpvfx-swift", "packaging", "VERSION"), "w", encoding="utf-8") as f:
            f.write("0.1.0\n")

    def bash(self, script, ref_type="tag", ref="", extra_env=None, stdin=""):
        """Run a fixed bash snippet after sourcing publish.sh. Every varying value reaches it through the
        environment or stdin, never through the script text."""
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GITHUB_REF_TYPE": ref_type, "GITHUB_REF_NAME": ref,
               "GITHUB_SHA": SHA, "GITHUB_REPOSITORY": "o/r", "GITHUB_RUN_ID": "42", "PUBLISH_SH": PUBLISH}
        env.update(extra_env or {})
        env["SNIPPET"] = script
        return subprocess.run(["bash", "-c", '. "$PUBLISH_SH"; eval "$SNIPPET"'], cwd=self.dir, env=env,
                              input=stdin, capture_output=True, text=True, timeout=30, check=False)

    def stub_gh(self, body):
        """A stand-in gh: publish.sh's calls go to a shell function running this script (no executable file)."""
        path = os.path.join(self.dir, "gh-stub.sh")
        with open(path, "w", encoding="utf-8") as f:
            f.write(body)
        return path

    def decide(self, ref, ref_type="tag"):
        r = self.bash(DUMP, ref_type, ref)
        out = dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line and not line.startswith("::"))
        return r, out


class Decide(Base):
    def test_main_is_a_nightly(self):
        r, d = self.decide("main", "branch")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((d["mode"], d["channel"], d["tag"]), ("nightly", "nightly", "nightly-0123456"))
        self.assertRegex(d["title"], r"^oneTake nightly \d{4}-\d{2}-\d{2} \(0123456\), development build$")
        self.assertIn("--prerelease", d["flags"])
        self.assertIn("--latest=false", d["flags"])
        self.assertIn(f"--target {SHA}", d["flags"])

    def test_stable_tag_is_latest(self):
        r, d = self.decide("v0.1.0")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((d["mode"], d["channel"], d["tag"], d["title"]), ("official", "stable", "v0.1.0", "oneTake 0.1.0"))
        self.assertEqual(d["flags"], "--verify-tag --latest")

    def check_prerelease(self, ref, channel, title):
        r, d = self.decide(ref)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((d["mode"], d["channel"], d["tag"], d["title"]), ("prerelease", channel, ref, title))
        self.assertEqual(d["flags"], "--verify-tag --prerelease --latest=false")
        self.assertNotIn("--latest ", d["flags"] + " ")

    def test_alpha(self):
        self.check_prerelease("v0.1.0-alpha.1", "alpha", "oneTake 0.1.0 alpha 1")

    def test_beta(self):
        self.check_prerelease("v0.1.0-beta.2", "beta", "oneTake 0.1.0 beta 2")

    def test_rc(self):
        self.check_prerelease("v0.1.0-rc.1", "rc", "oneTake 0.1.0 RC 1")

    def test_prerelease_version_must_match(self):
        r, _ = self.decide("v0.2.0-beta.1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("::error::tag v0.2.0-beta.1 is version 0.2.0 but", r.stdout)
        self.assertIn("says 0.1.0", r.stdout)

    def test_stable_version_must_match(self):
        r, _ = self.decide("v0.2.0")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("::error::", r.stdout)

    def test_unknown_suffix_is_refused(self):
        for ref in ("v0.1.0-foo", "v0.1.0-beta", "v0.1.0-beta.0", "v0.1.0-beta.01", "v0.1.0-Beta.1",
                    "v0.1.0-beta.1.2", "v0.1.0-alpha.1-rc.1", "v0.1.0-"):
            with self.subTest(ref=ref):
                r, d = self.decide(ref)
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertIn("must be alpha.<N>, beta.<N> or rc.<N>", r.stdout)
                self.assertNotIn("mode", d)

    def test_non_v_tag_publishes_nothing(self):
        r, d = self.decide("media-v1.2.3")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((d["mode"], d["tag"]), ("none", ""))
        self.assertIn("not a v* release tag", r.stdout)

    def test_other_branch_publishes_nothing(self):
        r, d = self.decide("feature/x", "branch")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(d["mode"], "none")


ASSETS = ("MpVFX-0.1.0-macos-arm64.dmg", "mpvfx_0.1.0_amd64.deb", "MpVFX-0.1.0-setup.exe",
          "MpVFX-0.1.0-linux-x86_64.tar.gz", "MpVFX-0.1.0-windows-x64.zip", "mac-smoke.png", "linux-smoke.png",
          "windows-smoke.png")
NOT_NOTARIZED = "macOS: not notarized: right-click → Open the first time"
NOTES = 'decide >/dev/null; mapfile -t assets < <(printf "%s" "$ASSETS"); changes_md=$CHANGES; notes'


class Notes(Base):
    def notes(self, ref, ref_type="tag", marker=None, hidden_marker=False, assets=ASSETS, changes="- x"):
        if marker is not None or hidden_marker:
            os.makedirs(os.path.join(self.dir, "dist"), exist_ok=True)
        if marker is not None:
            with open(os.path.join(self.dir, "dist", "macos-notarization.txt"), "w", encoding="utf-8") as f:
                f.write(marker + "\n")
        if hidden_marker:
            open(os.path.join(self.dir, "dist", ".not-notarized"), "w", encoding="utf-8").close()
        r = self.bash(NOTES, ref_type, ref, {"ASSETS": "\n".join(assets), "CHANGES": changes})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def test_banner_is_the_first_line_and_distinct_per_channel(self):
        cases = (("main", "branch", "> [!WARNING]", "> **Nightly**:"),
                 ("v0.1.0-alpha.1", "tag", "> [!WARNING]",
                  "> **Alpha**: early test build for testers; expect bugs. Not for real projects."),
                 ("v0.1.0-beta.2", "tag", "> [!NOTE]", "> **Beta**:"),
                 ("v0.1.0-rc.1", "tag", "> [!NOTE]", "> **Release candidate**: this build becomes v0.1.0 unless"),
                 ("v0.1.0", "tag", "> **Stable**: the official oneTake 0.1.0 release.", None))
        seen = set()
        for ref, ref_type, first, second in cases:
            with self.subTest(ref=ref):
                lines = self.notes(ref, ref_type, marker="notarized").splitlines()
                self.assertEqual(lines[0], first)
                if second:
                    self.assertTrue(lines[1].startswith(second), lines[1])
                seen.add(lines[1] if second else lines[0])
        self.assertEqual(len(seen), len(cases))

    def test_prereleases_say_test_build(self):
        for ref in ("v0.1.0-alpha.1", "v0.1.0-beta.2", "v0.1.0-rc.1"):
            with self.subTest(ref=ref):
                self.assertIn("This is a test build, not a stable release", self.notes(ref, marker="notarized"))
        self.assertNotIn("test build", self.notes("v0.1.0", marker="notarized"))

    def test_screenshots_embedded_per_os(self):
        text = self.notes("v0.1.0-beta.1", marker="notarized")
        base = "https://github.com/o/r/releases/download/v0.1.0-beta.1"
        for os_name, png in (("macOS", "mac-smoke.png"), ("Linux", "linux-smoke.png"), ("Windows", "windows-smoke.png")):
            self.assertIn(f"![{os_name}]({base}/{png})", text)
        self.assertEqual(text.count("!["), 3)

    def test_download_table_one_row_per_os(self):
        text = self.notes("main", "branch", marker="notarized")
        base = "https://github.com/o/r/releases/download/nightly-0123456"
        self.assertIn("| OS | File | Install |", text)
        rows = [line for line in text.splitlines() if line.startswith(("| macOS |", "| Windows |", "| Linux |"))]
        self.assertEqual(len(rows), 3, text)
        mac, win, linux = rows
        self.assertIn(f"[`MpVFX-0.1.0-macos-arm64.dmg`]({base}/MpVFX-0.1.0-macos-arm64.dmg) disk image", mac)
        self.assertIn("`MpVFX-0.1.0-setup.exe`", win)
        self.assertIn("installer", win)
        self.assertIn("portable zip", win)
        self.assertIn("Unsigned", win)
        self.assertIn(f"https://github.com/o/r/blob/{SHA}/README.md#download", win)
        self.assertIn("Debian package", linux)
        self.assertIn("portable archive", linux)
        self.assertNotIn("not notarized", text)

    def test_missing_installer_is_said(self):
        text = self.notes("v0.1.0", marker="notarized", assets=("mpvfx_0.1.0_amd64.deb",))
        self.assertIn("| macOS | not in this build |", text)
        self.assertNotIn("![", text)

    def test_not_notarized_line(self):
        for kwargs in ({"marker": "not-notarized"}, {}, {"marker": "notarized", "hidden_marker": True}):
            with self.subTest(**kwargs):
                text = self.notes("v0.1.0-alpha.1", **kwargs)
                self.assertIn(NOT_NOTARIZED, text)
                mac = next(line for line in text.splitlines() if line.startswith("| macOS |"))
                self.assertIn("Not notarized: right-click → Open the first time.", mac)
                shutil.rmtree(os.path.join(self.dir, "dist"), ignore_errors=True)

    def test_not_notarized_line_on_every_channel(self):
        for ref, ref_type in (("main", "branch"), ("v0.1.0-alpha.1", "tag"), ("v0.1.0-beta.1", "tag"),
                              ("v0.1.0-rc.1", "tag"), ("v0.1.0", "tag")):
            with self.subTest(ref=ref):
                self.assertIn(NOT_NOTARIZED, self.notes(ref, ref_type, marker="not-notarized"))
                shutil.rmtree(os.path.join(self.dir, "dist"), ignore_errors=True)

    def test_what_changed_and_links(self):
        text = self.notes("v0.1.0-beta.1", marker="notarized", changes="- Fix export (#12)")
        self.assertIn("## What changed\n\n- Fix export (#12)", text)
        self.assertIn(f"Commit: https://github.com/o/r/commit/{SHA}", text)
        self.assertIn("Run: https://github.com/o/r/actions/runs/42", text)


class Notarization(unittest.TestCase):
    """Notarization never blocks a build on any ref (owner, 2026-10-21); the marker reaches the publish job."""

    def test_workflow_never_requires_notarization(self):
        with open(os.path.join(HERE, "..", "workflows", "mpvfx-macos.yml"), encoding="utf-8") as f:
            text = f.read()
        values = [line.split(":", 1)[1].strip() for line in text.splitlines()
                  if line.strip().startswith("NOTARIZE_REQUIRED:")]
        self.assertEqual(values, ["'0'"])
        self.assertIn("dist/macos-notarization.txt", text)

    def test_package_script_marks_a_rejected_verdict(self):
        path = os.path.join(HERE, "..", "..", "mpvfx-swift", "packaging", "macos", "package.sh")
        with open(path, encoding="utf-8") as f:
            text = f.read()
        verdict = text[text.index('grep -q \'"status" *: *"Accepted"\''):text.index("xcrun stapler staple")]
        self.assertIn('NOTARIZE_REQUIRED:-1}" = 1', verdict)
        self.assertIn(': > "$dist/.not-notarized"', verdict)
        self.assertIn("exit 0", verdict)

    def test_package_script_signs_without_credentials(self):
        path = os.path.join(HERE, "..", "..", "mpvfx-swift", "packaging", "macos", "package.sh")
        with open(path, encoding="utf-8") as f:
            text = f.read()
        creds = text[text.index('if [ -z "${APPLE_ID:-}" ]'):text.index("  adhoc) ;;")]
        self.assertIn('NOTARIZE_REQUIRED:-1}" = 1', creds)
        self.assertIn("skip_notarize=1", creds)
        skip = text[text.index('if [ "${skip_notarize:-0}" = 1 ]'):text.index("xcrun notarytool submit")]
        self.assertIn(': > "$dist/.not-notarized"', skip)
        # The image is signed before the skip, so a missing credential never ships it unsigned.
        self.assertLess(text.index('codesign --force --sign "$MACOS_SIGN_IDENTITY" --timestamp "$dmg"'),
                        text.index('if [ "${skip_notarize:-0}" = 1 ]'))


class Changes(Base):
    def test_channel_of(self):
        r = self.bash('for t in nightly-abc1234 v0.1.0-alpha.1 v0.1.0-beta.2 v0.1.0-rc.1 v0.1.0 build-main-7 v0.1.0-foo;'
                      ' do printf "%s=%s\\n" "$t" "$(channel_of "$t")"; done')
        self.assertEqual(r.stdout.split(), ["nightly-abc1234=nightly", "v0.1.0-alpha.1=alpha", "v0.1.0-beta.2=beta",
                                            "v0.1.0-rc.1=rc", "v0.1.0=stable", "build-main-7=", "v0.1.0-foo="])

    def previous(self, tag, channel, tags):
        r = self.bash('previous_release "$TAG" "$CHANNEL"', extra_env={"TAG": tag, "CHANNEL": channel},
                      stdin="".join(t + "\n" for t in tags))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout.strip()

    def test_previous_release_of_same_or_higher_channel(self):
        newest_first = ["nightly-ccccccc", "v0.1.0-beta.2", "nightly-bbbbbbb", "v0.1.0-alpha.1", "build-main-9",
                        "v0.0.9"]
        self.assertEqual(self.previous("v0.1.0-beta.3", "beta", newest_first), "v0.1.0-beta.2")
        self.assertEqual(self.previous("v0.1.0-alpha.2", "alpha", newest_first), "v0.1.0-beta.2")
        self.assertEqual(self.previous("v0.1.0-rc.1", "rc", newest_first), "v0.0.9")
        self.assertEqual(self.previous("v0.1.0", "stable", newest_first), "v0.0.9")
        self.assertEqual(self.previous("nightly-ddddddd", "nightly", newest_first), "nightly-ccccccc")
        self.assertEqual(self.previous("nightly-ccccccc", "nightly", newest_first), "v0.1.0-beta.2")
        self.assertEqual(self.previous("v0.1.0", "stable", ["v0.1.0", "v0.1.0-rc.1"]), "")

    def fmt(self, subjects, total):
        r = self.bash('format_changes v0.1.0-beta.1 "$TOTAL"', extra_env={"TOTAL": str(total)},
                      stdin="".join(s + "\n" for s in subjects))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout.splitlines()

    def test_pull_request_numbers_are_linked(self):
        self.assertEqual(self.fmt(["Open recent projects (#76)", "plain subject"], 2),
                         ["- Open recent projects ([#76](https://github.com/o/r/pull/76))", "- plain subject"])

    def test_list_is_bounded_to_50(self):
        lines = self.fmt([f"change {i} (#{i})" for i in range(60)], 300)
        self.assertEqual(len(lines), 51)
        self.assertTrue(lines[-1].startswith("- ... and 250 more: [all changes since v0.1.0-beta.1]"
                                             "(https://github.com/o/r/compare/v0.1.0-beta.1..."), lines[-1])

    def test_no_changes(self):
        self.assertEqual(self.fmt([], 0), ["No changes since v0.1.0-beta.1."])


class Main(Base):
    """main() against a stand-in gh: the order of the calls and the notes it writes."""

    def test_beta_publish_creates_uploads_then_edits_notes(self):
        os.makedirs(os.path.join(self.dir, "dist"))
        for a in ("MpVFX-0.1.0-macos-arm64.dmg", "mac-smoke.png"):
            open(os.path.join(self.dir, "dist", a), "w", encoding="utf-8").close()
        log = os.path.join(self.dir, "gh.log")
        notes_copy = os.path.join(self.dir, "notes.md")
        stub = self.stub_gh('echo "$*" >> "$GH_LOG"\n'
                            'case "$1 $2" in\n'
                            '  "release view") [[ " $* " == *" --json "* ]] && exit 0; exit 1 ;;\n'
                            '  "release list") printf "%s\\n" nightly-aaaaaaa v0.1.0-beta.1 v0.1.0-alpha.1 ;;\n'
                            '  "release edit") while [ $# -gt 0 ]; do [ "$1" = --notes-file ] && cp "$2" "$NOTES_COPY";'
                            ' shift; done ;;\n'
                            '  "api repos/o/r/compare/v0.1.0-beta.1..."*)'
                            ' printf "2\\nFix export (#12)\\nAdd beta channel (#11)\\n" ;;\n'
                            'esac\n')
        r = self.bash('gh() { bash "$GH_STUB" "$@"; }; main dist/*.dmg dist/*.deb dist/*-smoke.png', "tag",
                      "v0.1.0-beta.2", {"GH_STUB": stub, "GH_LOG": log, "NOTES_COPY": notes_copy})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(log, encoding="utf-8") as f:
            calls = [line.split()[:2] for line in f]
        verbs = [" ".join(c) for c in calls if c[0] == "release"]
        self.assertEqual(verbs[-4:-1], ["release create", "release upload", "release edit"])
        with open(log, encoding="utf-8") as f:
            create = next(line for line in f if line.startswith("release create"))
        self.assertIn("--prerelease --latest=false", create)
        self.assertIn("--title oneTake 0.1.0 beta 2", create)
        with open(notes_copy, encoding="utf-8") as f:
            text = f.read()
        self.assertTrue(text.startswith("> [!NOTE]\n> **Beta**:"), text)
        self.assertIn("Since [v0.1.0-beta.1](https://github.com/o/r/releases/tag/v0.1.0-beta.1):", text)
        self.assertIn("- Fix export ([#12](https://github.com/o/r/pull/12))", text)
        self.assertIn("![macOS](https://github.com/o/r/releases/download/v0.1.0-beta.2/mac-smoke.png)", text)
        self.assertIn(NOT_NOTARIZED, text)


class Prune(Base):
    def test_only_old_nightlies_are_deleted(self):
        log = os.path.join(self.dir, "gh.log")
        # The stand-in ignores --jq and lists every tag, so the case guard in prune_nightlies is what is tested.
        stub = self.stub_gh('if [ "$1 $2" = "release list" ]; then\n'
                            '  printf "%s\\n" nightly-aaaaaaa v0.1.0 v0.1.0-alpha.1 v0.1.0-beta.2 v0.1.0-rc.1'
                            ' nightly-bbbbbbb\n'
                            'else echo "$@" >> "$GH_LOG"; fi\n')
        r = self.bash('gh() { bash "$GH_STUB" "$@"; }; prune_nightlies', extra_env={"GH_STUB": stub, "GH_LOG": log})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(log, encoding="utf-8") as f:
            deleted = [line.split()[2] for line in f]
        self.assertEqual(deleted, ["nightly-aaaaaaa", "nightly-bbbbbbb"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
