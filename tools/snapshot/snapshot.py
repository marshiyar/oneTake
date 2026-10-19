#!/usr/bin/env python3
"""snapshot.py [--engine-fixtures=omit|copy] SOURCE DEST: build the public oneTake tree from a checkout of the old app repository. Stdlib only.

SOURCE is a clean checkout of the old repository (read only: nothing in it is changed). DEST must not exist or be
empty. The script
  1. copies the tracked files of SOURCE that are public (PUBLIC below) and leaves out everything private (PRIVATE),
  2. lays the files of overlay/ (next to this script) over the copy: the oneTake README, licence, CI, ignore rules,
     session-start hook, the engine C module maps, the app's own Swift adapters, binaries.lock and its fetch script,
  3. rewrites the app for prebuilt engines (Package.swift, imports, adapter type names, CI shard keys, installers),
  4. writes snapshot-report.txt into DEST's parent: what was copied, what was left out and why, every rewrite, and
     any line that still names an old path (engines/, video-keyframing, ...) for a person to look at.
--engine-fixtures=copy (the default) copies the media files of the engine's fixtures folder that the app's tests read
into mpvfx-swift/Tests/EngineFixtures, each only after its row in the fixtures README shows the project generated it;
--engine-fixtures=omit leaves them out (those tests then fail).
Exit 0 when every rewrite applied, 1 when one did not match (the old repository changed: update this script),
2 on bad arguments.
"""
import fnmatch, os, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OVERLAY = os.path.join(HERE, "overlay")

# Tracked paths of the old repository that may enter oneTake (fnmatch patterns, matched in order after PRIVATE).
PUBLIC = [
    "LICENSE-APACHE", "LICENSE-MIT",
    ".github/ci/metal-toolchain.sh", ".github/ci/publish.sh", ".github/ci/run-shard.py", ".github/ci/test-shards.py",
    ".github/pull_request_template.md",
    "mpvfx-swift/*",
]

# Never copied, with the reason printed in the report. Checked before PUBLIC.
PRIVATE = [
    ("agent-kit/*", "maintainer session tooling (private)"),
    ("engines/*", "media engine sources (private; the app uses the prebuilt library)"),
    (".claude/*", "maintainer session tooling and hooks (private; oneTake has its own settings and session-start hook)"),
    ("*/.agents/*", "maintainer session data (private)"),
    (".agents/*", "maintainer session data (private)"),
    ("CLAUDE.md", "session instructions (private, rendered at session start)"),
    ("*/CLAUDE.md", "session instructions (private, rendered at session start)"),
    ("AGENTS.md", "session instructions (private, rendered at session start)"),
    ("*/AGENTS.md", "session instructions (private, rendered at session start)"),
    ("mpvfx-swift/.github/*", "old nested workflow folder GitHub never runs (oneTake CI lives in .github/workflows)"),
    ("mpvfx-swift/scripts/gate.sh", "maintainer check script (private); oneTake uses scripts/check.sh"),
    ("mpvfx-swift/scripts/build-media.sh", "built the engine from source; oneTake fetches it (scripts/fetch-binaries.py)"),
    ("mpvfx-swift/Package.resolved", "pinned the engine source packages; oneTake has no package dependencies"),
    (".github/workflows/*", "replaced by oneTake's workflows (overlay)"),
    (".github/ci/engine-key.py", "keyed engine source builds; no engine is built in oneTake"),
    (".github/ci/use-local-vkf.py", "pointed CI at a private source checkout; no tokens in oneTake CI"),
    (".github/ci/vkf-revision.py", "pinned a private source checkout; binaries.lock pins the engines"),
    ("README.md", "replaced by oneTake's README (overlay)"),
    ("LICENSE", "replaced by oneTake's LICENSE (overlay): app open, engines proprietary"),
    ("NOTICE", "replaced by oneTake's NOTICE (overlay): the old one lists engine third-party code"),
    (".gitignore", "replaced by oneTake's .gitignore (overlay)"),
    (".gitattributes", "replaced by oneTake's .gitattributes (overlay): the old one routes generated agent files"),
]

# Overlay files that replace a file of the old repository, with the git blob of the version they were written from.
# When the old file changed since, the report says so: carry the change into the overlay copy before publishing.
OVERLAY_BASE = {
    "mpvfx-swift/docs/PACKAGING.md": "f26897bc6c850692fa74646857c9c51ce7fa347c",
}

# Text that should not survive into oneTake once the rewrites ran; each hit is listed for a person to edit.
STALE = re.compile(r"engines/(?:mpvfx-media|artcraft)|video-keyframing|build-media\.sh|scripts/gate\.sh|\bVkfEngine\b|\bMpvfxEngine\b|"
                   r"import MpvfxMedia\b|VFK_TOKEN|deps/video|crates/scripts|ArtCraft|owner question")

