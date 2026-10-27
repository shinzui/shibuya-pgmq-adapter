#!/usr/bin/env python3
"""Reproduce every ExecPlan 9 gate using disposable databases and immutable sources.

Run inside nix develop. No database connection is accepted. Missing, failed or
inconclusive evidence exits nonzero. --smoke exercises tooling only and can never
produce PASS. Outputs are never overwritten or favorable samples discarded.
"""
import argparse
import difflib
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import random
import re
import resource
import shutil
import statistics
import subprocess
import sys
import tarfile
import time

# Import the sibling CLI without requiring third-party Python packages.
import importlib.util
_spec = importlib.util.spec_from_file_location("capture", Path(__file__).with_name("capture-dlq-worker-baseline.py"))
capture = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(capture)
SCENARIOS = capture.SCENARIOS
BENCH = capture.BENCH
ROOT = Path(__file__).resolve().parent.parent
SEED = 910262026


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def upper_bound(values, seed=SEED):
    if len(values) < 7 or any(not math.isfinite(v) or v <= 0 for v in values):
        raise ValueError("require seven finite, positive paired ratios")
    rng = random.Random(seed)
    medians = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(10_000))
    return medians[9499]


def gate(name, ratios, limit):
    bound = upper_bound(ratios)
    return {"name": name, "ratios": ratios, "median": statistics.median(ratios),
            "upper95": bound, "limit": limit, "status": "PASS" if bound <= limit else "FAIL"}


def worker_gates(name, controls, candidates, dlq=False, loaded=False):
    if len(controls) != len(candidates) or not all(r.get("valid") for r in controls + candidates):
        raise ValueError(f"{name}: invalid or missing worker observations")
    for run in controls + candidates:
        tables = run.get("maintenance", {}).get("tables", [])
        if not tables or any(table["autoVacuumCount"] or table["autoAnalyzeCount"]
                             or table["manualVacuumCount"] < 1 or table["manualAnalyzeCount"] < 1
                             or "autovacuum_enabled=false" not in table["options"] for table in tables):
            raise ValueError(f"{name}: uncontrolled fixture maintenance invalidates measurement")
    gates = [gate(name + "/throughput", [b["throughput"] / c["throughput"] for b,c in zip(controls,candidates)], 1 / 0.95),
             gate(name + "/p95", [c["p95Ms"] / b["p95Ms"] for b,c in zip(controls,candidates)], 1.10)]
    if not loaded:
        # The production source queue is perf_source: its field contribution is
        # 31 compact-JSON bytes. The dedicated encoding matrix asserts this too.
        allowance = 2048 + 4 * 31
        ratios = [c["allocatedPerCommit"] / (b["allocatedPerCommit"] + allowance if dlq else b["allocatedPerCommit"] * 1.05)
                  for b,c in zip(controls,candidates)]
        gates.append(gate(name + "/allocation", ratios, 1))
    if loaded:
        for run in candidates:
            admin = run["administration"]
            if admin["successful"] / admin["scheduled"] < 0.99 or admin["completed"] != admin["scheduled"]:
                gates.append({"name": name + "/admin-completion", "status": "FAIL", "counts": admin})
    return gates


def encoding_gates(encoding):
    if len(encoding["current"]) < 7 or len(encoding["current"]) != len(encoding["aware"]) or any(len(cases) != 30 for runs in encoding.values() for cases in runs):
        raise ValueError("incomplete encoding matrix")
    gates = []
    for index in range(30):
        old = [cases[index] for cases in encoding["current"]]
        new = [cases[index] for cases in encoding["aware"]]
        identities = {(case["reason"], case["bodyBytes"], case["metadata"]) for case in old + new}
        if len(identities) != 1:
            raise ValueError("encoding fixture identities differ")
        label = f"encoding/{old[0]['reason']}/{old[0]['bodyBytes']}/{old[0]['metadata']}"
        gates += [gate(label + "/time", [c["nsPerOp"] / max(b["nsPerOp"] * 1.1, b["nsPerOp"] + 500) for b,c in zip(old,new)], 1),
                  gate(label + "/allocation", [c["allocatedPerOp"] / (b["allocatedPerOp"] + 2048 + 4 * c["sourceFieldBytes"]) for b,c in zip(old,new)], 1)]
    return gates


