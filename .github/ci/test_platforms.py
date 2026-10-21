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
"""Tests for platforms.py: each change runs the platforms it can affect, and anything shared runs all of them."""
import contextlib
import importlib.util
import io
import os
import re
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
spec = importlib.util.spec_from_file_location("platforms", os.path.join(HERE, "platforms.py"))
pl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pl)

ALL = {"linux", "windows", "macos"}


def run(*paths):
    code, needed, _ = pl.classify(list(paths))
    return code, set(needed)


class Classify(unittest.TestCase):
    def test_documentation_only_runs_nothing(self):
        self.assertEqual(run("README.md", "mpvfx-swift/docs/STATUS.md", "LICENSE", "mpvfx-swift/.gitignore",
                             ".github/ISSUE_TEMPLATE/bug.yml", ".github/SECURITY.md"), (False, set()))

    def test_design_md_is_code(self):
        self.assertEqual(run("mpvfx-swift/docs/DESIGN.md"), (True, ALL))

    def test_shared_sources_tests_and_manifest_run_everything(self):
        for p in ("mpvfx-swift/Sources/MpvfxCanvas/CairoCanvas.swift", "mpvfx-swift/Sources/CMpvfxColorShared/shared.c",
                  "mpvfx-swift/Tests/MpvfxAudioTests/x.swift", "mpvfx-swift/Package.swift", "mpvfx-swift/binaries.lock",
                  "mpvfx-swift/scripts/fetch-binaries.py", "mpvfx-swift/packaging/VERSION",
                  "mpvfx-swift/packaging/icon/mpvfx-16.png", "mpvfx-swift/tools/MpvfxPreviewBench/main.swift",
                  ".gitattributes", "some/new/file.txt", ".github/actions/setup/action.yml"):
            self.assertEqual(run(p), (True, ALL), p)

    def test_windows_only(self):
        self.assertEqual(run("mpvfx-swift/packaging/windows/build-setup.ps1"), (True, {"windows"}))
        self.assertEqual(run("mpvfx-swift/Sources/CMpvfxWin32/d2d.cpp"), (True, {"windows", "linux"}))

    def test_linux_only(self):
        for p in ("mpvfx-swift/packaging/linux/build-deb.sh", "mpvfx-swift/Sources/CGtk3/shim.h",
                  "mpvfx-swift/Sources/CPulse/module.modulemap", "mpvfx-swift/Sources/CVulkan/shim.h",
                  "mpvfx-swift/Sources/CMpvfxVulkan/vk_render.c"):
            self.assertEqual(run(p), (True, {"linux"}), p)

    def test_macos_only(self):
        for p in ("mpvfx-swift/packaging/macos/package.sh", "mpvfx-swift/Sources/MpvfxMetal/MetalGradePipeline.swift",
                  ".github/workflows/mpvfx-macos.yml", ".github/ci/metal-toolchain.sh"):
            self.assertEqual(run(p), (True, {"macos"}), p)

    def test_metal_shaders_feed_every_platform(self):
        for p in ("mpvfx-swift/Sources/MpvfxMetal/Shaders/MpvfxColor.metal",
                  "mpvfx-swift/Sources/MpvfxMetal/Shaders/MpvfxColorShared.h"):
            self.assertEqual(run(p), (True, ALL), p)

    def test_compute_kernel_generator_runs_linux_and_windows(self):
        for p in ("mpvfx-swift/scripts/gpu/gen-compute-shaders.py", "mpvfx-swift/scripts/gpu/generated/grade.hlsl",
                  "mpvfx-swift/scripts/gpu/glsl.inc"):
            self.assertEqual(run(p), (True, {"linux", "windows"}), p)

    def test_ci_scripts_and_other_workflows_run_only_the_checks(self):
        for p in (".github/ci/agentbot.py", ".github/ci/test_agentbot.py", ".github/ci/publish.sh",
                  ".github/workflows/sentinel.yml", ".github/workflows/strip-check.yml", ".github/dependabot.yml",
                  ".github/sentinel.toml", ".claude/settings.json", ".codex/hooks.json",
                  "mpvfx-swift/scripts/copyright.py", "mpvfx-swift/scripts/test_fetch_binaries.py"):
            self.assertEqual(run(p), (True, set()), p)

    def test_ci_files_the_build_jobs_run(self):
        self.assertEqual(run(".github/workflows/mpvfx-ci.yml"), (True, ALL))
        self.assertEqual(run(".github/ci/test-shards.py"), (True, ALL))
        self.assertEqual(run(".github/ci/run-shard.py"), (True, {"linux", "windows"}))
        for p in (".github/workflows/mpvfx-ci-tests-source.yml", ".github/ci/source_workflows.py",
                  ".github/ci/remote_shards.py", ".github/ci/runners_app_installed.sh"):
            self.assertEqual(run(p), (True, {"linux", "windows"}), p)
        self.assertEqual(run(".github/ci/platforms.py"), (True, ALL))

    def test_platforms_add_up(self):
        self.assertEqual(run("mpvfx-swift/packaging/windows/install.ps1", "mpvfx-swift/packaging/macos/package.sh",
                             "README.md"), (True, {"windows", "macos"}))
        self.assertEqual(run(".github/ci/agentbot.py", "mpvfx-swift/Sources/CGtk3/shim.h"), (True, {"linux"}))

    def test_rules_match_whole_paths(self):
        self.assertEqual(run("x/mpvfx-swift/packaging/macos/package.sh"), (True, ALL))
        self.assertEqual(run("mpvfx-swift/Sources/MpvfxMetalExtra/a.swift"), (True, ALL))
        self.assertEqual(run(".github/workflows/mpvfx-ci.yml.bak"), (True, set()))

    def test_no_list_or_a_truncated_list_runs_everything(self):
        self.assertEqual(run(), (True, ALL))
        self.assertEqual(run(*["README.md"] * pl.MAX_FILES), (True, ALL))
        self.assertEqual(run(*["README.md"] * (pl.MAX_FILES - 1)), (False, set()))


