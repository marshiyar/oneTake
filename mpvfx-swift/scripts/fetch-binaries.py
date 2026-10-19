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

Each archive (.tar.gz, or .zip on Windows) is checked against its SHA-256 before it is unpacked into
.binaries/<component>/: include/ (the header), lib/ (the library; on Windows the import library <name>.lib), bin/ (the
DLL on Windows), and the engine's LICENSE and NOTICE, which the installers ship with it. One top-level folder in the
archive is dropped, zip member names may use "\" or "/", and a Windows import library named <name>.dll.lib or a DLL in
lib/ is put where the linker and the installers look. A component whose unpacked copy already matches the lock is not
downloaded again. Exit 0 when every
component is in place, 1 when one is missing or does not match, 2 on bad arguments or an unreadable lock.
Set GITHUB_TOKEN only to raise the GitHub API rate limit for --update; downloads need no token.
"""
import argparse, hashlib, json, os, platform, shutil, sys, tarfile, tempfile, tomllib, urllib.error, urllib.request, zipfile

LOCK = "binaries.lock"
DEST = ".binaries"
STAMP = ".lock-entry"
PLATFORMS = ("macos-arm64", "macos-x86_64", "linux-x86_64", "linux-aarch64", "windows-x86_64")
EXTENSIONS = (".tar.gz", ".zip")
SUMS = "SHA256SUMS"


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


def _inside(root, name):
    target = os.path.realpath(os.path.join(root, name))
    if not (target == root or target.startswith(root + os.sep)):
        raise FetchError(f"archive member {name!r} would unpack outside the target folder")
    return target


def _write(target, data_source, executable):
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with data_source as src, open(target, "wb") as out:
        shutil.copyfileobj(src, out)
    os.chmod(target, 0o755 if executable else 0o644)


def safe_extract(archive, dest):
    """Unpacks regular files and folders only (plus same-folder library links in a tarball), refusing any member that
    would land outside `dest`. Zip member names may use either path separator."""
    root = os.path.realpath(dest)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            for info in z.infolist():
                name = info.filename.replace("\\", "/")
                target = _inside(root, name)
                if name.endswith("/"):
                    os.makedirs(target, exist_ok=True)
                else:
                    _write(target, z.open(info), (info.external_attr >> 16) & 0o111)
        return
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            target = _inside(root, member.name)
            if member.isdir():
                os.makedirs(target, exist_ok=True)
            elif member.isfile():
                _write(target, tar.extractfile(member), member.mode & 0o111)
            elif member.issym() and "/" not in member.linkname and os.sep not in member.linkname:
                os.makedirs(os.path.dirname(target), exist_ok=True)
                if os.path.lexists(target):
                    os.remove(target)
                os.symlink(member.linkname, target)
            else:
                raise FetchError(f"{archive}: member {member.name!r} is neither a file, a folder nor a library link")


def normalize(folder, entry, plat):
    """Drops a single top-level folder and puts Windows import library and DLL where they are expected."""
    items = os.listdir(folder)
    if len(items) == 1 and os.path.isdir(os.path.join(folder, items[0])) and items[0] not in ("include", "lib", "bin"):
        inner = os.path.join(folder, items[0])
        for item in os.listdir(inner):
            os.replace(os.path.join(inner, item), os.path.join(folder, item))
        os.rmdir(inner)
    if plat.startswith("windows"):
        lib = entry["library"]
        moves = [(f"lib/{lib}.dll.lib", f"lib/{lib}.lib"), (f"lib/{lib}.dll", f"bin/{lib}.dll")]
        for old, new in moves:
            src, dst = os.path.join(folder, old), os.path.join(folder, new)
            if os.path.exists(src) and not os.path.exists(dst):
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)


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
        archive = os.path.join(work, "archive")
        download(url, archive, f"{name} {entry['version']}")
        got = sha256_of(archive)
        if got != sha:
            raise FetchError(f"{name} {entry['version']} ({plat}): SHA-256 mismatch for {url}\n"
                             f"  expected {sha}\n  received {got}\nThe download is not the pinned build; nothing was unpacked.")
        unpacked = os.path.join(work, "unpacked")
        os.makedirs(unpacked)
        safe_extract(archive, unpacked)
        normalize(unpacked, entry, plat)
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


def release_assets(entry, tag):
    """{asset name: (url, sha256 or "")}: from the release's SHA256SUMS file (no API, no token), else the GitHub API."""
    base = f"https://github.com/{entry['repo']}/releases/download/{tag}"
    with tempfile.TemporaryDirectory() as work:
        sums = os.path.join(work, SUMS)
        try:
            download(f"{base}/{SUMS}", sums, f"{SUMS} of {tag}")
            out = {}
            for line in open(sums, encoding="utf-8"):
                parts = line.split()
                if len(parts) == 2 and len(parts[0]) == 64:
                    asset = parts[1].lstrip("*")
                    out[asset] = (f"{base}/{asset}", parts[0].lower())
            if out:
                return out
        except FetchError:
            pass
    release = github_json(f"https://api.github.com/repos/{entry['repo']}/releases/tags/{tag}")
    return {a["name"]: (a["browser_download_url"], (a.get("digest") or "").removeprefix("sha256:"))
            for a in release.get("assets", [])}


def update(lock, name, version):
    entry = lock.get(name)
    if not entry:
        raise FetchError(f"binaries.lock has no component {name!r} (known: {', '.join(lock)})")
    prefix = entry["tag"][:entry["tag"].rindex("-v") + 2] if "-v" in entry["tag"] else f"{name}-v"
    tag = f"{prefix}{version}"
    assets = release_assets(entry, tag)
    platforms = {}
    for plat in PLATFORMS:
        stem = entry["asset"].format(version=version, platform=plat)
        found = next(((stem + ext, assets[stem + ext]) for ext in EXTENSIONS if stem + ext in assets), None)
        if not found:
            continue
        asset, (url, digest) = found
        if len(digest) != 64:
            with tempfile.TemporaryDirectory() as work:
                path = os.path.join(work, "asset")
                download(url, path, f"{name} {version} {plat}")
                digest = sha256_of(path)
        platforms[plat] = {"url": url, "sha256": digest}
        print(f"{name} {version} {plat}: {asset} {digest}")
    if not platforms:
        raise FetchError(f"release {tag} has no asset named like {entry['asset']}{{{','.join(EXTENSIONS)}}}")
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
