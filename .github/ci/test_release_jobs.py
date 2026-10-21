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
"""Tests for the release jobs of mpvfx-ci.yml and the secret gating of mpvfx-macos.yml (owner ruling 2026-10-21: no OS
holds another back; the Apple ID is used only for a stable v<X.Y.Z> tag)."""
import os
import unittest

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STABLE = "startsWith(github.ref, 'refs/tags/v') && !contains(github.ref, '-')"


def workflow(name):
    with open(os.path.join(ROOT, ".github", "workflows", name), encoding="utf-8") as f:
        return yaml.safe_load(f)


def downloads(job):
    return {s["with"]["name"]: s.get("if") for s in job["steps"] if "download-artifact" in s.get("uses", "")}


class ReleaseJobs(unittest.TestCase):
    def setUp(self):
        self.jobs = workflow("mpvfx-ci.yml")["jobs"]

    def test_linux_and_windows_publish_without_waiting_for_macos(self):
        publish = self.jobs["publish"]
        self.assertNotIn("macos", publish["needs"])
        self.assertEqual(set(downloads(publish)), {"linux", "windows"})
        # main and prerelease tags only: a stable tag (no hyphen) is left to publish-macos.
        self.assertIn("refs/heads/main", publish["if"])
        self.assertIn("contains(github.ref, '-')", publish["if"])

    def test_macos_joins_the_same_release_after_publish(self):
        job = self.jobs["publish-macos"]
        self.assertIn("macos", job["needs"])
        self.assertIn("publish", job["needs"])      # ordered after publish, so the two never race
        self.assertTrue(job["if"].strip().startswith("always()"))   # runs whatever publish's result
        self.assertIn("needs.macos.result == 'success'", job["if"])
        self.assertIsNone(downloads(job)["macos"])

    def test_a_stable_tag_ships_every_os_or_none(self):
        job = self.jobs["publish-macos"]
        self.assertEqual(job["env"]["STABLE"], "${{ " + STABLE + " }}")
        self.assertEqual(downloads(job), {"linux": "env.STABLE == 'true'", "windows": "env.STABLE == 'true'",
                                          "macos": None})
        gate = next(s for s in job["steps"] if s.get("name", "").startswith("Every OS passed"))
        self.assertEqual(gate["if"], "env.STABLE == 'true'")
        for os_name in ("LINUX", "WINDOWS", "MACOS"):
            self.assertIn(os_name, gate["run"])
        self.assertIn("exit 1", gate["run"])

    def test_publish_macos_checkout_keeps_no_token(self):
        checkout = next(s for s in self.jobs["publish-macos"]["steps"] if "actions/checkout" in s.get("uses", ""))
        self.assertIs(checkout["with"]["persist-credentials"], False)


class MacosVerification(unittest.TestCase):
    """Owner ruling 2026-10-21: developer verification is tried wherever the secrets are and never fails the build;
    the disk image is named and released as Developer Verified or Developer Stamp Unverified."""

    def setUp(self):
        self.steps = [s for j in workflow("mpvfx-macos.yml")["jobs"].values() for s in j.get("steps", [])]

    def test_signing_and_apple_secrets_never_reach_a_pull_request(self):
        values = [v for s in self.steps for v in (s.get("env") or {}).values() if isinstance(v, str)]
        secret = [v for v in values if "secrets." in v]
        self.assertEqual(len(secret), 5)   # the certificate, its password, APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID
        for value in secret:
            self.assertTrue(value.startswith(
                "${{ github.event_name != 'pull_request' && github.event_name != 'merge_group' && secrets."), value)

    def test_verification_never_fails_the_build(self):
        package = next(s for s in self.steps if s.get("name", "").startswith("Package"))
        self.assertEqual(package["env"]["NOTARIZE_REQUIRED"], "0")
        self.assertIn("developer-verified", package["run"])
        self.assertIn("developer-stamp-unverified", package["run"])
        with open(os.path.join(ROOT, "mpvfx-swift", "packaging", "macos", "package.sh"), encoding="utf-8") as f:
            script = f.read()
        self.assertNotIn("notarization was not accepted\" >&2; exit 1", script)
        self.assertIn(': > "$dist/.not-notarized"', script)

    def test_the_release_labels_each_kind(self):
        with open(os.path.join(ROOT, ".github", "ci", "publish.sh"), encoding="utf-8") as f:
            script = f.read()
        self.assertIn('*-developer-verified.dmg) echo "#oneTake for macOS (Developer Verified)"', script)
        unverified = '*-developer-stamp-unverified.dmg) echo "#oneTake for macOS (Developer Stamp Unverified)"'
        self.assertIn(unverified, script)
        self.assertIn('files+=("$f$(asset_label "$f")")', script)


if __name__ == "__main__":
    unittest.main()
