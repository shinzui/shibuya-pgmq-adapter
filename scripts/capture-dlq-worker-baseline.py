#!/usr/bin/env python3
"""Capture the fixed original-dependency worker control for ExecPlan 9.

Run inside nix develop. This captures worker evidence only; it cannot certify the
plan's complete performance matrix. It never accepts a database connection.
"""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import tarfile

SCENARIOS = (
    "ack-one", "ack-four", "ack-fifo", "dlq-direct-meta",
    "dlq-direct-small", "dlq-topic-meta", "dlq-topic-small",
)
BENCH = "shibuya-pgmq-adapter-bench"
INSTRUMENTATION = (f"{BENCH}/app/DlqPerformance.hs", f"{BENCH}/app/PerformanceDatabase.hs", f"{BENCH}/app/WorkerPerformance.hs")


def query(args, cwd):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def run_logged(args, cwd, log):
    """Retain failures and interrupt only this child's own process group."""
    with log.open("w") as output:
        child = subprocess.Popen(args, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            status = child.wait()
        except BaseException:
            for sig, seconds in ((signal.SIGINT, 10), (signal.SIGTERM, 5), (signal.SIGKILL, 5)):
                if child.poll() is not None:
                    break
                os.killpg(child.pid, sig)
                try:
                    child.wait(timeout=seconds)
                except subprocess.TimeoutExpired:
                    continue
            raise
    if status:
        raise RuntimeError(f"child exited {status}: {log}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scenario", choices=SCENARIOS, action="append")
    parser.add_argument("--repetitions", type=int, default=1)
    parser.add_argument("--warmup-seconds", type=int, default=10)
    parser.add_argument("--sample-seconds", type=int, default=60)
    parser.add_argument("--seed-count", type=int, default=1_000_000)
    args = parser.parse_args()
    if args.repetitions < 1 or args.warmup_seconds < 10 or args.sample_seconds < 60 or args.seed_count < 1000:
        parser.error("require positive repetitions, >=10s warmup, >=60s samples, and >=1000 seeded rows")
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    baseline = query(["git", "rev-parse", f"{args.baseline_ref}^{{commit}}"], root)
    snapshot = output / "source"
    snapshot.mkdir()
    archive = output / "baseline.tar"
    with archive.open("wb") as dest:
        subprocess.run(["git", "archive", baseline], cwd=root, stdout=dest, check=True)
    with tarfile.open(archive) as source:
        source.extractall(snapshot, filter="data")
    cabal_path = f"{BENCH}/{BENCH}.cabal"
    original_cabal = (snapshot / cabal_path).read_text()
    component = (root / cabal_path).read_text().split("executable dlq-performance\n", 1)[1].split("\nexecutable ", 1)[0]
    component = component.replace("^>=0.7.0.0", "^>=0.6.1.1").replace("shibuya-core ^>=0.12.0.0", "shibuya-core ^>=0.11.0.0")
    instrumented_cabal = original_cabal + "\nexecutable dlq-performance\n" + component
    (snapshot / cabal_path).write_text(instrumented_cabal)
    patch = list(difflib.unified_diff(original_cabal.splitlines(True), instrumented_cabal.splitlines(True),
                                    fromfile=f"a/{cabal_path}", tofile=f"b/{cabal_path}"))
    hashes = {}
    for relative in INSTRUMENTATION:
        content = (root / relative).read_text()
        (snapshot / relative).write_text(content)
        patch.extend(difflib.unified_diff([], content.splitlines(True), fromfile="/dev/null", tofile=f"b/{relative}"))
        hashes[relative] = hashlib.sha256(content.encode()).hexdigest()
    (output / "instrumentation.patch").write_text("".join(patch))
    environment = {
        "baselineCommit": baseline, "instrumentationHostCommit": query(["git", "rev-parse", "HEAD"], root),
        "platform": platform.platform(), "machine": platform.machine(), "cpuCount": os.cpu_count(),
        "ghc": query(["ghc", "--numeric-version"], root),
        "postgresql": query(["postgres", "--version"], root),
        "cabal": query(["cabal", "--version"], root), "optimization": 2,
        "runtimeFlags": ["-N4", "-T"], "instrumentationSha256": hashes,
        "arguments": {key: str(value) if isinstance(value, Path) else value for key, value in vars(args).items()},
    }
    if sys.platform == "darwin":
        environment["hardware"] = query(["sysctl", "hw.model", "hw.memsize", "machdep.cpu.brand_string"], root)
    (output / "environment.json").write_text(json.dumps(environment, indent=2) + "\n")
    options = [f"--project-dir={snapshot}", "--builddir=dist-baseline", "--enable-optimization=2"]
    run_logged(["cabal", "build", "dlq-performance", *options], root, output / "build.log")
    plan = snapshot / "dist-baseline/cache/plan.json"
    (output / "dependency-plan.json").write_bytes(plan.read_bytes())
    binary = query(["cabal", "list-bin", "dlq-performance", *options], root).splitlines()[-1]
    summary = []
    for scenario in args.scenario or SCENARIOS:
        for index in range(args.repetitions):
            name = f"{scenario}-{index + 1}"
            print(f"BASELINE-CAPTURE: {name}", flush=True)
            log = output / f"{name}.log"
            run_logged([binary, scenario, str(args.warmup_seconds), str(args.sample_seconds), str(args.seed_count),
                        "+RTS", "-N4", "-T", "-RTS"], root, log)
            records = [json.loads(line) for line in log.read_text().splitlines() if line.startswith("{")]
            if len(records) != 1 or records[0].get("scenario") != scenario:
                raise RuntimeError(f"expected one matching measurement: {log}")
            result = records[0]
            (output / f"{name}.json").write_text(json.dumps(result) + "\n")
            summary.append({key: value for key, value in result.items() if key != "latenciesMs"})
            (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    if not all(result["valid"] for result in summary):
        raise RuntimeError("inconclusive baseline: insufficient observations or queue depletion; retain every run")
    print("BASELINE-CAPTURE: COMPLETE (original worker control only; not performance acceptance)")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"BASELINE-CAPTURE: INCONCLUSIVE: {error}", file=sys.stderr)
        sys.exit(1)
