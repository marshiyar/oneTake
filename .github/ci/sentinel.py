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
"""sentinel.py: what a video editor has no business doing, found in this repository or in what it ships.

  python3 -I -B .github/ci/sentinel.py repo [--root DIR]          the tracked tree: sources, scripts, workflows, files
  python3 -I -B .github/ci/sentinel.py artifact [--baseline DIR] [--write-imports DIR] <dir or file>...
                                                                  unpacked installers: every binary's imports

Not an antivirus: there is no signature database. It is a behaviour-surface check written for this app, which plays
and edits media on one machine and never talks to a network, spawns a shell, watches the keyboard or installs anything
persistent. Anything of that kind is a finding unless `.github/sentinel.toml` allows that exact place with a reason.

`repo` checks every tracked file (git ls-files):
  sources/scripts   network APIs, process spawning, dynamic loading, keyboard/screen capture, persistence, privilege,
                    anti-debugging, remote-code patterns (curl|sh, Invoke-Expression, base64-to-shell), eval/exec,
                    credential-shaped literals, Trojan Source characters (bidi and zero-width), long high-entropy
                    literals (obfuscated payloads)
  workflows         third-party actions not pinned to a commit, missing or write-all `permissions`, pull_request_target
                    or workflow_run checking out the pull request's head, GitHub-event text inside `run:` or `with:`
                    (expression injection), secrets echoed, unsecure-commands switch
  files             code in a file that should be data (ELF, PE, Mach-O, Java class magic anywhere), archives, anything
                    executable by mode that is not a script, files over the size limit
  binaries.lock     every download URL under this project's release host, every checksum 64 hex digits
`artifact` reads each ELF, PE or Mach-O (fat too) with its own headers, no external tool: the libraries it loads and the
functions it imports, against the forbidden sets (network, process spawning, input hooks, debugging, persistence) and,
with --baseline, against the recorded list for that binary (.github/sentinel-baseline/<name>.imports): any import that
is new since the last recorded release is a finding, so what ships never changes unnoticed.

Prints a Markdown table (file, rule, line or symbol, detail); exit 1 on any finding not allowed, 0 clean, 2 bad input.
"""
import argparse, fnmatch, math, os, re, struct, subprocess, sys, tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "..", "sentinel.toml")
SOURCE_EXT = {".swift", ".c", ".cpp", ".cc", ".cxx", ".h", ".hpp", ".hh", ".hxx", ".m", ".mm", ".metal", ".hlsl", ".glsl", ".comp", ".py", ".sh", ".ps1",
              ".cmd", ".bat", ".js", ".mjs", ".ts", ".rb", ".pl", ".yml", ".yaml", ".toml", ".json", ".md", ".txt",
              ".plist", ".inc", ".modulemap", ".iss", ".nsi", ".desktop"}
SCRIPT_EXT = {".py", ".sh", ".ps1", ".cmd", ".bat", ".js", ".mjs", ".ts", ".rb", ".pl"}
CODE_EXT = {".swift", ".c", ".cpp", ".cc", ".cxx", ".h", ".hpp", ".hh", ".hxx", ".m", ".mm"}
SIZE_LIMIT = 8 * 1024 * 1024
RELEASE_HOST = "https://github.com/marshiyar/mpvfx-media-binaries/releases/download/"