def snapshot(output, name, ref=None):
    dest = output / (name + "-source")
    dest.mkdir()
    if ref:
        archive = output / (name + ".tar")
        with archive.open("wb") as stream:
            subprocess.run(["git", "archive", ref], cwd=ROOT, stdout=stream, check=True)
        with tarfile.open(archive) as stream:
            stream.extractall(dest, filter="data")
    else:
        paths = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT).decode().split("\0")
        for relative in filter(None, paths):
            src = ROOT / relative
            if src.is_file():
                target = dest / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, target)
    return dest


def instrument(snapshot_dir, matched):
    """Apply only retained benchmark code; matching deps needs a core API shim."""
    cabal_path = Path(BENCH) / (BENCH + ".cabal")
    old = (snapshot_dir / cabal_path).read_text()
    component = (ROOT / cabal_path).read_text().split("executable dlq-performance\n", 1)[1].split("\nexecutable ", 1)[0]
    if not matched:
        component = component.replace("^>=0.7.0.0", "^>=0.6.1.1").replace("shibuya-core ^>=0.12.0.0", "shibuya-core ^>=0.11.0.0")
    (snapshot_dir / cabal_path).write_text(old + "\nexecutable dlq-performance\n" + component)
    for relative in capture.INSTRUMENTATION:
        shutil.copy2(ROOT / relative, snapshot_dir / relative)
    if matched:
        for path in snapshot_dir.glob("*/*.cabal"):
            s = re.sub(r"(pgmq-(?:core|hasql|effectful|migration)) \^>=0\.6(?:\.1\.1)?", r"\1 ^>=0.7.0.0", path.read_text())
            s = s.replace("shibuya-core ^>=0.11.0.0", "shibuya-core ^>=0.12.0.0").replace("shibuya-metrics ^>=0.11.0.0", "shibuya-metrics ^>=0.12.0.0")
            path.write_text(s)
        internal = snapshot_dir / "shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs"
        s = internal.read_text().replace("import Shibuya.Core.Ingested (Ingested (..))", "import Shibuya.Core.Ingested (DeliveryStatus (..), Ingested (..))")
        s = s.replace("lease = Just lease\n", "lease = Just lease,\n              deliveryStatus = pure DeliveryCurrent\n")
        internal.write_text(s)


def build(output, snapshot_dir, name, candidate=False):
    target = "dlq-admin-performance" if candidate else "dlq-performance"
    options = [f"--project-dir={snapshot_dir}", "--builddir=dist-performance", "--enable-optimization=2"]
    capture.run_logged(["cabal", "build", target, *options], ROOT, output / (name + "-build.log"))
    plan = snapshot_dir / "dist-performance/cache/plan.json"
    shutil.copy2(plan, output / (name + "-dependencies.json"))
    return capture.query(["cabal", "list-bin", target, *options], ROOT).splitlines()[-1]


def source_patch(original, modified):
    result = []
    for path in sorted(modified.rglob("*")):
        if path.is_file() and "dist-performance" not in path.parts:
            relative = path.relative_to(modified)
            previous = original / relative
            try:
                before = previous.read_text() if previous.exists() else ""
                after = path.read_text()
            except UnicodeDecodeError:
                continue
            if before != after:
                result.extend(difflib.unified_diff(before.splitlines(True), after.splitlines(True), fromfile="a/" + str(relative), tofile="b/" + str(relative)))
    return "".join(result)


