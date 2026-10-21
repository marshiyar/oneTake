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
"""agentbot.py: the repository's own bots, run by .github/workflows/agentbot.yml after a workflow finishes.

  agentbot.py digest  <run id>               one comment per pull request: each failing job of that CI run, with the
                                             lines that name the failure (compiler errors, failed assertions, failed
                                             test cases), edited in place on every run; "all green" when it passes
  agentbot.py flakes  <run id>               a CI run that passed on a re-run: the tests (or jobs) that failed on the
                                             earlier attempts are recorded in the issue "Flaky tests", with counts
  agentbot.py shots   <run id> <out dir>     a pull request that touches UI code: each OS's launch-smoke PNG against
                                             main's latest, changed-pixel share and mean change, and a diff image
                                             written to <out dir> for upload; one comment
  agentbot.py bench   <run id>               a bench run on a pull request: each metric's p50 and p95 against main's
                                             latest bench run on the same runner class; one comment
  agentbot.py bench-runners <run id> <pr> <head sha>
                                             the same for a pull request's bench run on OneTake-actionRunners-1
                                             (<run id> is that repository's run; read with $RUNNERS_TOKEN)

Talks to the REST API with $GITHUB_TOKEN ($GITHUB_REPOSITORY names the repository); stdlib only. Never fails the
workflow over a bot problem it can report instead (exit 0 with a ::warning::); exit 2 on bad arguments.
"""
import io, json, os, re, struct, sys, urllib.error, urllib.request, zipfile, zlib

API = "https://api.github.com"
REPO = os.environ.get("GITHUB_REPOSITORY", "")
TOKEN = os.environ.get("GITHUB_TOKEN", "")
# bench.yml sends the benchmarks of main and of this repository's pull requests to the organization's runner pool;
# their artifacts are in that repository's onetake-bench.yml runs, read with a token for it (agentbot.yml mints one).
RUNNERS_REPO = "OneTake-app/OneTake-actionRunners-1"
RUNNERS_TOKEN = os.environ.get("RUNNERS_TOKEN", "")
# onetake-bench.yml's run-name: "onetake-bench <kind> <sha>"; kind main is a baseline, kind pr a pull request's run.
RUNNERS_BENCH = ("linux", "macos")   # the bench.yml jobs bench-source.yml runs there; windows always runs here
RUNNERS_TITLE = re.compile(r"^onetake-bench (main|pr|branch) ([0-9a-f]{40})$")
CI = "mpvfx-ci"
MAX_COMMENT = 60000
MAX_PIXELS = 4096 * 4096
FENCE = "`" * 3
UI_PATHS = re.compile(r"^mpvfx-swift/Sources/(MpvfxDesktop|MpvfxDesktopCore|MpvfxPanels|MpvfxTimeline|MpvfxCanvas|"
                      r"MpvfxTheme|MpvfxPlayer|CMpvfxWin32)/")


# --- REST ---------------------------------------------------------------------------------------------------------------

class _NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    """Logs and artifacts redirect to signed storage URLs, which refuse a second Authorization header."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            new.remove_header("Authorization")
        return new


_opener = urllib.request.build_opener(_NoAuthRedirect)


def api(method, path, body=None, raw=False, limit=None, repo=None, token=None):
    """limit: with raw, the most bytes to read; a longer body raises ValueError. repo and token: another repository
    than $GITHUB_REPOSITORY, read with its own token."""
    url = path if path.startswith("http") else f"{API}/repos/{repo or REPO}/{path.lstrip('/')}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token or TOKEN}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "mpvfx-agentbot"})
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with _opener.open(req, timeout=120) as r:
        payload = r.read(limit + 1) if limit else r.read()
    if limit and len(payload) > limit:
        raise ValueError(f"{path}: more than {limit} bytes")
    return payload if raw else (json.loads(payload) if payload else None)


def pages(path, key):
    out, page = [], 1
    while True:
        sep = "&" if "?" in path else "?"
        got = api("GET", f"{path}{sep}per_page=100&page={page}")
        items = got[key] if key else got
        out += items
        if len(items) < 100:
            return out
        page += 1


def run_prs(run):
    nums = [p["number"] for p in run.get("pull_requests") or []]
    if not nums:
        nums = [p["number"] for p in api("GET", f"commits/{run['head_sha']}/pulls") if p.get("state") == "open"]
    return nums


def upsert_comment(pr, marker, body):
    """Edits this bot's comment carrying `marker` on the pull request, or adds one."""
    body = f"<!-- {marker} -->\n" + body
    if len(body) > MAX_COMMENT:
        body = body[:MAX_COMMENT - 200] + "\n\n_(cut at the comment size limit; the full logs are linked above)_\n"
    for c in pages(f"issues/{pr}/comments", None):
        if f"<!-- {marker} -->" in (c.get("body") or "") and c.get("user", {}).get("type") == "Bot":
            api("PATCH", f"issues/comments/{c['id']}", {"body": body})
            return
    api("POST", f"issues/{pr}/comments", {"body": body})