# (rule, which files, pattern, what it means). "code": the app's compiled sources; "script": scripts and workflows;
# "text": every tracked text file.
RULES = [
    ("network", "code", r"\b(URLSession|NWConnection|NWListener|NWBrowser|CFNetwork|CFSocket|CFStream|NSURLConnection|"
                        r"FoundationNetworking|getaddrinfo|gethostbyname|inet_addr|WSAStartup|WSASocket|WinHttp[A-Za-z]+|"
                        r"InternetOpen[A-Za-z]*|URLDownloadToFile|curl_easy_[a-z]+|libcurl|\bsocket\s*\(|"
                        r"\bsendto\s*\(|\brecvfrom\s*\()", "a network API in an app that never talks to a network"),
    ("process", "code", r"\b(Process\(\)|NSTask|posix_spawn[p]?|execv[pe]*\s*\(|execl[pe]*\s*\(|\bsystem\s*\(\s*\x22|"
                        r"\bpopen\s*\(|CreateProcess(AsUser)?[AW]?\s*\(|ShellExecute(Ex)?[AW]?\s*\(|WinExec\s*\(|"
                        r"NSAppleScript|osascript|NSWorkspace\.shared\.open)", "spawning a program or a shell"),
    ("dynamic-load", "code", r"\b(dlopen|dlsym|LoadLibrary(Ex)?[AW]?|GetProcAddress)\s*\(",
     "loading code at run time by name"),
    ("surveillance", "code", r"\b(CGEventTapCreate|CGEventTapEnable|CGWindowListCreateImage|CGDisplayCreateImage|"
                             r"SetWindowsHookEx[AW]?|GetAsyncKeyState|RegisterRawInputDevices|XRecordCreateContext|"
                             r"AVCaptureDevice|AVCaptureSession|IOHIDManager|SCShareableContent|SCStream)\b",
     "keyboard, screen or camera capture"),
    ("persistence", "code+script", r"(LaunchAgents|LaunchDaemons|SMLoginItemSetEnabled|SMAppService|"
                                   r"CurrentVersion\\+Run(Once)?\b|\bcrontab\b|systemctl\s+enable|/etc/init\.d|"
                                   r"\bschtasks\b|StartupItems|\.config/autostart)", "making something run again at login or boot"),
    ("privilege", "code+script", r"\b(AuthorizationExecuteWithPrivileges|AuthorizationCreate|SeDebugPrivilege|"
                                 r"AdjustTokenPrivileges|setuid\s*\(|seteuid\s*\(|RunAs|runas\b|Start-Process[^\n]*-Verb\s+RunAs)",
     "taking privileges"),
    ("anti-debug", "code", r"\b(ptrace\s*\(|IsDebuggerPresent|CheckRemoteDebuggerPresent|NtQueryInformationProcess|"
                           r"P_TRACED|KERN_PROC\b)", "checking for a debugger"),
    ("remote-code", "script", r"((curl|wget|Invoke-WebRequest|iwr)\b[^\n|]*\|\s*(sudo\s+)?(ba|z|da)?sh\b|"
                              r"base64\s+(-d|--decode)[^\n|]*\|\s*(ba|z|da)?sh\b|Invoke-Expression|\biex\b|"
                              r"DownloadString\s*\(|FromBase64String\s*\()", "running what was downloaded or decoded"),
    ("eval", "script", r"(\beval\s*\(|\bexec\s*\(|\bexecfile\s*\(|subprocess\.[a-zA-Z_]+\([^\n]*shell\s*=\s*True|"
                       r"os\.system\s*\(|\bcompile\s*\([^\n]*exec)", "evaluating text as code"),
    ("secret", "text", r"(AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|gho_[A-Za-z0-9]{36}|"
                       r"xox[abpr]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{32,}|-----BEGIN (RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----|"
                       r"AIza[0-9A-Za-z_-]{35})", "a credential-shaped literal"),
    ("trojan-source", "text", "[‪-‮⁦-⁩​-‍⁠﻿؜᠎]",
     "a bidi or zero-width character that renders differently from what the compiler reads"),
]
LITERAL = re.compile(r'"([A-Za-z0-9+/=_-]{80,})"')
WORKFLOW_EVENT = re.compile(r"\$\{\{[^}]*github\.(event\.(issue|comment|pull_request|review|review_comment|discussion|"
                            r"commits|head_commit|workflow_run|inputs)(\.[A-Za-z_]+|\[[^\]]*\])*\.(title|body|message|name|"
                            r"email|ref|head_ref|head_branch|branch|default_branch|login|description|path)\b|head_ref)")
ENV_LINE = re.compile(r"^\s*[A-Za-z_][A-Za-z0-9_]*:\s*\$\{\{")
ENV_VALUE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*):")
USES = re.compile(r"^\s*-?\s*uses:\s*([^\s#]+)")
NETWORK_IMPORTS = {"connect", "socket", "getaddrinfo", "gethostbyname", "gethostbyname2", "getnameinfo", "sendto",
                   "recvfrom", "bind", "listen", "accept", "accept4", "inet_pton", "inet_addr", "WSAStartup", "WSASocketW",
                   "WSAConnect", "WinHttpOpen", "WinHttpConnect", "InternetOpenW", "InternetOpenA", "InternetOpenUrlW",
                   "URLDownloadToFileW", "curl_easy_init", "SSL_connect", "CFSocketCreate", "CFStreamCreatePairWithSocketToHost",
                   "getifaddrs", "res_query"}
