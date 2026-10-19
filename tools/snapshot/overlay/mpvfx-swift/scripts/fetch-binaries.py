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
"""fetch-binaries.py: download the prebuilt engine libraries pinned in binaries.lock and check them. Stdlib only.

Run from mpvfx-swift (the folder holding binaries.lock), before `swift build`:
  python3 scripts/fetch-binaries.py                       # every component, for this machine
  python3 scripts/fetch-binaries.py --platform linux-x86_64 --component media
  python3 scripts/fetch-binaries.py --update media 0.2.0  # maintainers: pin a published release (URLs and SHA-256)

Each archive is checked against its SHA-256 before it is unpacked into .binaries/<component>/ (include/, lib/, and
bin/ on Windows). A component whose unpacked copy already matches the lock is not downloaded again. Exit 0 when every
component is in place, 1 when one is missing or does not match, 2 on bad arguments or an unreadable lock.
Set GITHUB_TOKEN only to raise the GitHub API rate limit for --update; downloads need no token.
"""
import argparse, hashlib, json, os, platform, shutil, sys, tarfile, tempfile, tomllib, urllib.error, urllib.request

LOCK = "binaries.lock"
DEST = ".binaries"
STAMP = ".lock-entry"
PLATFORMS = ("macos-arm64", "macos-x86_64", "linux-x86_64", "linux-aarch64", "windows-x86_64")


class FetchError(Exception):
    pass


def host_platform():
    system = {"Darwin": "macos", "Linux": "linux", "Windows": "windows"}.get(platform.system())
    machine = {"x86_64": "x86_64", "amd64": "x86_64", "arm64": "arm64", "aarch64": "aarch64"}.get(platform.machine().lower())
    if system is None or machine is None:
        raise FetchError(f"no prebuilt engines for {platform.system()} {platform.machine()}")
    if system == "macos" and machine == "aarch64":
        machine = "arm64"
    if system == "linux" and machine == "arm64":
        machine = "aarch64"
    return f"{system}-{machine}"


def load_lock(path):
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        raise FetchError(f"cannot read {path}: {e}")


def expected_files(entry, plat):
    lib = entry["library"]
    files = [f"include/{entry['header']}"]
    if plat.startswith("macos"):
        files.append(f"lib/lib{lib}.dylib")
    elif plat.startswith("linux"):
        files.append(f"lib/lib{lib}.so")
    else:
        files += [f"lib/{lib}.lib", f"bin/{lib}.dll"]
    return files


def pinned(name, entry, plat):
    """(url, sha256) of `name` on `plat`, or a FetchError that says what is missing and what to do."""
    version, tag, repo = entry.get("version", "?"), entry.get("tag", "?"), entry.get("repo", "?")
    target = entry.get("platforms", {}).get(plat)
    if not target:
        raise FetchError(f"binaries.lock has no {plat} build of {name} {version}; "
                         f"supported here: {', '.join(sorted(entry.get('platforms', {}))) or 'none'}")
    url, sha = target.get("url", ""), target.get("sha256", "").lower()
    if not url or len(sha) != 64:
        raise FetchError(f"binaries.lock pins no SHA-256 for {name} {version} on {plat}: release {tag} of {repo} is not "
                         f"published yet, or the lock was not updated after it was. Once it exists, run "
                         f"`python3 scripts/fetch-binaries.py --update {name} {version}`.")
    return url, sha


