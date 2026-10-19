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
"""test-shards.py --os macos|linux|windows <dump-package.json>: the test shards, each with the key of its inputs.

One shard list for every OS, so the same tests run together everywhere; each OS runs it on its own runners
(mpvfx-macos.yml for macOS, the linux-test and windows-test jobs of mpvfx-ci.yml). A shard's key hashes the git blobs
of every target in its test targets' dependency closure (Sources/, Tests/), the package manifest and lock, the engine
versions and checksums pinned in binaries.lock, the CI files that run the
tests on that OS, and the OS name. A shard whose key already has a pass recorded (cache entry
<os>-pass-<shard>-<key>) built from byte-identical inputs on that OS's pinned toolchain, so the workflow skips it; the
nightly run and a dispatch with full_tests ignore recorded passes and run every shard (toolchain and runner drift).
Prints the shard list as JSON. Run from mpvfx-swift.
"""
import argparse, hashlib, json, subprocess

A = r"MpvfxAudioTests\."
LIBRARY = r"MpvfxRuntimeTests\.LibraryServiceTests/"
LIVE_EDIT = A + "AudioFxLiveEditTests/"
PRESETS = A + "AudioFxLiveEditTests/(testEveryPresetChangesTheExportRenderOnBothRacks|testEveryFxTypeIsHeardInLivePlaybackOnBothRacks)$"
SEEK = A + "GraphPlaybackTests/testOutputAfterSeekEqualsOfflineBitIdentical$"
SEEK_SHORT = A + "GraphPlaybackTests/(testPreRollTiming|testForwardSeekContinuesWithoutRestart)$"
DETERMINISTIC = r"MpvfxAudioGraphTests\.PlaybackIdentityTests/testRendererIsDeterministicAcrossInstances$"
# Balanced by the seconds measured on macOS, the slowest OS, in runs 39210089199 and 39213966532 (xcode-27, every test
# once, 2953 s and 2720 s; the real-time audio tests vary by up to 40% between runs, so the comments give both). The
# longest single test, the 500 MiB library import, is a shard of its own and sets the floor; the other three are
# filled to about the same time. Four shards, not five: with the package job that is the 5 macOS jobs the account runs
# at once, so no shard waits for a runner. On Linux and Windows the same shards take 2 to 7 minutes each. Shard "rest"
# skips exactly what the others filter, so together they run every test once.
SHARDS = [
    ("library", ["MpvfxRuntimeTests"], LIBRARY, ""),                                     # 791 / 611 s (one test)
    ("audio-presets", ["MpvfxAudioTests"], PRESETS + "|" + SEEK_SHORT, ""),             # 797 / 662 s
    ("audio-live", ["MpvfxAudioTests", "MpvfxAudioGraphTests"],                          # 722 / 700 s
     "|".join([LIVE_EDIT, SEEK, DETERMINISTIC]), PRESETS),
    ("rest", None, "", "|".join([LIBRARY, LIVE_EDIT, SEEK, SEEK_SHORT, DETERMINISTIC])),  # 642 / 747 s
]
PRODUCTS = {}   # no package products: the engines are prebuilt (binaries.lock)
CI = ["../.github/ci/test-shards.py", "../.github/ci/run-shard.py", "binaries.lock", "scripts/fetch-binaries.py", "Package.swift", "Package.resolved", "scripts"]
WORKFLOW = {"macos": "../.github/workflows/mpvfx-macos.yml", "linux": "../.github/workflows/mpvfx-ci.yml",
            "windows": "../.github/workflows/mpvfx-ci.yml"}


def closure(targets, names):
    seen, products, todo = set(), set(), list(names)
    while todo:
        name = todo.pop()
        if name in seen:
            continue
        seen.add(name)
        for dep in targets[name]["dependencies"]:
            kind, value = next(iter(dep.items()))
            if kind == "product":
                products.add(value[0])
            elif value[0] in targets:
                todo.append(value[0])
            else:
                products.add(value[0])
    return seen, products


def target_dir(t):
    return t.get("path") or ("Tests/" if t["type"] == "test" else "Sources/") + t["name"]


def unlisted(targets):
    """Sources/ and Tests/ folders no dumped target owns: targets the manifest declares only under another platform's
    #if (MpvfxMetal is macOS-only, and the plan jobs dump the manifest on Linux). Every key includes them."""
    owned = {target_dir(t) for t in targets.values()}
    files = subprocess.run(["git", "ls-files", "--", "Sources", "Tests"], capture_output=True, text=True,
                           check=True).stdout.split()
    return sorted({"/".join(f.split("/")[:2]) for f in files if f.count("/") >= 2} - owned)


def key(targets, names, os_name):
    seen, products = closure(targets, names)
    paths = sorted({target_dir(targets[n]) for n in seen}) + unlisted(targets) + CI + [WORKFLOW[os_name]]
    for p in sorted(products):
        paths += PRODUCTS.get(p, [])
    blobs = subprocess.run(["git", "ls-files", "-s", "--", *paths], capture_output=True, text=True, check=True).stdout
    h = hashlib.sha256(blobs.encode())
    h.update(json.dumps(sorted(products)).encode())
    h.update(os_name.encode())
    return h.hexdigest()[:20]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--os", required=True, choices=sorted(WORKFLOW), dest="os_name")
    ap.add_argument("package", help="the output of `swift package dump-package`")
    a = ap.parse_args(argv)
    with open(a.package) as f:
        targets = {t["name"]: t for t in json.load(f)["targets"]}
    tests = sorted(n for n, t in targets.items() if t["type"] == "test")
    out = [{"shard": s, "filter": f, "skip": k, "key": key(targets, names or tests, a.os_name)}
           for s, names, f, k in SHARDS]
    print(json.dumps(out))


if __name__ == "__main__":
    main()
