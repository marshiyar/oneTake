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
"""macos_gate.py classify <files.txt> | wait [--minutes N] [--every S]: makes ci-ok require the macOS build of a pull
request that touches macOS code.

classify prints macos_code=true|false for $GITHUB_OUTPUT. A file is macOS code when it is under mpvfx-swift/ and is
named *Mac*.swift, lies under MpvfxMetal/, is Package.swift, or is a .swift file whose text at HEAD contains
`#if os(macOS)`, `import AppKit` or `canImport(AppKit)`. Reads GITHUB_REPOSITORY, GH_TOKEN and HEAD.

wait runs only for such a pull request, when its macOS build was sent to OneTake-app/OneTake-actionRunners-1
(SENT=true): it reads the commit status `macos (runners-1)` of HEAD until it is success, and exits 1 on failure, error
or when none passed after N minutes (default 45). When SENT is not true and the local macos job did not succeed,
nothing will report: it exits 1 at once. Reads HEAD, SENT, GITHUB_REPOSITORY and GITHUB_TOKEN; stdlib only.
"""
import argparse
import importlib.util
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CONTEXT = "macos (runners-1)"
ROOT = "mpvfx-swift/"
MARKERS = ("#if os(macOS)", "import AppKit", "canImport(AppKit)")


def _remote():
    spec = importlib.util.spec_from_file_location("remote_shards", os.path.join(HERE, "remote_shards.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def path_is_macos(path):
    """True when the path alone makes it macOS code."""
    if not path.startswith(ROOT):
        return False
    name = path.rsplit("/", 1)[-1]
    return (name == "Package.swift" and path == ROOT + "Package.swift") or path.startswith(ROOT + "Sources/MpvfxMetal/") \
        or (name.endswith(".swift") and "Mac" in name)


def text_is_macos(text):
    return any(m in text for m in MARKERS)


def touches_macos(paths, read):
    """True when any path is macOS code. read(path) is the file's text at HEAD, or None when it does not exist there;
    it may raise OSError, which counts as macOS (an unreadable file is not proof it is safe)."""
    for p in paths:
        if path_is_macos(p):
            return True
        if p.startswith(ROOT) and p.endswith(".swift"):
            try:
                t = read(p)
            except (OSError, ValueError):
                return True
            if t is not None and text_is_macos(t):
                return True
    return False


def state_of(statuses):
    """The newest status of CONTEXT (the API lists newest first), or pending when it has none."""
    for st in statuses:
        if st.get("context") == CONTEXT:
            return st.get("state", "pending")
    return "pending"


def decide(local_result, sent, state):
    """('pass'|'fail'|'wait', why) for a pull request that touches macOS code."""
    if local_result == "success":
        return "pass", "the local macos job passed"
    if sent != "true":
        return "fail", f"the macos job ended {local_result} and the build was not sent to the runners"
    if state == "success":
        return "pass", f"{CONTEXT} is success"
    if state in ("failure", "error"):
        return "fail", f"{CONTEXT} is {state}"
    return "wait", f"{CONTEXT} is {state}"


def fetch_text(repo, sha, path, token):
    rs = _remote()
    url = f"https://{rs.API_HOST}/repos/{repo}/contents/{urllib.parse.quote(path)}?ref={sha}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github.raw+json",
                                               "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "mpvfx-macos-gate"})
    try:
        with rs.https_opener().open(req, timeout=60) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def wait(read, sent, minutes, every, sleep=time.sleep, clock=time.monotonic):
    """Polls until decide() is not 'wait' or the deadline passes; (verdict, why)."""
    deadline = clock() + minutes * 60
    while True:
        try:
            v, why = decide("skipped", sent, state_of(read()))
        except (urllib.error.URLError, OSError, ValueError) as e:
            print(f"::warning::statuses not read: {e}")
            v, why = "wait", "statuses not read"
        if v != "wait":
            return v, why
        if clock() >= deadline:
            return "fail", f"{CONTEXT} did not report a result in {minutes:g} minutes"
        sleep(every)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("mode", choices=("classify", "wait"))
    ap.add_argument("files", nargs="?")
    ap.add_argument("--minutes", type=float, default=45)
    ap.add_argument("--every", type=float, default=60)
    a = ap.parse_args(argv)
    env = os.environ
    repo, sha, token = env.get("GITHUB_REPOSITORY", ""), env.get("HEAD", ""), env.get("GH_TOKEN") or env.get("GITHUB_TOKEN", "")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repo) or not re.fullmatch(r"[0-9a-f]{40}", sha) or not token:
        print("macos_gate: HEAD, GITHUB_REPOSITORY and GH_TOKEN are required", file=sys.stderr)
        return 2
    if a.mode == "classify":
        with open(a.files, encoding="utf-8") as f:
            paths = [l.strip() for l in f if l.strip()]
        print(f"macos_code={'true' if touches_macos(paths, lambda p: fetch_text(repo, sha, p, token)) else 'false'}")
        return 0
    rs = _remote()
    sent = env.get("SENT", "")
    if sent != "true":
        v, why = decide(env.get("LOCAL", "skipped"), sent, "pending")
    else:
        v, why = wait(lambda: rs.statuses(repo, sha, token), sent, a.minutes, a.every)
    print(f"{'::error::' if v == 'fail' else ''}macOS build: {why}")
    return 0 if v == "pass" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
