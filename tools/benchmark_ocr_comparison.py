#!/usr/bin/env python3
"""Benchmark historical and current Panels+ English OCR on the same annotations.

Run from anywhere:
    python3 tools/benchmark_ocr_comparison.py

The default report is tests/OCR_BENCHMARK_COMPARISON.md. Use --output to choose
another path. Raw logs go under dist/ and benchmark best-score records are not
updated. KOReader's installed English model is selected automatically on a
desktop installation; --koreader-dir and --tessdata-dir override discovery.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOLDOUT_PAGES = (5, 10, 15, 20, 25, 30, 35, 45)
BEFORE_RUNNER = r"""
local root = assert(os.getenv("PANELSPLUS_ROOT"))
local historical_wordfinder = assert(os.getenv("PANELSPLUS_BEFORE_FILE"))
require("setupkoenv")
require("ffi/koptcontext")
require("ffi/blitbuffer")
local lfs = require("libs/libkoreader-lfs")
assert(lfs.chdir(root))
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
require("tests.spec.helper")
package.loaded["src._wordfinder"] = assert(loadfile(historical_wordfinder))()
local framework = require("tests.PanelsPlusTestFramework")
local original_it = framework.it
framework.it = function(name, fn)
    if name ~= "reads annotated text with the bundled fast English model" then
        original_it(name, fn)
    end
