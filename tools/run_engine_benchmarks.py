#!/usr/bin/env python3
"""Run headless engine benchmark gates and optional exact cycle measurement."""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_IMAGE = os.environ.get("SIM6502_IMAGE", "ghcr.io/barryw/sim6502:latest")
DEFAULT_PULL = os.environ.get("SIM6502_PULL", "always")
PASS_RE = re.compile(r"'(?P<name>[^']+) - (?P<description>[^']+)' : (?P<status>PASSED|FAILED)")
MEASURE_RE = re.compile(
    r"'(?P<name>[^']+)'\s+-\s+Expected\s+(?P<cycles>\d+)\s+<\s+0\s+in assertion\s+'(?P<label>[^']+)'"
)
TEST_RE = re.compile(r'test\("(?P<name>[^"]+)",\s*"(?P<description>[^"]+)"(?P<header>.*?)\)\s*\{(?P<body>.*?)\n\s*\}', re.S)
BUDGET_RE = re.compile(r'assert\(cycles\s*<\s*(?P<budget>\d+)\s*,\s*"(?P<label>[^"]+)"\)')
TAGS_RE = re.compile(r'tags\s*=\s*"(?P<tags>[^"]+)"')


def repo_root_from_script() -> Path:
    return Path(__file__).resolve().parents[1]


def comma(value: int | None) -> str:
    if value is None:
        return "-"
    return f"{value:,}"


def docker_suite_path(repo_root: Path, suite: Path) -> str:
    try:
        relative = suite.resolve().relative_to(repo_root.resolve())
    except ValueError:
        raise SystemExit(f"Suite must be inside repo root: {suite}") from None
    return "/code/" + relative.as_posix()


def run_sim6502(repo_root: Path, image: str, pull: str, suite_path: str) -> subprocess.CompletedProcess[str]:
    cmd = [
        "docker",
        "run",
        f"--pull={pull}",
        "--rm",
        "-v",
        f"{repo_root}:/code",
        image,
        "-s",
        suite_path,
    ]
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def run_temp_suite(repo_root: Path, image: str, pull: str, suite_text: str, filename: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="engine-bench-") as tmp:
        temp_dir = Path(tmp)
        temp_suite = temp_dir / filename
        temp_suite.write_text(suite_text, encoding="utf-8")
        cmd = [
            "docker",
            "run",
            f"--pull={pull}",
            "--rm",
            "-v",
            f"{repo_root}:/code",
            "-v",
            f"{temp_dir}:/bench",
            image,
            "-s",
            f"/bench/{filename}",
        ]
        return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def parse_suite_metadata(suite_text: str) -> dict[str, dict[str, object]]:
    metadata: dict[str, dict[str, object]] = {}
    for match in TEST_RE.finditer(suite_text):
        name = match.group("name")
        header = match.group("header")
        body = match.group("body")
        budget_match = BUDGET_RE.search(body)
        tags_match = TAGS_RE.search(header)
        metadata[name] = {
            "name": name,
            "description": match.group("description"),
            "tags": tags_match.group("tags").split(",") if tags_match else [],
            "cycle_budget": int(budget_match.group("budget")) if budget_match else None,
            "cycle_label": budget_match.group("label") if budget_match else None,
        }
    return metadata


def parse_statuses(output: str, metadata: dict[str, dict[str, object]]) -> list[dict[str, object]]:
    seen: dict[str, dict[str, object]] = {}
    for match in PASS_RE.finditer(output):
        name = match.group("name")
        item = dict(metadata.get(name, {"name": name}))
        item["name"] = name
        item.setdefault("description", match.group("description"))
        item["status"] = match.group("status")
        seen[name] = item
    ordered = [seen[name] for name in metadata if name in seen]
    ordered.extend(item for name, item in seen.items() if name not in metadata)
    return ordered


def parse_measurements(output: str) -> dict[str, int]:
    measurements: dict[str, int] = {}
    for match in MEASURE_RE.finditer(output):
        measurements[match.group("name")] = int(match.group("cycles"))
    return measurements


def measure_cycles(repo_root: Path, image: str, pull: str, suite_text: str) -> dict[str, int]:
    forced = re.sub(r"assert\(cycles\s*<\s*\d+\s*,", "assert(cycles < 0,", suite_text)
    result = run_temp_suite(repo_root, image, pull, forced, "engine_benchmark_cycles.6502")
    return parse_measurements(result.stdout)


def print_summary(tests: list[dict[str, object]], measurements: dict[str, int] | None) -> None:
    passed = sum(1 for test in tests if test.get("status") == "PASSED")
    total = len(tests)
    print(f"Benchmark gates: {passed}/{total} passed")
    for test in tests:
        name = str(test["name"])
        status = str(test.get("status", "UNKNOWN"))
        budget = test.get("cycle_budget")
        measured = measurements.get(name) if measurements else None
        detail = ""
        if budget is not None:
            detail = f" cycles {comma(measured)} / {comma(int(budget))}"
            if measured is not None:
                headroom = int(budget) - int(measured)
                detail += f" headroom {comma(headroom)}"
        print(f"  {status:6} {name}{detail}")


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run headless chess engine benchmarks under sim6502.")
    parser.add_argument("--repo-root", type=Path, default=repo_root_from_script(), help="Repository root to mount at /code.")
    parser.add_argument("--suite", type=Path, default=None, help="Benchmark suite path. Defaults to tests/engine_benchmark.6502.")
    parser.add_argument("--docker-image", default=DEFAULT_IMAGE, help="sim6502 Docker image to use.")
    parser.add_argument("--docker-pull", choices=["always", "missing", "never"], default=DEFAULT_PULL, help="Docker pull policy for the sim6502 image.")
    parser.add_argument("--measure-cycles", action="store_true", help="Collect exact cycle counts by forcing cycle assertions to report.")
    parser.add_argument("--json", type=Path, default=None, help="Write machine-readable benchmark results to this path.")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    repo_root = args.repo_root.resolve()
    suite = (args.suite or repo_root / "tests" / "engine_benchmark.6502").resolve()

    for required in (repo_root / "build" / "engine_harness.prg", repo_root / "build" / "engine_harness.sym", suite):
        if not required.exists():
            print(f"Missing required file: {required}", file=sys.stderr)
            return 2

    suite_text = suite.read_text(encoding="utf-8")
    metadata = parse_suite_metadata(suite_text)

    print(f"Engine benchmark suite: {suite.relative_to(repo_root)}")
    print(f"sim6502 image: {args.docker_image}")
    print(f"sim6502 pull: {args.docker_pull}")

    regression = run_sim6502(repo_root, args.docker_image, args.docker_pull, docker_suite_path(repo_root, suite))
    tests = parse_statuses(regression.stdout, metadata)
    if regression.returncode != 0 or not tests:
        print(regression.stdout.rstrip())

    measurements: dict[str, int] = {}
    if args.measure_cycles:
        measurements = measure_cycles(repo_root, args.docker_image, args.docker_pull, suite_text)

    print_summary(tests, measurements if args.measure_cycles else None)

    payload = {
        "docker_image": args.docker_image,
        "docker_pull": args.docker_pull,
        "suite": str(suite.relative_to(repo_root)),
        "passed": regression.returncode == 0,
        "tests": tests,
        "cycle_measurements": measurements,
    }
    if args.json:
        write_json(args.json, payload)

    return regression.returncode


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
