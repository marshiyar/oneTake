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
import os, shutil, subprocess, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PUBLISH = os.path.join(HERE, "publish.sh")
SHA = "0123456789abcdef0123456789abcdef01234567"
BASH = shutil.which("bash") or "/bin/bash"

DUMP = 'decide; printf "mode=%s\\nchannel=%s\\ntag=%s\\ntitle=%s\\nflags=%s\\n" ' \
       '"$mode" "$channel" "$tag" "$title" "${flags[*]-}"'


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir)
        os.makedirs(os.path.join(self.dir, "mpvfx-swift", "packaging"))
        with open(os.path.join(self.dir, "mpvfx-swift", "packaging", "VERSION"), "w") as f:
            f.write("0.1.0\n")

    def bash(self, script, ref_type="tag", ref="", extra_env=None):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GITHUB_REF_TYPE": ref_type, "GITHUB_REF_NAME": ref,
               "GITHUB_SHA": SHA, "GITHUB_REPOSITORY": "o/r", "GITHUB_RUN_ID": "42"}
        env.update(extra_env or {})
        return subprocess.run([BASH, "-c", f'. "{PUBLISH}"; {script}'], cwd=self.dir, env=env,
                              capture_output=True, text=True, timeout=30)

    def decide(self, ref, ref_type="tag"):
        r = self.bash(DUMP, ref_type, ref)
        out = dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line and not line.startswith("::"))
        return r, out


class Decide(Base):
    def test_main_is_a_nightly(self):
        r, d = self.decide("main", "branch")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((d["mode"], d["channel"], d["tag"]), ("nightly", "nightly", "nightly-0123456"))
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


class Notes(Base):
    def notes(self, ref, ref_type="tag", marker=None):
        if marker is not None:
            os.makedirs(os.path.join(self.dir, "dist"))
            with open(os.path.join(self.dir, "dist", "macos-notarization.txt"), "w") as f:
                f.write(marker + "\n")
        r = self.bash("decide >/dev/null; notes", ref_type, ref)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def test_prerelease_notes_name_the_channel_and_say_test_build(self):
        for ref, words in (("v0.1.0-alpha.1", "Alpha channel"), ("v0.1.0-beta.2", "Beta channel"),
                           ("v0.1.0-rc.1", "Release-candidate channel")):
            with self.subTest(ref=ref):
                text = self.notes(ref, marker="notarized")
                self.assertIn("This is a test build, not a stable release", text)
                self.assertIn(words, text)
                self.assertIn(f"https://github.com/o/r/commit/{SHA}", text)
                self.assertNotIn("not notarized", text)
                shutil.rmtree(os.path.join(self.dir, "dist"))

    def test_rc_notes_name_the_stable_version(self):
        self.assertIn("becomes v0.1.0 unless", self.notes("v0.1.0-rc.1", marker="notarized"))

    def test_unnotarized_build_says_how_to_open(self):
        text = self.notes("v0.1.0-beta.1", marker="not-notarized")
        self.assertIn("not notarized", text)
        self.assertIn("right-click", text)
        self.assertIn("Open", text)

    def test_missing_marker_counts_as_unnotarized(self):
        self.assertIn("not notarized", self.notes("main", "branch"))

    def test_notarized_stable_notes_have_no_gatekeeper_hint(self):
        text = self.notes("v0.1.0", marker="notarized")
        self.assertIn("oneTake 0.1.0, built from", text)
        self.assertNotIn("not notarized", text)


class Prune(Base):
    def test_only_old_nightlies_are_deleted(self):
        bindir = os.path.join(self.dir, "bin")
        os.makedirs(bindir)
        log = os.path.join(self.dir, "gh.log")
        # The stand-in ignores --jq and lists every tag, so the case guard in prune_nightlies is what is tested.
        with open(os.path.join(bindir, "gh"), "w") as f:
            f.write('#!/bin/sh\n'
                    'if [ "$1 $2" = "release list" ]; then\n'
                    '  printf "%s\\n" nightly-aaaaaaa v0.1.0 v0.1.0-alpha.1 v0.1.0-beta.2 v0.1.0-rc.1 nightly-bbbbbbb\n'
                    'else echo "$@" >> "$GH_LOG"; fi\n')
        os.chmod(os.path.join(bindir, "gh"), 0o755)
        r = self.bash("prune_nightlies", extra_env={"PATH": bindir + os.pathsep + os.environ.get("PATH", ""),
                                                    "GH_LOG": log})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        with open(log) as f:
            deleted = [line.split()[2] for line in f]
        self.assertEqual(deleted, ["nightly-aaaaaaa", "nightly-bbbbbbb"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
