"""Protect release acceptance from false PASS results and inverted comparisons."""
import importlib.util
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
import unittest

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location("performance", Path(__file__).with_name("check-dlq-performance.py"))
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


MAINTENANCE = {"tables": [{"autoVacuumCount": 0, "autoAnalyzeCount": 0, "manualVacuumCount": 1, "manualAnalyzeCount": 1, "options": ["autovacuum_enabled=false"]}]}


class PerformanceAcceptance(unittest.TestCase):
    def test_seven_pairs_are_required(self):
        for values in ([], [1] * 6, [float("nan")] * 7, [0] * 7):
            with self.assertRaises(ValueError):
                performance.upper_bound(values)

    def test_bootstrap_is_deterministic_and_retains_bad_pairs(self):
        values = [1, 1, 1, 1, 1.2, 1.2, 1.2]
        self.assertEqual(performance.upper_bound(values), performance.upper_bound(values))
        self.assertEqual(performance.gate("regression", values, 1.1)["status"], "FAIL")

    def test_worker_throughput_ratio_direction(self):
        before = dict(valid=True, throughput=100, p95Ms=1, allocatedPerCommit=100, maintenance=MAINTENANCE)
        after = dict(valid=True, throughput=90, p95Ms=1, allocatedPerCommit=100, maintenance=MAINTENANCE)
        results = performance.worker_gates("worker", [before] * 7, [after] * 7)
        self.assertEqual(results[0]["status"], "FAIL")
        self.assertEqual(results[1]["status"], "PASS")

    def test_depleted_fixture_is_inconclusive(self):
        with self.assertRaises(ValueError):
            performance.worker_gates("depleted", [dict(valid=False)] * 7, [dict(valid=True)] * 7)

    def test_uncontrolled_maintenance_is_inconclusive(self):
        run = dict(valid=True, throughput=100, p95Ms=1, maintenance={"tables": []})
        with self.assertRaises(ValueError):
            performance.worker_gates("maintenance", [run] * 7, [run] * 7)

    def test_operator_gate_allows_the_planned_one_percent_failure_budget(self):
        before = dict(valid=True, throughput=100, p95Ms=1, maintenance=MAINTENANCE)
        after = dict(before, administration=dict(scheduled=660, successful=659, completed=660, failed=1))
        results = performance.worker_gates("operator", [before] * 7, [after] * 7, loaded=True)
        self.assertTrue(all(row["status"] == "PASS" for row in results))

    def test_failed_operator_requests_cannot_pass(self):
        before = dict(valid=True, throughput=100, p95Ms=1, maintenance=MAINTENANCE)
        after = dict(before, administration=dict(scheduled=660, successful=650, completed=660, failed=10))
        results = performance.worker_gates("operator", [before] * 7, [after] * 7, loaded=True)
        self.assertTrue(any(row["status"] == "FAIL" for row in results))

    def test_extension_never_overwrites_previous_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            result = output / "result.json"
            result.write_text('{"status":"PASS"}')
            with self.assertRaises(ValueError):
                performance.extend_worker(SimpleNamespace(output=output))
            self.assertEqual(result.read_text(), '{"status":"PASS"}')
            self.assertFalse((output / "error.txt").exists())

    def test_extension_cannot_overlap_the_parent_experiment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            parent = root / ".dev/parent"
            parent.mkdir(parents=True)
            (parent / "result.json").write_text('{"status":"RUNNING"}')
            output = root / ".dev/extension"
            with patch.object(performance, "ROOT", root), self.assertRaises(ValueError):
                performance.extend_worker(SimpleNamespace(output=output, extend_worker_from=parent))
            self.assertFalse(output.exists())

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