# --- failures in a log ------------------------------------------------------------------------------------------------

STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
PRIMARY = re.compile(r"(: error: |^error(\[E\d+\])?: |Test Case '[^']+' failed|✘ |recorded an issue|Fatal error:|"
                     r"^FAIL: |^ERROR: |Traceback \(most recent call last\)|^##\[error\](?!Process completed with exit code))")
NOISE = re.compile(r"^(##\[(group|endgroup)\]|shell: |env:$|  [A-Z_]+: |\[command\]|Post job cleanup|Cleaning up|"
                   r"Test Case '[^']+' (started|passed)|--- batch |Test Suite '[^']+' (started|passed)|##\[error\]Process completed)")
TEST_NAME = re.compile(r"Test Case '-\[([^' \]]+) ([^' \]]+)\]' failed|Test Case '([^' ]+)' failed|"
                       r"✘ Test (\S+?)\(?\)? (?:recorded|failed)")


def clean(text):
    return [ANSI.sub("", STAMP.sub("", l)).rstrip() for l in text.splitlines()]


def failure_lines(text, limit=40):
    """The lines that name what failed: each error or failed test with the line after it, repeats dropped; else the
    last lines before the step's exit (a script that printed its own reason)."""
    lines = clean(text)
    out, seen = [], set()
    for i, line in enumerate(lines):
        if "warning:" in line or not PRIMARY.search(line):
            continue
        key = re.sub(r"\d+(\.\d+)? seconds", "", line.split("/")[-1])
        if key in seen:
            continue
        seen.add(key)
        out.append(line)
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        if nxt and not PRIMARY.search(nxt) and "warning:" not in nxt and not NOISE.match(nxt) and len(out) < limit:
            out.append(nxt)
        if len(out) >= limit:
            break
    if out:
        return out
    # No error line of a known shape: the failing step's own output, from the end of its command echo to its exit.
    for i, line in enumerate(lines):
        if line.startswith("##[error]Process completed with exit code"):
            start = max((k for k in range(i) if lines[k].startswith("##[endgroup]")), default=max(0, i - 12)) + 1
            step = [l for l in lines[start:i] if l and not NOISE.match(l)]
            return step[-12:] + [line]
    return lines[-12:]


def failed_tests(text):
    names = []
    for m in TEST_NAME.finditer("\n".join(clean(text))):
        name = (f"{m.group(1)}.{m.group(2)}" if m.group(1) else m.group(3) or m.group(4) or "").strip()
        if name and name not in names:
            names.append(name)
    return names


def job_log(job_id):
    try:
        return api("GET", f"actions/jobs/{job_id}/logs", raw=True).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return f"(log not available: HTTP {e.code})"


# --- digest -----------------------------------------------------------------------------------------------------------

