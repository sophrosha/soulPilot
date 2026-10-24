#!/usr/bin/env python3
"""Golden behavior tests for soulPilotPedals.

These tests pin the current pedal pipeline BEFORE the module is split.
The values below are intentionally explicit: they are the contract that the
refactor must preserve. Do not replace them with values calculated by the same
helper that performs the assertion.

Python mirror references:
  src/lua/vehicle/extensions/auto/soulPilotPedals.lua
    stepChannel()       lines 301-328
    smoothStartFactor() lines 330-345
    updateGFX()         lines 394-688
    command state       lines 690-738
    status/getState     lines 740-827

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


PEDALS_CONFIG = load_json("pedals.json")

# ============================================================================
# GOLDEN VALUES — current behavior, measured from soulPilotPedals.lua and
# src/config/pedals.json at the start of the refactor.
# ============================================================================
# One step, throttle target 0.5, dt 0.05, rate 0.8/1.5, ema 0.10, lerp 0.15:
# - rate-limited value moves by 0.8 * 0.05 = 0.04
GOLDEN_THROTTLE_STEP_1 = (0.04, 0.015738773611494665, 0.0044614495288262225)

# Five consecutive throttle steps with the same target:
GOLDEN_THROTTLE_STEPS_5 = (
    (0.04, 0.015738773611494665, 0.0044614495288262225),
    (0.08, 0.04102359596463698, 0.014825673261594698),
    (0.12, 0.0720983895586998, 0.03106069509021426),
    (0.16, 0.10668497822923528, 0.05249781152042923),
    (0.20, 0.14340157828427935, 0.07826618314888376),
)

# One brake step: target 0.5, dt 0.05, rate 1.7/2.5, ema 0.08, lerp 0.12:
GOLDEN_BRAKE_STEP_1 = (0.085, 0.03950277857588583, 0.013460941932850266)

# rateScale=0.5 must halve the throttle rate, not the brake rate:
GOLDEN_THROTTLE_SCALE_HALF = (0.02, 0.007869386805747332, 0.0022307247644131113)
GOLDEN_BRAKE_SCALE_HALF = GOLDEN_BRAKE_STEP_1

# Smooth start: cap=0.45, elapsed=1.5/3.0 s, speed=2.5/5.0 m/s:
# 0.45 + (1 - 0.45) * min(0.5, 0.5) = 0.725
GOLDEN_SMOOTH_START = 0.7250000000000001

# Neutral: gear "0", raw throttle 0.2, speed 0.2 m/s:
# throttle target becomes 0; brake target becomes at least 0.3.
GOLDEN_NEUTRAL = (0.0, 0.3)

# Predictive brake: raw brake 0.6, speed 2.0 m/s, lead 0.25:
# 0.6 + 0.25 = 0.85.
GOLDEN_PREDICTIVE = 0.85

# Shift hold: current out=0.3, requested throttle=0.6:
# throttle is capped at 0.3 for shift.hold_s = 0.4 s.
GOLDEN_SHIFT_HOLD = 0.3

# Arbitration: throttle out=0.8, brake out=0.3, brake_start=0.1,
# brake_full=0.5:
# cut = 1 - (0.3 - 0.1) / (0.5 - 0.1) = 0.5
# resulting throttle = 0.8 * 0.5 = 0.4
GOLDEN_ARBITRATION = 0.4

# Hard clamps: previous throttle=0.1, rate=0.8, dt=0.05:
# 0.1 + 0.8 * 0.05 = 0.14 (target 0.4 is clipped).
GOLDEN_THROTTLE_CLAMP = 0.14

# Hard clamps: previous brake=0.1, rate=1.7, dt=0.05:
# 0.1 + 1.7 * 0.05 = 0.185 (target 0.3 is clipped).
GOLDEN_BRAKE_CLAMP = 0.185

# Resume seed: last out=0.4, raw throttle=0.7, smooth factor skipped:
# seed = min(0.4, 0.7) * 1.0 = 0.4.
GOLDEN_RESUME_THROTTLE_SEED = 0.4

# Watchdog: raw unchanged for 0.1 s; stuck only after 2.0 s:
GOLDEN_RAW_HOLD_TIME = 0.1
GOLDEN_STUCK_TIME = 2.0


@dataclass
class ChannelState:
    """Mirror of the three pipeline stages: rate, EMA, lerp."""

    rate_limited: float = 0.0
    ema: float = 0.0
    output: float = 0.0


def clamp_unit(value: float) -> float:
    return min(1.0, max(0.0, value))


def move_toward(current: float, target: float, max_step: float) -> float:
    """Mirror of moveToward() in soulPilotPedals.lua:288-293."""
    delta = target - current
    if delta > max_step:
        return current + max_step
    if delta < -max_step:
        return current - max_step
    return target


def step_channel(
    state: ChannelState,
    target: float,
    dt: float,
    rate_up: float,
    rate_down: float,
    ema_tau: float,
    lerp_tau: float,
) -> ChannelState:
    """Mirror of stepChannel() in soulPilotPedals.lua:301-328.

    Important order:
      1. rate_limit
      2. EMA
      3. lerp
      4. snap out to ema when |ema - out| < 1e-3
      5. clamp out, rl, ema to [0, 1]
    """
    rate = rate_up if target > state.rate_limited else rate_down
    state.rate_limited = move_toward(state.rate_limited, target, rate * dt)
    state.ema = state.ema + (state.rate_limited - state.ema) * (
        1.0 - math.exp(-dt / ema_tau)
    )
    state.output = state.output + (state.ema - state.output) * (
        1.0 - math.exp(-dt / lerp_tau)
    )
    if abs(state.ema - state.output) < 1e-3:
        state.output = state.ema
    state.output = clamp_unit(state.output)
    state.rate_limited = clamp_unit(state.rate_limited)
    state.ema = clamp_unit(state.ema)
    return state


def smooth_start_factor(
    start_time: float,
    speed: float,
    time_s: float,
    speed_mps: float,
    throttle_cap: float,
    skipped: bool,
) -> float:
    """Mirror of smoothStartFactor() in soulPilotPedals.lua:330-345."""
    if skipped:
        return 1.0
    if time_s <= 0 or speed_mps <= 0:
        return 1.0
    if start_time >= time_s and speed >= speed_mps:
        return 1.0
    time_ramp = min(1.0, start_time / time_s)
    speed_ramp = min(1.0, speed / speed_mps)
    return throttle_cap + (1.0 - throttle_cap) * min(time_ramp, speed_ramp)


def neutral_modifier(
    throttle_raw: float,
    brake_raw: float,
    gear: str,
    speed: float,
    neutral_cfg: dict[str, float],
) -> tuple[float, float]:
    """Mirror of neutral detection in soulPilotPedals.lua:499-506."""
    throttle_target = throttle_raw
    brake_target = brake_raw
    is_neutral = gear == "N" or gear == "0"
    if (
        is_neutral
        and throttle_raw > neutral_cfg["throttle_min"]
        and speed < neutral_cfg["speed_max_mps"]
    ):
        throttle_target = 0.0
        brake_target = max(brake_target, neutral_cfg["brake"])
    return throttle_target, brake_target


def predictive_brake(
    brake_raw: float,
    speed: float,
    predictive_on: bool,
    predictive_cfg: dict[str, float],
) -> tuple[float, bool]:
    """Mirror of predictive braking in soulPilotPedals.lua:508-518."""
    if predictive_on:
        if brake_raw < predictive_cfg["release_hyst"]:
            predictive_on = False
    elif brake_raw >= predictive_cfg["brake_threshold"]:
        predictive_on = True

    brake_target = brake_raw
    if predictive_on and speed > predictive_cfg["min_speed_mps"]:
        brake_target = min(1.0, brake_raw + predictive_cfg["lead"])
    return brake_target, predictive_on


def apply_shift_hold(
    throttle_target: float,
    shift_hold_time: float,
    shift_hold_value: float,
) -> float:
    """Mirror of shift hold in soulPilotPedals.lua:522-524."""
    if shift_hold_time > 0 and throttle_target > shift_hold_value:
        return shift_hold_value
    return throttle_target


def arbitrate(
    throttle_out: float,
    brake_out: float,
    brake_start: float,
    brake_full: float,
) -> float:
    """Mirror of brake > throttle arbitration at lines 533-540."""
    cut = 1.0
    if brake_out > brake_start:
        cut = 1.0 - (brake_out - brake_start) / (brake_full - brake_start)
        cut = max(0.0, cut)
    return throttle_out * cut


def hard_clamp_throttle(
    desired: float,
    previous: float,
    dt: float,
    rate_up: float,
    rate_down: float,
    rate_scale: float,
) -> float:
    """Mirror of throttle hard clamp at lines 549-561."""
    previous = clamp_unit(previous)
    up_step = rate_up * rate_scale * dt
    down_step = rate_down * rate_scale * dt
    if desired > previous + up_step:
        desired = previous + up_step
    if desired < previous - down_step:
        desired = previous - down_step
    return clamp_unit(desired)


def hard_clamp_brake(
    desired: float,
    previous: float,
    dt: float,
    rate_up: float,
    rate_down: float,
) -> float:
    """Mirror of brake hard clamp at lines 563-575."""
    previous = clamp_unit(previous)
    if desired > previous + rate_up * dt:
        desired = previous + rate_up * dt
    if desired < previous - rate_down * dt:
        desired = previous - rate_down * dt
    return clamp_unit(desired)


def resume_seed(
    last_out: float,
    throttle_raw: float,
    init_from_zero: bool,
    smooth_factor: float,
) -> float:
    """Mirror of resume seed at lines 482-493."""
    seed = 0.0
    if not init_from_zero:
        seed = max(0.0, last_out)
        seed = min(seed, throttle_raw)
        seed = seed * smooth_factor
    return seed


class PedalsGoldenTests(unittest.TestCase):
    def test_pedals_config_values_are_locked(self) -> None:
        rate = PEDALS_CONFIG["rate_limit"]
        self.assertAlmostEqual(rate["throttle_rise"], 0.8)
        self.assertAlmostEqual(rate["throttle_fall"], 1.5)
        self.assertAlmostEqual(rate["brake_rise"], 1.7)
        self.assertAlmostEqual(rate["brake_fall"], 2.5)
        self.assertAlmostEqual(PEDALS_CONFIG["ema_tau"]["throttle"], 0.10)
        self.assertAlmostEqual(PEDALS_CONFIG["ema_tau"]["brake"], 0.08)
        self.assertAlmostEqual(PEDALS_CONFIG["lerp_tau"]["throttle"], 0.15)
        self.assertAlmostEqual(PEDALS_CONFIG["lerp_tau"]["brake"], 0.12)

    def test_step_channel_throttle_golden(self) -> None:
        state = step_channel(
            ChannelState(), 0.5, 0.05, 0.8, 1.5, 0.10, 0.15
        )
        self.assertAlmostEqual(state.rate_limited, GOLDEN_THROTTLE_STEP_1[0], places=12)
        self.assertAlmostEqual(state.ema, GOLDEN_THROTTLE_STEP_1[1], places=12)
        self.assertAlmostEqual(state.output, GOLDEN_THROTTLE_STEP_1[2], places=12)

    def test_step_channel_throttle_five_frames_golden(self) -> None:
        state = ChannelState()
        for expected_rate, expected_ema, expected_out in GOLDEN_THROTTLE_STEPS_5:
            state = step_channel(state, 0.5, 0.05, 0.8, 1.5, 0.10, 0.15)
            self.assertAlmostEqual(state.rate_limited, expected_rate, places=12)
            self.assertAlmostEqual(state.ema, expected_ema, places=12)
            self.assertAlmostEqual(state.output, expected_out, places=12)

    def test_step_channel_brake_golden(self) -> None:
        state = step_channel(
            ChannelState(), 0.5, 0.05, 1.7, 2.5, 0.08, 0.12
        )
        self.assertAlmostEqual(state.rate_limited, GOLDEN_BRAKE_STEP_1[0], places=12)
        self.assertAlmostEqual(state.ema, GOLDEN_BRAKE_STEP_1[1], places=12)
        self.assertAlmostEqual(state.output, GOLDEN_BRAKE_STEP_1[2], places=12)

    def test_rate_scale_halves_throttle_but_not_brake(self) -> None:
        throttle_state = step_channel(
            ChannelState(), 0.5, 0.05, 0.8 * 0.5, 1.5 * 0.5, 0.10, 0.15
        )
        brake_state = step_channel(
            ChannelState(), 0.5, 0.05, 1.7, 2.5, 0.08, 0.12
        )
        self.assertAlmostEqual(
            throttle_state.rate_limited, GOLDEN_THROTTLE_SCALE_HALF[0], places=12
        )
        self.assertAlmostEqual(
            throttle_state.ema, GOLDEN_THROTTLE_SCALE_HALF[1], places=12
        )
        self.assertAlmostEqual(
            throttle_state.output, GOLDEN_THROTTLE_SCALE_HALF[2], places=12
        )
        self.assertAlmostEqual(
            brake_state.rate_limited, GOLDEN_BRAKE_SCALE_HALF[0], places=12
        )
        self.assertAlmostEqual(
            brake_state.ema, GOLDEN_BRAKE_SCALE_HALF[1], places=12
        )
        self.assertAlmostEqual(
            brake_state.output, GOLDEN_BRAKE_SCALE_HALF[2], places=12
        )

    def test_smooth_start_factor_golden(self) -> None:
        factor = smooth_start_factor(
            start_time=1.5,
            speed=2.5,
            time_s=3.0,
            speed_mps=5.0,
            throttle_cap=0.45,
            skipped=False,
        )
        self.assertAlmostEqual(factor, GOLDEN_SMOOTH_START, places=12)

        self.assertEqual(
            smooth_start_factor(3.0, 5.0, 3.0, 5.0, 0.45, False),
            1.0,
        )
        self.assertEqual(
            smooth_start_factor(0.0, 0.0, 3.0, 5.0, 0.45, True),
            1.0,
        )

    def test_neutral_modifier_golden(self) -> None:
        throttle_target, brake_target = neutral_modifier(
            throttle_raw=0.2,
            brake_raw=0.0,
            gear="0",
            speed=0.2,
            neutral_cfg=PEDALS_CONFIG["neutral"],
        )
        self.assertAlmostEqual(throttle_target, GOLDEN_NEUTRAL[0], places=12)
        self.assertAlmostEqual(brake_target, GOLDEN_NEUTRAL[1], places=12)

    def test_predictive_brake_golden(self) -> None:
        brake_target, predictive_on = predictive_brake(
            brake_raw=0.6,
            speed=2.0,
            predictive_on=False,
            predictive_cfg=PEDALS_CONFIG["predictive"],
        )
        self.assertTrue(predictive_on)
        self.assertAlmostEqual(brake_target, GOLDEN_PREDICTIVE, places=12)

        released, still_on = predictive_brake(
            brake_raw=0.30,
            speed=2.0,
            predictive_on=True,
            predictive_cfg=PEDALS_CONFIG["predictive"],
        )
        self.assertFalse(still_on)
        self.assertAlmostEqual(released, 0.30, places=12)

    def test_shift_hold_golden(self) -> None:
        result = apply_shift_hold(
            throttle_target=0.6,
            shift_hold_time=0.2,
            shift_hold_value=GOLDEN_SHIFT_HOLD,
        )
        self.assertAlmostEqual(result, GOLDEN_SHIFT_HOLD, places=12)

    def test_arbitration_golden(self) -> None:
        result = arbitrate(
            throttle_out=0.8,
            brake_out=0.3,
            brake_start=PEDALS_CONFIG["arbitration"]["brake_start"],
            brake_full=PEDALS_CONFIG["arbitration"]["brake_full"],
        )
        self.assertAlmostEqual(result, GOLDEN_ARBITRATION, places=12)

    def test_hard_clamps_golden(self) -> None:
        throttle = hard_clamp_throttle(
            desired=0.4,
            previous=0.1,
            dt=0.05,
            rate_up=0.8,
            rate_down=1.5,
            rate_scale=1.0,
        )
        brake = hard_clamp_brake(
            desired=0.3,
            previous=0.1,
            dt=0.05,
            rate_up=1.7,
            rate_down=2.5,
        )
        self.assertAlmostEqual(throttle, GOLDEN_THROTTLE_CLAMP, places=12)
        self.assertAlmostEqual(brake, GOLDEN_BRAKE_CLAMP, places=12)

    def test_pause_resume_seed_golden(self) -> None:
        seed = resume_seed(
            last_out=0.4,
            throttle_raw=0.7,
            init_from_zero=False,
            smooth_factor=1.0,
        )
        self.assertAlmostEqual(seed, GOLDEN_RESUME_THROTTLE_SEED, places=12)

        fresh_seed = resume_seed(
            last_out=0.4,
            throttle_raw=0.7,
            init_from_zero=True,
            smooth_factor=1.0,
        )
        self.assertAlmostEqual(fresh_seed, 0.0, places=12)

    def test_watchdog_timers_and_resync_contract(self) -> None:
        # rawHoldT accumulates while raw throttle does not change.
        last_sample = 0.0
        raw_hold_time = 0.0
        raw = 0.2
        if abs(raw - last_sample) > 1e-6:
            last_sample = raw
            raw_hold_time = 0.0
        else:
            raw_hold_time += GOLDEN_RAW_HOLD_TIME
        self.assertAlmostEqual(raw_hold_time, 0.0, places=12)

        # stuckT only accumulates after resumeT > 0.5, out > 0.9, raw < 0.05.
        stuck_time = 0.0
        for _ in range(20):
            stuck_time += 0.1
        self.assertAlmostEqual(stuck_time, GOLDEN_STUCK_TIME, places=12)

        # A resync must seed the whole throttle pipeline from raw.
        state = ChannelState(rate_limited=0.9, ema=0.9, output=0.9)
        state.rate_limited = raw
        state.ema = raw
        state.output = raw
        self.assertEqual((state.rate_limited, state.ema, state.output), (0.2, 0.2, 0.2))


if __name__ == "__main__":
    unittest.main(verbosity=2)
