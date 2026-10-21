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
"""bench.py: the app's benchmarks on this machine, from a release build (run from mpvfx-swift after
`swift build -c release`).

  python3 ../.github/ci/bench.py --out <dir> [--runs N] [--launcher "<cmd...>"] [--only a,b] [--skip a,b]
                                 [--budgets <file> [--baseline <main bench-<os>.json>]]
  python3 ../.github/ci/bench.py --check <bench-<os>.json> --budgets <file> [--baseline <main bench-<os>.json>]

Benchmarks (each a separate process per run, so one run's state never reaches the next):
  startup   the app (MpVFX) launched with a hidden window on the built-in demo until its first painted frame is
            written as a PNG (MPVFX_SMOKE_SNAPSHOT; MPVFX_SMOKE_DELAY_MS=100 settle), wall time from spawn to exit
            and the process's peak memory. --launcher wraps the command (Linux: xvfb-run ... dbus-run-session --).
  audio     MpvfxAudioBench 30: the every-FX graph rendered offline and in 128-frame live blocks, speed against
            real time, and the seek pre-roll.
  grade     MpvfxColorBench 10: the colour grade on the CPU and on the GPU (Vulkan, Direct3D 11 or Metal) at 1080p and
            4K for three looks, ms per frame.
  preview   MpvfxPreviewBench, every scenario (1080p, 4k, stacked, graded, scrub) on clips the bench makes with
            the media engine's own encoder: fps, ms per frame per stage, peak memory.
Every number is recorded with its unit, the samples, n, p50, p95 and max (nearest rank), the machine (OS, CPU,
cores, memory, GPU as the grade bench names it, class), the commit and the date; the result is <out>/bench-<os>.json
plus a Markdown table on stdout. A GitHub-hosted runner is a shared machine: compare runs of the same class only,
and read trends, not single runs.
With --budgets (.github/ci/bench-budgets.json) the report is then checked: a metric's p50 past its ceiling or floor, a
budgeted metric missing from a benchmark that ran, or (with --baseline, main's latest report of the same runner class)
a p50 more than the file's regression_pct worse than main's fails, and the failed metrics are printed as a table.
Exit 1 on a failed budget, 2 on an unusable input. --check checks an existing report without running anything.
"""
import argparse
import datetime
import json
import math
import os
import platform
import re
import shlex
import subprocess
import sys
import tempfile
import time

HERE = os.getcwd()