def digest(run_id):
    run = api("GET", f"actions/runs/{run_id}")
    prs = run_prs(run)
    if not prs:
        print("digest: the run belongs to no open pull request")
        return
    sha = run["head_sha"]
    jobs = pages(f"actions/runs/{run_id}/jobs?filter=latest", "jobs")
    failed = [j for j in jobs if j.get("conclusion") in ("failure", "timed_out") and j["name"] != "ci-ok"]
    if not failed:
        verdict = "passed" if run.get("conclusion") == "success" else run.get("conclusion") or "finished"
        body = f"### CI on `{sha[:7]}`: {verdict}, no failing job\n\n[{CI} run]({run['html_url']})\n"
    else:
        parts = [f"### CI on `{sha[:7]}`: {len(failed)} failing job{'s' if len(failed) != 1 else ''}\n",
                 f"[{CI} run]({run['html_url']}) · the lines below are the ones that name each failure\n"]
        for j in failed:
            lines = failure_lines(job_log(j["id"]))
            text = "\n".join(l.replace(FENCE, "'" * 3) for l in lines)   # log text stays inside its block
            parts.append(f"\n**{j['name']}** ([log]({j['html_url']}))\n\n{FENCE}text\n{text}\n{FENCE}\n")
        body = "".join(parts)
    for pr in prs:
        upsert_comment(pr, "agentbot:ci-digest", body)
    print(f"digest: {len(failed)} failing jobs on {sha[:7]}, posted to #{', #'.join(map(str, prs))}")


# --- flakes -----------------------------------------------------------------------------------------------------------

FLAKY_TITLE = "Flaky tests"
STATE = re.compile(r"<!-- agentbot:flakes (\{.*?\}) -->", re.S)


def record_flakes(state, found, run, when):
    """state: {name: {"count", "last", "runs"}}; found: names failed on an earlier attempt of a passing run."""
    for name in found:
        e = state.setdefault(name, {"count": 0, "last": "", "runs": []})
        e["count"] += 1
        e["last"] = when
        e["runs"] = (e["runs"] + [run])[-5:]
    return state


def flakes_body(state):
    rows = sorted(state.items(), key=lambda kv: (-kv[1]["count"], kv[0]))
    lines = ["Tests and jobs that failed and then passed on a re-run of the same commit (agentbot, edited in place).",
             "A name here is a flake to fix at its cause, not a reason to re-run.", "",
             "| test or job | times | last | runs |", "|---|---:|---|---|"]
    for name, e in rows:
        links = " ".join(f"[{i + 1}]({u})" for i, u in enumerate(e["runs"]))
        lines.append(f"| `{name}` | {e['count']} | {e['last'][:10]} | {links} |")
    return "\n".join(lines) + "\n\n<!-- agentbot:flakes " + json.dumps(state, sort_keys=True) + " -->\n"


def failed_attempts(attempt, conclusion_of):
    """The attempts to scan for a run that passed on `attempt`: the failures just before it, walking back until an
    attempt that succeeded (its failures were recorded when that attempt passed), so a rerun of a passing run
    never records the same failure twice."""
    out = []
    for a in range(attempt - 1, 0, -1):
        if conclusion_of(a) == "success":
            break
        out.append(a)
    return sorted(out)


def flakes(run_id):
    run = api("GET", f"actions/runs/{run_id}")
    attempt = run.get("run_attempt", 1)
    if run.get("conclusion") != "success" or attempt < 2:
        print("flakes: not a run that passed on a re-run")
        return
    found = []
    for a in failed_attempts(attempt, lambda n: api("GET", f"actions/runs/{run_id}/attempts/{n}").get("conclusion")):
        for j in pages(f"actions/runs/{run_id}/attempts/{a}/jobs", "jobs"):
            if j.get("conclusion") in ("failure", "timed_out") and j["name"] != "ci-ok":
                names = failed_tests(job_log(j["id"]))
                found += [n for n in (names or [f"job: {j['name']}"]) if n not in found]
    if not found:
        print("flakes: the earlier attempts had no failed job")
        return
    issue = next((i for i in pages("issues?state=open&creator=github-actions%5Bbot%5D", None)
                  if i["title"] == FLAKY_TITLE and "pull_request" not in i), None)
    state = {}
    if issue:
        m = STATE.search(issue.get("body") or "")
        state = json.loads(m.group(1)) if m else {}
    state = record_flakes(state, found, run["html_url"], run.get("updated_at", ""))
    body = flakes_body(state)
    if issue:
        api("PATCH", f"issues/{issue['number']}", {"body": body})
    else:
        api("POST", "issues", {"title": FLAKY_TITLE, "body": body})
    print(f"flakes: recorded {', '.join(found)}")


