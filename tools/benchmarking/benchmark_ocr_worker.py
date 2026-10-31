#!/usr/bin/env python3
"""Compare fresh CLI and persistent native OCR on identical recorded requests."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def recorded_requests(cache_path):
    cache = json.loads(cache_path.read_text())
    fingerprints = {}
    requests = {}

    def fingerprint(path):
        if path not in fingerprints:
            fingerprints[path] = hashlib.sha256(Path(path).read_bytes()).hexdigest()
        return fingerprints[path]

    for key in cache:
        fields = key.split("|")[-12:]
        if len(fields) != 12:
            continue
        image, image_hash, x, y, width, height, sw, sh, directory, language, model_hash, mode = fields
        model = Path(directory) / (language + ".traineddata")
        if not directory:
            # The cached system-model fingerprint is still part of the key;
            # both backends resolve the current installed model identically.
            model = None
        try:
            if fingerprint(image) != image_hash or (model is not None and fingerprint(str(model)) != model_hash):
                continue
            item = dict(image=image, x=int(x), y=int(y), width=int(width), height=int(height),
                        scaled_width=int(sw), scaled_height=int(sh), data_dir=directory,
                        language=language, page_mode=6 if int(mode) == -1 else int(mode))
        except (OSError, ValueError):
            continue
        requests[tuple(item.values())] = item
    return list(requests.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, help="JSON request array; defaults to recorded OCR cache requests")
    parser.add_argument("--cache", type=Path, default=ROOT / "tests/dataset-mangas/.cache/ocr-results-v1.json")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--limit", type=int, default=0, help="evenly spaced request sample (0 means all)")
    parser.add_argument("--output", type=Path, help="save measurements as JSON")
    args = parser.parse_args()
    if args.workers < 1 or args.limit < 0:
        parser.error("workers must be positive and limit must be nonnegative")
    os.chdir(ROOT)
    if args.input:
        requests = json.loads(args.input.read_text())
    elif args.cache.exists():
        requests = recorded_requests(args.cache)
    else:
        parser.error("run the OCR dataset once to populate its raw-result cache, or supply --input")
    if args.limit and len(requests) > args.limit:
        requests = [requests[i * len(requests) // args.limit] for i in range(args.limit)]
    if not requests:
        parser.error("no matching current-page/model requests were found")
    for index, item in enumerate(requests):
        item["id"] = str(index)
    environment = os.environ.copy()
    environment.setdefault("GOCACHE", "/tmp/panelsplus-go-build-cache")
    environment.setdefault("OMP_THREAD_LIMIT", "1")
    environment.setdefault("MAGICK_THREAD_LIMIT", "1")
    with tempfile.TemporaryDirectory(prefix="panelsplus-ocr-benchmark-") as directory:
        executable = str(Path(directory) / "ocr_worker")
        subprocess.run(["go", "build", "-tags", "ocr_native", "-o", executable, "./tools/ocr_worker"],
                       env=environment, check=True)
        input_path = Path(directory) / "requests.json"
        input_path.write_text(json.dumps(requests))
        outputs, profiles = {}, {}
        for backend in ("cli", "native"):
            completed = subprocess.run([executable, "--input", str(input_path), "--backend", backend,
                                        "--workers", str(args.workers), "--profile"],
                                       env=environment, capture_output=True, text=True, check=True)
            outputs[backend] = json.loads(completed.stdout)
            profiles[backend] = json.loads(completed.stderr.strip().splitlines()[-1])
            print(f"{backend}: {len(requests)} requests in {profiles[backend]['wall_seconds']:.3f}s", flush=True)
        mismatches = [a["id"] for a, b in zip(outputs["cli"], outputs["native"]) if a != b]
        if len(outputs["cli"]) != len(outputs["native"]):
            raise SystemExit("backend result counts differ")
        report = dict(requests=len(requests), workers=args.workers, profiles=profiles, mismatches=mismatches)
        if args.output:
            args.output.write_text(json.dumps(report, indent=2) + "\n")
        if mismatches:
            raise SystemExit(f"OCR output differs for {len(mismatches)} requests: {mismatches[:20]}")
        print(f"All raw outputs match; speedup {profiles['cli']['wall_seconds'] / profiles['native']['wall_seconds']:.2f}x")


if __name__ == "__main__":
    main()
