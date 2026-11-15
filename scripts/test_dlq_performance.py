"""Protect release acceptance from false PASS results and inverted comparisons."""
import importlib.util
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch
import unittest

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location("performance", Path(__file__).with_name("check-dlq-performance.py"))
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


MAINTENANCE = {"tables": [{"autoVacuumCount": 0, "autoAnalyzeCount": 0, "manualVacuumCount": 1, "manualAnalyzeCount": 1, "options": ["autovacuum_enabled=false"]}]}


WORKER = dict(valid=True, throughput=100, p95Ms=1, allocatedPerCommit=100, maintenance=MAINTENANCE,
              committed=6000, remaining=10000, warmupSeconds=10, sampleSeconds=60, requestedSampleSeconds=60,
              scenario="ack-one", seedCount=20000, workers=1, workerConnections=4,
              batchSize=1, bodyBytes=100, fifo=False, metadata=False, clock="raw", databaseSettings={})


class PerformanceAcceptance(unittest.TestCase):
    def test_seven_pairs_are_required(self):
        for values in ([], [1] * 6, [float("nan")] * 7, [0] * 7):
            with self.assertRaises(ValueError):
                performance.upper_bound(values)

    def test_bootstrap_is_deterministic_and_retains_bad_pairs(self):
        values = [1, 1, 1, 1, 1.2, 1.2, 1.2]
        self.assertEqual(performance.upper_bound(values), performance.upper_bound(values))
        self.assertEqual(performance.gate("uncertain", values, 1.1)["status"], "INCONCLUSIVE")

    def test_clear_regression_and_pass_keep_original_budgets(self):
        self.assertEqual(performance.gate("regression", [1.2] * 7, 1.1)["status"], "FAIL")
        self.assertEqual(performance.gate("boundary", [1.1] * 7, 1.1)["status"], "PASS")

    def test_saved_fifo_uncertainty_is_not_a_pass_or_proven_regression(self):
        ratios = [0.892874357326478, 1.106649604017771, 0.872, 0.8992437129798527,
                  1.17246511627907, 0.4535507018496812, 1.2986190476190476]
        result = performance.gate("fifo", ratios, 1.1)
        self.assertEqual(result["upper95"], 1.17246511627907)
        self.assertLess(result["lower95"], 1)
        self.assertEqual(result["status"], "INCONCLUSIVE")
        self.assertEqual(performance.result_status([result]), "INCONCLUSIVE")

    def test_missing_or_uncertain_results_cannot_certify_acceptance(self):
        self.assertEqual(performance.result_status([]), "INCONCLUSIVE")
        self.assertEqual(performance.result_status([{"status": "PASS"}, {"status": "INCONCLUSIVE"}]), "INCONCLUSIVE")
        self.assertEqual(performance.result_status([{"status": "FAIL"}, {"status": "INCONCLUSIVE"}]), "FAIL")

    def test_short_or_mismatched_worker_records_are_rejected(self):
        for change in (dict(sampleSeconds=1), dict(committed=999), dict(seedCount=30000),
                       dict(batchSize=50), dict(remaining=1), dict(databaseSettings={"work_mem": "different"}),
                       dict(measurementMode="blocked-stdin-v1")):
            with self.subTest(change=change), self.assertRaises(ValueError):
                performance.worker_gates("invalid", [WORKER] * 7, [dict(WORKER, **change)] * 7)

    def test_worker_throughput_ratio_direction(self):
        before = dict(WORKER)
        after = dict(WORKER, throughput=90)
        results = performance.worker_gates("worker", [before] * 7, [after] * 7)
        self.assertEqual(results[0]["status"], "FAIL")
        self.assertEqual(results[1]["status"], "PASS")

    def test_depleted_fixture_is_inconclusive(self):
        with self.assertRaises(ValueError):
            performance.worker_gates("depleted", [dict(valid=False)] * 7, [dict(valid=True)] * 7)

    def test_uncontrolled_maintenance_is_inconclusive(self):
        run = dict(WORKER, maintenance={"tables": []})
        with self.assertRaises(ValueError):
            performance.worker_gates("maintenance", [run] * 7, [run] * 7)

    def test_operator_gate_allows_the_planned_one_percent_failure_budget(self):
        before = dict(WORKER)
        after = dict(before, administration=dict(scheduled=660, started=660, successful=659, completed=660, failed=1))
        results = performance.worker_gates("operator", [before] * 7, [after] * 7, loaded=True)
        self.assertTrue(all(row["status"] == "PASS" for row in results))

    def test_failed_operator_requests_cannot_pass(self):
        before = dict(WORKER)
        after = dict(before, administration=dict(scheduled=660, started=660, successful=650, completed=660, failed=10))
        results = performance.worker_gates("operator", [before] * 7, [after] * 7, loaded=True)
        self.assertTrue(any(row["status"] == "FAIL" for row in results))

    def test_under_delivered_operator_load_cannot_pass(self):
        after = dict(WORKER, administration=dict(scheduled=11, started=11, successful=11, completed=11, failed=0))
        results = performance.worker_gates("operator", [WORKER] * 7, [after] * 7, loaded=True)
        self.assertEqual(results[-1]["status"], "FAIL")

    def test_reused_binary_contents_are_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            with self.assertRaisesRegex(ValueError, "lacks binary hashes"):
                performance.verified_binaries(root)
            binary = root / "worker"
            binary.write_bytes(b"measured executable")
            row = dict(path=str(binary), sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
            (root / "binaries.json").write_text(json.dumps({kind: row for kind in ("original", "matched", "candidate")}))
            self.assertEqual(performance.verified_binaries(root)["original"], str(binary))
            binary.write_bytes(b"changed executable")
            with self.assertRaisesRegex(ValueError, "binary changed"):
                performance.verified_binaries(root)

    def test_focused_modes_cannot_run_or_certify_the_full_matrix(self):
        for option, scope, builds, measurements, gate_count in (
                ("--repeatability", "repeatability", 1, 14, 6),
                ("--worker-only", "worker", 3, 21, 6)):
            with self.subTest(option=option), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                output = root / ".dev/focused"
                def snapshot(dest, name, ref=None):
                    path = dest / (name + "-source")
                    path.mkdir()
                    return path
                def build(dest, source, name, candidate=False):
                    binary = source / "worker"
                    binary.write_bytes(b"executable")
                    (dest / (name + "-dependencies.json")).write_text('{"install-plan": []}')
                    return str(binary)
                with patch.object(performance, "ROOT", root), \
                     patch.object(sys, "argv", ["check", "--baseline-ref", "baseline", "--output", str(output), option, "ack-fifo"]), \
                     patch.object(performance.capture, "query", return_value="identity"), \
                     patch.object(performance.subprocess, "check_output", return_value=b""), \
                     patch.object(performance, "snapshot", side_effect=snapshot), \
                     patch.object(performance, "instrument"), \
                     patch.object(performance, "build", side_effect=build) as builder, \
                     patch.object(performance.Experiment, "measure", return_value=WORKER) as measure:
                    self.assertEqual(performance.main(), 0)
                    self.assertEqual(builder.call_count, builds)
                    self.assertEqual(measure.call_count, measurements)
                    result = json.loads((output / "result.json").read_text())
                    self.assertEqual(result["scope"], scope)
                    self.assertEqual(len(result["gates"]), gate_count)
                    if scope == "repeatability":
                        self.assertEqual(len({call.args[0] for call in measure.call_args_list}), 1)

    def test_encoding_absolute_time_allowance_and_allocation_boundary(self):
        old = [{"reason": str(i), "bodyBytes": 100, "metadata": False, "nsPerOp": 1000,
                "allocatedPerOp": 1000, "sourceFieldBytes": 31} for i in range(30)]
        allowed = [dict(case, nsPerOp=1400, allocatedPerOp=3172) for case in old]
        self.assertTrue(all(gate["status"] == "PASS" for gate in performance.encoding_gates({"current": [old]*7, "aware": [allowed]*7})))
        excessive = [dict(case, nsPerOp=1501, allocatedPerOp=3173) for case in old]
        self.assertTrue(all(gate["status"] == "FAIL" for gate in performance.encoding_gates({"current": [old]*7, "aware": [excessive]*7})))

    def test_duplicate_encoding_cases_cannot_fill_the_matrix(self):
        duplicate = dict(reason="poison", bodyBytes=100, metadata=False,
                         nsPerOp=1000, allocatedPerOp=1000, sourceFieldBytes=31)
        with self.assertRaisesRegex(ValueError, "duplicate encoding"):
            performance.encoding_gates({"current": [[duplicate] * 30] * 7, "aware": [[duplicate] * 30] * 7})

    def test_resume_rejects_a_running_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            parent = root / ".dev/parent"
            parent.mkdir(parents=True)
            (parent / "result.json").write_text('{"status":"RUNNING"}')
            with patch.object(performance, "ROOT", root), self.assertRaises(ValueError):
                performance.verify_frozen_parent(parent, "unused")

    def test_resume_retains_matching_invalid_evidence_without_rerunning(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory) / "parent"
            parent.mkdir()
            artifact = parent / "0001-case.json"
            artifact.write_text('{"valid":false}')
            output = Path(directory) / "resumed"
            output.mkdir()
            experiment = performance.Experiment(output)
            experiment.load_parent(parent, {"runs": [{"artifact": artifact.name, "arguments": ["scenario", 60, 3000000]}]})
            with patch.object(performance.capture, "run_logged", side_effect=AssertionError("must reuse")):
                self.assertFalse(experiment.measure("unused", ["scenario", 60, 3000000], "case")["valid"])
            self.assertEqual(artifact.read_text(), '{"valid":false}')

    def test_changed_fixture_cannot_reuse_old_measurement(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory) / "parent"
            parent.mkdir()
            artifact = parent / "0001-case.json"
            artifact.write_text('{"valid":true}')
            output = Path(directory) / "resumed"
            output.mkdir()
            experiment = performance.Experiment(output)
            experiment.load_parent(parent, {"runs": [{"artifact": artifact.name, "arguments": ["scenario", 60, 3000000]}]})
            with patch.object(performance.capture, "run_logged", side_effect=RuntimeError("fresh measurement requested")), self.assertRaisesRegex(RuntimeError, "fresh measurement"):
                experiment.measure("unused", ["scenario", 60, 100000], "case")

    def test_rejects_sequential_scans_and_sorts_below_limit(self):
        self.assertFalse(performance.plans_use_indexes([{"Plan": {"Node Type": "Limit", "Plans": [{"Node Type": "Seq Scan"}]}}]))
        self.assertFalse(performance.plans_use_indexes([{"Plan": {"Node Type": "Sort"}}]))
        self.assertTrue(performance.plans_use_indexes([{"Plan": {"Node Type": "Index Scan", "Index Cond": "msg_id > 0"}}]))


if __name__ == "__main__":
    unittest.main()