# --- shots ------------------------------------------------------------------------------------------------------------

def png_decode(data):
    """(width, height, rows of RGBA bytes) for an 8-bit, non-interlaced PNG (grey, grey+alpha, RGB, RGBA or palette).
    Any malformed input raises ValueError: the file comes from a pull request's run."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat, plte, trns, header = 8, b"", None, None, None
    while pos < len(data):
        if pos + 12 > len(data):
            raise ValueError("PNG chunk header cut short")
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        if pos + 12 + n > len(data):
            raise ValueError(f"PNG chunk {kind!r} longer than the file")
        chunk = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            if n != 13:
                raise ValueError(f"PNG IHDR of {n} bytes, not 13")
            header = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"PLTE":
            plte = chunk
        elif kind == b"tRNS":
            trns = chunk
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + n
    if header is None:
        raise ValueError("PNG without IHDR")
    w, h, depth, ctype, _, _, interlace = header
    if ctype not in (0, 2, 3, 4, 6):
        raise ValueError(f"PNG colour type {ctype} is not one of 0, 2, 3, 4, 6")
    if ctype == 3 and not plte:
        raise ValueError("palette PNG without PLTE")
    if depth != 8 or interlace:
        raise ValueError(f"unsupported PNG (depth {depth}, interlace {interlace})")
    if w * h > MAX_PIXELS:   # the image comes from the pull request's own run: bound what it can make this job do
        raise ValueError(f"PNG of {w}x{h} is over the {MAX_PIXELS:,}-pixel limit")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    d = zlib.decompressobj()
    try:
        raw = d.decompress(idat, (w * channels + 1) * h + 1)
    except zlib.error as e:
        raise ValueError(f"PNG data does not inflate: {e}") from None
    if d.unconsumed_tail:
        raise ValueError("PNG data longer than its header says")
    if len(raw) < (w * channels + 1) * h:
        raise ValueError("PNG data shorter than its header says")
    stride = w * channels
    rows, prev, p = [], bytearray(stride), 0
    for _ in range(h):
        f, line = raw[p], bytearray(raw[p + 1:p + 1 + stride])
        if f > 4:
            raise ValueError(f"PNG row filter {f} is not 0 to 4")
        p += 1 + stride
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b, c = prev[i], prev[i - channels] if i >= channels else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = line
        rgba = bytearray(w * 4)
        for x in range(w):
            px = line[x * channels:(x + 1) * channels]
            if ctype == 6: rgba[x * 4:x * 4 + 4] = px
            elif ctype == 2: rgba[x * 4:x * 4 + 4] = bytes(px) + b"\xff"
            elif ctype == 0: rgba[x * 4:x * 4 + 4] = bytes([px[0]] * 3) + b"\xff"
            elif ctype == 4: rgba[x * 4:x * 4 + 4] = bytes([px[0]] * 3 + [px[1]])
            else:
                k = px[0]
                if k * 3 + 3 > len(plte):
                    raise ValueError(f"PNG palette index {k} outside its {len(plte) // 3}-entry PLTE")
                alpha = trns[k] if trns and k < len(trns) else 255
                rgba[x * 4:x * 4 + 4] = plte[k * 3:k * 3 + 3] + bytes([alpha])
        rows.append(bytes(rgba))
    return w, h, rows


def png_encode(w, h, rows):
    raw = b"".join(b"\0" + r for r in rows)
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def png_compare(a, b, threshold=8):
    """(changed share 0..1, mean absolute change per channel, diff image rows or None when the sizes differ)."""
    (wa, ha, ra), (wb, hb, rb) = a, b
    if (wa, ha) != (wb, hb):
        return 1.0, 255.0, None
    changed, total, rows = 0, 0, []
    for y in range(ha):
        row = bytearray(wa * 4)
        for x in range(wa):
            pa, pb = ra[y][x * 4:x * 4 + 3], rb[y][x * 4:x * 4 + 3]
            d = max(abs(pa[0] - pb[0]), abs(pa[1] - pb[1]), abs(pa[2] - pb[2]))
            total += abs(pa[0] - pb[0]) + abs(pa[1] - pb[1]) + abs(pa[2] - pb[2])
            if d > threshold:
                changed += 1
                row[x * 4:x * 4 + 4] = b"\xff\x20\x60\xff"
            else:
                grey = (pb[0] + pb[1] + pb[2]) // 12 + 40
                row[x * 4:x * 4 + 4] = bytes([grey, grey, grey, 255])
        rows.append(bytes(row))
    return changed / (wa * ha), total / (wa * ha * 3), rows


MAX_ARTIFACT = 64 * 1024 * 1024  # the most a downloaded artifact ZIP, and each file read out of it, may hold


def artifact_files(run_id, name, suffix, repo=None):
    """{file name: bytes} of the files ending in `suffix` inside the run's artifact `name` (empty when absent); repo
    RUNNERS_REPO reads a run of the runners repository."""
    other = {"repo": RUNNERS_REPO, "token": RUNNERS_TOKEN} if repo == RUNNERS_REPO else {}
    arts = api("GET", f"actions/runs/{run_id}/artifacts?name={name}", **other)["artifacts"]
    if not arts or arts[0].get("expired"):
        return {}
    try:
        data = api("GET", f"actions/artifacts/{arts[0]['id']}/zip", raw=True, limit=MAX_ARTIFACT, **other)
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            return {os.path.basename(i.filename): z.read(i) for i in z.infolist()
                    if i.filename.endswith(suffix) and i.file_size <= MAX_ARTIFACT}
    except (ValueError, zipfile.BadZipFile) as e:
        print(f"::warning::artifact {name} of run {run_id} not read: {e}")
        return {}


def latest_main_run(workflow, artifact, accept=None, events=("push",)):
    """The newest green run of this repository's main, started by one of `events`, with `artifact` (and, when given,
    for which accept(run id) is true). Never a pull request's run: `branch=main` also matches a fork's pull request
    from its own branch called main, so the event and the head repository are both checked."""
    runs = []
    for event in events:
        runs += api("GET", f"actions/workflows/{workflow}/runs?branch=main&event={event}&per_page=20")["workflow_runs"]
    for r in sorted(runs, key=lambda r: r.get("created_at", ""), reverse=True):
        if r.get("event") not in events or (r.get("head_repository") or {}).get("full_name") != REPO:
            continue
        if r.get("conclusion") == "success" and api("GET", f"actions/runs/{r['id']}/artifacts?name={artifact}")["artifacts"]:
            if accept is None or accept(r["id"]):
                return r
    return None


def shots(run_id, out_dir):
    run = api("GET", f"actions/runs/{run_id}")
    prs = run_prs(run)
    if not prs:
        print("shots: the run belongs to no open pull request")
        return
    files = [f["filename"] for f in pages(f"pulls/{prs[0]}/files", None)]
    if not any(UI_PATHS.match(f) for f in files):
        print("shots: the pull request changes no UI code")
        return
    base = latest_main_run("mpvfx-ci.yml", "linux")
    if not base:
        print("::warning::shots: no green main run with smoke snapshots to compare against")
        return
    os.makedirs(out_dir, exist_ok=True)
    rows = ["| OS | changed pixels | mean change | |", "|---|---:|---:|---|"]
    for artifact in ("linux", "windows", "macos"):
        mine, theirs = artifact_files(run_id, artifact, "-smoke.png"), artifact_files(base["id"], artifact, "-smoke.png")
        name = next(iter(mine), None)
        if not name or name not in theirs:
            rows.append(f"| {artifact} | – | – | no snapshot on {'this run' if not name else 'main'} |")
            continue
        try:
            a, b = png_decode(mine[name]), png_decode(theirs[name])
        except ValueError as e:
            rows.append(f"| {artifact} | – | – | {e} |")
            continue
        share, mean, diff = png_compare(a, b)
        if diff is None:
            note = f"size changed: {b[0]}×{b[1]} → {a[0]}×{a[1]}"
        else:
            with open(os.path.join(out_dir, f"{artifact}-diff.png"), "wb") as f:
                f.write(png_encode(a[0], a[1], diff))
            for label, data in (("pr", mine[name]), ("main", theirs[name])):
                with open(os.path.join(out_dir, f"{artifact}-{label}.png"), "wb") as f:
                    f.write(data)
            note = "unchanged" if share == 0 else "changed"
        rows.append(f"| {artifact} | {share * 100:.2f}% | {mean:.2f} | {note} |")
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    here = f"{server}/{REPO}/actions/runs/{os.environ.get('GITHUB_RUN_ID', '')}"
    body = (f"### Launch-smoke snapshots of `{run['head_sha'][:7]}` against main `{base['head_sha'][:7]}`\n\n" +
            "\n".join(rows) + f"\n\nImages (this PR, main, and the difference in red): the `snapshots` artifact of "
            f"[this run]({here}). A pixel counts as changed when a channel moves by more than 8 levels.\n")
    for pr in prs:
        upsert_comment(pr, "agentbot:shots", body)
    print("shots: posted")


# --- bench ------------------------------------------------------------------------------------------------------------

def bench_compare(mine, theirs, threshold=0.15):
    """Markdown rows: each metric in both reports, its p50 and p95 then and now, flagged when p50 moved > threshold."""
    rows, flagged = [], 0
    for name, m in sorted(mine.get("metrics", {}).items()):
        t = theirs.get("metrics", {}).get(name)
        if not t or not t.get("p50") or t.get("unit") != m.get("unit"):  # a changed unit is not comparable
            continue
        change = (m["p50"] - t["p50"]) / t["p50"]
        flag = abs(change) > threshold
        flagged += flag
        rows.append(f"| `{name}` | {m['unit']} | {t['p50']:g} → {m['p50']:g} | {t['p95']:g} → {m['p95']:g} | "
                    f"{change * 100:+.1f}%{' **⚑**' if flag else ''} |")
    return rows, flagged


def latest_runners_main_run(accept):
    """The newest green onetake-bench run of a main commit on the runners repository for which accept(run id) is true.
    Its run-name says what was benchmarked; a run whose payload was refused never ends in success."""
    got = api("GET", "actions/workflows/onetake-bench.yml/runs?event=repository_dispatch&status=success&per_page=30",
              repo=RUNNERS_REPO, token=RUNNERS_TOKEN)
    for r in sorted(got.get("workflow_runs", []), key=lambda r: r.get("created_at", ""), reverse=True):
        m = RUNNERS_TITLE.match(r.get("display_title") or "")
        if r.get("conclusion") == "success" and m and m.group(1) == "main" and accept(r["id"]):
            return r
    return None


def bench_report(files):
    return json.loads(next(iter(files.values()))) if files else {}


def bench_baseline(art, klass):
    """The report of main's newest bench of machine class `klass`: from this repository's bench.yml runs (run here when
    nothing was sent) or from the runners repository's onetake-bench.yml runs, whichever is newer; None when neither."""
    found, loaded = [], {}

    def same_class(where):
        def accept(rid):
            loaded[(where, rid)] = bench_report(artifact_files(rid, art, ".json", repo=where))
            return bool(loaded[(where, rid)]) and loaded[(where, rid)].get("machine", {}).get("class") == klass
        return accept

    # bench.yml has no push trigger: main is benchmarked by workflow_run (after green CI), on schedule and by hand.
    here = latest_main_run("bench.yml", art, same_class(None), events=("workflow_run", "schedule", "workflow_dispatch"))
    if here:
        found.append((here.get("created_at", ""), loaded[(None, here["id"])]))
    if RUNNERS_TOKEN:
        there = latest_runners_main_run(same_class(RUNNERS_REPO))
        if there:
            found.append((there.get("created_at", ""), loaded[(RUNNERS_REPO, there["id"])]))
    return max(found, key=lambda f: f[0])[1] if found else None