class Experiment:
    def __init__(self, output):
        self.output = output
        self.sequence = 0
        self.runs = []
        self.gates = []
        self.reuse = {}
        self.parent = None

    def load_parent(self, parent, result):
        self.parent = parent
        for run in result["runs"]:
            artifact = parent / run["artifact"]
            label = artifact.name.split("-", 1)[1].removesuffix(".json")
            key = (label, tuple(map(str, run["arguments"])))
            if key in self.reuse:
                raise ValueError("duplicate reusable measurement identity: " + label)
            # Include failed/invalid records too. Changing nothing must not
            # silently rerun a failure until it happens to look favorable.
            self.reuse[key] = artifact.resolve()

    def measure(self, binary, arguments, label):
        self.sequence += 1
        key = (label, tuple(map(str, arguments)))
        if key in self.reuse:
            artifact = self.reuse[key]
            record = json.loads(artifact.read_text())
            self.runs.append({"artifact": str(artifact), "arguments": arguments, "reusedFrom": str(self.parent)})
            self.save("RUNNING")
            print("DLQ-PERFORMANCE: retained " + label, flush=True)
            return record
        name = f"{self.sequence:04}-{label}"
        print(f"DLQ-PERFORMANCE: measuring {name}", flush=True)
        log = self.output / (name + ".log")
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        start = time.monotonic()
        capture.run_logged([binary, *map(str, arguments), "+RTS", "-N4", "-T", "-RTS"], ROOT, log)
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        records = [json.loads(line) for line in log.read_text().splitlines() if line.startswith("{")]
        if len(records) != 1:
            raise ValueError(f"expected one measurement record: {log}")
        record = records[0]
        record["processCounters"] = {"elapsedSeconds": time.monotonic() - start,
            "userSeconds": after.ru_utime - before.ru_utime, "systemSeconds": after.ru_stime - before.ru_stime,
            "inputBlocks": after.ru_inblock - before.ru_inblock, "outputBlocks": after.ru_oublock - before.ru_oublock,
            "scope": "runner and its disposable PostgreSQL children, including setup"}
        write_json(self.output / (name + ".json"), record)
        self.runs.append({"artifact": name + ".json", "arguments": arguments})
        self.save("RUNNING")
        return record

    def save(self, status):
        write_json(self.output / "result.json", {"status": status, "bootstrapSeed": SEED, "bootstrapResamples": 10000,
            "runs": self.runs, "gates": self.gates, "resumedFrom": str(self.parent) if self.parent else None})


def plans_use_indexes(value):
    nodes = []
    def visit(item):
        if isinstance(item, dict):
            if "Node Type" in item:
                nodes.append(item)
            for child in item.values():
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)
    visit(value)
    return (not any(node["Node Type"] in ("Seq Scan", "Sort", "Incremental Sort") for node in nodes)
            and any(node["Node Type"] in ("Index Scan", "Index Only Scan")
                    and "msg_id" in node.get("Index Cond", "") for node in nodes))