report = []
failures = []


def note(line=""):
    report.append(line)


def tracked(root):
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True, check=True).stdout
    return sorted(p.decode() for p in out.split(b"\0") if p)


def classify(path):
    """("private", reason) | ("public", None) | ("unlisted", None)."""
    for pattern, reason in PRIVATE:
        if fnmatch.fnmatch(path, pattern):
            return "private", reason
    if any(fnmatch.fnmatch(path, p) for p in PUBLIC):
        return "public", None
    return "unlisted", None


def read(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def rewrite(dest, rel, what, edit):
    """Applies edit(text) -> text to DEST/rel; records a failure when the file is missing or nothing changed."""
    path = os.path.join(dest, rel)
    if not os.path.exists(path):
        failures.append(f"{rel}: missing ({what})")
        return
    before = read(path)
    try:
        after = edit(before)
    except AssertionError as e:
        failures.append(f"{rel}: {what}: {e}")
        return
    if after == before:
        failures.append(f"{rel}: {what}: no change (the old file no longer looks as expected)")
        return
    write(path, after)
    note(f"  rewrote {rel}: {what}")


def sub_once(pattern, repl, text, flags=0, what="pattern"):
    new, n = re.subn(pattern, repl, text, count=1, flags=flags)
    assert n == 1, f"{what} not found"
    return new


# ---- Package.swift ---------------------------------------------------------------------------------------------------

ENGINE_TARGETS = '''
// The media and keyframe engines are proprietary dynamic libraries, not built here: `python3 scripts/fetch-binaries.py`
// downloads the versions pinned in binaries.lock, checks their SHA-256 and unpacks each into .binaries/<component>/
// (include/ the C header, lib/ the library and on Windows its import library, bin/ the DLL on Windows).
// CMediaEngine and CKeyframeEngine are their C interfaces; OneTakeMedia and OneTakeKeyframes are the app's own Swift
// adapters over those headers. The installers copy the libraries next to the app (docs/PACKAGING.md).
#if os(Windows)
// The linker wants a native Windows path, so the folder is cut from #filePath itself (either separator).
let manifestDir: String = {
    let path = #filePath
    guard let cut = path.lastIndex(where: { $0 == "\\\\" || $0 == "/" }) else { preconditionFailure("no folder in \\(path)") }
    return String(path[..<cut])
}()
let pathSeparator = "\\\\"
#else
let manifestDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let pathSeparator = "/"
#endif

func engineLibraryDir(_ component: String) -> String {
    [manifestDir, ".binaries", component, "lib"].joined(separator: pathSeparator)
}

func engineLinkerSettings(_ component: String) -> [LinkerSetting] {
    let dir = engineLibraryDir(component)
    #if os(Windows)
    return [.unsafeFlags(["-L", dir])]   // the DLL is found next to the exe, or on PATH for tests
    #else
    // The rpath lets `swift run` and `swift test` load the library where it was unpacked; the installers replace it.
    return [.unsafeFlags(["-L", dir, "-Xlinker", "-rpath", "-Xlinker", dir])]
    #endif
}

let engineTargets: [Target] = [
    .systemLibrary(name: "CMediaEngine", path: "Sources/CMediaEngine"),
    .target(name: "OneTakeMedia", dependencies: ["CMediaEngine"], linkerSettings: engineLinkerSettings("media")),
    .systemLibrary(name: "CKeyframeEngine", path: "Sources/CKeyframeEngine"),
    .target(name: "OneTakeKeyframes", dependencies: ["CKeyframeEngine"], linkerSettings: engineLinkerSettings("keyframes")),
]
'''


def drop_comment_block_above(text, anchor):
    """Removes the run of `//` comment lines directly above the line that starts with `anchor`."""
    lines = text.split("\n")
    idx = next((i for i, l in enumerate(lines) if l.startswith(anchor)), None)
    assert idx is not None, f"line starting {anchor!r} not found"
    start = idx
    while start > 0 and lines[start - 1].lstrip().startswith("//"):
        start -= 1
    return "\n".join(lines[:start] + lines[idx:])


def package_swift(text):
    text = drop_comment_block_above(text, "let mediaEngine: Target.Dependency")
    text = sub_once(r"^let mediaEngine: Target\.Dependency = .*$",
                    '// The media engine through the app\'s adapter (prebuilt library; see engineTargets below).\n'
                    'let mediaEngine: Target.Dependency = "OneTakeMedia"', text, re.M, "mediaEngine dependency")
    text = drop_comment_block_above(text, "let vkfEngine: Target.Dependency")
    text = sub_once(r"^let vkfEngine: Target\.Dependency = .*$",
                    '// The keyframe engine through the app\'s adapter (prebuilt library; see engineTargets below).\n'
                    'let keyframeEngine: Target.Dependency = "OneTakeKeyframes"', text, re.M, "vkfEngine dependency")
    text = re.sub(r"\bvkfEngine\b", "keyframeEngine", text)
    # The package dependency list (engine sources) becomes empty: from `    dependencies: [` to its `    ],`.
    text = sub_once(r"^    dependencies: \[\n.*?^    \],\n", "    dependencies: [],\n", text, re.M | re.S,
                    "package dependencies block")
    # Target comments that described the source packages.
    text = "\n".join(l for l in text.split("\n")
                     if not (l.lstrip().startswith("//") and re.search(r"video-keyframing|engines/|CORE-MATH|C\+\+ core", l)))
    text = sub_once(r"^let package = Package\(", lambda m: ENGINE_TARGETS.lstrip("\n") + "\nlet package = Package(", text, re.M,
                    "`let package = Package(`")
    text = sub_once(r"\] \+ platformTargets,", "] + platformTargets + engineTargets,", text, 0, "`] + platformTargets,`")
    text = re.sub(r"\bVkfEngine\b", "KeyframeRuntime", text)
    text = re.sub(r"\bMpvfxMedia\b", "OneTakeMedia", text)
    assert "package: \"crates\"" not in text and "video-keyframing\"" not in text, "an engine source package remains"
    return text


# ---- Swift sources ---------------------------------------------------------------------------------------------------

def swift_sources(dest):
    renamed = 0
    for top in ("mpvfx-swift/Sources", "mpvfx-swift/Tests", "mpvfx-swift/tools"):
        for dirpath, _, files in os.walk(os.path.join(dest, top)):
            for name in files:
                if not name.endswith(".swift") or "/OneTake" in dirpath.replace(os.sep, "/"):
                    continue
                path = os.path.join(dirpath, name)
                before = read(path)
                after = re.sub(r"^import MpvfxMedia\b", "import OneTakeMedia", before, flags=re.M)
                after = re.sub(r"^import MpvfxEngine\b", "import OneTakeKeyframes", after, flags=re.M)
                after = re.sub(r"\bVkfEngine\b", "KeyframeRuntime", after)
                after = re.sub(r"\bMpvfxMedia\b", "OneTakeMedia", after)
                after = re.sub(r"\bCVkf\b", "the keyframe engine", after)
                if after != before:
                    write(path, after)
                    renamed += 1
    note(f"  rewrote {renamed} Swift files: engine imports -> OneTakeMedia / OneTakeKeyframes, VkfEngine -> KeyframeRuntime")
    old = os.path.join(dest, "mpvfx-swift/Sources/MpvfxShared/Engine/VkfEngineKeyframeEngine.swift")
    if os.path.exists(old):
        os.rename(old, old.replace("VkfEngineKeyframeEngine", "KeyframeRuntimeKeyframeEngine"))
        note("  renamed Sources/MpvfxShared/Engine/VkfEngineKeyframeEngine.swift -> KeyframeRuntimeKeyframeEngine.swift")
    else:
        failures.append("Sources/MpvfxShared/Engine/VkfEngineKeyframeEngine.swift: missing (adapter conformance file)")


# ---- CI shard keys ---------------------------------------------------------------------------------------------------

def test_shards(text):
    text = sub_once(r"^PRODUCTS = \{.*\}$", "PRODUCTS = {}   # no package products: the engines are prebuilt (binaries.lock)",
                    text, re.M, "PRODUCTS line")
    text = sub_once(r'"\.\./\.github/ci/use-local-vkf\.py"', '"binaries.lock", "scripts/fetch-binaries.py"', text, 0,
                    "use-local-vkf.py in CI list")
    text = sub_once(r'^    if "MpvfxEngine" in products:\n(?:        .*\n)+', "", text, re.M, "video-keyframing revision block")
    text = text.replace("the media\nengine and ArtCraft crates and the video-keyframing commit when the closure links them",
                        "the engine\nversions and checksums pinned in binaries.lock")
    return text


# ---- Engine test fixtures -------------------------------------------------------------------------------------------

FIXTURES = "engines/mpvfx-media-processing/crates/fixtures"
APP_FIXTURES = "mpvfx-swift/Tests/EngineFixtures"


def fixture_paths(dest):
    """MediaTestSupport.swift and WavFixtures.swift read the engine's fixtures from Tests/EngineFixtures instead."""
    rewrite(dest, "mpvfx-swift/Tests/MpvfxRuntimeTests/Media/MediaTestSupport.swift", "engine fixtures from Tests/EngineFixtures",
            lambda t: sub_once(r'\.deletingLastPathComponent\(\)\.deletingLastPathComponent\(\)\.appendingPathComponent\('
                               r'"engines/mpvfx-media-processing/crates/fixtures/\\\(name\)"\)',
                               '.appendingPathComponent("EngineFixtures/\\\\(name)")',
                               t.replace("(`engines/mpvfx-media-processing/crates/fixtures/<name>`; provenance in its README)",
                                         "(`Tests/EngineFixtures/<name>`; provenance in its README)"),
                               0, "engineFixture path"))
    rewrite(dest, "mpvfx-swift/Tests/MpvfxAudioTests/WavFixtures.swift", "engine fixtures from Tests/EngineFixtures",
            lambda t: sub_once(r'"\.\./engines/mpvfx-media-processing/crates/fixtures"', '"Tests/EngineFixtures"', t, 0,
                               "mediaFixtures path"))


OWN_LICENCE = re.compile(r"LicenseRef-MpVFX|^\s*generated", re.I)
OUTSIDE = re.compile(r"extracted from|https?://|conformance|(?<!no )third-party|downloaded", re.I)


def fixture_rows(root):
    """[(patterns, row text, own)] from the fixtures README table: which files a row covers and whether the project
    made them itself (its licence column names the project's own licence or says generated, and no outside source)."""
    rows = []
    for line in read(os.path.join(root, "README.md")).split("\n"):
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 3 or not cells[0].startswith("`fixtures/"):
            continue
        tokens = re.findall(r"`([^`]+)`", cells[0])
        folder = tokens[0].removeprefix("fixtures/").split("/")[0]
        patterns = []
        for t in tokens:
            t = t.removeprefix("fixtures/")
            t = t if "/" in t else f"{folder}/{t}"
            t = re.sub(r"\d+\.\.\w*?\d+", "*", t)
            patterns += [t, t + ".*"]
        licence = cells[-1]
        own = bool(OWN_LICENCE.search(licence)) and not OUTSIDE.search(licence)
        rows.append((patterns, f"| {cells[0]} | {' | '.join(cells[1:-1])} |", own))
    return rows


def copy_fixtures(src, dest):
    """Copies the engine fixtures the app's tests read, after checking each one's origin in the fixtures README:
    files the project generated itself are copied; anything else (or a file with no README row) is not, and fails
    the snapshot so a person makes that test generate its input or skip with a reason."""
    root = os.path.join(src, FIXTURES)
    literals, folders = set(), set()
    for dirpath, _, files in os.walk(os.path.join(dest, "mpvfx-swift/Tests")):
        for name in files:
            if name.endswith(".swift"):
                text = read(os.path.join(dirpath, name))
                literals.update(l for l in re.findall(r'"([A-Za-z0-9_.-][A-Za-z0-9_./-]*)"', text) if ".." not in l)
                folders.update(re.findall(r'engineFixture\("([A-Za-z0-9_./-]+)"\)', text))
    needed = {l for l in literals if os.path.isfile(os.path.join(root, l))}
    needed |= {f"{d}/{l}" for d in folders if os.path.isdir(os.path.join(root, d))
               for l in literals if "/" not in l and os.path.isfile(os.path.join(root, d, l))}
    # Companion files a test reads by appending to a fixture's name (`fixture + ".json"`, decode references).
    needed |= {f"{rel}{os.path.splitext(n)[1]}" for rel in list(needed)
               for n in os.listdir(os.path.join(root, os.path.dirname(rel)))
               if n.startswith(os.path.basename(rel) + ".") and n.count(".") == os.path.basename(rel).count(".") + 1}
    rows = fixture_rows(root)
    copied, refused, notes = [], [], []
    for rel in sorted(needed):
        row = next((r for r in rows if any(fnmatch.fnmatch(rel, p) for p in r[0])), None)
        if row is None or not row[2]:
            refused.append((rel, "no provenance row" if row is None else "not made by the project"))
            continue
        target = os.path.join(dest, APP_FIXTURES, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(os.path.join(root, rel), target)
        copied.append(rel)
        if row[1] not in notes:
            notes.append(row[1])
    readme = ["# Engine test fixtures", "",
              "Media files the app's tests decode, probe or import. Every file here was generated by the project's own",
              "fixture scripts from synthetic signals (tools such as FFmpeg were used only to encode them); none comes",
              "from an outside collection. They are distributed with the app's tests under the repository's LICENSE.",
              "How each one was made:", "", "| Files | How generated |", "| --- | --- |"]
    readme += notes
    write(os.path.join(dest, APP_FIXTURES, "README.md"), "\n".join(readme) + "\n")
    note(f"  engine test fixtures: copied {len(copied)} project-generated files into {APP_FIXTURES}:")
    note("    " + ", ".join(copied))
    note("    generated instead: none needed; skipped: " + (", ".join(f"{r} ({why})" for r, why in refused) or "none"))
    for rel, why in refused:
        failures.append(f"{APP_FIXTURES}/{rel}: {why}: make the test that reads it generate its input "
                        f"(MediaTestSupport) or skip it in oneTake with a reason")


# ---- Comments and docs that named the old engine sources ----------------------------------------------------------

ENGINE = r"(?:\.\./)?engines/mpvfx-media-processing/crates"
TEXT_FIXES = [
    # App README: where the engine comes from, and its private documents.
    (r"the project's own media engine, the\n\[`" + ENGINE + r"`\]\(" + ENGINE + r"\) package: hand-written Rust \(no third-party code\) and its Swift wrapper, consumed\nas a SwiftPM dependency and linked in as a static library\.",
     "the project's own media engine, a\nproprietary prebuilt library (`binaries.lock`, `scripts/fetch-binaries.py`) that the app calls through its own Swift\nadapter, [`Sources/OneTakeMedia`](Sources/OneTakeMedia)."),
    (r"go through the `MpvfxMedia` product of the engine package\n  \(\[`" + ENGINE + r"/swift/Sources/MpvfxMedia`\]\(" + ENGINE + r"/swift/Sources/MpvfxMedia\)\), the Swift wrapper of the\n  engine's C ABI\.",
     "go through [`Sources/OneTakeMedia`](Sources/OneTakeMedia), the app's\n  Swift adapter over the engine's C interface."),
    (r"The contract is \[`" + ENGINE + r"/target/formats\.md`\]\(" + ENGINE + r"/target/formats\.md\)\.\n",
     "The media engine decides what each format supports; the app's list is `Sources/MpvfxRuntime/Media/ImportFormats.swift`.\n"),
    (r"HEVC and MP2 decode through the owner's ArtCraft crates, which the engine builds\.",
     "HEVC and MP2 decode inside the media engine."),
    (r" \(owner\s+question Q2 in\s+\[`" + ENGINE + r"/target/open-questions\.md`\]\(" + ENGINE + r"/target/open-questions\.md\)\)",
     " (not decided yet)"),
    (r", pending owner question Q2 in `" + ENGINE + r"/target/open-questions\.md`", ", not decided yet"),
    # The engine's private format table, named in comments and docs.
    (r"`" + ENGINE + r"/target/formats\.md`", "the media engine's format table"),
    (ENGINE + r"/target/formats\.md", "the media engine's format table"),
    # Fixtures now live with the app's tests.
    (r"`" + ENGINE + r"/fixtures/`", "`Tests/EngineFixtures/`"),
    # The engine's location in the old repository.
    (r"\(`" + ENGINE + r"`, linked in-process\)", "(a prebuilt library loaded in-process, `binaries.lock`)"),
    # Keyframe engine names.
    (r"the video-keyframing package \(Engine/VkfEngineKeyframeEngine\.swift\)",
     "the keyframe engine adapter OneTakeKeyframes (Engine/KeyframeRuntimeKeyframeEngine.swift)"),
    (r"the video-keyframing package \(product MpvfxEngine\)", "the keyframe engine adapter (module OneTakeKeyframes)"),
    (r"kept in the video-keyframing history", "kept in the keyframe engine's history"),
    (r"video-keyframing engine", "keyframe engine"),
    (r"ArtCraft's decoder in the engine", "the engine's decoder"),
    (r"the ArtCraft decoders the engine builds", "the engine's decoders"),
    # Build steps.
    (r"sh scripts/build-media\.sh && swift build", "python3 scripts/fetch-binaries.py && swift build"),
    (r"Build the media engine first \(scripts/build-media\.sh\)\.", "Fetch the engine libraries first (python3 scripts/fetch-binaries.py)."),
    (r"`scripts/gate\.sh` does", "`scripts/check.sh` does"),
    (r"\(scripts/gate\.sh builds before testing\)", "(scripts/check.sh builds before testing)"),
]


def text_fixes(dest):
    counts = [0] * len(TEXT_FIXES)
    for dirpath, _, files in os.walk(os.path.join(dest, "mpvfx-swift")):
        if APP_FIXTURES in dirpath.replace(os.sep, "/"):
            continue
        for name in files:
            if not name.endswith((".swift", ".md", ".sh", ".py")):
                continue
            path = os.path.join(dirpath, name)
            before = text = read(path)
            for i, (pattern, repl) in enumerate(TEXT_FIXES):
                text, n = re.subn(pattern, lambda m, r=repl: r, text)
                counts[i] += n
            if text != before:
                write(path, text)
    # The app's own message for a missing keyframe engine, as the parity fixture records it.
    parity = os.path.join(dest, "mpvfx-swift/Tests/MpvfxSharedTests/Engine/Fixtures/engineParity.json")
    if os.path.exists(parity):
        text = read(parity)
        fixed = text.replace("The video-keyframing engine is not loaded", "The keyframe engine is not loaded")
        if fixed != text:
            write(parity, fixed)
            counts[TEXT_FIXES.index((r"video-keyframing engine", "keyframe engine"))] += 1
    unused = [TEXT_FIXES[i][0][:70] for i, c in enumerate(counts) if c == 0]
    note(f"  rewrote {sum(counts)} comments and doc lines that named the old engine sources or build steps")
    if unused:
        note("    (patterns that matched nothing, fine if the old text is gone: " + "; ".join(unused) + ")")


# ---- Installers --------------------------------------------------------------------------------------------------------

def macos_package(text):
    text = sub_once(r'f=\$\(basename "\$d"\); src="\$d"; \[ -f "\$src" \] \|\| src="\$bin/\$f"',
                    'f=$(basename "$d"); src="$d"; [ -f "$src" ] || src="$bin/$f"\n'
                    '  [ -f "$src" ] || src=$(ls .binaries/*/lib/"$f" 2>/dev/null | head -n 1)   # engine dylibs (binaries.lock)\n'
                    '  [ -f "$src" ] || { echo "package.sh: cannot find $d to bundle" >&2; exit 1; }',
                    text, 0, "dylib copy loop")
    text = sub_once(r'(otool -l "\$app/Contents/MacOS/MpVFX" \| grep -q "@executable_path/\.\./Frameworks")',
                    '# Drop the build-time rpaths into .binaries/ so the app only looks inside its own bundle.\n'
                    'for r in $(otool -l "$app/Contents/MacOS/MpVFX" | awk \'$1 == "path" {print $2}\' | grep "/\\.binaries/" || true); do\n'
                    '  install_name_tool -delete_rpath "$r" "$app/Contents/MacOS/MpVFX"\n'
                    'done\n\\1', text, 0, "rpath check")
    text = sub_once(r'^(set_dir=)', 'for c in .binaries/*/; do   # each engine\'s licence and third-party notices travel with it\n'
                    '  c=$(basename "$c"); mkdir -p "$app/Contents/Resources/EngineLicenses/$c"\n'
                    '  cp .binaries/"$c"/LICENSE .binaries/"$c"/NOTICE "$app/Contents/Resources/EngineLicenses/$c/" 2>/dev/null || true\n'
                    'done\n\\1', text, re.M, "iconset line")
    return text


def linux_deb(text):
    text = sub_once(r'(strip --strip-unneeded "\$root/opt/mpvfx/MpVFX"\n)',
                    '\\1# The engine libraries (binaries.lock) go to /usr/lib/mpvfx; the program looks for them there.\n'
                    'mkdir -p "$root/usr/lib/mpvfx"\n'
                    'cp -L .binaries/*/lib/*.so* "$root/usr/lib/mpvfx/"\n'
                    'patchelf --set-rpath /usr/lib/mpvfx "$root/opt/mpvfx/MpVFX"\n'
                    'for c in .binaries/*/; do   # each engine\'s licence and third-party notices\n'
                    '  c=$(basename "$c"); mkdir -p "$root/usr/share/doc/mpvfx/engines/$c"\n'
                    '  cp .binaries/"$c"/LICENSE .binaries/"$c"/NOTICE "$root/usr/share/doc/mpvfx/engines/$c/" 2>/dev/null || true\n'
                    'done\n',
                    text, 0, "strip line")
    text = sub_once(r'for lib in \$\(objdump -p "\$root/opt/mpvfx/MpVFX" \| awk \'/NEEDED/ \{print \$2\}\'\); do\n',
                    'for lib in $(objdump -p "$root/opt/mpvfx/MpVFX" "$root"/usr/lib/mpvfx/*.so* | awk \'/NEEDED/ {print $2}\' | sort -u); do\n'
                    '  [ -e "$root/usr/lib/mpvfx/$lib" ] && continue   # shipped in the package\n',
                    text, 0, "NEEDED loop")
    text = text.replace("exported by its own media engine, linked into the program.",
                        "exported by its media engine, installed with it as a library.")
    return text


# ---- Copyright check -------------------------------------------------------------------------------------------------

def copyright_script(text):
    text = sub_once(r"copyright block \(owner ruling 2026-10-19, root AGENTS\.md, LICENSE\)\.", "copyright block (LICENSE).",
                    text, 0, "docstring first line")
    text = sub_once(r"^Not covered: .*?(?=^\"\"\")",
                    lambda m: "Not covered: test fixtures and files a generator writes whose output CI checks against it (their\n"
                              "generator carries the block; see GENERATED).\n", text, re.M | re.S, "'Not covered' paragraph")
    text = sub_once(r"^# The Swift editor continues.*?\n(?=OPEN_TEXT)",
                    "# The app continues the Apache-2.0 mpvfx app and is dual licensed (LICENSE).\n", text, re.M | re.S,
                    "licence comment above OPEN_TEXT")
    text = sub_once(r'^PRIVATE = \(.*?\)\n', 'PRIVATE = ()   # every file in this repository is under the app licence\n',
                    text, re.M | re.S, "PRIVATE tuple")
    text = sub_once(r'^SKIP = \(.*?\)\n', 'SKIP = ()\n', text, re.M | re.S, "SKIP tuple")
    text = sub_once(r'"/fixtures/" in path', '"/fixtures/" in path or "/EngineFixtures/" in path', text, 0,
                    "fixtures test in covered()")
    return text


# ---- App README ------------------------------------------------------------------------------------------------------

APP_BUILD = """Requirements: Swift 6.0 or newer and Python 3.11 or newer (for the engine download script).

- macOS 15 or newer: Xcode (SQLite and Core Audio come with the system).
- Linux: `libgtk-3-dev`, `libsqlite3-dev`, `pkg-config`; `libpulse-dev` for audio output.
- Windows 10 or 11: the Swift toolchain; put `.binaries\\media\\bin` and `.binaries\\keyframes\\bin` on `PATH` to run.

The media and keyframe engines are proprietary prebuilt libraries (see the repository's LICENSE).
[`binaries.lock`](binaries.lock) pins their versions and SHA-256 checksums; [`scripts/fetch-binaries.py`](scripts/fetch-binaries.py)
downloads and verifies them into `.binaries/`. The app's own Swift adapters over their C headers are
[`Sources/OneTakeMedia`](Sources/OneTakeMedia) and [`Sources/OneTakeKeyframes`](Sources/OneTakeKeyframes).

Installers (macOS disk image, Windows setup.exe, Ubuntu/Debian .deb) are built by CI; how to get, build and sign them: [`docs/PACKAGING.md`](docs/PACKAGING.md).

Run these from this folder, `mpvfx-swift/`:

```sh
python3 scripts/fetch-binaries.py   # engine libraries (again after binaries.lock changes)
swift build
swift run MpVFX                     # the standalone project (made on first launch)
MPVFX_DEMO=1 swift run MpVFX        # the built-in demo timeline
MPVFX_PROJECT=/path/to/project swift run MpVFX
sh scripts/check.sh                 # fetch, build, tests and the other checks CI runs first
```

If `swift build` reports "Could not find Package.swift", the shell is not in `mpvfx-swift/`; if it cannot find
`mpvfx_media.h` or `cvkf.h`, or the link step misses `mpvfx_media` or `cvkf`, run `python3 scripts/fetch-binaries.py`
first. `MPVFX_PROJECT` takes a project folder or its `.studio/project.json`.

"""


APP_CHECKS = """## Development and checks

From `mpvfx-swift/`, before every push:

```sh
sh scripts/check.sh          # engine libraries, fetch-script tests, copyright blocks, shaders, swift build, swift test
sh scripts/check.sh --fast   # the same without swift build and swift test
```

CI ([`../.github/workflows/mpvfx-ci.yml`](../.github/workflows/mpvfx-ci.yml)) builds, tests and packages the app on
Linux, Windows and macOS with the engine libraries pinned in [`binaries.lock`](binaries.lock); `ci-ok` is the
required check. How to contribute: [`../CONTRIBUTING.md`](../CONTRIBUTING.md).

"""


def app_readme(text):
    text = sub_once(r"^Requirements: Swift.*?(?=^## )", lambda m: APP_BUILD, text, re.M | re.S, "build section")
    text = sub_once(r"^## Development and checks\n.*?(?=^## )", lambda m: APP_CHECKS, text, re.M | re.S,
                    "development section")
    text = re.sub(r"\[`gate\.sh`\]\(scripts/gate\.sh\), \[`build-media\.sh`\]\(scripts/build-media\.sh\)",
                  "[`check.sh`](scripts/check.sh), [`fetch-binaries.py`](scripts/fetch-binaries.py)", text)
    return text


# ---- main --------------------------------------------------------------------------------------------------------------

def main(argv):
    fixtures = "copy"
    if argv[1:2] and argv[1].startswith("--engine-fixtures="):
        fixtures = argv.pop(1).split("=", 1)[1]
    if len(argv) != 3 or fixtures not in ("omit", "copy"):
        print(__doc__, file=sys.stderr)
        return 2
    src, dest = os.path.abspath(argv[1]), os.path.abspath(argv[2])
    if subprocess.run(["git", "-C", src, "rev-parse", "--git-dir"], capture_output=True).returncode != 0:
        print(f"snapshot.py: {src} is not a git checkout", file=sys.stderr)
        return 2
    if os.path.exists(dest) and os.listdir(dest):
        print(f"snapshot.py: {dest} is not empty", file=sys.stderr)
        return 2
    os.makedirs(dest, exist_ok=True)
    head = subprocess.run(["git", "-C", src, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    note(f"oneTake snapshot of {head}")
    note()

    copied, left_out, unlisted = [], {}, []
    for rel in tracked(src):
        kind, reason = classify(rel)
        if kind == "private":
            left_out.setdefault(reason, []).append(rel)
            continue
        if kind == "unlisted":
            unlisted.append(rel)
            continue
        target = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(os.path.join(src, rel), target)
        copied.append(rel)

    overlaid = []
    for dirpath, _, files in os.walk(OVERLAY):
        for name in files:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, OVERLAY).replace(os.sep, "/")
            target = os.path.join(dest, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(full, target)
            overlaid.append(rel)

    for rel, blob in OVERLAY_BASE.items():
        now = subprocess.run(["git", "-C", src, "rev-parse", f"HEAD:{rel}"], capture_output=True, text=True).stdout.strip()
        if now != blob:
            failures.append(f"{rel}: changed in the old repository since the oneTake copy in overlay/ was written "
                            f"(was {blob[:10]}, now {now[:10] or 'gone'}): merge the change into overlay/{rel}, then "
                            f"update OVERLAY_BASE")

    note("Rewrites")
    rewrite(dest, "mpvfx-swift/Package.swift", "engine source packages -> prebuilt engine targets", package_swift)
    swift_sources(dest)
    fixture_paths(dest)
    if fixtures == "copy":
        copy_fixtures(src, dest)
    else:
        note(f"  engine test fixtures NOT copied (--engine-fixtures=omit): the tests that read {APP_FIXTURES} will fail")
    rewrite(dest, ".github/ci/test-shards.py", "shard keys from binaries.lock instead of engine sources", test_shards)
    rewrite(dest, "mpvfx-swift/packaging/macos/package.sh", "bundle the engine dylibs, drop build rpaths", macos_package)
    rewrite(dest, "mpvfx-swift/packaging/linux/build-deb.sh", "engine libraries under /usr/lib/mpvfx", linux_deb)
    rewrite(dest, "mpvfx-swift/README.md", "build section for prebuilt engines", app_readme)
    text_fixes(dest)
    rewrite(dest, "mpvfx-swift/scripts/copyright.py", "only the app licence applies here", copyright_script)
    note()

    note(f"Copied {len(copied)} public files from the old repository; laid {len(overlaid)} oneTake files over them:")
    for rel in sorted(overlaid):
        note(f"  + {rel}")
    note()
    note(f"Left out {sum(len(v) for v in left_out.values())} files:")
    for reason, paths in sorted(left_out.items(), key=lambda kv: kv[0]):
        tops = sorted({"/".join(p.split("/")[:2]) if p.count("/") > 1 else p for p in paths})
        shown = ", ".join(tops[:8]) + (f", ... ({len(tops)} groups)" if len(tops) > 8 else "")
        note(f"  {len(paths):5d}  {reason}: {shown}")
    if unlisted:
        note()
        note(f"Not copied because no rule names them ({len(unlisted)}; add them to PUBLIC or PRIVATE):")
        for rel in unlisted:
            note(f"  ? {rel}")

    stale = []
    for dirpath, _, files in os.walk(dest):
        for name in files:
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, dest).replace(os.sep, "/")
            if rel.startswith("tools/") or rel.startswith(APP_FIXTURES):
                continue
            try:
                text = read(path)
            except (UnicodeDecodeError, OSError):
                continue
            for n, line in enumerate(text.split("\n"), 1):
                if STALE.search(line):
                    stale.append(f"  {rel}:{n}: {line.strip()[:140]}")
    note()
    note(f"Lines that still name an old engine path or name ({len(stale)}; edit before publishing or accept):")
    report.extend(stale)
    if failures:
        note()
        note("REWRITES THAT DID NOT APPLY (the old repository changed; update tools/snapshot/snapshot.py):")
        report.extend(f"  ! {f}" for f in failures)

    out = os.path.join(os.path.dirname(dest), "snapshot-report.txt")
    write(out, "\n".join(report) + "\n")
    print(f"snapshot: {len(copied)} copied, {len(overlaid)} overlaid, "
          f"{sum(len(v) for v in left_out.values())} left out, {len(unlisted)} unlisted, {len(stale)} stale lines, "
          f"{len(failures)} failed rewrites; report: {out}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