SPAWN_IMPORTS = {"execve", "execv", "execvp", "execl", "execlp", "posix_spawn", "posix_spawnp", "system", "popen", "fork",
                 "vfork", "CreateProcessW", "CreateProcessA", "CreateProcessAsUserW", "ShellExecuteW", "ShellExecuteExW",
                 "WinExec", "ShellExecuteA"}
HOOK_IMPORTS = {"SetWindowsHookExW", "SetWindowsHookExA", "GetAsyncKeyState", "RegisterRawInputDevices",
                "CGEventTapCreate", "CGWindowListCreateImage", "CGDisplayCreateImage", "XRecordCreateContext"}
DEBUG_IMPORTS = {"ptrace", "IsDebuggerPresent", "CheckRemoteDebuggerPresent", "NtQueryInformationProcess"}
PERSIST_IMPORTS = {"SMLoginItemSetEnabled", "RegSetValueExW", "RegCreateKeyExW", "AuthorizationExecuteWithPrivileges",
                   "AdjustTokenPrivileges"}
IMPORT_SETS = [("network", NETWORK_IMPORTS), ("spawn", SPAWN_IMPORTS), ("input-hook", HOOK_IMPORTS),
               ("anti-debug", DEBUG_IMPORTS), ("persistence", PERSIST_IMPORTS)]
NETWORK_LIBS = re.compile(r"(winhttp|wininet|ws2_32|urlmon|libcurl|libssl|CFNetwork|Network\.framework|libnghttp|wsock32)", re.I)


class Findings:
    def __init__(self, config):
        self.rows, self.allowed, self.config = [], 0, config

    def add(self, path, rule, where, detail):
        for a in self.config.get("allow", []):
            if a.get("rule") == rule and fnmatch.fnmatch(path, a.get("path", "")) and \
                    (not a.get("match") or a["match"] in detail or a["match"] in str(where)):
                self.allowed += 1
                self.rows.append((path, rule, where, detail, "allowed: " + a.get("reason", "")))
                return
        self.rows.append((path, rule, where, detail, "**FINDING**"))

    def failures(self):
        return sum(1 for r in self.rows if r[4] == "**FINDING**")

    def table(self):
        lines = ["| file | rule | where | detail | verdict |", "|---|---|---|---|---|"]
        for path, rule, where, detail, verdict in self.rows:
            detail = detail.replace("|", "\\|")
            lines.append(f"| `{path}` | {rule} | {where} | {detail[:160]} | {verdict} |")
        return "\n".join(lines)


def load_config():
    try:
        return tomllib.load(open(CONFIG, "rb"))
    except FileNotFoundError:
        return {}


def skipped(path, config):
    return any(fnmatch.fnmatch(path, g) for g in config.get("skip", []))


def entropy(s):
    counts = {c: s.count(c) for c in set(s)}
    return -sum(n / len(s) * math.log2(n / len(s)) for n in counts.values())


# --- repo ------------------------------------------------------------------------------------------------------------

def tracked(root):
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True, check=True).stdout
    return [p.decode("utf-8", "surrogateescape") for p in out.split(b"\0") if p]


def scan_text(path, text, f):
    ext = os.path.splitext(path)[1].lower()
    is_code, is_script = ext in CODE_EXT, ext in SCRIPT_EXT or path.startswith(".github/workflows/")
    for rule, scope, pattern, meaning in RULES:
        applies = (scope == "text" or ("code" in scope and is_code) or ("script" in scope and is_script))
        if not applies:
            continue
        for m in re.finditer(pattern, text):
            line = text.count("\n", 0, m.start()) + 1
            f.add(path, rule, f"line {line}", f"{meaning}: `{m.group(0).strip()[:60]}`")
    if is_code or is_script:
        for m in LITERAL.finditer(text):
            lit = m.group(1)
            if entropy(lit) >= 4.6:
                line = text.count("\n", 0, m.start()) + 1
                f.add(path, "obfuscation", f"line {line}", f"{len(lit)}-character literal with entropy {entropy(lit):.1f} bits/char")


