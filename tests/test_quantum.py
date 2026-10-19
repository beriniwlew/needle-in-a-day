"""Regression tests against the real Q# runtime; no extra test dependencies.

Run with: uv run python -m unittest discover -s tests -v
"""
from __future__ import annotations

import json
import math
from pathlib import Path
import shutil
import tempfile
import unittest

import needle_bridge as bridge

ROOT = Path(__file__).resolve().parents[1]


class GroverTests(unittest.TestCase):
    def test_known_probabilities_and_cheaper_ties(self):
        for total, marked, iterations, probability in (
            (8, 1, 2, 0.9453125),
            (8, 2, 1, 1.0),
            (8, 3, 1, 0.84375),
            (8, 4, 0, 0.5),
            (16, 9, 0, 0.5625),
            (8, 8, 0, 1.0),
        ):
            with self.subTest(total=total, marked=marked):
                self.assertEqual(bridge.grover_iterations(str(ROOT), total, marked), iterations)
                self.assertAlmostEqual(bridge.success_probability(str(ROOT), total, marked), probability)

    def test_first_peak_never_worse_than_uniform_sampling(self):
        # Compute the achieved probability independently from the chosen count.
        # This covers every marked fraction at the small register sizes we teach.
        for total in (2, 4, 8, 16, 32, 64, 128):
            for marked in range(1, total + 1):
                with self.subTest(total=total, marked=marked):
                    iterations = bridge.grover_iterations(str(ROOT), total, marked)
                    theta = math.asin(math.sqrt(marked / total))
                    achieved = math.sin((2 * iterations + 1) * theta) ** 2
                    self.assertGreaterEqual(achieved + 1e-12, marked / total)

    def test_dense_search_circuit_preserves_uniform_success_rate(self):
        # The old one-iteration circuit gave about 31.6%, below this range.
        free = [True] * 9 + [False] * 7
        measured = bridge.search_day(str(ROOT), free, 400, 42)
        self.assertEqual(len(measured), 400)
        self.assertTrue(all(0 <= index < len(free) for index in measured))
        rate = sum(free[index] for index in measured) / len(measured)
        self.assertAlmostEqual(rate, 9 / 16, delta=0.10)

    def test_invalid_counts_are_rejected(self):
        for total, marked in ((0, 0), (8, 0), (8, -1), (8, 9)):
            with self.subTest(total=total, marked=marked):
                with self.assertRaises(Exception) as caught:
                    bridge.grover_iterations(str(ROOT), total, marked)
                self.assertIn("Need 1 <= marked <= total", str(caught.exception))

    def test_zero_budget_still_reports_one_candidate_verification(self):
        # Singleton resource dimensions exercise the empty register slices too.
        for search in (bridge.earliest_booking, bridge.best_placement):
            with self.subTest(search=search.__name__):
                index, at_best, calls, runs = search(
                    str(ROOT), [[True, True]], [[True, True]], [True], [True], 1, 0, 42)
                self.assertIn(index, (0, 1))
                self.assertEqual((at_best, calls, runs), (0, 0, 1))

    def test_no_solution_uses_budget_and_returns_sentinel(self):
        for search in (bridge.earliest_booking, bridge.best_placement):
            with self.subTest(search=search.__name__):
                index, at_best, calls, runs = search(
                    str(ROOT), [[False, False]], [[True, True]], [True], [True], 1, 3, 42)
                self.assertEqual((index, at_best, calls), (-1, 0, 3))
                self.assertGreater(runs, 0)


class SampleDriftTests(unittest.TestCase):
    def setUp(self):
        # Alter only a temporary project, never the user's actual examples.
        self.temporary = tempfile.TemporaryDirectory(prefix="needle-samples-")
        self.root = Path(self.temporary.name)
        shutil.copy2(ROOT / "qsharp.json", self.root / "qsharp.json")
        shutil.copytree(ROOT / "src", self.root / "src")
        shutil.copytree(ROOT / "samples", self.root / "samples")

    def tearDown(self):
        bridge.release()
        self.temporary.cleanup()

    def test_current_samples_match(self):
        self.assertEqual(bridge.sample_mismatches(str(self.root)), [])

    def test_every_table_and_flag_is_compared(self):
        for sample in ("location", "location-quiet"):
            path = self.root / "samples" / f"{sample}.json"
            original = path.read_text()
            for key in ("providerFree", "subLocationFree", "qualified", "suitable"):
                with self.subTest(sample=sample, key=key):
                    data = json.loads(original)
                    if key in ("providerFree", "subLocationFree"):
                        data[key][0][0] = not data[key][0][0]
                    else:
                        data[key][0] = not data[key][0]
                    path.write_text(json.dumps(data))
                    self.assertEqual(bridge.sample_mismatches(str(self.root)),
                                     [f"samples/{sample}.json: {key} differs from the Q# sample"])
                    path.write_text(original)

    def test_drift_is_detected_even_when_feasible_count_is_unchanged(self):
        path = self.root / "samples" / "location.json"
        data = json.loads(path.read_text())

        def count():
            return bridge.feasible_count(str(self.root), data["providerFree"],
                                         data["subLocationFree"], data["qualified"], data["suitable"], 2)

        before = count()
        data["providerFree"][2][0] = not data["providerFree"][2][0]  # Casey remains unqualified.
        path.write_text(json.dumps(data))
        self.assertEqual(count(), before)
        self.assertEqual(bridge.sample_mismatches(str(self.root)),
                         ["samples/location.json: providerFree differs from the Q# sample"])

    def test_changed_json_day_is_detected(self):
        path = self.root / "samples" / "days.json"
        data = json.loads(path.read_text())
        day = next(day for day in data["days"] if day["name"] == "three openings")
        day["free"][0] = not day["free"][0]
        path.write_text(json.dumps(data))
        self.assertEqual(bridge.sample_mismatches(str(self.root)),
                         ["samples/days.json: three openings differs from Samples.DayFree()"])

    def test_changed_qsharp_day_is_detected(self):
        path = self.root / "src" / "Samples.qs"
        original = "return [false, false, true, false, true, false, false, true];"
        replacement = "return [true, false, false, false, true, false, false, true];"
        source = path.read_text()
        self.assertIn(original, source)
        path.write_text(source.replace(original, replacement))
        self.assertEqual(bridge.sample_mismatches(str(self.root)),
                         ["samples/days.json: three openings differs from Samples.DayFree()"])


if __name__ == "__main__":
    unittest.main()