end
require("tests.dataset-mangas.dataset.Bloom_Into_You_Vol_8.bloom_ocr_spec")
os.exit(framework.summary() and 0 or 1)
"""
BOX_PATTERN = re.compile(r"^\s*OCR boxes: (\d+)/(\d+) matched", re.MULTILINE)
TEXT_PATTERN = re.compile(
    r"^\s*OCR text \(native, ([^)]+)\): (\d+)/(\d+) matched", re.MULTILINE
)


def git(*args: str) -> str:
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()


def find_koreader_dir(override: Path | None) -> Path:
    if override is not None:
        directory = override.expanduser().resolve()
    elif os.environ.get("KOREADER_DIR"):
        directory = Path(os.environ["KOREADER_DIR"]).expanduser().resolve()
    elif executable := shutil.which("koreader"):
        directory = Path(executable).resolve().parent
    else:
        raise ValueError("KOReader not found; pass --koreader-dir")
    if (
        not (directory / "setupkoenv.lua").is_file()
        or not (directory / "ffi/koptcontext.lua").is_file()
    ):
        raise ValueError(f"KOReader native OCR runtime is missing from {directory}")
    return directory


def find_tessdata_dir(override: Path | None, koreader_dir: Path) -> Path:
    if override is not None:
        candidates = [override]
    elif os.environ.get("PANELSPLUS_OCR_TESSDATA"):
        candidates = [Path(os.environ["PANELSPLUS_OCR_TESSDATA"])]
    else:
        candidates = [
            Path.home() / ".config/koreader/data/tessdata",
            koreader_dir / "data/tessdata",
        ]
    for candidate in candidates:
        directory = candidate.expanduser().resolve()
        if (directory / "eng.traineddata").is_file():
            return directory
    raise ValueError("KOReader English model not found; pass --tessdata-dir")


def annotation_totals() -> tuple[int, int]:
    path = ROOT / "tests/dataset-mangas/dataset/Bloom_Into_You_Vol_8/annotation.json"
    pages = json.loads(path.read_text())[0]["pages"]
    full = sum(len(page.get("word", [])) for page in pages)
    held = sum(
        len(page.get("word", []))
        for page in pages
        if page["page_index"] in HOLDOUT_PAGES
    )
    if full == 0 or held == 0:
        raise ValueError("OCR annotations are missing")
    return full, held


def run_case(
    label: str,
    pages: tuple[int, ...] | None,
    runner: Path,
    koreader_dir: Path,
    tessdata_dir: Path,
    old_wordfinder: Path,
    log_dir: Path,
) -> None:
    environment = os.environ.copy()
    environment.pop("PANELSPLUS_REQUIRE_DATASETS", None)
    environment.pop("PANELSPLUS_OCR_PAGES", None)
    environment.update(
        PANELSPLUS_ROOT=str(ROOT),
        PANELSPLUS_BEFORE_FILE=str(old_wordfinder),
        PANELSPLUS_OCR_NATIVE="1",
        PANELSPLUS_OCR_TESSDATA=str(tessdata_dir),
        PANELSPLUS_OCR_CANDIDATE=str(ROOT / "data/ocr"),
        OMP_THREAD_LIMIT="1",
    )
    if pages:
        environment["PANELSPLUS_OCR_PAGES"] = ",".join(map(str, pages))
    log_path = log_dir / f"{label}.log"
    print(f"Running {label}...", flush=True)
    with log_path.open("w") as log:
        result = subprocess.run(
            ["luajit", str(runner)],
            cwd=koreader_dir,
            env=environment,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=False,
        )
    (log_dir / f"{label}.exit").write_text(f"{result.returncode}\n")
    output = log_path.read_text()
    for line in output.splitlines():
        if "OCR boxes:" in line or "OCR text (native," in line:
            print(line, flush=True)


def measured(
    log_dir: Path, label: str, expected_total: int, expected_models: int
) -> tuple[int, list[tuple[str, int]]]:
    log_path = log_dir / f"{label}.log"
    output = log_path.read_text()
    exit_code = int((log_dir / f"{label}.exit").read_text())
    box = BOX_PATTERN.search(output)
    texts = TEXT_PATTERN.findall(output)
    if box is None or len(texts) != expected_models:
        raise ValueError(f"Incomplete {label} benchmark; inspect {log_path}")
    if int(box[2]) != expected_total or any(
        int(text[2]) != expected_total for text in texts
    ):
        raise ValueError(
            f"Incomplete dataset in {label}; expected {expected_total} words"
        )
    unexpected = [
        line
        for line in output.splitlines()
        if "[FAIL]" in line and "locates the annotated words" not in line
    ]
    if unexpected or (exit_code != 0 and "[FAIL]" not in output):
        raise ValueError(
            f"Unexpected failure in {label}: {unexpected or exit_code}; inspect {log_path}"
        )
    return int(box[1]), [(model, int(correct)) for model, correct, _ in texts]


def score(correct: int, total: int) -> str:
    return f"{correct}/{total} ({correct / total * 100:.2f}%)"


def delta(new: int, old: int, total: int) -> str:
    return f"+{new - old} words ({(new - old) / total * 100:.2f} percentage points)"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_report(
    report: Path,
    log_dir: Path,
    baseline: str,
    current: str,
    tessdata_dir: Path,
) -> None:
    full_total, held_total = annotation_totals()
    old_box, old = measured(log_dir, "before_full", full_total, 1)
    now_box, now = measured(log_dir, "current_full", full_total, 2)
    old_held_box, old_held = measured(log_dir, "before_holdout", held_total, 1)
    now_held_box, now_held = measured(log_dir, "current_holdout", held_total, 2)
    if any(
        model != str(tessdata_dir)
        for model, _ in (old + old_held + now[:1] + now_held[:1])
    ):
        raise ValueError("The installed-model runs used an unexpected OCR directory")
    if now[1][0] != "bundled fast English" or now_held[1][0] != "bundled fast English":
        raise ValueError("The fine-tuned model run is missing")

    stock = tessdata_dir / "eng.traineddata"
    fine = ROOT / "data/ocr/eng_fast.traineddata"
    holdout = ", ".join(map(str, HOLDOUT_PAGES))
    body = f"""# Panels+ English OCR benchmark: before and now

Generated {dt.datetime.now(dt.timezone.utc).date().isoformat()} by `tools/benchmark_ocr_comparison.py`.
The historical OCR module is from `{baseline[:7]}`; the current working tree
is based on `{current[:7]}`. Both run against the same current annotations and
images from *Bloom Into You, Vol. 8* using KOReader's native k2pdfopt/Tesseract
OCR library.

| OCR path | Full set ({full_total} words) | Held-out pages ({held_total} annotations) |
| --- | ---: | ---: |
| Before, KOReader installed English | {score(old[0][1], full_total)} | {score(old_held[0][1], held_total)} |
| Now, KOReader installed English | {score(now[0][1], full_total)} | {score(now_held[0][1], held_total)} |
| Now, Panels+ fine-tuned English | {score(now[1][1], full_total)} | {score(now_held[1][1], held_total)} |

