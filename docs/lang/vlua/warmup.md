# Vehicle: warmup.lua

`src/lua/vehicle/extensions/auto/soulPilotWarmup.lua` starts the engine, checks temperatures, applies sway and hands control to AI.

## State machine

```text
off -> starting_engine -> warming_up -> done
```

`off` is also used after reset. `done` can still fade a small remaining sway value to zero.

## Main functions

| Function | Purpose |
|---|---|
| `soulPilotWarmupCmd.on(confPath, opts)` | Start warm-up; supports `noSway` and `skipIfWarm`. |
| `soulPilotWarmupCmd.off()` | Cancel warm-up and release writes. |
| `soulPilotWarmupCmd.status()` | Print the current state. |
| `soulPilotWarmupCmd.getState()` | Return the state string. |
| `soulPilotWarmupCmd.pushState()` | Ask the vehicle to push state to GE (fallback poll). |
| `M.updateGFX(dt)` | Main tick: timers, temperatures, finish and sway. |
| `M.onReset()` / `M.onVehicleDestroyed()` | Reset module state. |

## Sway

```lua
phase_time = max(elapsed - sway_start, 0)
value = amplitude * sin(2 * pi * freq_hz * phase_time) ^ 3
```

Properties:

- phase is relative to `sway_start`; it is never accumulated across starts;
- value is written as an absolute `steering_input`, not added to it;
- amplitude is clamped to `0.001..0.035`;
- output is bounded by the configured amplitude;
- when wheel takes over, the sway write is cleared;
- `finish()` calls `resetSwayAtFinish()`.

## Handover

When temperatures pass, `finish()`:

1. stops sway and clears `steering_input`;
2. releases the parking brake;
3. wakes popup;
4. auto-enables pedals and wheel when configured;
5. enables wheel with `{ seed_zero = true }`;
6. starts AI (`traffic` by default);
7. notifies GE with `onVehicleWarmupDone`.

## Config

`warmup.json` controls timing, temperature thresholds, sway and finish policy.

## Failure behavior

The warm-up ends on `max_timeout_s` with a warning and still performs the safe handover. Engine start has its own `start_timeout_s`.
