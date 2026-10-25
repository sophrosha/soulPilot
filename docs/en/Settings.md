# Settings

## Sources and precedence

Settings are resolved in this order:

1. user settings:

```text
%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\settings\mod_settings\soulPilot\
```

2. source defaults:

```text
src/config/
```

3. deployed runtime defaults:

```text
config/
```

The first readable file wins. User files are never modified by `dev_mode.py`.

## Main files

| File | Purpose |
|---|---|
| `master.json` | Module enable flags, AI mode, warm-up policy and `debug_mode`. |
| `wheel.json` | Steering rate limits, EMA, lerp and profile mode. |
| `pedals.json` | Throttle/brake rates, arbitration and smooth start. |
| `warmup.json` | Engine thresholds, sway and AI handover. |
| `lights.json` | Day/night light states, polling and hysteresis. |
| `lights_by_map.json` | Optional per-map night windows. |
| `popup.json` | Eye models, blink intervals and debug delay. |
| `pet.json` | Pet duration, throttle, sound and cooldown. |
| `pain.json` | Damage thresholds, stuck/flipped detection and recovery. |
| `music.json` | Music-reactive steering amplitudes. |
| `parking.json` | Parking search and stop parameters. |
| `graph.json` | Graph diagnostics friction/turn/speed settings. |

## Debug logging

`master.json` contains:

```json
"debug_mode": 0
```

At `0`, only `WARN`/`ERROR` and explicit `status` output reaches the console. Set it to `1` to enable verbose module logs. Vehicle `aplPrint` output follows the same flag.

## Warm-up

```json
{
  "timing": { "min_time_s": 10, "max_timeout_s": 30 },
  "engine": { "temp_threshold_c": 75, "oil_threshold_c": 60 },
  "sway": {
    "enabled": 1,
    "amplitude": 0.035,
    "freq_hz": 0.2,
    "fade_time_s": 2,
    "duration_s": 4
  },
  "finish": {
    "auto_engage_after_warmup": 1,
    "ai_mode_after_warmup": "traffic"
  }
}
```

Keep `sway.amplitude` at or below `0.035`. On finish the sway is reset and the steering pipeline is seeded from zero.

## Popup

```json
{
  "models": ["bolide", "wigeon", "bx", "wendover", "barstow"],
  "day_min_s": 120,
  "day_max_s": 180,
  "night_min_s": 180,
  "night_max_s": 300,
  "blink_min_s": 1.2,
  "blink_max_s": 1.2,
  "debug_force_blink_delay_s": 0,
  "squint_min": 0.27,
  "squint_max": 0.50,
  "squint_duration_s": 6.0
}
```

- `squint_min` / `squint_max` - cover travel during a cat-squint; `0.0` is fully closed, `1.0` is fully open.
- `squint_duration_s` - total duration of the cat-squint envelope.
- `debug_force_blink_delay_s: 0` - normal behavior, blink every 2-3 minutes.
- `5` — debug mode, blink every 5 seconds (works at night too).
- Model names are matched against the basename of `vehicle.JBeam`, so full JBeam paths are accepted.

## Wheel

The current custom tuning is intentionally:

```json
{
  "mode": "custom",
  "rate_limit": { "steer_rise": 6.0, "steer_fall": 8.0 },
  "ema_tau": { "steer": 0.08 },
  "lerp_tau": { "steer": 0.05 }
}
```

`mode: comfort/sport` replaces the rates with a preset; `custom` uses the explicit values. Comfort is tuned to rise/fall `1.8/2.5`, EMA `0.15`, lerp `0.12`.

## Pet

```json
{
  "duration_s": 6.0,
  "sound": {
    "sound_event": "art/sound/apl_pet.wav",
    "pitch": 0.8,
    "volume": 5.0,
    "no_pos": true
  }
}
```

A non-empty `sound_event` is required for purring. The GE layer uses `Engine.Audio.playOnce` and falls back to `file:<path>`.

## Changing settings in-game

- HUD app changes are saved to user settings.
- Console commands apply immediately for most modules.
- Wheel settings can require a vehicle respawn after saving.
