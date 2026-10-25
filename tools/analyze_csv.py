#!/usr/bin/env python3
"""Compare raw and smoothed soulPilot CSV channels.

The game CSV contains paired columns such as:

    steer_raw, steer_smoothed
    throttle_raw, throttle_smoothed
    brake_raw, brake_smoothed

This tool works without pandas/numpy and prints a Markdown table by default.
Use --json for machine-readable output, or --plot for an optional matplotlib
chart when matplotlib is installed.

Examples:
    python tools/analyze_csv.py ai/csv/2026-10-25_*.csv
    python tools/analyze_csv.py day_bolide.csv day_200bx.csv --json report.json
    python tools/analyze_csv.py day_*.csv --plot analysis.png
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

CHANNELS = ("steer", "throttle", "brake")
FALLBACK_DT = 0.05


@dataclass
class SeriesStats:
    name: str
    count: int
    duration_s: float
    raw_min: float
    raw_max: float
    smooth_min: float
    smooth_max: float
    mean_abs_error: float
    max_abs_error: float
    rms_error: float
    correlation: float
    raw_max_step: float
    smooth_max_step: float
    corner_samples: int
    corner_mean_abs_error: float


def number(value: object, fallback: float = 0.0) -> float:
    try:
        result = float(value)
        if math.isfinite(result):
            return result
    except (TypeError, ValueError):
        pass
    return fallback


def read_csv(path: Path) -> tuple[list[dict[str, str]], list[float]]:
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)
        if not reader.fieldnames:
            return [], []

    time_key = "time" if "time" in (reader.fieldnames or []) else "t"
    times: list[float] = []
    for index, row in enumerate(rows):
        value = number(row.get(time_key), index * FALLBACK_DT)
        if times and value <= times[-1]:
            value = times[-1] + FALLBACK_DT
        times.append(value)
    return rows, times


def pearson(left: list[float], right: list[float]) -> float:
    count = min(len(left), len(right))
    if count < 2:
        return 0.0
    left_mean = sum(left[:count]) / count
    right_mean = sum(right[:count]) / count
    numerator = sum((left[i] - left_mean) * (right[i] - right_mean) for i in range(count))
    left_norm = math.sqrt(sum((left[i] - left_mean) ** 2 for i in range(count)))
    right_norm = math.sqrt(sum((right[i] - right_mean) ** 2 for i in range(count)))
    if left_norm == 0.0 or right_norm == 0.0:
        return 0.0
    return numerator / (left_norm * right_norm)


def analyze_channel(
    name: str,
    raw: list[float],
    smooth: list[float],
    times: list[float],
) -> SeriesStats | None:
    if not raw or not smooth:
        return None
    count = min(len(raw), len(smooth), len(times))
    raw = raw[:count]
    smooth = smooth[:count]
    times = times[:count]
    errors = [abs(smooth[i] - raw[i]) for i in range(count)]
    raw_steps = [abs(raw[i] - raw[i - 1]) for i in range(1, count)]
    smooth_steps = [abs(smooth[i] - smooth[i - 1]) for i in range(1, count)]
    corner_indices = [i for i, value in enumerate(raw) if abs(value) >= 0.15]
    corner_errors = [errors[i] for i in corner_indices]

    return SeriesStats(
        name=name,
        count=count,
        duration_s=max(0.0, times[-1] - times[0]) if count else 0.0,
        raw_min=min(raw),
        raw_max=max(raw),
        smooth_min=min(smooth),
        smooth_max=max(smooth),
        mean_abs_error=sum(errors) / count,
        max_abs_error=max(errors),
        rms_error=math.sqrt(sum(error * error for error in errors) / count),
        correlation=pearson(raw, smooth),
        raw_max_step=max(raw_steps) if raw_steps else 0.0,
        smooth_max_step=max(smooth_steps) if smooth_steps else 0.0,
        corner_samples=len(corner_indices),
        corner_mean_abs_error=(sum(corner_errors) / len(corner_errors)) if corner_errors else 0.0,
    )


def analyze_file(path: Path) -> dict[str, SeriesStats]:
    rows, times = read_csv(path)
    if not rows:
        return {}
    result: dict[str, SeriesStats] = {}
    for channel in CHANNELS:
        raw_key = f"{channel}_raw"
        smooth_key = f"{channel}_smoothed"
        if raw_key not in rows[0] or smooth_key not in rows[0]:
            continue
        raw = [number(row.get(raw_key)) for row in rows]
        smooth = [number(row.get(smooth_key)) for row in rows]
        stats = analyze_channel(channel, raw, smooth, times)
        if stats:
            result[channel] = stats
    return result


def print_markdown(results: dict[Path, dict[str, SeriesStats]]) -> None:
    print("| File | Channel | Samples | Duration | Raw range | Smooth range | Mean abs err | RMS err | Corr | Raw max step | Smooth max step | Corner err |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for path, channels in results.items():
        for channel, stats in channels.items():
            print(
                f"| {path.name} | {channel} | {stats.count} | "
                f"{stats.duration_s:.1f}s | {stats.raw_min:.3f}..{stats.raw_max:.3f} | "
                f"{stats.smooth_min:.3f}..{stats.smooth_max:.3f} | "
                f"{stats.mean_abs_error:.4f} | {stats.rms_error:.4f} | "
                f"{stats.correlation:.3f} | {stats.raw_max_step:.4f} | "
                f"{stats.smooth_max_step:.4f} | {stats.corner_mean_abs_error:.4f} |"
            )


def plot_results(results: dict[Path, dict[str, SeriesStats]], output: Path) -> None:
    try:
        import matplotlib.pyplot as plt
    except ImportError as exc:
        raise SystemExit("--plot requires matplotlib: pip install matplotlib") from exc

    channels = sorted({channel for data in results.values() for channel in data})
    fig, axes = plt.subplots(len(results), max(1, len(channels)), figsize=(12, 3 * len(results)))
    if len(results) == 1:
        axes = [axes]
    for row_index, (path, data) in enumerate(results.items()):
        for column_index, channel in enumerate(channels):
            axis = axes[row_index][column_index] if len(channels) > 1 else axes[row_index]
            stats = data.get(channel)
            if stats is None:
                axis.set_axis_off()
                continue
            axis.bar([channel], [stats.mean_abs_error], color="#ff8a1f")
            axis.set_title(f"{path.name}: {channel}")
            axis.set_ylabel("mean |smoothed-raw|")
            axis.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    fig.savefig(output, dpi=150)
    print(f"plot: {output}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Compare raw and smoothed soulPilot CSV channels")
    parser.add_argument("csv", nargs="+", type=Path, help="CSV file(s) from the game")
    parser.add_argument("--json", type=Path, help="write machine-readable metrics")
    parser.add_argument("--plot", type=Path, help="write a matplotlib PNG summary")
    args = parser.parse_args(argv)

    missing = [path for path in args.csv if not path.is_file()]
    if missing:
        for path in missing:
            print(f"ERROR: not found: {path}", file=sys.stderr)
        return 1

    results = {path: analyze_file(path) for path in args.csv}
    results = {path: data for path, data in results.items() if data}
    if not results:
        print("ERROR: no raw/smoothed channel pairs found in the CSV files", file=sys.stderr)
        return 2

    if args.json:
        payload = {
            path.name: {
                channel: stats.__dict__
                for channel, stats in data.items()
            }
            for path, data in results.items()
        }
        args.json.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"json: {args.json}")

    print_markdown(results)
    if args.plot:
        plot_results(results, args.plot)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
