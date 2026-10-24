#!/usr/bin/env python3
"""Golden behavior tests for the soulPilot refactor.

These tests pin the current AutopilotLive behavior before files are moved or
renamed. They are intentionally independent of the old Lua filenames.

Run from the repository root:

    python -m unittest discover -s src/tests -v
"""

from __future__ import annotations

import json
import math
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG_CANDIDATES = (
    REPO_ROOT / "src" / "config",
    REPO_ROOT / "ai" / "config",
)


def find_config_dir() -> Path:
    for candidate in CONFIG_CANDIDATES:
        if candidate.is_dir():
            return candidate
    candidates = ", ".join(str(path) for path in CONFIG_CANDIDATES)
    raise RuntimeError(f"Config directory not found. Tried: {candidates}")


CONFIG_DIR = find_config_dir()


def load_json(name: str) -> dict[str, Any]:
    with (CONFIG_DIR / name).open(encoding="utf-8") as handle:
        return json.load(handle)


def clamp_symmetric(value: float) -> float:
    if value < -1.0:
        return -1.0
    if value > 1.0:
        return 1.0
    return value


def move_toward(current: float, target: float, max_step: float) -> float:
    delta = target - current
    if delta > max_step:
        return current + max_step
    if delta < -max_step:
        return current - max_step
    return target


@dataclass
class WheelState:
    rate_limited: float = 0.0
    ema: float = 0.0
    output: float = 0.0


class WheelPipeline:
    """Python mirror of autopilotLiveWheel.lua stepWheel()."""

    def __init__(self, config: dict[str, Any], rate_scale: float = 1.0) -> None:
        self.rate_rise = float(config["rate_limit"]["steer_rise"])
        self.rate_fall = float(config["rate_limit"]["steer_fall"])
        self.ema_tau = float(config["ema_tau"]["steer"])
        self.lerp_tau = float(config["lerp_tau"]["steer"])
        self.rate_scale = rate_scale
        self.state = WheelState()

    def step(self, target: float, dt: float) -> WheelState:
        target = clamp_symmetric(target)
        state = self.state

        use_rise = abs(target) > abs(state.rate_limited)
        rate = (self.rate_rise if use_rise else self.rate_fall) * self.rate_scale
        state.rate_limited = move_toward(state.rate_limited, target, rate * dt)

        state.ema += (state.rate_limited - state.ema) * (
            1.0 - math.exp(-dt / self.ema_tau)
        )
        if abs(state.ema - state.rate_limited) < 1e-4:
            state.ema = state.rate_limited

        state.output += (state.ema - state.output) * (
            1.0 - math.exp(-dt / self.lerp_tau)
        )
        if abs(state.ema - state.output) < 1e-3:
            state.output = state.ema
        state.output = clamp_symmetric(state.output)
        return state


class WheelConfigTests(unittest.TestCase):
    def test_custom_wheel_values_are_locked(self) -> None:
        config = load_json("wheel.json")
        self.assertEqual(config["mode"], "custom")
        self.assertAlmostEqual(config["rate_limit"]["steer_rise"], 6.0)
        self.assertAlmostEqual(config["rate_limit"]["steer_fall"], 8.0)
        self.assertAlmostEqual(config["ema_tau"]["steer"], 0.08)
        self.assertAlmostEqual(config["lerp_tau"]["steer"], 0.05)

    def test_first_frame_is_golden(self) -> None:
        pipeline = WheelPipeline(load_json("wheel.json"))
        state = pipeline.step(0.5, 0.05)
        self.assertAlmostEqual(state.rate_limited, 0.30000000000000004, places=12)
        self.assertAlmostEqual(state.ema, 0.13942157144430295, places=12)
        self.assertAlmostEqual(state.output, 0.08813124165412846, places=12)

    def test_five_frame_sequence_is_golden(self) -> None:
        pipeline = WheelPipeline(load_json("wheel.json"))
        expected = [
            (0.30000000000000004, 0.13942157144430295, 0.08813124165412846),
            (0.5, 0.30699627523814493, 0.226480328991288),
            (0.5, 0.39669255057448344, 0.3340749736179078),
            (0.5, 0.44470350704384465, 0.40400554398949473),
            (0.5, 0.470401920188198, 0.4459760584164102),
        ]
        for rate_limited, ema, output in expected:
            state = pipeline.step(0.5, 0.05)
            self.assertAlmostEqual(state.rate_limited, rate_limited, places=12)
            self.assertAlmostEqual(state.ema, ema, places=12)
            self.assertAlmostEqual(state.output, output, places=12)

    def test_rate_scale_reduces_first_step(self) -> None:
        pipeline = WheelPipeline(load_json("wheel.json"), rate_scale=0.5)
        state = pipeline.step(0.5, 0.05)
        self.assertAlmostEqual(state.rate_limited, 0.15000000000000002, places=12)
        self.assertAlmostEqual(state.ema, 0.06971078572215147, places=12)
        self.assertAlmostEqual(state.output, 0.04406562082706423, places=12)

    def test_reverse_direction_uses_fall_rate(self) -> None:
        pipeline = WheelPipeline(load_json("wheel.json"))
        pipeline.state = WheelState(0.3, 0.3, 0.3)
        state = pipeline.step(-0.5, 0.05)
        self.assertAlmostEqual(state.rate_limited, 0.0, places=12)
        self.assertAlmostEqual(state.ema, 0.16057842855569704, places=12)
        self.assertAlmostEqual(state.output, 0.21186875834587154, places=12)

    def test_output_is_clamped_and_monotonic(self) -> None:
        pipeline = WheelPipeline(load_json("wheel.json"))
        previous = 0.0
        for _ in range(10):
            state = pipeline.step(0.5, 0.05)
            self.assertLessEqual(abs(state.output), 1.0)
            self.assertGreaterEqual(state.output, previous - 1e-12)
            previous = state.output


class ConfigContractTests(unittest.TestCase):
    def test_all_configs_are_valid_json(self) -> None:
        for path in sorted(CONFIG_DIR.glob("*.json")):
            with self.subTest(path=path.name):
                with path.open(encoding="utf-8") as handle:
                    data = json.load(handle)
                self.assertIsInstance(data, dict)

    def test_master_has_no_parking_module_flag(self) -> None:
        master = load_json("master.json")
        self.assertNotIn("enable_parking", master)
        self.assertIn("enable_wheel", master)
        self.assertIn("enable_music", master)

    def test_parking_radius_is_map_wide(self) -> None:
        parking = load_json("parking.json")
        self.assertGreaterEqual(parking["search_radius_m"], 999999.0)

    def test_translations_are_valid_and_have_no_broken_placeholders(self) -> None:
        translations_root = REPO_ROOT / "locales" / "translations"
        if not translations_root.is_dir():
            self.skipTest("translation directory is not present in this layout")
        for path in sorted(translations_root.glob("*/autopilotLive.translation.json")):
            with self.subTest(path=path.parent.name):
                text = path.read_text(encoding="utf-8")
                data = json.loads(text)
                self.assertNotIn("??????", text)
                self.assertIsInstance(data, dict)


if __name__ == "__main__":
    unittest.main(verbosity=2)
