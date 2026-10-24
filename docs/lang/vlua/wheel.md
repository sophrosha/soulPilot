# Vehicle: wheel.lua

`src/lua/vehicle/extensions/auto/soulPilotWheel.lua` owns steering smoothing and the public wheel command table.

## Command table

| Function | Description |
|---|---|
| `soulPilotWheelCmd.on(config_path, options)` | Enable steering smoothing; `options.seed_zero` starts from 0. |
| `soulPilotWheelCmd.off()` | Disable and restore vanilla AI filtering. |
| `soulPilotWheelCmd.setRateScale(scale)` | Temporary rate scale for recovery. |
| `soulPilotWheelCmd.status()` | Print state/diagnostics. |
| `soulPilotWheelGetState()` | Return a state snapshot for warmup/pain. |

## Frame pipeline

```text
AI/manual target
  -> rate limit (steer_rise / steer_fall)
  -> EMA
  -> lerp
  -> music offset
  -> clamp [-1, 1]
  -> electrics.values.steering_input
```

## Seeding

`wheelState` has `need_init` and `seed_zero`.

- Normal `on()` seeds from the current steering target.
- Warm-up auto-engagement calls `on(path, { seed_zero = true })`.
- `seed_zero` makes the first AI frame start at zero, so a manual full-lock position cannot become the AI target.

## Guards

- No AI driving: clear override, mark `need_init`, reset rate statistics.
- Invalid steering values are sanitized.
- Music offsets are applied after smoothing and clamped.
- `onReset()` restores `need_init`.
- `onVehicleDestroyed()` disables the module.

## Config

`wheel.json`:

- `mode` — `comfort`, `sport` or `custom`;
- `rate_limit.steer_rise/steer_fall`;
- `ema_tau.steer`;
- `lerp_tau.steer`.

Current custom values: `6.0/8.0`, EMA `0.08`, lerp `0.05`.