def verify_frozen_parent(parent, baseline):
    if not parent.is_relative_to(ROOT / ".dev"):
        raise ValueError("parent experiment must be under this checkout's .dev")
    previous = json.loads((parent / "result.json").read_text())
    if previous["status"] == "RUNNING":
        raise ValueError("wait for the parent experiment to finish")
    environment = json.loads((parent / "environment.json").read_text())
    if environment["baselineCommit"] != baseline:
        raise ValueError("baseline differs from parent")
    for name, command in (("ghc", ["ghc", "--numeric-version"]), ("postgresql", ["postgres", "--version"]), ("cabal", ["cabal", "--version"])):
        if capture.query(command, ROOT) != environment[name]:
            raise ValueError(name + " differs from parent")
    for relative, digest in json.loads((parent / "candidate-sha256.json").read_text()).items():
        path = ROOT / relative
        if path.suffix in (".hs", ".cabal", ".nix") or path.name in ("cabal.project", "flake.lock"):
            if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise ValueError("measured source/constraints changed: " + relative)
    if environment["machine"] != platform.machine() or environment["cpuCount"] != os.cpu_count():
        raise ValueError("hardware differs from parent")
    if environment.get("hardware") and capture.query(["sysctl", "hw.model", "hw.memsize", "machdep.cpu.brand_string"], ROOT) != environment["hardware"]:
        raise ValueError("hardware differs from parent")
    return previous, environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", required=True)
    parser.add_argument("--pairs", type=int, default=7)
    parser.add_argument("--ack-one-pairs", type=int, default=21, help="fixed sample count for the short-latency single-worker case; never stop early on a favorable bound")
    parser.add_argument("--warmup-seconds", type=int, default=10)
    parser.add_argument("--sample-seconds", type=int, default=60)
    parser.add_argument("--seed-count", type=int, default=3_000_000)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--smoke", action="store_true", help="short diagnostic; always INCONCLUSIVE")
    parser.add_argument("--resume-from", type=Path, help="retain every matching measurement from a finished parent")
    parser.add_argument("--case-seed-count", dest="case_seed_counts", action="append", default=[], help="fixed source fixture SCENARIO=ROWS (default fifo-load-one=100000)")
    parser.add_argument("--encoding-pairs", type=int, default=7, help="fixed encoding pair count, chosen before measurement")
    args = parser.parse_args()
    if not args.smoke and (args.pairs < 7 or args.encoding_pairs < 7 or args.warmup_seconds < 10 or args.sample_seconds < 60):
        parser.error("acceptance requires >=7 pairs, >=10s warmup and >=60s samples")
    if args.pairs < 1 or args.ack_one_pairs < 1 or args.encoding_pairs < 1 or args.warmup_seconds < 0 or args.sample_seconds < 1 or args.seed_count < 1000:
        parser.error("invalid experiment size")
    overrides = {} if args.smoke else {"fifo-load-one": 100_000}
    for override in args.case_seed_counts:
        name, separator, value = override.partition("=")
        if not separator or name not in (*SCENARIOS, "ack-load-one", "ack-load-fifty", "fifo-load-one", "fifo-load-fifty") or not value.isdecimal() or int(value) < 1000:
            parser.error("invalid per-case source fixture: " + override)
        overrides[name] = int(value)
    args.case_seed_counts = overrides
    output = args.output.resolve()
    if not output.is_relative_to(ROOT / ".dev"):
        parser.error("output must be under this checkout's .dev directory")
    output.mkdir(parents=True, exist_ok=False)
    experiment = Experiment(output)
    try:
        baseline = capture.query(["git", "rev-parse", args.baseline_ref + "^{commit}"], ROOT)
        env = {"baselineCommit": baseline, "candidateCommit": capture.query(["git", "rev-parse", "HEAD"], ROOT),
            "platform": platform.platform(), "machine": platform.machine(), "cpuCount": os.cpu_count(),
            "ghc": capture.query(["ghc", "--numeric-version"], ROOT), "cabal": capture.query(["cabal", "--version"], ROOT),
            "postgresql": capture.query(["postgres", "--version"], ROOT), "optimization": 2, "runtimeFlags": ["-N4", "-T"],
            "arguments": {k: str(v) if isinstance(v, Path) else v for k,v in vars(args).items()}}
        if sys.platform == "darwin":
            env["hardware"] = capture.query(["sysctl", "hw.model", "hw.memsize", "machdep.cpu.brand_string"], ROOT)
        write_json(output / "environment.json", env)
        (output / "candidate-working.patch").write_bytes(subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=ROOT))
        if args.resume_from:
            parent = args.resume_from.resolve()
            previous, parent_environment = verify_frozen_parent(parent, baseline)
            experiment.load_parent(parent, previous)
            env["orchestratorCommit"] = env["candidateCommit"]
            env["candidateCommit"] = parent_environment["candidateCommit"]
            env["resumedFrom"] = str(parent)
            env["parentResultSha256"] = hashlib.sha256((parent / "result.json").read_bytes()).hexdigest()
            write_json(output / "environment.json", env)
            for kind in ("original", "matched", "candidate"):
                (output / (kind + "-source")).symlink_to((parent / (kind + "-source")).resolve(), target_is_directory=True)
                shutil.copy2(parent / (kind + "-dependencies.json"), output / (kind + "-dependencies.json"))
            for filename in ("candidate-sha256.json", "original-instrumentation.patch", "matched-compatibility.patch", "candidate-working.patch"):
                shutil.copy2(parent / filename, output / filename)
            binaries = {}
            for kind in ("original", "matched", "candidate"):
                target = "dlq-admin-performance" if kind == "candidate" else "dlq-performance"
                binaries[kind] = str(next(path for path in (parent / (kind + "-source") / "dist-performance").rglob(target)
                                          if path.is_file() and os.access(path, os.X_OK)))
        else:
            original = snapshot(output, "original", baseline)
            pristine = snapshot(output, "pristine", baseline)
            matched = snapshot(output, "matched", baseline)
            candidate = snapshot(output, "candidate")
            instrument(original, False)
            instrument(matched, True)
            (output / "original-instrumentation.patch").write_text(source_patch(pristine, original))
            (output / "matched-compatibility.patch").write_text(source_patch(original, matched))
            hashes = {str(p.relative_to(candidate)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in candidate.rglob("*") if p.is_file()}
            write_json(output / "candidate-sha256.json", hashes)
            binaries = {"original": build(output, original, "original"), "matched": build(output, matched, "matched"),
                        "candidate": build(output, candidate, "candidate", True)}
        dependencies = {}
        for kind in ("original", "matched", "candidate"):
            plan = json.loads((output / (kind + "-dependencies.json")).read_text())
            dependencies[kind] = {item["pkg-name"]: item["pkg-version"] for item in plan["install-plan"] if item.get("style") != "local"}
        shared = dependencies["matched"].keys() & dependencies["candidate"].keys()
        mismatches = {name: [dependencies["matched"][name], dependencies["candidate"][name]] for name in shared if dependencies["matched"][name] != dependencies["candidate"][name]}
        write_json(output / "dependency-comparison.json", {"versions": dependencies, "matchedDifferences": mismatches})
        if mismatches:
            raise ValueError("matched control dependencies differ from candidate; inspect dependency-comparison.json")
        warm, sample, seeds = args.warmup_seconds, args.sample_seconds, args.seed_count
        # Worker controls share one candidate sample per pair. Alternate order
        # against BOTH controls; all three run sequentially on fresh fixtures.
        for scenario in SCENARIOS:
            data = {k: [] for k in ("original", "matched", "candidate", "none")}
            worker_pairs = args.pairs
            if not args.smoke and scenario == "ack-one":
                worker_pairs = max(args.pairs, args.ack_one_pairs)
            case_seeds = args.case_seed_counts.get(scenario, seeds)
            for pair in range(worker_pairs):
                order = ["original", "matched", "candidate"] + (["none"] if scenario == "ack-four" else [])
                if pair % 2:
                    order.reverse()
                for kind in order:
                    arguments = [scenario, warm, sample, case_seeds] if kind in ("original", "matched") else ["worker", scenario, warm, sample, case_seeds, "none" if kind == "none" else "idle"]
                    record = experiment.measure(binaries.get(kind, binaries["candidate"]), arguments, f"worker-{scenario}-{kind}-{pair + 1}")
                    data[kind].append(record)
            if not args.smoke:
                for kind in ("original", "matched"):
                    experiment.gates += worker_gates(scenario + "/" + kind, data[kind], data["candidate"], scenario.startswith("dlq"))
                if data["none"]:
                    experiment.gates += worker_gates("idle-handle", data["none"], data["candidate"])
                experiment.save("RUNNING")
        for scenario in ("ack-load-one", "ack-load-fifty", "fifo-load-one", "fifo-load-fifty"):
            case_seeds = args.case_seed_counts.get(scenario, seeds)
            data = {"idle": [], "load": []}
            for pair in range(args.pairs):
                for mode in (["idle", "load"] if pair % 2 == 0 else ["load", "idle"]):
                    data[mode].append(experiment.measure(binaries["candidate"], ["worker", scenario, warm, sample, case_seeds, mode], f"load-{scenario}-{mode}-{pair + 1}"))
            if not args.smoke:
                experiment.gates += worker_gates("operator-load/" + scenario, data["idle"], data["load"], loaded=True)
        encoding = {"current": [], "aware": []}
        for pair in range(args.pairs if args.smoke else max(args.pairs, args.encoding_pairs)):
            for mode in (["current", "aware"] if pair % 2 == 0 else ["aware", "current"]):
                encoding[mode].append(experiment.measure(binaries["candidate"], ["encoding", mode, warm, sample], f"encoding-{mode}-{pair + 1}")["cases"])
        if not args.smoke:
            experiment.gates += encoding_gates(encoding)
        reads = {}
        for layout, depth, body in [(l,d,100) for l in ("ordinary","unlogged") for d in (100_000,1_000_000)] + [("ordinary",1000,100_000)]:
            data = {"raw": [], "adapter": []}
            for pair in range(args.pairs):
                for mode in (["raw", "adapter"] if pair % 2 == 0 else ["adapter", "raw"]):
                    data[mode].append(experiment.measure(binaries["candidate"], ["reads", layout, depth, body, mode, warm, sample], f"reads-{layout}-{depth}-{body}-{mode}-{pair + 1}")["cases"])
            reads[(layout, depth, body)] = data
            if not args.smoke:
                if any(len(cases) != 12 for runs in data.values() for cases in runs):
                    raise ValueError("incomplete read matrix")
                for index in range(12):
                    old = [cases[index] for cases in data["raw"]]
                    new = [cases[index] for cases in data["adapter"]]
                    label = f"reads/{layout}/{depth}/{body}/{old[0]['position']}/{old[0]['limit']}/{old[0]['fetch']}"
                    if any(not plans_use_indexes(case["explain"]) or case["count"] < 1 for case in old + new):
                        raise ValueError(label + ": query plan or observations invalid")
                    experiment.gates.append(gate(label, [c["p95Ms"] / (2 * b["p95Ms"] + 5) for b,c in zip(old,new)], 1))
        if not args.smoke:
            for layout in ("ordinary", "unlogged"):
                for index in range(12):
                    old = [cases[index] for cases in reads[(layout,100_000,100)]["adapter"]]
                    new = [cases[index] for cases in reads[(layout,1_000_000,100)]["adapter"]]
                    experiment.gates.append(gate(f"depth/{layout}/{index}", [c["p95Ms"] / b["p95Ms"] for b,c in zip(old,new)], 1.5))
        retention = experiment.measure(binaries["candidate"], ["retention", 3 if args.smoke else 300], "retention")
        if not args.smoke:
            early = [row["liveBytes"] for row in retention["heapSamples"] if 60 <= row["seconds"] < 120]
            late = [row["liveBytes"] for row in retention["heapSamples"] if 240 <= row["seconds"] <= 300]
            if not early or not late:
                raise ValueError("missing second/final minute retention samples")
            control = statistics.median(early)
            delta = statistics.median(late) - control
            experiment.gates.append({"name": "retained-heap", "growthBytes": delta, "limitBytes": max(0.05 * control, 8 * 1024**2),
                "status": "PASS" if delta <= max(0.05 * control, 8 * 1024**2) else "FAIL"})
        if not args.smoke and len(experiment.gates) < 198:
            raise ValueError("incomplete performance gate matrix")
        status = "INCONCLUSIVE" if args.smoke else "FAIL" if any(g["status"] != "PASS" for g in experiment.gates) else "PASS"
        experiment.save(status)
        print("DLQ-PERFORMANCE: " + status, flush=True)
        return 0 if status == "PASS" else 1
    except BaseException as error:
        experiment.save("INCONCLUSIVE")
        (output / "error.txt").write_text(str(error) + "\n")
        raise


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print("DLQ-PERFORMANCE: INCONCLUSIVE: " + str(error), file=sys.stderr)
        sys.exit(1)
