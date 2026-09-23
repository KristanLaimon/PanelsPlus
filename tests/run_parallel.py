#!/usr/bin/env python3
"""Run isolated Lua test jobs, splitting production benchmarks by volume."""

import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
RUNNER = ["lua", "tests/run_tests.lua"]
PRODUCTION_SPEC = "tests.spec.new_dataset_benchmark_spec"
DATASET_SPECS = {
    "tests.spec.dataset_benchmark_spec",
    "tests.spec.dataset_support_spec",
    "tests.spec.textbasedformats_dataset_spec",
    PRODUCTION_SPEC,
}
OCR_SPECS = {
    "tests.spec.wordfinder_spec",
    "tests.spec.ocr_benchmark_spec",
    "tests.spec.panelviewer_refineword_spec",
    "tests.dataset-mangas.dataset.Bloom_Into_You_Vol_8.bloom_ocr_spec",
}


def discover(option):
    return subprocess.check_output(RUNNER + [option], cwd=ROOT, text=True).splitlines()


def make_jobs(specs, datasets):
    units, jobs = [], []
    for spec in dict.fromkeys(specs):
        if spec == PRODUCTION_SPEC:
            jobs.extend((title, [spec], title) for title in datasets)
        elif spec.startswith("tests.dataset-mangas.dataset.") or spec == "tests.spec.dataset_benchmark_spec":
            jobs.append((spec, [spec], None))
        else:
            units.append(spec)
    if units:
        jobs.insert(0, ("Unit tests", units, None))
    return jobs


def is_dataset_spec(spec):
    return spec in DATASET_SPECS or spec.startswith("tests.dataset-mangas.dataset.")


def without_dataset_specs(specs):
    return [spec for spec in specs if not is_dataset_spec(spec)]


def focused_specs(specs, focus):
    if focus == "ocr":
        return [spec for spec in specs if spec in OCR_SPECS]
    return [spec for spec in specs if spec not in OCR_SPECS]


def run_jobs(jobs, workers, command=None):
    command = RUNNER if command is None else command
    pending = iter(jobs)
    active = []
    failed = 0
    started = time.monotonic()
    environment = os.environ.copy()
    # Avoid multiplying ImageMagick's internal thread count by worker count.
    environment.setdefault("MAGICK_THREAD_LIMIT", "1")
    environment.pop("PANELSPLUS_TEST_DATASET", None)
    print(f"Running {len(jobs)} jobs with up to {workers} workers", flush=True)
    try:
        while True:
            while len(active) < workers:
                job = next(pending, None)
                if job is None:
                    break
                label, specs, dataset = job
                env = environment.copy()
                if dataset:
                    env["PANELSPLUS_TEST_DATASET"] = dataset
                log = tempfile.TemporaryFile(mode="w+")
                try:
                    process = subprocess.Popen(command + specs, cwd=ROOT, env=env,
                                               stdout=log, stderr=subprocess.STDOUT,
                                               start_new_session=True)
                except BaseException:
                    log.close()
                    raise
                active.append((process, log, label, time.monotonic()))
                print(f"==> Started: {label}", flush=True)
            if not active:
                break
            for entry in active[:]:
                process, log, label, job_started = entry
                if process.poll() is None:
                    continue
                log.seek(0)
                print(log.read(), end="")
                log.close()
                active.remove(entry)
                failed += process.returncode != 0
                status = "PASS" if process.returncode == 0 else "FAIL"
                print(f"==> {status}: {label} ({time.monotonic() - job_started:.1f}s)", flush=True)
            if active:
                time.sleep(0.05)
    finally:
        for process, log, _, _ in active:
            # Include image-conversion subprocesses when cancelling a worker.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            log.close()
    print(f"{len(jobs) - failed} jobs passed, {failed} failed in {time.monotonic() - started:.1f}s")
    return int(failed > 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-j", "--jobs", type=int, default=min(4, os.cpu_count() or 1),
                        help="maximum concurrent Lua workers (default: up to 4 CPUs)")
    parser.add_argument("--skip-datasets", action="store_true",
                        help="exclude dataset and benchmark specifications")
    focus = parser.add_mutually_exclusive_group()
    focus.add_argument("--panels", action="store_true", help="run panel specs only")
    focus.add_argument("--ocr", action="store_true", help="run OCR specs only")
    parser.add_argument("specs", nargs="*")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")
    specs = [s.removeprefix("./").removesuffix(".lua").replace("/", ".").replace("\\", ".")
             for s in args.specs] if args.specs else discover("--list")
    if args.skip_datasets:
        specs = without_dataset_specs(specs)
    if args.panels or args.ocr:
        specs = focused_specs(specs, "ocr" if args.ocr else "panels")
    return run_jobs(make_jobs(specs, discover("--list-datasets")), args.jobs)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
