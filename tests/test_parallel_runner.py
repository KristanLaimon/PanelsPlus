"""Scheduler regression checks using tiny subprocesses instead of full volumes."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("parallel", Path(__file__).with_name("run_parallel.py"))
parallel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parallel)


class ParallelRunnerTests(unittest.TestCase):
    def test_worker_thread_limits_default_to_one_and_respect_overrides(self):
        command = [sys.executable, "-c",
                   "import os; print('threads=' + os.environ['MAGICK_THREAD_LIMIT']"
                   " + ',' + os.environ['OMP_THREAD_LIMIT'])"]
        for limit in (None, "3"):
            with self.subTest(limit=limit), patch.dict(os.environ):
                for key in ("MAGICK_THREAD_LIMIT", "OMP_THREAD_LIMIT"):
                    if limit is None:
                        os.environ.pop(key, None)
                    else:
                        os.environ[key] = limit
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    result = parallel.run_jobs([("thread limits", [], None)], 1, command)
                self.assertEqual(0, result)
                expected = limit or "1"
                self.assertIn(f"threads={expected},{expected}", output.getvalue())

    def test_discovery_includes_every_flat_spec_once(self):
        expected = {"tests." + path.stem for path in (parallel.ROOT / "tests").glob("*_spec.lua")}
        discovered = parallel.discover("--list")
        self.assertEqual(expected, set(discovered))
        self.assertEqual(sorted(expected), discovered)
        self.assertIn("tests.pagerender_spec", discovered)
        self.assertIn("tests.panelviewer_phrase_spec", discovered)

    def test_focused_modes_partition_discovered_specs(self):
        specs = parallel.discover("--list")
        ocr = parallel.focused_specs(specs, "ocr")
        panels = parallel.focused_specs(specs, "panels")
        self.assertIn("tests.bloom_ocr_spec", ocr)
        self.assertIn("tests.bloom_into_you_spec", panels)
        self.assertEqual(set(specs), set(ocr) | set(panels))
        self.assertFalse(set(ocr) & set(panels))

    def test_dataset_filter_excludes_every_dataset_specification(self):
        specs = [
            "tests.geometry_spec",
            parallel.PRODUCTION_SPEC,
            "tests.bloom_into_you_spec",
            "tests.dataset_benchmark_spec",
            "tests.dataset_support_spec",
            "tests.textbasedformats_dataset_spec",
            "tests.algorithm_benchmark_spec",
            "tests.bloom_ocr_spec",
            "tests.miss_kobayashi_spec",
        ]

        self.assertEqual(["tests.geometry_spec"], parallel.without_dataset_specs(specs))

    def test_every_spec_and_volume_is_scheduled_once(self):
        specs = ["tests.geometry_spec", parallel.PRODUCTION_SPEC,
                 "tests.bloom_into_you_spec", "tests.dataset_benchmark_spec"]
        jobs = parallel.make_jobs(specs + specs, ["Book", "Other"])
        self.assertEqual(5, len(jobs))
        self.assertEqual(["Book", "Other"], [dataset for _, _, dataset in jobs if dataset])
        self.assertCountEqual(specs, set(s for _, group, _ in jobs for s in group))

    def test_workers_overlap_respect_limit_and_propagate_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "worker.py"
            script.write_text('''import os, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
name = sys.argv[2]
(root / (name + '.start')).write_text(str(time.monotonic()))
time.sleep(0.15)
(root / (name + '.end')).write_text(str(time.monotonic()))
print('worker ' + name)
sys.exit(1 if name == 'bad' else 0)
''')
            jobs = [(name, [directory, name], None) for name in ["a", "bad", "c", "d"]]
            for workers in [1, 2]:
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    result = parallel.run_jobs(jobs, workers, [sys.executable, str(script)])
                self.assertEqual(1, result)
                events = []
                for name, _, _ in jobs:
                    self.assertIn("worker " + name, output.getvalue())
                    for suffix, delta in [("start", 1), ("end", -1)]:
                        events.append((float((Path(directory) / (name + '.' + suffix)).read_text()), delta))
                active = peak = 0
                for _, delta in sorted(events):
                    active += delta
                    peak = max(peak, active)
                self.assertEqual(workers, peak)


if __name__ == "__main__":
    unittest.main()
