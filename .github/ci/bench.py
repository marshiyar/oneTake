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

Benchmarks (each a separate process per run, so one run's state never reaches the next):
  startup   the app (MpVFX) launched with a hidden window on the built-in demo until its first painted frame is
            written as a PNG (MPVFX_SMOKE_SNAPSHOT; MPVFX_SMOKE_DELAY_MS=100 settle), wall time from spawn to exit
            and the process's peak memory. --launcher wraps the command (Linux: xvfb-run ... dbus-run-session --).
  audio     MpvfxAudioBench 30: the every-FX graph rendered offline and in 128-frame live blocks, speed against
            real time, and the seek pre-roll.
  grade     MpvfxColorBench 10: the colour grade on the CPU and on the GPU (Vulkan, Direct3D 11 or Metal) at 1080p and
            4K for three looks, ms per frame.
  preview   MpvfxPreviewBench, every scenario (1080p, 4k, stacked, graded, scrub) on clips the bench makes with
            the media engine's own encoder: fps, ms per frame per stage, peak memory; and export (10 s of 1080p30
            exported to MP4 through renderNativeTimeline): export_fps, paint_ms, encode_ms, peak_rss_mib.
Every number is recorded with its unit, the samples, n, p50, p95 and max (nearest rank), the machine (OS, CPU,
cores, memory, GPU as the grade bench names it, class), the commit and the date; the result is <out>/bench-<os>.json
plus a Markdown table on stdout. A GitHub-hosted runner is a shared machine: compare runs of the same class only,
and read trends, not single runs.
"""
import argparse, datetime, json, math, os, platform, re, shlex, subprocess, tempfile, time

HERE = os.getcwd()


def sh(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def machine():
    """What the numbers were measured on."""
    system = platform.system()
    cpu, ram = platform.processor() or platform.machine(), None
    if system == "Linux":
        with open("/proc/cpuinfo", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("model name"):
                    cpu = line.split(":", 1)[1].strip(); break
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal"):
                    ram = round(int(line.split()[1]) / 1048576, 1); break
    elif system == "Darwin":
        cpu = sh("sysctl", "-n", "machdep.cpu.brand_string") or cpu
        mem = sh("sysctl", "-n", "hw.memsize")
        ram = round(int(mem) / 1073741824, 1) if mem.isdigit() else None
    elif system == "Windows":
        out = sh("powershell", "-NoProfile", "-Command",
                 "(Get-CimInstance Win32_Processor).Name; (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory")
        lines = [l.strip() for l in out.splitlines() if l.strip()]
        if len(lines) >= 2:
            cpu = lines[0]
            ram = round(int(lines[1]) / 1073741824, 1) if lines[1].isdigit() else None
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
        for scenario in ("1080p", "4k", "stacked", "graded", "scrub", "export"):
            wall, peak, out, code = run([exe, scenario, clips, results])
            if code != 0:
                raise SystemExit(f"preview {scenario} run {i + 1}: exit {code}\n{out[-3000:]}")
    with open(results, encoding="utf-8") as f:
        result_lines = f.readlines()
    for line in result_lines:
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        scenario = rec.get("scenario", "unknown")
        for key, value in rec.items():
            # The bench writes every value as a JSON string ("fps":"29.9"); text such as "display" does not parse.
            try:
                value = float(value)
            except (TypeError, ValueError):
                continue
            if math.isfinite(value) and key != "frames":
                unit = "fps" if "fps" in key else "MiB" if "mib" in key.lower() or "rss" in key.lower() else "ms" if "ms" in key else ""
                r.add(f"preview.{scenario}.{key}", unit, value)


def table(metrics):
    lines = ["| metric | unit | n | p50 | p95 | max | note |", "|---|---|---:|---:|---:|---:|---|"]
    for name, m in metrics.items():
        lines.append(f"| `{name}` | {m['unit']} | {m['n']} | {m['p50']:g} | {m['p95']:g} | {m['max']:g} | {m.get('note', '')} |")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True, help="directory for bench-<os>.json, logs and fixtures")
    ap.add_argument("--runs", type=int, default=5, help="processes per benchmark (default 5)")
    ap.add_argument("--launcher", default="", help="command that wraps the app for the startup benchmark")
    ap.add_argument("--only", default="", help="comma list of benchmarks to run")
    ap.add_argument("--skip", default="", help="comma list of benchmarks to leave out")
    args = ap.parse_args()
    names = ["startup", "audio", "grade", "preview"]
    if args.only:
        names = [n for n in names if n in args.only.split(",")]
    names = [n for n in names if n not in args.skip.split(",")]
    os.makedirs(args.out, exist_ok=True)
    bin_dir = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], capture_output=True, text=True, check=True).stdout.strip()
    launcher = shlex.split(args.launcher) if args.launcher else None
    info = machine()
    r = Results()
    started = time.time()
    if "startup" in names:
        bench_startup(bin_dir, args.runs, args.out, launcher, r)
    if "audio" in names:
        bench_audio(bin_dir, args.runs, r)
    if "grade" in names:
        bench_grade(bin_dir, args.runs, r, info)
    if "preview" in names:
        bench_preview(bin_dir, args.runs, args.out, r)
    metrics = r.finish()
    commit = sh("git", "rev-parse", "HEAD") or os.environ.get("GITHUB_SHA", "unknown")
    report = {"schema": 1, "commit": commit, "date": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
              "machine": info, "runs": args.runs, "benchmarks": names, "elapsed_s": round(time.time() - started, 1), "metrics": metrics}
    tag = platform.system().lower()
    path = os.path.join(args.out, f"bench-{tag}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1, sort_keys=True)
    print(f"### {info['os']}: {info['cpu']}, {info['cores']} cores, {info['ram_gb']} GiB, GPU {info.get('gpu', 'not measured')} ({info['class']})")
    print(f"commit {commit[:7]}, {args.runs} runs per benchmark, {report['elapsed_s']} s; `{os.path.basename(path)}` in the artifact\n")
    print(table(metrics))


if __name__ == "__main__":
    main()