def bench_body(head_sha, mine_by_os, oses):
    """The comment: per OS in `oses`, each metric of `mine_by_os[os]` (artifact files) against main's newest
    same-class run."""
    parts = [f"### Benchmarks of `{head_sha[:7]}` against main\n",
             "p50 and p95, main → this PR, per OS; ⚑ marks a p50 change over 15%. Hosted runners are shared machines: "
             "read a flag as a reason to look, not a verdict.\n"]
    for os_name in oses:
        mine = mine_by_os.get(os_name) or {}
        m = bench_report(mine)
        t = bench_baseline(f"bench-{os_name}", m.get("machine", {}).get("class")) if mine else None
        if not mine or not t:
            parts.append(f"\n**{os_name}**: {'no result on this run' if not mine else 'no main run of the same machine class to compare against yet'}\n")
            continue
        rows, flagged = bench_compare(m, t)
        parts.append(f"\n**{os_name}** (main `{t['commit'][:7]}`, {flagged} flagged)\n\n| metric | unit | p50 | p95 | p50 change |\n"
                     "|---|---|---:|---:|---:|\n" + "\n".join(rows) + "\n")
    return "".join(parts)


def bench(run_id):
    run = api("GET", f"actions/runs/{run_id}")
    prs = run_prs(run)
    if not prs:
        print("bench: the run belongs to no open pull request")
        return
    mine = {o: artifact_files(run_id, f"bench-{o}", ".json") for o in ("linux", "windows", "macos")}
    if not any(mine.values()):
        print("bench: no bench results in this run")
        return
    # When bench.yml sent linux and macos to the runners repository, this run holds windows only: the comment lists
    # the systems this run benchmarked, and bench-runners posts the others in a comment of its own.
    oses = ("linux", "windows", "macos") if mine["linux"] or mine["macos"] else ("windows",)
    body = bench_body(run["head_sha"], mine, oses)
    for pr in prs:
        upsert_comment(pr, "agentbot:bench", body)
    print("bench: posted")