With the model held fixed, the current Panels+ OCR path gains
**{delta(now[0][1], old[0][1], full_total)}** on the full set and
**{delta(now_held[0][1], old_held[0][1], held_total)}** on the held-out pages.
With current code held fixed, the fine-tuned model gains
**{delta(now[1][1], now[0][1], full_total)}** and
**{delta(now_held[1][1], now_held[0][1], held_total)}**, respectively.

Word-box geometry before and now: **{score(old_box, full_total)}** →
**{score(now_box, full_total)}** on the full set; **{score(old_held_box, held_total)}**
→ **{score(now_held_box, held_total)}** on the held-out pages. This measures
finding the annotated word region before OCR model choice.

## Model files

| Model | File | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| KOReader installed English | `{stock}` | {stock.stat().st_size} | `{sha256(stock)}` |
| Panels+ fine-tuned English | `{fine}` | {fine.stat().st_size} | `{sha256(fine)}` |

The installed English file is the `tessdata_best` base model used for the
fine-tuning recipe. Word agreement ignores case and punctuation, with special
handling for punctuation-only labels. A missed word box counts as an OCR miss.

The full set includes training crops and is a development score. The held-out
pages ({holdout}) were excluded from model training, but all pages informed
word-box tuning. The harness uses ImageMagick to render crops and a fake
document around KOReader's real native OCR library; it does not measure the
complete reader UI, a physical device, or rendering latency. Historical code
is loaded into today's benchmark harness, rather than an entire old KOReader
installation. Historical and held-out geometry checks may fail today's 95%
acceptance gate; all reported counts were checked for complete coverage.

Raw logs: `{log_dir}`. The runner sets `PANELSPLUS_OCR_CANDIDATE` to the existing
bundled model directory so benchmark best-score records are not updated.
"""
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(body)
    print(f"Wrote {report}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, default=ROOT / "tests/OCR_BENCHMARK_COMPARISON.md"
    )
    parser.add_argument(
        "--baseline", default="1bf5d32", help="Git commit before bundled OCR"
    )
    parser.add_argument(
        "--koreader-dir", type=Path, help="KOReader install with setupkoenv.lua"
    )
    parser.add_argument(
        "--tessdata-dir", type=Path, help="KOReader data/tessdata directory"
    )
    args = parser.parse_args()

    for command in ("git", "luajit", "magick"):
        if shutil.which(command) is None:
            raise ValueError(f"Missing benchmark command: {command}")
    koreader_dir = find_koreader_dir(args.koreader_dir)
    tessdata_dir = find_tessdata_dir(args.tessdata_dir, koreader_dir)
    if not (ROOT / "data/ocr/eng_fast.traineddata").is_file():
        raise ValueError("Panels+ fine-tuned English model missing from data/ocr")
    baseline = git("rev-parse", "--verify", f"{args.baseline}^{{commit}}")
    current = git("rev-parse", "HEAD")
    ROOT.joinpath("dist").mkdir(exist_ok=True)
    log_dir = Path(tempfile.mkdtemp(prefix="ocr-benchmark.", dir=ROOT / "dist"))
    print(f"Raw logs: {log_dir}", flush=True)

    with tempfile.TemporaryDirectory(prefix="panelsplus-ocr-") as temporary:
        temporary_dir = Path(temporary)
        old_wordfinder = temporary_dir / "wordfinder_before.lua"
        old_wordfinder.write_text(git("show", f"{baseline}:src/_wordfinder.lua") + "\n")
        old_runner = temporary_dir / "run_before.lua"
        old_runner.write_text(BEFORE_RUNNER)
        run_case(
            "before_full",
            None,
            old_runner,
            koreader_dir,
            tessdata_dir,
            old_wordfinder,
            log_dir,
        )
        run_case(
            "current_full",
            None,
            ROOT / "tools/benchmark_ocr_native.lua",
            koreader_dir,
            tessdata_dir,
            old_wordfinder,
            log_dir,
        )
        run_case(
            "before_holdout",
            HOLDOUT_PAGES,
            old_runner,
            koreader_dir,
            tessdata_dir,
            old_wordfinder,
            log_dir,
        )
        run_case(
            "current_holdout",
            HOLDOUT_PAGES,
            ROOT / "tools/benchmark_ocr_native.lua",
            koreader_dir,
            tessdata_dir,
            old_wordfinder,
            log_dir,
        )
    write_report(
        args.output.expanduser().resolve(), log_dir, baseline, current, tessdata_dir
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"Benchmark failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