EVENT_HEAD = re.compile(r"\$\{\{[^}]*github\.(event\.(pull_request|workflow_run)\.(head|pull_requests)|head_ref)")
ENV_BLOCK = re.compile(r"^(\s*(?:-\s+)?)env:\s*(#.*)?$")


def scan_workflow(path, text, f):
    if not re.search(r"^permissions:", text, re.M):
        f.add(path, "workflow-permissions", "file", "no top-level `permissions:`: the token gets the default write set")
    if re.search(r"^permissions:\s*write-all", text, re.M) or re.search(r"^\s+permissions:\s*write-all", text, re.M):
        f.add(path, "workflow-permissions", "file", "`permissions: write-all`")
    env_indent = None   # column of the `env:` key whose mapping the current line sits in; only there is `KEY: ${{ }}` safe
    event_vars = set()  # env variables that carry the pull request's head (repository, ref, branch)
    lines = text.splitlines()
    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            indent = len(line) - len(line.lstrip())
            if env_indent is not None and indent <= env_indent:
                env_indent = None
            e = ENV_BLOCK.match(line)
            if e:
                env_indent = len(e.group(1))
        in_env = env_indent is not None and not ENV_BLOCK.match(line)
        if in_env:
            m = ENV_VALUE.match(line)
            if m and EVENT_HEAD.search(line):
                event_vars.add(m.group(1))
        m = USES.match(line)
        if m:
            action = m.group(1).strip("'\"")
            if action.startswith("./") or action.startswith("docker://"):
                continue
            ref = action.split("@", 1)[1] if "@" in action else ""
            owner = action.split("/", 1)[0]
            if not re.fullmatch(r"[0-9a-f]{40}", ref):
                f.add(path, "workflow-unpinned-action", f"line {i}", f"action not pinned to a commit: `{action}`")
            if not ref:
                f.add(path, "workflow-unpinned-action", f"line {i}", f"action without a version: `{action}`")
        if WORKFLOW_EVENT.search(line) and not (in_env and ENV_LINE.match(line)):
            f.add(path, "workflow-injection", f"line {i}", "GitHub-event text used outside an `env:` assignment")
        if re.search(r"\becho\b[^\n]*\$\{\{\s*secrets\.", line):
            f.add(path, "workflow-secret-echo", f"line {i}", "a secret written to the log")
        if "ACTIONS_ALLOW_UNSECURE_COMMANDS" in line:
            f.add(path, "workflow-unsecure-commands", f"line {i}", "unsecure workflow commands switched on")
    dangerous_trigger = re.search(r"\b(pull_request_target|workflow_run)\b", text)
    if dangerous_trigger:
        direct = re.search(r"\b(?:ref|repository):\s*['\"]?\$\{\{\s*github\.(event\.(pull_request|workflow_run)\.(head|pull_requests)|head_ref)", text)
        routed = event_vars and re.search(
            r"^\s*-?\s*(?:ref|repository):\s*['\"]?\$\{\{\s*env\.(" + "|".join(map(re.escape, sorted(event_vars))) + r")\b", text, re.M)
        if direct or routed:
            f.add(path, "workflow-pwn-request", "file",
                  f"`{dangerous_trigger.group(1)}` workflow checks out the pull request's head with the repository's token")


