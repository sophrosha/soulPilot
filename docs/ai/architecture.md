# AI Architecture

## Overview

soulPilot sits between player input, the HUD and BeamNG's built-in AI. It smooths vehicle inputs and orchestrates warm-up, lights, popup, pet and recovery behavior.

```text
Player / HUD / Quick Access
            |
       GE extension
   main.lua + modules/*
            |
  vehicleBridge.sendToVehicle
            |
       Vehicle VM
   soulPilot*Cmd tables
            |
 wheel / pedals / lights / popup / pet / pain
```

## GE layer

The GE layer owns command registration, configuration, master state, popup model validation, pet audio, damage polling, CSV and logging. `main.lua` only wires modules and forwards BeamNG hooks.

Key modules:

- `master.lua` — state machine and module orchestration;
- `commands.lua` — public commands and `apl_*` aliases;
- `vehicleBridge.lua` — GE → vehicle queueing;
- `configLoader.lua` — user/source/runtime config resolution;
- `popup.lua` — model guard and popup start/night updates;
- `pet.lua` — purr playback and command routing.

## Vehicle layer

The vehicle layer owns physical writes:

- wheel: `steering_input`, `rate_limit -> EMA -> lerp -> clamp`;
- pedals: throttle/brake arbitration and overrides;
- warm-up: engine start, temperatures, relative sway, AI handover;
- lights: `lights_state`, auto/manual guard and popup suppression;
- popup: eye open/close state machine;
- pet/pain: animation and recovery guards.

## Master sequence

```text
apl_autopilot("on")
  -> warm-up state machine
  -> engine start + temperature checks
  -> relative sway fades to zero
  -> wheel/pedals enabled
  -> wheel seeded from zero
  -> ai.setMode("traffic")
  -> lights/popup/pain enabled
```

A warm-up timeout is reported but still hands control over safely. Already-enabled modules are not duplicated.

## Safety invariants

- Sway is `amp * sin(2π f (elapsed - sway_start))^3`, bounded by `0.035`.
- Warm-up never integrates phase across starts.
- Manual full lock never becomes the AI's initial wheel target after warm-up.
- Pedal overrides are cleared on reset and guarded by a watchdog.
- Popup night suppression is bypassed only by explicit debug mode.
- GE commands must tolerate a missing player vehicle.
