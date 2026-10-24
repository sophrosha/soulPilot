# Modules

soulPilot is split into a Game Engine (GE) layer and a vehicle layer. Both layers use Lua modules with explicit command tables.

## GE layer

| Module | Responsibility |
|---|---|
| `main.lua` | Thin extension entrypoint: requires modules, wires dependencies and forwards hooks. |
| `modules/logger.lua` | Console/file logging and writable data-directory selection. |
| `modules/configLoader.lua` | Defaults, user overrides and runtime config lookup. |
| `modules/vehicleBridge.lua` | GE → vehicle `queueLuaCommand` bridge and fallback vehicle. |
| `modules/commands.lua` | Public commands and legacy `apl_*` aliases. |
| `modules/master.lua` | Autopilot state machine and module orchestration. |
| `modules/csv.lua` | Driving CSV recording. |
| `modules/uiBridge.lua` | Debug/UI bridge. |
| `modules/lights.lua` | Automatic headlight target and night windows. |
| `modules/popup.lua` | Popup model guard, start/stop and night updates. |
| `modules/pet.lua` | Pet command, purr playback and rejection handling. |
| `modules/pain.lua` | Damage polling, recovery and escalation. |
| `modules/diagnostics.lua` | Diagnostics entrypoints. |
| `modules/diagnostics_graph.lua` | Graph export, map diagnostics and marks. |

## Vehicle layer

| Module | Responsibility |
|---|---|
| `auto/soulPilot.lua` | Vehicle core, CSV/debug commands and layer logging. |
| `auto/soulPilotWarmup.lua` | Engine start, temperature thresholds, sway and AI handover. |
| `auto/soulPilotWheel.lua` | Steering command table and the per-frame wheel pipeline. |
| `auto/soulPilotPedals.lua` | Pedal command table and per-frame pedal pipeline. |
| `auto/soulPilotLights.lua` | `lights_state` writes, auto/manual guard and popup suppression. |
| `auto/soulPilotPopup.lua` | Eye open/close state machine and blink intervals. |
| `auto/soulPilotPet.lua` | Pet interaction guard and animation. |
| `auto/soulPilotPain.lua` | Damage monitor and pain state. |
| `auto/soulPilotMusic.lua` | Music data consumer and steering offsets. |
| `auto/soulPilotPark.lua` | Vehicle-side parking commands. |

## Wheel pipeline

```text
target -> rate limit -> EMA -> lerp -> clamp -> steering_input
```

After warm-up, the wheel is re-seeded from zero (`seed_zero`) so a manual steering position cannot become the AI's starting target.

## Pedal pipeline

```text
raw throttle/brake -> arbitration -> rate limits -> EMA -> lerp -> overrides
```

Brake hard clamps are independent of throttle rate scaling.

## Bridge rules

- GE code must use `soulPilotWheelCmd`, `soulPilotPedalsCmd`, `soulPilotPopupCmd`, `soulPilotPetCmd`, `soulPilotLightsCmd`, `soulPilotWarmupCmd` and `soulPilotCmd`.
- Legacy `autopilotLive*Cmd` names exist only as vehicle-side compatibility aliases.
- New code must call the vehicle layer through `vehicleBridge.sendToVehicle`.