class Repository(unittest.TestCase):
    def test_every_path_a_rule_names_exists(self):
        # A renamed file would leave its rule matching nothing, and a renamed build workflow would fall to the
        # rule for the workflows no build uses.
        for p in (".github/workflows/mpvfx-ci.yml", ".github/workflows/mpvfx-macos.yml", ".github/ci/test-shards.py",
                  ".github/ci/run-shard.py", ".github/ci/metal-toolchain.sh", ".github/ci/platforms.py",
                  ".github/workflows/mpvfx-ci-tests-source.yml", ".github/ci/source_workflows.py",
                  ".github/ci/remote_shards.py", ".github/ci/runners_app_installed.sh",
                  "mpvfx-swift/docs/DESIGN.md", "mpvfx-swift/scripts/copyright.py",
                  "mpvfx-swift/scripts/test_fetch_binaries.py"):
            self.assertTrue(os.path.isfile(os.path.join(ROOT, p)), p)
        for d in ("packaging/linux", "packaging/windows", "packaging/macos", "scripts/gpu", "Sources/CGtk3",
                  "Sources/CPulse", "Sources/CVulkan", "Sources/CMpvfxVulkan", "Sources/CMpvfxWin32",
                  "Sources/MpvfxMetal/Shaders"):
            self.assertTrue(os.path.isdir(os.path.join(ROOT, "mpvfx-swift", d)), d)

    def test_every_ci_file_the_build_workflows_call_runs_a_platform(self):
        # publish.sh runs only in the publish job, which pull requests never reach.
        for wf in ("mpvfx-ci.yml", "mpvfx-macos.yml"):
            with open(os.path.join(ROOT, ".github/workflows", wf)) as f:
                called = set(re.findall(r"\.github/ci/[\w-]+\.(?:py|sh)", f.read())) - {".github/ci/publish.sh"}
            self.assertTrue(called, wf)
            for p in called:
                self.assertNotEqual(run(p)[1], set(), f"{wf} calls {p}")


class Main(unittest.TestCase):
    def test_prints_github_outputs(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("mpvfx-swift/packaging/macos/package.sh\n\nREADME.md\n")
        try:
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                pl.main([f.name])
        finally:
            os.unlink(f.name)
        self.assertEqual(out.getvalue(), "code=true\nlinux=false\nwindows=false\nmacos=true\n")
        self.assertIn("macos: runs (mpvfx-swift/packaging/macos/package.sh)", err.getvalue())
        self.assertIn("linux: not affected, skipped", err.getvalue())


if __name__ == "__main__":
    unittest.main()