def code_magic(data):
    if data[:4] == b"\x7fELF":
        return "ELF"
    if data[:2] == b"MZ" and len(data) > 0x40:
        off, = struct.unpack_from("<I", data, 0x3C)
        if 0 < off < len(data) - 4 and data[off:off + 4] == b"PE\0\0":
            return "PE"
    magic = data[:4]
    if magic in (b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe"):
        return "Mach-O"
    if magic == b"\xca\xfe\xba\xbe":
        return "Mach-O fat or Java class"
    if data[:2] == b"#!" and b"\n" in data[:200]:
        return None  # a script by shebang: judged by its text rules, and by mode below
    return None


def scan_files(root, paths, config, f):
    archives = {".zip", ".7z", ".rar", ".tar", ".gz", ".tgz", ".xz", ".bz2", ".dmg", ".pkg", ".msi", ".exe", ".dll",
                ".so", ".dylib", ".a", ".o", ".jar", ".war", ".apk", ".deb", ".rpm", ".iso", ".bin", ".com", ".scr"}
    for rel in paths:
        path = os.path.join(root, rel)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        size = os.path.getsize(path)
        ext = os.path.splitext(rel)[1].lower()
        if size > SIZE_LIMIT:
            f.add(rel, "file-size", "file", f"{size:,} bytes tracked (limit {SIZE_LIMIT:,})")
        if ext in archives:
            f.add(rel, "file-archive-or-binary", "file", f"a `{ext}` file in the source tree")
        with open(path, "rb") as fh:
            head = fh.read(4096)
        kind = code_magic(head)
        if kind:
            f.add(rel, "file-code-in-data", "file", f"{kind} image tracked as a file")
        mode = os.stat(path).st_mode
        if mode & 0o111 and ext not in SCRIPT_EXT and not head.startswith(b"#!"):
            f.add(rel, "file-executable", "file", "executable by mode but neither a script nor marked with a shebang")


def scan_lock(root, f):
    rel = os.path.join("mpvfx-swift", "binaries.lock")
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        return
    text = open(path, encoding="utf-8").read()
    for i, line in enumerate(text.splitlines(), 1):
        for url in re.findall(r"https?://[^\s\"']+", line):
            if not url.startswith(RELEASE_HOST):
                f.add(rel, "lock-download-host", f"line {i}", f"download not under this project's release host: `{url}`")
        m = re.search(r"sha256\s*=\s*\"([^\"]*)\"", line)
        if m and not re.fullmatch(r"[0-9a-f]{64}", m.group(1)):
            f.add(rel, "lock-checksum", f"line {i}", "sha256 is not 64 hex digits")


def scan_repo(root, config, f):
    paths = tracked(root)
    for rel in paths:
        if skipped(rel, config):
            continue
        ext = os.path.splitext(rel)[1].lower()
        if ext in SOURCE_EXT or rel.startswith(".github/") or "/scripts/" in rel or "/packaging/" in rel:
            try:
                text = open(os.path.join(root, rel), encoding="utf-8").read()
            except (UnicodeDecodeError, OSError):
                continue
            scan_text(rel, text, f)
            if rel.startswith(".github/workflows/") and ext in (".yml", ".yaml"):
                scan_workflow(rel, text, f)
    scan_files(root, paths, config, f)   # the skip list is for the text rules; magic, archive, mode and size cover every file
    scan_lock(root, f)


# --- artifact ----------------------------------------------------------------------------------------------------------

class NoImportData(Exception):
    """A binary whose import metadata could not be read: reported as a finding, never as an empty import set."""


def elf_dynamic_imports(data, cls, endian):
    """Imports through the program headers (PT_DYNAMIC), for an executable that has no section header table."""
    if cls == 2:
        phoff, = struct.unpack_from(endian + "Q", data, 0x20); phentsize, phnum = struct.unpack_from(endian + "HH", data, 0x36)
    else:
        phoff, = struct.unpack_from(endian + "I", data, 0x1C); phentsize, phnum = struct.unpack_from(endian + "HH", data, 0x2A)
    loads, dyn = [], None
    for i in range(phnum):
        base = phoff + i * phentsize
        kind, = struct.unpack_from(endian + "I", data, base)
        if cls == 2:
            off, vaddr, _, filesz = struct.unpack_from(endian + "QQQQ", data, base + 8)
        else:
            off, vaddr, _, filesz = struct.unpack_from(endian + "IIII", data, base + 4)
        if kind == 1:
            loads.append((vaddr, filesz, off))
        elif kind == 2:
            dyn = (off, filesz)
    if dyn is None:
        raise NoImportData("ELF with neither section headers nor a PT_DYNAMIC segment: its imports cannot be read")

    def fo(vaddr):
        for va, size, off in loads:
            if va <= vaddr < va + size:
                return off + vaddr - va
        raise NoImportData("ELF dynamic table points outside its loadable segments")

    step = 16 if cls == 2 else 8
    needed, tags = [], {}
    for j in range(dyn[1] // step):
        tag, val = struct.unpack_from(endian + ("qQ" if cls == 2 else "iI"), data, dyn[0] + j * step)
        if tag == 0:
            break
        if tag == 1:
            needed.append(val)
        else:
            tags[tag] = val
    libs, funcs = [], set()
    if 5 not in tags:   # DT_STRTAB
        if needed:
            raise NoImportData("ELF dynamic table has DT_NEEDED but no string table")
        return libs, funcs
    strtab = fo(tags[5])
    for val in needed:
        libs.append(data[strtab + val:data.index(b"\0", strtab + val)].decode("ascii", "replace"))
    if 6 in tags:   # DT_SYMTAB: the symbols run up to the string table, which the linker places right after them
        symtab, entsize = fo(tags[6]), tags.get(11, 24 if cls == 2 else 16)
        count = (strtab - symtab) // entsize if strtab > symtab else 0
        for j in range(count):
            e = symtab + j * entsize
            if cls == 2:
                st_name, st_info, _, st_shndx = struct.unpack_from(endian + "IBBH", data, e)
            else:
                st_name, = struct.unpack_from(endian + "I", data, e); st_shndx, = struct.unpack_from(endian + "H", data, e + 14)
            if st_shndx == 0 and st_name:
                funcs.add(data[strtab + st_name:data.index(b"\0", strtab + st_name)].decode("ascii", "replace"))
    return libs, funcs


def elf_imports(data):
    cls, endian = data[4], ("<" if data[5] == 1 else ">")
    if cls == 2:
        shoff, = struct.unpack_from(endian + "Q", data, 0x28); shentsize, shnum = struct.unpack_from(endian + "HH", data, 0x3A)
    else:
        shoff, = struct.unpack_from(endian + "I", data, 0x20); shentsize, shnum = struct.unpack_from(endian + "HH", data, 0x2E)
    if not shoff or not shnum:
        return elf_dynamic_imports(data, cls, endian)
    sections = []
    for i in range(shnum):
        base = shoff + i * shentsize
        name, kind, = struct.unpack_from(endian + "II", data, base)
        if cls == 2:
            off, size = struct.unpack_from(endian + "QQ", data, base + 0x18); link, = struct.unpack_from(endian + "I", data, base + 0x28)
            entsize, = struct.unpack_from(endian + "Q", data, base + 0x38)
        else:
            off, size = struct.unpack_from(endian + "II", data, base + 0x10); link, = struct.unpack_from(endian + "I", data, base + 0x18)
            entsize, = struct.unpack_from(endian + "I", data, base + 0x24)
        sections.append((kind, off, size, link, entsize))
    libs, funcs = [], set()
    for kind, off, size, link, entsize in sections:
        if kind == 11 and entsize:   # SHT_DYNSYM
            _, soff, ssize, _, _ = sections[link]
            strs = data[soff:soff + ssize]
            for j in range(size // entsize):
                e = off + j * entsize
                if cls == 2:
                    st_name, st_info, _, st_shndx = struct.unpack_from(endian + "IBBH", data, e)
                else:
                    st_name, = struct.unpack_from(endian + "I", data, e); st_shndx, = struct.unpack_from(endian + "H", data, e + 14)
                if st_shndx == 0 and st_name:
                    funcs.add(strs[st_name:strs.index(b"\0", st_name)].decode("ascii", "replace"))
        if kind == 6:   # SHT_DYNAMIC: DT_NEEDED
            _, soff, ssize, _, _ = sections[link]
            strs = data[soff:soff + ssize]
            step = 16 if cls == 2 else 8
            for j in range(size // step):
                e = off + j * step
                tag, val = struct.unpack_from(endian + ("qQ" if cls == 2 else "iI"), data, e)
                if tag == 1:
                    libs.append(strs[val:strs.index(b"\0", val)].decode("ascii", "replace"))
    return libs, funcs


def pe_imports(data):
    off, = struct.unpack_from("<I", data, 0x3C)
    coff = off + 4
    nsections, optsize = struct.unpack_from("<H", data, coff + 2)[0], struct.unpack_from("<H", data, coff + 16)[0]
    opt = coff + 20
    magic, = struct.unpack_from("<H", data, opt)
    plus = magic == 0x20B
    dirs = opt + (112 if plus else 96)
    sections = []
    for i in range(nsections):
        base = opt + optsize + i * 40
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, base + 8)
        sections.append((vaddr, max(vsize, rawsize), rawptr))

    def fo(rva):
        for vaddr, size, rawptr in sections:
            if vaddr <= rva < vaddr + size:
                return rawptr + rva - vaddr
        return None

    def cstr(rva):
        o = fo(rva)
        return data[o:data.index(b"\0", o)].decode("ascii", "replace") if o is not None else "?"

    libs, funcs = [], set()

    def walk(rva, stride, name_at, thunk_at, first_at):
        base = fo(rva) if rva else None
        while base is not None:
            fields = struct.unpack_from("<%dI" % (stride // 4), data, base)
            name_rva = fields[name_at]
            if not name_rva:
                break
            libs.append(cstr(name_rva))
            thunk = fo(fields[thunk_at] or fields[first_at])
            step = 8 if plus else 4
            while thunk is not None:
                val, = struct.unpack_from("<Q" if plus else "<I", data, thunk)
                if not val:
                    break
                if not (val >> (63 if plus else 31)):
                    funcs.add(cstr((val & 0x7FFFFFFF) + 2))
                thunk += step
            base += stride

    ndirs, = struct.unpack_from("<I", data, dirs - 4)
    imp_rva, _ = struct.unpack_from("<II", data, dirs + 1 * 8)
    walk(imp_rva, 20, 3, 0, 4)                 # IMAGE_IMPORT_DESCRIPTOR: OriginalFirstThunk, Name, FirstThunk
    if ndirs > 13:                              # delay-load imports: IMAGE_DELAYLOAD_DESCRIPTOR, name at +4, INT at +16
        delay_rva, _ = struct.unpack_from("<II", data, dirs + 13 * 8)
        walk(delay_rva, 32, 1, 4, 3)
    return libs, funcs


def macho_imports(data, base=0):
    magic, = struct.unpack_from("<I", data, base)
    is64 = magic in (0xFEEDFACF, 0xCFFAEDFE)
    endian = ">" if magic in (0xCFFAEDFE, 0xCEFAEDFE) else "<"
    ncmds, = struct.unpack_from(endian + "I", data, base + 16)
    cmd_off = base + (32 if is64 else 28)
    libs, funcs = [], set()
    for _ in range(ncmds):
        cmd, size = struct.unpack_from(endian + "II", data, cmd_off)
        if cmd in (0xC, 0x80000018, 0x1F, 0x80000023):   # LOAD_DYLIB, LOAD_WEAK, REEXPORT, LOAD_UPWARD
            name_off, = struct.unpack_from(endian + "I", data, cmd_off + 8)
            raw = data[cmd_off + name_off:cmd_off + size]
            libs.append(raw[:raw.index(b"\0")].decode("ascii", "replace") if b"\0" in raw else raw.decode("ascii", "replace"))
        elif cmd == 0x2:   # SYMTAB
            symoff, nsyms, stroff, strsize = struct.unpack_from(endian + "IIII", data, cmd_off + 8)
            strs = data[base + stroff:base + stroff + strsize]
            entry = 16 if is64 else 12
            for i in range(nsyms):
                n_strx, = struct.unpack_from(endian + "I", data, base + symoff + i * entry)
                n_type = data[base + symoff + i * entry + 4]
                if not (n_type & 0xE0) and (n_type & 0x0E) == 0 and n_strx:
                    name = strs[n_strx:strs.find(b"\0", n_strx)].decode("ascii", "replace")
                    funcs.add(name[1:] if name.startswith("_") else name)
        cmd_off += size
    return libs, funcs


def imports(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) < 64:
        return None
    if data[:4] == b"\x7fELF":
        return ("ELF",) + elf_imports(data)
    if data[:2] == b"MZ":
        off, = struct.unpack_from("<I", data, 0x3C)
        if off + 4 <= len(data) and data[off:off + 4] == b"PE\0\0":
            return ("PE",) + pe_imports(data)
        return None
    magic, = struct.unpack_from(">I", data, 0)
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        n, = struct.unpack_from(">I", data, 4)
        libs, funcs = [], set()
        for i in range(n):
            o, = struct.unpack_from(">I", data, 8 + i * 20 + 8) if magic == 0xCAFEBABE else struct.unpack_from(">Q", data, 8 + i * 32 + 8)
            l, s = macho_imports(data, o); libs += l; funcs |= s
        return "Mach-O", libs, funcs
    if magic in (0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE):
        return ("Mach-O",) + macho_imports(data)
    return None


def baseline_lines(libs, funcs):
    return [f"lib {l}" for l in sorted(set(libs))] + [f"fn {s}" for s in sorted(funcs)]


def compare_baseline(shown, name, libs, funcs, baseline, out_dir, f):
    """The binary's imports against .github/sentinel-baseline/<name>.imports: every new library or function is a
    finding (what ships changed; the pull request that changed it updates the baseline), a missing baseline too. The
    current list is written to out_dir so the run's artifact holds the file to commit."""
    now = baseline_lines(libs, funcs)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
        with open(os.path.join(out_dir, name + ".imports"), "w", encoding="utf-8") as fh:
            fh.write("\n".join(now) + "\n")
    path = os.path.join(baseline, name + ".imports")
    if not os.path.isfile(path):
        f.add(shown, "import-baseline", "file", f"no baseline `{os.path.relpath(path)}`: {len(now)} imports to record")
        return
    known = set(open(path, encoding="utf-8").read().split("\n"))
    for line in now:
        if line not in known:
            f.add(shown, "import-added", line, f"not in `{os.path.basename(path)}`")
    gone = sorted(l for l in known if l and l not in set(now))
    if gone:
        f.rows.append((shown, "import-removed", f"{len(gone)}", ", ".join(gone[:8]) + (" …" if len(gone) > 8 else ""), "info"))


def scan_artifacts(roots, config, f, baseline=None, out_dir=None):
    seen = 0
    for root in roots:
        files = [root] if os.path.isfile(root) else [os.path.join(d, n) for d, _, ns in os.walk(root) for n in sorted(ns)]
        for path in files:
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                result = imports(path)
            except (NoImportData, struct.error, ValueError, IndexError) as e:
                if any(fnmatch.fnmatch(os.path.basename(path), g) for g in config.get("skip", [])):
                    continue
                seen += 1
                f.add(os.path.relpath(path, root if os.path.isdir(root) else os.path.dirname(root)),
                      "import-unreadable", "file", f"imports could not be read: {e}")
                continue
            if not result:
                continue
            if any(fnmatch.fnmatch(os.path.basename(path), g) for g in config.get("skip", [])):
                continue
            seen += 1
            fmt, libs, funcs = result
            shown = os.path.relpath(path, root if os.path.isdir(root) else os.path.dirname(root))
            if baseline:
                compare_baseline(shown, os.path.basename(path), libs, funcs, baseline, out_dir, f)
            for lib in libs:
                if NETWORK_LIBS.search(lib):
                    f.add(shown, "import-network-library", lib, f"{fmt} loads a network library")
            for name, wanted in IMPORT_SETS:
                hit = sorted(funcs & wanted)
                for sym in hit:
                    f.add(shown, "import-" + name, sym, f"{fmt} imports `{sym}`")
            f.rows.append((shown, "imports", f"{len(libs)} libraries", f"{len(funcs)} functions; libraries: " + ", ".join(libs[:12]) +
                           (f" (+{len(libs) - 12})" if len(libs) > 12 else ""), "info"))
    if not seen:
        print("sentinel: no ELF, PE or Mach-O file under the given paths", file=sys.stderr)
        sys.exit(2)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    r = sub.add_parser("repo"); r.add_argument("--root", default=os.path.abspath(os.path.join(HERE, "..", "..")))
    a = sub.add_parser("artifact"); a.add_argument("paths", nargs="+")
    a.add_argument("--baseline", help="directory of <binary>.imports files; new imports are findings")
    a.add_argument("--write-imports", metavar="DIR", help="write each binary's current import list here")
    args = ap.parse_args()
    config = load_config()
    f = Findings(config.get(args.mode, {}))
    if args.mode == "repo":
        scan_repo(args.root, config.get("repo", {}), f)
    else:
        scan_artifacts(args.paths, config.get("artifact", {}), f, args.baseline, args.write_imports)
    print(f.table())
    print()
    n = f.failures()
    print(f"sentinel {args.mode}: {len(f.rows)} rows, {f.allowed} allowed, {n} findings")
    sys.exit(1 if n else 0)


if __name__ == "__main__":
    main()
