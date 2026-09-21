"""Scheduler regression checks using tiny subprocesses instead of full volumes."""

import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("parallel", Path(__file__).with_name("run_parallel.py"))
parallel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parallel)


class ParallelRunnerTests(unittest.TestCase):
    def test_dataset_filter_excludes_every_dataset_specification(self):
        specs = [
            "tests.spec.geometry_spec",
            parallel.PRODUCTION_SPEC,
            "tests.dataset-mangas.dataset.Book.book_spec",
            "tests.spec.dataset_benchmark_spec",
            "tests.spec.dataset_support_spec",
            "tests.spec.textbasedformats_dataset_spec",
        ]

        self.assertEqual(["tests.spec.geometry_spec"], parallel.without_dataset_specs(specs))

    def test_every_spec_and_volume_is_scheduled_once(self):
        specs = ["tests.spec.geometry_spec", parallel.PRODUCTION_SPEC,
                 "tests.dataset-mangas.dataset.Book.book_spec", "tests.spec.dataset_benchmark_spec"]
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
