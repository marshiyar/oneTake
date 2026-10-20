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
"""Tests for fetch-binaries.py against local archives (file:// URLs, no network): python3 scripts/test_fetch_binaries.py"""
import contextlib, hashlib, importlib.util, io, pathlib, tarfile, tempfile, unittest, zipfile

spec = importlib.util.spec_from_file_location("fetch_binaries", pathlib.Path(__file__).with_name("fetch-binaries.py"))
fb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fb)

PLAT = "linux-x86_64"


def make_archive(path, members):
    with tarfile.open(path, "w:gz") as tar:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def make_zip(path, members):
    with zipfile.ZipFile(path, "w") as z:
        for name, data in members.items():
            z.writestr(name, data)
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def write_lock(path, url, sha, plat=PLAT):
    path.write_text(f'''# test lock
[media]
version = "0.1.0"
tag = "media-v0.1.0"
repo = "example/binaries"
asset = "mpvfx-media-{{version}}-{{platform}}"
library = "mpvfx_media"
header = "mpvfx_media.h"

[media.platforms.{plat}]
url = "{url}"
sha256 = "{sha}"
''')


class FetchBinariesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.archive = self.tmp / "media.tar.gz"
        self.good = {"include/mpvfx_media.h": b"/* header */\n", "lib/libmpvfx_media.so": b"\x7fELF", "LICENSE": b"x"}
        self.lock = self.tmp / "binaries.lock"
        self.dest = self.tmp / ".binaries"

    def run_fetch(self, *extra):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()) as out:
            code = fb.main(["--lock", str(self.lock), "--dest", str(self.dest), "--platform", PLAT, *extra])
        return code, out.getvalue(), err.getvalue()

    def test_fetches_verifies_and_skips_when_current(self):
        sha = make_archive(self.archive, self.good)
        write_lock(self.lock, self.archive.as_uri(), sha)
        code, out, err = self.run_fetch()
        self.assertEqual(code, 0, err)
        self.assertTrue((self.dest / "media/include/mpvfx_media.h").exists())
        self.assertTrue((self.dest / "media/lib/libmpvfx_media.so").exists())
        code, out, _ = self.run_fetch()
        self.assertEqual(code, 0)
        self.assertIn("already in place", out)

    def test_checksum_mismatch_unpacks_nothing(self):
        make_archive(self.archive, self.good)
        write_lock(self.lock, self.archive.as_uri(), "0" * 64)
        code, _, err = self.run_fetch()
        self.assertEqual(code, 1)
        self.assertIn("SHA-256 mismatch", err)
        self.assertFalse((self.dest / "media").exists())

    def test_unpublished_release_says_what_to_do(self):
        write_lock(self.lock, "https://example.invalid/none.tar.gz", "")
        code, _, err = self.run_fetch()
        self.assertEqual(code, 1)
        self.assertIn("not published yet", err)
        self.assertIn("--update media 0.1.0", err)

    def test_missing_asset_is_reported(self):
        write_lock(self.lock, (self.tmp / "absent.tar.gz").as_uri(), "a" * 64)
        code, _, err = self.run_fetch()
        self.assertEqual(code, 1)
        self.assertIn("cannot download", err)

    def test_archive_without_the_library_is_refused(self):
        sha = make_archive(self.archive, {"include/mpvfx_media.h": b"x"})
        write_lock(self.lock, self.archive.as_uri(), sha)
        code, _, err = self.run_fetch()
        self.assertEqual(code, 1)
        self.assertIn("lacks lib/libmpvfx_media.so", err)

    def test_member_outside_the_folder_is_refused(self):
        sha = make_archive(self.archive, {**self.good, "../escape.txt": b"x"})
        write_lock(self.lock, self.archive.as_uri(), sha)
        code, _, err = self.run_fetch()
        self.assertEqual(code, 1)
        self.assertIn("outside", err)
        self.assertFalse((self.tmp / "escape.txt").exists())

    def test_unknown_platform_entry(self):
        sha = make_archive(self.archive, self.good)
        write_lock(self.lock, self.archive.as_uri(), sha)
        code, _, err = self.run_fetch("--platform", "windows-x86_64")
        self.assertEqual(code, 1)
        self.assertIn("no windows-x86_64 build", err)

    def test_top_level_folder_is_dropped(self):
        sha = make_archive(self.archive, {f"mpvfx-media-0.1.0-{PLAT}/{k}": v for k, v in self.good.items()})
        write_lock(self.lock, self.archive.as_uri(), sha)
        code, _, err = self.run_fetch()
        self.assertEqual(code, 0, err)
        self.assertTrue((self.dest / "media/lib/libmpvfx_media.so").exists())
        self.assertTrue((self.dest / "media/LICENSE").exists())

    def test_windows_zip_with_backslash_names_and_dll_lib(self):
        archive = self.tmp / "media.zip"
        top = "mpvfx-media-0.1.0-windows-x86_64\\"
        sha = make_zip(archive, {top + "include\\mpvfx_media.h": b"x", top + "lib\\mpvfx_media.dll": b"MZ",
                                 top + "lib\\mpvfx_media.dll.lib": b"!<arch>", top + "LICENSE": b"x"})
        write_lock(self.lock, archive.as_uri(), sha, plat="windows-x86_64")
        code, _, err = self.run_fetch("--platform", "windows-x86_64")
        self.assertEqual(code, 0, err)
        self.assertTrue((self.dest / "media/lib/mpvfx_media.lib").exists())
        self.assertTrue((self.dest / "media/bin/mpvfx_media.dll").exists())
        self.assertFalse((self.dest / "media/mpvfx-media-0.1.0-windows-x86_64").exists())

    def test_zip_member_outside_the_folder_is_refused(self):
        archive = self.tmp / "media.zip"
        sha = make_zip(archive, {"..\\escape.txt": b"x"})
        write_lock(self.lock, archive.as_uri(), sha, plat="windows-x86_64")
        code, _, err = self.run_fetch("--platform", "windows-x86_64")
        self.assertEqual(code, 1)
        self.assertIn("outside", err)

    def test_update_reads_the_release_checksum_file(self):
        rel = self.tmp / "release"
        rel.mkdir()
        sha = make_archive(rel / f"mpvfx-media-0.2.0-{PLAT}.tar.gz", self.good)
        (rel / "SHA256SUMS").write_text(f"{sha}  mpvfx-media-0.2.0-{PLAT}.tar.gz\n")
        write_lock(self.lock, "https://example.invalid/a.tar.gz", "")
        lock = fb.load_lock(self.lock)
        lock["media"]["repo"] = "example/binaries"
        original = fb.download
        fb.download = lambda url, out, what: original(url.replace(
            "https://github.com/example/binaries/releases/download/media-v0.2.0", rel.as_uri()), out, what)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                fb.update(lock, "media", "0.2.0")
        finally:
            fb.download = original
        self.assertEqual(lock["media"]["version"], "0.2.0")
        self.assertEqual(lock["media"]["tag"], "media-v0.2.0")
        self.assertEqual(lock["media"]["platforms"][PLAT]["sha256"], sha)

    def test_lock_rewrite_keeps_the_header_comment(self):
        write_lock(self.lock, "https://example.invalid/a.tar.gz", "")
        lock = fb.load_lock(self.lock)
        lock["media"]["platforms"][PLAT]["sha256"] = "b" * 64
        fb.write_lock(self.lock, lock)
        text = self.lock.read_text()
        self.assertTrue(text.startswith("# test lock\n"))
        self.assertEqual(fb.load_lock(self.lock), lock)


if __name__ == "__main__":
    unittest.main()
