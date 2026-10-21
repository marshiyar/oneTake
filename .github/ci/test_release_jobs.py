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


class MacosSecrets(unittest.TestCase):
    def test_signing_and_apple_secrets_reach_only_a_stable_tag(self):
        seen = 0
        for job in workflow("mpvfx-macos.yml")["jobs"].values():
            for step in job.get("steps", []):
                for key, value in (step.get("env") or {}).items():
                    if isinstance(value, str) and "secrets." in value:
                        seen += 1
                        self.assertTrue(value.startswith("${{ " + STABLE + " && secrets."), f"{key}: {value}")
        self.assertEqual(seen, 5)   # the certificate and its password, APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID


if __name__ == "__main__":
    unittest.main()