def sh(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def _first_field(path, prefix):
    """The text after `prefix` on the first line of `path` that starts with it, or None."""
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.startswith(prefix):
                return line[len(prefix):].lstrip(" \t:")
    return None


def _linux_cpu_ram(cpu):
    model = _first_field("/proc/cpuinfo", "model name")
    mem = _first_field("/proc/meminfo", "MemTotal")
    return (model.strip() if model else cpu), (round(int(mem.split()[0]) / 1048576, 1) if mem else None)


def _darwin_cpu_ram(cpu):
    mem = sh("sysctl", "-n", "hw.memsize")
    return sh("sysctl", "-n", "machdep.cpu.brand_string") or cpu, round(int(mem) / 1073741824, 1) if mem.isdigit() else None


def _windows_cpu_ram(cpu):
    out = sh("powershell", "-NoProfile", "-Command",
             "(Get-CimInstance Win32_Processor).Name; (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory")
    lines = [line.strip() for line in out.splitlines() if line.strip()]
    if len(lines) < 2:
        return cpu, None
    return lines[0], round(int(lines[1]) / 1073741824, 1) if lines[1].isdigit() else None


def machine():
    """What the numbers were measured on."""
    system = platform.system()
    probe = {"Linux": _linux_cpu_ram, "Darwin": _darwin_cpu_ram, "Windows": _windows_cpu_ram}.get(system)
    cpu = platform.processor() or platform.machine()
    cpu, ram = probe(cpu) if probe else (cpu, None)
    return {"os": f"{system} {platform.release()}", "cpu": cpu, "cores": os.cpu_count(), "ram_gb": ram,
            "class": "github-hosted runner" if os.environ.get("GITHUB_ACTIONS") else "local machine"}


def run(cmd, env=None, cwd=None, launcher=None):
    """Runs `cmd` once: (wall seconds, peak RSS MiB or None, stdout+stderr, exit code)."""
    full = (launcher or []) + cmd
    e = dict(os.environ); e.update(env or {})
    t = time.perf_counter()
    if hasattr(os, "wait4"):
        # Output goes to a file and the child is reaped with wait4 here, so its resource usage (peak RSS) is ours;
        # communicate()/wait() would reap it first and discard the usage.
        with tempfile.TemporaryFile() as log:
            p = subprocess.Popen(full, env=e, cwd=cwd, stdout=log, stderr=subprocess.STDOUT)
            _, status, usage = os.wait4(p.pid, 0)
            wall = time.perf_counter() - t
            code = os.waitstatus_to_exitcode(status)
            p.returncode = code
            log.seek(0)
            out = log.read().decode("utf-8", errors="replace")
        peak = usage.ru_maxrss / (1048576 if platform.system() == "Darwin" else 1024)
        return wall, peak, out, code
    p = subprocess.run(full, env=e, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return time.perf_counter() - t, None, p.stdout, p.returncode


def rank(samples, q):
    """Nearest-rank percentile of `samples` (q in 0..1)."""
    s = sorted(samples)
    return s[min(len(s), max(1, math.ceil(q * len(s)))) - 1]


class Results:
    def __init__(self):
        self.metrics = {}

    def add(self, name, unit, value, note=""):
        m = self.metrics.setdefault(name, {"unit": unit, "samples": [], "note": note})
        m["samples"].append(round(float(value), 4))

    def finish(self):
        for m in self.metrics.values():
            s = m["samples"]
            m.update(n=len(s), p50=rank(s, 0.5), p95=rank(s, 0.95), max=max(s))
        return self.metrics


def bench_startup(bin_dir, runs, out_dir, launcher, r):
    exe = os.path.join(bin_dir, "MpVFX.exe" if platform.system() == "Windows" else "MpVFX")
    png = os.path.join(out_dir, "startup.png")
    for i in range(runs):
        if os.path.exists(png):
            os.remove(png)
        env = {"MPVFX_HIDDEN_TEST_WINDOW": "1", "MPVFX_SMOKE_DELAY_MS": "100", "MPVFX_SMOKE_SNAPSHOT": png}
        wall, peak, out, code = run([exe], env=env, launcher=launcher)
        if code != 0 or not os.path.exists(png):
            raise SystemExit(f"startup run {i + 1}: exit {code}, snapshot {'written' if os.path.exists(png) else 'missing'}\n{out[-3000:]}")
        r.add("startup.launch_to_first_frame_ms", "ms", wall * 1000, "spawn to exit after the first painted frame + 100 ms settle")
        if peak is not None:
            r.add("startup.peak_rss_mib", "MiB", peak)


def bench_audio(bin_dir, runs, r):
    exe = os.path.join(bin_dir, "MpvfxAudioBench" + (".exe" if platform.system() == "Windows" else ""))
    for i in range(runs):
        wall, peak, out, code = run([exe, "30"])
        if code != 0:
            raise SystemExit(f"audio run {i + 1}: exit {code}\n{out[-3000:]}")
        m = re.search(r"renderAll:\s+([\d.]+) s\s+->\s+([\d.]+)x real time", out)
        b = re.search(r"128-frame blocks:\s+([\d.]+) s\s+->\s+([\d.]+)x real time \(([\d.]+) us per block", out)
        if not m or not b:
            raise SystemExit(f"audio run {i + 1}: unexpected output\n{out[-3000:]}")
        r.add("audio.render_offline_x_realtime", "x real time", m.group(2), "every-FX graph, 30 s")
        r.add("audio.live_block_us", "us per 128-frame block", b.group(3), "budget 2667 us at 48 kHz")
        for s in re.finditer(r"seek pre-roll to\s+([\d.]+) s:\s+([\d.]+) s", out):
            r.add(f"audio.seek_preroll_at_{s.group(1)}s_ms", "ms", float(s.group(2)) * 1000)
        if peak is not None:
            r.add("audio.peak_rss_mib", "MiB", peak)


def bench_grade(bin_dir, runs, r, info):
    exe = os.path.join(bin_dir, "MpvfxColorBench" + (".exe" if platform.system() == "Windows" else ""))
    for i in range(runs):
        wall, peak, out, code = run([exe, "10"])
        if code != 0:
            raise SystemExit(f"grade run {i + 1}: exit {code}\n{out[-3000:]}")
        g = re.search(r"GPU: (\S+) on (.+?); median", out)
        if g and "gpu" not in info:
            info["gpu"] = g.group(2).strip()
            info["gpu_software_device"] = "software device" in g.group(2)
        rows = 0
        for row in re.finditer(r"^\| (\d+x\d+) \| (.+?) \| ([\d.]+) \| ([\d.]+) \| ([\d.]+)x \| (\d+) \| (\d+) \|$", out, re.M):
            size, look = row.group(1), row.group(2).split(" (")[0].split(":")[0].strip().replace(" ", "_")
            r.add(f"grade.{size}.{look}.cpu_ms", "ms per frame", row.group(3), row.group(2))
            r.add(f"grade.{size}.{look}.gpu_ms", "ms per frame", row.group(4), row.group(2))
            r.add(f"grade.{size}.{look}.max_diff", "levels", row.group(6), "CPU vs GPU output")
            rows += 1
        if rows == 0:
            raise SystemExit(f"grade run {i + 1}: no result rows\n{out[-3000:]}")


def bench_preview(bin_dir, runs, out_dir, r):
    exe = os.path.join(bin_dir, "MpvfxPreviewBench" + (".exe" if platform.system() == "Windows" else ""))
    # MpvfxPreviewBench writes this path into JSON unescaped: forward slashes work on Windows too.
    clips = os.path.join(out_dir, "clips").replace("\\", "/"); os.makedirs(clips, exist_ok=True)
    wall, _, out, code = run([exe, "--make-clips", clips])
    if code != 0:
        raise SystemExit(f"preview --make-clips: exit {code}\n{out[-3000:]}")
    results = os.path.join(out_dir, "preview.jsonl")
    open(results, "w").close()  # the bench appends: start from an empty file so a reused --out holds only this run
    for i in range(runs):
        for scenario in ("1080p", "4k", "stacked", "graded", "scrub"):
            wall, peak, out, code = run([exe, scenario, clips, results])
            if code != 0:
                raise SystemExit(f"preview {scenario} run {i + 1}: exit {code}\n{out[-3000:]}")
    with open(results, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                preview_record(json.loads(line), r)


def preview_unit(key):
    if "fps" in key:
        return "fps"
    if "mib" in key.lower() or "rss" in key.lower():
        return "MiB"
    return "ms" if "ms" in key else ""


def preview_record(rec, r):
    """One MpvfxPreviewBench result line into `r`, as preview.<scenario>.<key>."""
    scenario = rec.get("scenario", "unknown")
    for key, value in rec.items():
        # The bench writes every value as a JSON string ("fps":"29.9"); text such as "display" does not parse.
        try:
            value = float(value)
        except (TypeError, ValueError):
            continue
        if math.isfinite(value) and key != "frames":
            r.add(f"preview.{scenario}.{key}", preview_unit(key), value)


def table(metrics):
    lines = ["| metric | unit | n | p50 | p95 | max | note |", "|---|---|---:|---:|---:|---:|---|"]
    for name, m in metrics.items():
        lines.append(f"| `{name}` | {m['unit']} | {m['n']} | {m['p50']:g} | {m['p95']:g} | {m['max']:g} | {m.get('note', '')} |")
    return "\n".join(lines)


# --- budgets ------------------------------------------------------------------------------------------------------------
# .github/ci/bench-budgets.json: per OS, a ceiling ("max") or a floor ("min") on each budgeted metric's p50, for one
# runner class. A metric past its budget fails, and so does a budgeted metric missing from a benchmark that ran. With a
# baseline (main's latest report of the same class and OS), a metric not marked "noisy" also fails when its p50 is more
# than regression_pct worse than the baseline's.

OS_KEYS = {"linux": "linux", "darwin": "macos", "windows": "windows"}


class BudgetError(ValueError):
    """The budget file, the report or the baseline cannot be checked."""


def number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        raise BudgetError(f"{what} {path}: {e}") from e
    if not isinstance(doc, dict):
        raise BudgetError(f"{what} {path}: not a JSON object")
    return doc


def machine_of(report):
    m = report.get("machine")
    return m if isinstance(m, dict) else {}


def os_key(report):
    return OS_KEYS.get(str(machine_of(report).get("os", "")).split(" ")[0].lower())


def budget_entry(name, e):
    """("min" or "max", the limit) of one budget entry, which needs a unit and exactly one numeric min or max."""
    kinds = [k for k in ("min", "max") if k in e] if isinstance(e, dict) else []
    if len(kinds) != 1 or not isinstance(e.get("unit"), str) or not number(e[kinds[0]]):
        raise BudgetError(f"budget {name!r}: needs a unit and exactly one numeric min or max")
    return kinds[0], e[kinds[0]]


def breach(m, e, kind, limit):
    """Why the result `m` breaks the budget `e`, or None when it holds."""
    if not isinstance(m, dict) or not number(m.get("p50")):
        return "missing from the results"
    if m.get("unit") != e["unit"]:
        return f"unit is {m.get('unit')!r}, the budget's is {e['unit']!r}"
    if kind == "max" and m["p50"] > limit:
        return "over the ceiling"
    if kind == "min" and m["p50"] < limit:
        return "under the floor"
    return None


def budget_failures(report, budgets):
    """Rows (metric, unit, p50 or None, budget, why) for each budget the report breaks. Budgets of a benchmark the run
    left out (--only, --skip) are not checked."""
    ran, got, rows = set(report.get("benchmarks") or ()), report.get("metrics") or {}, []
    for name, e in sorted(budgets.items()):
        kind, limit = budget_entry(name, e)
        if name.split(".")[0] not in ran:
            continue
        m = got.get(name)
        why = breach(m, e, kind, limit)
        if why:
            p50 = m["p50"] if isinstance(m, dict) and number(m.get("p50")) else None
            rows.append((name, e["unit"], p50, f"{'≥' if kind == 'min' else '≤'} {limit:g}", why))
    return rows


def worse_by(m, t, kind):
    """How much worse m's p50 is than t's, as a fraction (negative when better); None when not comparable."""
    if not (isinstance(m, dict) and isinstance(t, dict)) or m.get("unit") != t.get("unit"):
        return None
    a, b = m.get("p50"), t.get("p50")
    if not (number(a) and number(b)) or b == 0:
        return None
    return (a - b) / b if kind == "max" else (b - a) / b


def regression_failures(report, base, budgets, pct):
    """Rows for each budgeted metric not marked noisy whose p50 is more than pct% worse than the baseline's."""
    mine, theirs, rows = report.get("metrics") or {}, base.get("metrics") or {}, []
    for name, e in sorted(budgets.items()):
        kind, _ = budget_entry(name, e)
        worse = None if e.get("noisy") else worse_by(mine.get(name), theirs.get(name), kind)
        if worse is not None and worse > pct / 100:
            rows.append((name, e["unit"], mine[name]["p50"], f"main {theirs[name]['p50']:g}", f"{worse * 100:.0f}% worse than main"))
    return rows


def os_budgets(budgets, report):
    """(OS key, the file's block for the report's OS)."""
    key = os_key(report)
    block = (budgets.get("os") or {}).get(key) if key else None
    if not isinstance(block, dict) or not isinstance(block.get("metrics"), dict):
        raise BudgetError(f"the budget file has no block for OS {machine_of(report).get('os')!r}")
    return key, block


def regression_rows(report, base, budgets, block):
    """(rows, note) of the regression rule against `base`, main's latest report."""
    if base is None:
        return [], "no main baseline: the regression rule was not applied"
    if machine_of(base).get("class") != machine_of(report).get("class") or os_key(base) != os_key(report):
        return [], "the main baseline is from another machine class or OS: the regression rule was not applied"
    pct = budgets.get("regression_pct")
    if not number(pct) or pct <= 0:
        raise BudgetError("regression_pct must be a positive number")
    note = f"regression rule: p50 more than {pct:g}% worse than main `{str(base.get('commit', ''))[:7]}` fails"
    return regression_failures(report, base, block["metrics"], pct), note


def check_budgets(report, budgets, base=None):
    """(failed rows, notes) of `report` against the budget file `budgets` and, when given, main's report `base`.
    Only a report of the file's runner class is checked, and an OS marked pending is not."""
    if not isinstance(report.get("metrics"), dict) or not isinstance(report.get("benchmarks"), list):
        raise BudgetError("the report has no metrics object or benchmarks list")
    klass = machine_of(report).get("class")
    if klass != budgets.get("class"):
        return [], [f"the budgets are for a {budgets.get('class')!r}, this is a {klass!r}: not checked"]
    key, block = os_budgets(budgets, report)
    if block.get("pending"):
        return [], [f"{key}: budgets pending, not checked ({block['pending']})"]
    rows = budget_failures(report, block["metrics"])
    regressed, note = regression_rows(report, base, budgets, block)
    return rows + regressed, [f"{key}: {len(block['metrics'])} budgets ({klass})", note]


def budget_table(rows, notes):
    """Markdown: the notes, then the failed metrics as a table, or that every budget held."""
    lines = ["", "#### Budgets (.github/ci/bench-budgets.json)", ""] + [f"- {n}" for n in notes]
    if not rows:
        return "\n".join(lines + ["", "Every budget held."])
    lines += ["", f"**{len(rows)} failed**", "", "| metric | unit | p50 | budget | failed because |", "|---|---|---:|---:|---|"]
    lines += [f"| `{n}` | {u} | {'-' if v is None else f'{v:g}'} | {lim} | {why} |" for n, u, v, lim, why in rows]
    return "\n".join(lines)


def apply_budgets(report, budgets_path, baseline_path=None):
    """Prints the budget check of `report`. Exit code: 1 when a metric failed, 2 when an input is unusable, else 0. A
    baseline path that does not exist means main has no report yet (the regression rule is skipped, with a note)."""
    try:
        budgets = load_json(budgets_path, "budget file")
        base = load_json(baseline_path, "baseline") if baseline_path and os.path.exists(baseline_path) else None
        rows, notes = check_budgets(report, budgets, base)
    except BudgetError as e:
        print(f"::error::bench budgets: {e}")
        return 2
    print(budget_table(rows, notes))
    if rows:
        print(f"::error::bench budgets: {len(rows)} metric(s) failed; see the table above")
    return 1 if rows else 0


# --- main ---------------------------------------------------------------------------------------------------------------

def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", help="directory for bench-<os>.json, logs and fixtures")
    ap.add_argument("--runs", type=int, default=5, help="processes per benchmark (default 5)")
    ap.add_argument("--launcher", default="", help="command that wraps the app for the startup benchmark")
    ap.add_argument("--only", default="", help="comma list of benchmarks to run")
    ap.add_argument("--skip", default="", help="comma list of benchmarks to leave out")
    ap.add_argument("--budgets", help="budget file (.github/ci/bench-budgets.json): exit 1 with a table of failed metrics")
    ap.add_argument("--baseline", help="main's latest bench-<os>.json for the regression rule (a missing file skips it)")
    ap.add_argument("--check", metavar="REPORT", help="check this bench-<os>.json against --budgets instead of running")
    args = ap.parse_args(argv)
    if args.check and not args.budgets:
        ap.error("--check needs --budgets")
    if not args.check and not args.out:
        ap.error("--out is required unless --check is given")
    return args


def selected(args):
    names = ["startup", "audio", "grade", "preview"]
    if args.only:
        names = [n for n in names if n in args.only.split(",")]
    return [n for n in names if n not in args.skip.split(",")]


def run_benchmarks(args, names, info):
    bin_dir = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], capture_output=True, text=True, check=True).stdout.strip()
    launcher = shlex.split(args.launcher) if args.launcher else None
    r = Results()
    if "startup" in names:
        bench_startup(bin_dir, args.runs, args.out, launcher, r)
    if "audio" in names:
        bench_audio(bin_dir, args.runs, r)
    if "grade" in names:
        bench_grade(bin_dir, args.runs, r, info)
    if "preview" in names:
        bench_preview(bin_dir, args.runs, args.out, r)
    return r.finish()


def measure(args):
    """Runs the selected benchmarks, writes <out>/bench-<os>.json, prints the table; returns the report."""
    names = selected(args)
    os.makedirs(args.out, exist_ok=True)
    info = machine()
    started = time.time()
    metrics = run_benchmarks(args, names, info)
    commit = sh("git", "rev-parse", "HEAD") or os.environ.get("GITHUB_SHA", "unknown")
    report = {"schema": 1, "commit": commit, "date": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
              "machine": info, "runs": args.runs, "benchmarks": names, "elapsed_s": round(time.time() - started, 1), "metrics": metrics}
    path = os.path.join(args.out, f"bench-{platform.system().lower()}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    print(f"### {info['os']}: {info['cpu']}, {info['cores']} cores, {info['ram_gb']} GiB, GPU {info.get('gpu', 'not measured')} ({info['class']})")
    print(f"commit {commit[:7]}, {args.runs} runs per benchmark, {report['elapsed_s']} s; `{os.path.basename(path)}` in the artifact\n")
    print(table(metrics))
    return report


def main(argv=None):
    args = parse_args(argv)
    if args.check:
        try:
            report = load_json(args.check, "report")
        except BudgetError as e:
            print(f"::error::bench budgets: {e}")
            return 2
    else:
        report = measure(args)
    return apply_budgets(report, args.budgets, args.baseline) if args.budgets else 0


if __name__ == "__main__":
    sys.exit(main())
