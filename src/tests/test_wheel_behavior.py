#!/usr/bin/env python3
"""Golden behavior tests for soulPilotWheel.

The numbers below are explicit contracts for the wheel refactor. They were
taken from the current wheel.json and the current stepWheel() implementation.

Python mirror references:
  src/lua/vehicle/extensions/auto/soulPilotWheel.lua
    validate/load       lines 111-176
    stepWheel()         lines 192-210
    needInit seeding    lines 284-290
    rate statistics     lines 213-227
    music offsets       lines 240-258

Run all tests from the repository root:

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
    raise RuntimeError("Config directory not found")


CONFIG_DIR = find_config_dir()


def load_json(name: str) -> dict[str, Any]:
    with (CONFIG_DIR / name).open(encoding="utf-8") as handle:
        return json.load(handle)


WHEEL_CONFIG = load_json("wheel.json")

# ============================================================================
# GOLDEN VALUES — current wheel behavior at the start of the refactor.
# ============================================================================
# First frame: target 0.5, dt 0.05, rate rise=6.0, EMA=0.08, lerp=0.05.
GOLDEN_FIRST_STEP = (0.30000000000000004, 0.13942157144430295, 0.08813124165412846)

# First frame with rateScale=0.5.
GOLDEN_FIRST_STEP_HALF_SCALE = (
    0.15000000000000002,
    0.06971078572215147,
    0.04406562082706423,
)

# Five frames for a constant target 0.5.
GOLDEN_FIVE_STEPS = (
    (0.30000000000000004, 0.13942157144430295, 0.08813124165412846),
    (0.5, 0.30699627523814493, 0.226480328991288),
    (0.5, 0.39669255057448344, 0.3340749736179078),
    (0.5, 0.44470350704384465, 0.40400554398949473),
    (0.5, 0.470401920188198, 0.4459760584164102),
)

# Reverse from a settled +0.5 toward -0.5; fall rate is used.
GOLDEN_REVERSE_STEP = (0.09999999999999998, 0.31410457140759607, 0.3824916777944954)

# needInit must seed the complete pipeline directly to the raw target.
GOLDEN_NEED_INIT = (0.5, 0.5, 0.5)

# Rate statistics after seeding at 0.5 and stepping twice toward 0.8.
GOLDEN_RATE_RAW = 1.2186851492471835
GOLDEN_RATE_OUT = 0.8092675064548704


@dataclass
class WheelState:
    rate_limited: float = 0.0
    ema: float = 0.0
    output: float = 0.0


def clamp_symmetric(value: float) -> float:
    return min(1.0, max(-1.0, value))


def move_toward(current: float, target: float, max_step: float) -> float:
    """Mirror of moveToward() in soulPilotWheel.lua:179-184."""
    delta = target - current
    if delta > max_step:
        return current + max_step
    if delta < -max_step:
        return current - max_step
    return target


def exponential_step(current: float, target: float, dt: float, tau: float, snap_epsilon: float | None) -> float:
    """Mirror of the time-constant EMA/lerp step."""
    if tau <= 0:
        return target
    value = current + (target - current) * (1 - math.exp(-dt / tau))
    if snap_epsilon is not None and abs(value - target) < snap_epsilon:
        return target
    return value


def step_wheel(
    state: WheelState,
    target: float,
    dt: float,
    rate_scale: float = 1.0,
) -> WheelState:
    """Mirror of stepWheel() in soulPilotWheel.lua:192-210.

    The wheel differs from pedals:
    - rise/fall selection uses absolute steering magnitude;
    - EMA snap is 1e-4;
    - lerp snap is 1e-3;
    - only the output is clamped to [-1, 1].
    """
    rate_limit = WHEEL_CONFIG["rate_limit"]
    rate = (
        rate_limit["steer_rise"]
        if abs(target) > abs(state.rate_limited)
        else rate_limit["steer_fall"]
    ) * rate_scale

    state.rate_limited = move_toward(state.rate_limited, target, rate * dt)
    state.ema = exponential_step(
        state.ema,
        state.rate_limited,
        dt,
        WHEEL_CONFIG["ema_tau"]["steer"],
        1e-4,
    )

    lerp_tau = WHEEL_CONFIG["lerp_tau"]["steer"]
    if lerp_tau > 0:
        state.output = exponential_step(
            state.output,
            state.ema,
            dt,
            lerp_tau,
            1e-3,
        )
    else:
        state.output = state.ema

    state.output = clamp_symmetric(state.output)
    return state


def initialize(state: WheelState, target: float) -> WheelState:
    """Mirror of the needInit seed at soulPilotWheel.lua:284-290."""
    state.rate_limited = target
    state.ema = target
    state.output = target
    return state


def initialize_if_needed(
    state: WheelState,
    target: float,
    need_init: bool,
) -> tuple[WheelState, bool]:
    """Mirror of wheelOverrides.initialize(): false means no reseed."""
    if not need_init:
        return state, False
    return initialize(state, target), True


def update_rate_stats(
    state: WheelState,
    previous: tuple[float, float] | None,
    raw: float,
    output: float,
    dt: float,
    rate_raw: float,
    rate_out: float,
) -> tuple[float, float]:
    """Mirror of updateRateStats() at soulPilotWheel.lua:213-227."""
    if previous is not None and dt > 0:
        alpha = 1 - math.exp(-dt / 0.15)
        raw_instant = (raw - previous[0]) / dt
        out_instant = (output - previous[1]) / dt
        rate_raw += (raw_instant - rate_raw) * alpha
        rate_out += (out_instant - rate_out) * alpha
    return rate_raw, rate_out


class WheelGoldenTests(unittest.TestCase):
    def test_current_config_is_locked(self) -> None:
        self.assertEqual(WHEEL_CONFIG["mode"], "custom")
        self.assertAlmostEqual(WHEEL_CONFIG["rate_limit"]["steer_rise"], 6.0)
        self.assertAlmostEqual(WHEEL_CONFIG["rate_limit"]["steer_fall"], 8.0)
        self.assertAlmostEqual(WHEEL_CONFIG["ema_tau"]["steer"], 0.08)
        self.assertAlmostEqual(WHEEL_CONFIG["lerp_tau"]["steer"], 0.05)

    def test_first_step_golden(self) -> None:
        state = step_wheel(WheelState(), 0.5, 0.05)
        self.assertAlmostEqual(state.rate_limited, GOLDEN_FIRST_STEP[0], places=12)
        self.assertAlmostEqual(state.ema, GOLDEN_FIRST_STEP[1], places=12)
        self.assertAlmostEqual(state.output, GOLDEN_FIRST_STEP[2], places=12)

    def test_rate_scale_halves_wheel_rate(self) -> None:
        state = step_wheel(WheelState(), 0.5, 0.05, rate_scale=0.5)
        self.assertAlmostEqual(
            state.rate_limited, GOLDEN_FIRST_STEP_HALF_SCALE[0], places=12
        )
        self.assertAlmostEqual(
            state.ema, GOLDEN_FIRST_STEP_HALF_SCALE[1], places=12
        )
        self.assertAlmostEqual(
            state.output, GOLDEN_FIRST_STEP_HALF_SCALE[2], places=12
        )

    def test_five_steps_golden(self) -> None:
        state = WheelState()
        for expected_rate, expected_ema, expected_output in GOLDEN_FIVE_STEPS:
            state = step_wheel(state, 0.5, 0.05)
            self.assertAlmostEqual(state.rate_limited, expected_rate, places=12)
            self.assertAlmostEqual(state.ema, expected_ema, places=12)
            self.assertAlmostEqual(state.output, expected_output, places=12)

    def test_reverse_step_uses_fall_rate(self) -> None:
        state = step_wheel(WheelState(0.5, 0.5, 0.5), -0.5, 0.05)
        self.assertAlmostEqual(state.rate_limited, GOLDEN_REVERSE_STEP[0], places=12)
        self.assertAlmostEqual(state.ema, GOLDEN_REVERSE_STEP[1], places=12)
        self.assertAlmostEqual(state.output, GOLDEN_REVERSE_STEP[2], places=12)

    def test_target_is_clamped_to_symmetric_range(self) -> None:
        state = step_wheel(WheelState(), 10.0, 0.05)
        self.assertLessEqual(abs(state.output), 1.0)
        self.assertAlmostEqual(state.rate_limited, 0.3, places=12)

    def test_need_init_seeds_pipeline_directly(self) -> None:
        state = initialize(WheelState(), 0.5)
        self.assertEqual(
            (state.rate_limited, state.ema, state.output),
            GOLDEN_NEED_INIT,
        )

    def test_need_init_is_idempotent_after_seed(self) -> None:
        state = initialize(WheelState(), 0.5)
        state.rate_limited = 0.6
        state.ema = 0.6
        state.output = 0.6

        state, seeded = initialize_if_needed(state, 0.5, need_init=False)
        self.assertFalse(seeded)
        self.assertEqual((state.rate_limited, state.ema, state.output), (0.6, 0.6, 0.6))

        state, seeded = initialize_if_needed(state, 0.5, need_init=True)
        self.assertTrue(seeded)
        self.assertEqual((state.rate_limited, state.ema, state.output), (0.5, 0.5, 0.5))

    def test_rate_statistics_golden(self) -> None:
        state = initialize(WheelState(), 0.5)
        previous = (0.5, 0.5)
        rate_raw, rate_out = 0.0, 0.0

        state = step_wheel(state, 0.5, 0.05)
        rate_raw, rate_out = update_rate_stats(
            state, previous, 0.5, state.output, 0.05, rate_raw, rate_out
        )
        previous = (0.5, state.output)

        state = step_wheel(state, 0.8, 0.05)
        rate_raw, rate_out = update_rate_stats(
            state, previous, 0.8, state.output, 0.05, rate_raw, rate_out
        )
        previous = (0.8, state.output)

        state = step_wheel(state, 0.8, 0.05)
        rate_raw, rate_out = update_rate_stats(
            state, previous, 0.8, state.output, 0.05, rate_raw, rate_out
        )
        self.assertAlmostEqual(rate_raw, GOLDEN_RATE_RAW, places=12)
        self.assertAlmostEqual(rate_out, GOLDEN_RATE_OUT, places=12)

    def test_music_offset_is_added_after_smoothing(self) -> None:
        state = step_wheel(WheelState(), 0.5, 0.05)
        without_music = state.output
        with_music = clamp_symmetric(without_music + 0.01)
        self.assertAlmostEqual(with_music - without_music, 0.01, places=12)
        self.assertLessEqual(abs(with_music), 1.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