def bench_runners(run_id, pr, head_sha):
    """A pull request's bench run on the runners repository, reported back by its onetake-bench.yml (payload checked
    here again: every value comes from a repository_dispatch)."""
    if not (re.fullmatch(r"[0-9]{1,20}", run_id) and re.fullmatch(r"[0-9]{1,7}", pr) and
            re.fullmatch(r"[0-9a-f]{40}", head_sha)):
        raise ValueError("bench-runners: run id, pull request number or head sha is malformed")
    if not RUNNERS_TOKEN:
        raise ValueError("bench-runners: RUNNERS_TOKEN is not set")
    run = api("GET", f"actions/runs/{run_id}", repo=RUNNERS_REPO, token=RUNNERS_TOKEN)
    m = RUNNERS_TITLE.match(run.get("display_title") or "")
    if not run.get("path", "").endswith("onetake-bench.yml") or not m or m.group(1) != "pr":
        print(f"bench-runners: run {run_id} is not a pull request's onetake-bench run")
        return
    p = api("GET", f"pulls/{pr}")
    if p.get("state") != "open" or p.get("head", {}).get("sha") != head_sha:
        print(f"bench-runners: #{pr} is closed or has moved past {head_sha[:7]}; nothing posted")
        return
    mine = {o: artifact_files(run_id, f"bench-{o}", ".json", repo=RUNNERS_REPO) for o in RUNNERS_BENCH}
    upsert_comment(pr, "agentbot:bench-runners", bench_body(head_sha, mine, RUNNERS_BENCH))
    print("bench-runners: posted")


def main(argv):
    cmds = {"digest": (digest, 1), "flakes": (flakes, 1), "shots": (shots, 2), "bench": (bench, 1),
            "bench-runners": (bench_runners, 3)}
    if len(argv) < 2 or argv[1] not in cmds or len(argv) - 2 != cmds[argv[1]][1]:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    if not REPO or not TOKEN:
        print("agentbot: GITHUB_REPOSITORY and GITHUB_TOKEN are required", file=sys.stderr)
        return 2
    try:
        cmds[argv[1]][0](*argv[2:])
    except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
        print(f"::warning::agentbot {argv[1]}: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