def download(url, out, what):
    request = urllib.request.Request(url, headers={"User-Agent": "mpvfx-fetch-binaries"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response, open(out, "wb") as f:
            shutil.copyfileobj(response, f)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise FetchError(f"{what}: {url} does not exist (HTTP 404): is the release published, and does the lock name "
                             f"the right version?")
        raise FetchError(f"{what}: {url}: HTTP {e.code}")
    except (urllib.error.URLError, OSError) as e:
        raise FetchError(f"{what}: cannot download {url}: {e}")


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def safe_extract(archive, dest):
    """Unpacks regular files and folders only, refusing any member that would land outside `dest`."""
    root = os.path.realpath(dest)
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            target = os.path.realpath(os.path.join(root, member.name))
            if not (target == root or target.startswith(root + os.sep)):
                raise FetchError(f"{archive}: member {member.name!r} would unpack outside {dest}")
            if member.isdir():
                os.makedirs(target, exist_ok=True)
            elif member.isfile():
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with tar.extractfile(member) as src, open(target, "wb") as out:
                    shutil.copyfileobj(src, out)
                os.chmod(target, 0o755 if member.mode & 0o111 else 0o644)
            elif member.issym() and plat_allows_links(member, root, target):
                os.makedirs(os.path.dirname(target), exist_ok=True)
                if os.path.lexists(target):
                    os.remove(target)
                os.symlink(member.linkname, target)
            else:
                raise FetchError(f"{archive}: member {member.name!r} is neither a file, a folder nor a library link")


def plat_allows_links(member, root, target):
    """A versioned-library link (libx.so -> libx.so.1) is accepted when it points inside the same folder."""
    resolved = os.path.realpath(os.path.join(os.path.dirname(target), member.linkname))
    return os.sep not in member.linkname and "/" not in member.linkname and resolved.startswith(root + os.sep)


def fetch(name, entry, plat, dest):
    url, sha = pinned(name, entry, plat)
    home = os.path.join(dest, name)
    stamp = os.path.join(home, STAMP)
    record = f"{entry['version']} {plat} {sha}\n"
    files = expected_files(entry, plat)
    if os.path.exists(stamp) and open(stamp).read() == record and all(os.path.exists(os.path.join(home, f)) for f in files):
        print(f"{name} {entry['version']} ({plat}): already in place")
        return
    os.makedirs(dest, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=dest) as work:
        archive = os.path.join(work, "archive.tar.gz")
        download(url, archive, f"{name} {entry['version']}")
        got = sha256_of(archive)
        if got != sha:
            raise FetchError(f"{name} {entry['version']} ({plat}): SHA-256 mismatch for {url}\n"
                             f"  expected {sha}\n  received {got}\nThe download is not the pinned build; nothing was unpacked.")
        unpacked = os.path.join(work, "unpacked")
        os.makedirs(unpacked)
        safe_extract(archive, unpacked)
        missing = [f for f in files if not os.path.exists(os.path.join(unpacked, f))]
        if missing:
            raise FetchError(f"{name} {entry['version']} ({plat}): the archive lacks {', '.join(missing)}")
        with open(os.path.join(unpacked, STAMP), "w") as f:
            f.write(record)
        shutil.rmtree(home, ignore_errors=True)
        os.replace(unpacked, home)
    print(f"{name} {entry['version']} ({plat}): fetched and verified ({sha[:12]}...)")


# ---- --update ------------------------------------------------------------------------------------------------------

def github_json(url):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "mpvfx-fetch-binaries"}
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise FetchError(f"{url}: no such release (HTTP 404)")
        raise FetchError(f"{url}: HTTP {e.code}")
    except (urllib.error.URLError, OSError) as e:
        raise FetchError(f"{url}: {e}")


def update(lock, name, version):
    entry = lock.get(name)
    if not entry:
        raise FetchError(f"binaries.lock has no component {name!r} (known: {', '.join(lock)})")
    prefix = entry["tag"].rsplit("v", 1)[0] if "v" in entry["tag"] else f"{name}-v"
    tag = f"{prefix}v{version}"
    release = github_json(f"https://api.github.com/repos/{entry['repo']}/releases/tags/{tag}")
    assets = {a["name"]: a for a in release.get("assets", [])}
    platforms = {}
    for plat in PLATFORMS:
        asset = assets.get(entry["asset"].format(version=version, platform=plat))
        if not asset:
            continue
        digest = (asset.get("digest") or "").removeprefix("sha256:")
        if len(digest) != 64:
            with tempfile.TemporaryDirectory() as work:
                path = os.path.join(work, "asset")
                download(asset["browser_download_url"], path, f"{name} {version} {plat}")
                digest = sha256_of(path)
        platforms[plat] = {"url": asset["browser_download_url"], "sha256": digest}
        print(f"{name} {version} {plat}: {digest}")
    if not platforms:
        raise FetchError(f"release {tag} has no asset named like {entry['asset']}")
    entry.update(version=version, tag=tag, platforms=platforms)
    return lock


def toml_value(v):
    return json.dumps(v)  # strings only in this file; JSON string escapes are valid TOML basic strings


def write_lock(path, lock):
    with open(path, encoding="utf-8") as f:
        header = []
        for line in f:
            if line.startswith("#") or not line.strip():
                header.append(line)
            else:
                break
    out = ["".join(header).rstrip("\n") + "\n"]
    for name, entry in lock.items():
        out.append(f"\n[{name}]\n")
        out += [f"{k} = {toml_value(v)}\n" for k, v in entry.items() if k != "platforms"]
        for plat, target in entry.get("platforms", {}).items():
            out.append(f"\n[{name}.platforms.{plat}]\n")
            out += [f"{k} = {toml_value(v)}\n" for k, v in target.items()]
    with open(path, "w", encoding="utf-8") as f:
        f.write("".join(out))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--lock", default=LOCK)
    ap.add_argument("--dest", default=DEST)
    ap.add_argument("--platform", choices=PLATFORMS, help="default: this machine")
    ap.add_argument("--component", action="append", help="only this component (repeatable)")
    ap.add_argument("--update", nargs=2, metavar=("COMPONENT", "VERSION"), help="pin a published release in the lock")
    args = ap.parse_args(argv)
    try:
        lock = load_lock(args.lock)
        if args.update:
            write_lock(args.lock, update(lock, *args.update))
            print(f"{args.lock}: {args.update[0]} pinned to {args.update[1]}")
            return 0
        plat = args.platform or host_platform()
        names = args.component or list(lock)
        unknown = [n for n in names if n not in lock]
        if unknown:
            print(f"fetch-binaries: unknown component(s) {', '.join(unknown)} (known: {', '.join(lock)})", file=sys.stderr)
            return 2
    except FetchError as e:
        print(f"fetch-binaries: {e}", file=sys.stderr)
        return 2
    failed = 0
    for name in names:
        try:
            fetch(name, lock[name], plat, args.dest)
        except FetchError as e:
            print(f"fetch-binaries: {e}", file=sys.stderr)
            failed = 1
    return failed


if __name__ == "__main__":
    sys.exit(main())
