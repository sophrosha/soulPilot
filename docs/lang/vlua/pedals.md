# Vehicle: pedals.lua

`src/lua/vehicle/extensions/auto/soulPilotPedals.lua` owns throttle/brake smoothing and pedal overrides.

## Command table

| Function | Description |
|---|---|
| `soulPilotPedalsCmd.on(config_path)` | Enable pedal smoothing and load the config. |
| `soulPilotPedalsCmd.off()` | Clear overrides and reset state. |
| `soulPilotPedalsCmd.setRateScale(scale, duration)` | Temporary rate scale for recovery. |
| `soulPilotPedalsCmd.status()` | Print status and diagnostics. |
| `soulPilotPedalsGetState()` | Return a state snapshot for warmup/pain. |

## Pipeline

```text
raw throttle/brake
  -> arbitration (brake starts at brake_start, reaches full at brake_full)
  -> rate limits (independent brake limits)
  -> EMA
  -> lerp
  -> smooth start cap
  -> electrics throttle/brake overrides
```

## Key behaviors

- `rateScale` reduces throttle smoothing rate only; brake hard clamps stay independent.
- Predictive braking uses lead time and release hysteresis.
- Shift hold, neutral handling and stuck-pedal watchdog are guarded.
- `need_init` and `init_from_zero` control safe re-seeding after enable/reset.
- `onReset()` clears overrides and resets the pipeline.
- `onVehicleDestroyed()` disables the module.

## Config

`pedals.json` contains:

- `rate_limit.throttle_rise/fall`, `brake_rise/fall`;
- `shift.hold_s`;
- `ema_tau` and `lerp_tau`;
- `arbitration`;
- `neutral`;
- `smooth_start`;
- `predictive`.

## Safety

The watchdog releases stale overrides. Hard clamps and neutral handling prevent unsafe throttle when the AI is not driving.
