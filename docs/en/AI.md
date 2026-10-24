# AI Architecture

## Goals

The AI layer makes BeamNG's built-in driving AI behave more smoothly and gives the player a single, predictable control surface. It does not replace BeamNG's traffic AI; it smooths the inputs and adds an orchestration layer around it.

## Layers

```text
Player / Quick Access / HUD
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

### GE layer

The GE layer owns:

- command registration and legacy aliases;
- configuration and user overrides;
- master state and warm-up orchestration;
- popup model validation and night state;
- pet sound playback;
- damage polling and recovery escalation;
- CSV/logging.

### Vehicle layer

The vehicle layer owns:

- `steering_input` and pedal override writes;
- `lights_state` and eye animation;
- warm-up engine control and sway;
- pet animation and handbrake behavior;
- vehicle-side guards for speed, engine, cooldown and spam.

## Master sequence

```text
apl_autopilot("on")
  -> master waits for warm-up
  -> warm-up starts engine / checks temperatures
  -> optional sway fades back to zero
  -> wheel + pedals are enabled
  -> AI mode is set in the vehicle VM
  -> GE enables lights/popup/pain
```

If warm-up times out, the master still finishes safely and reports the timeout. Modules that were manually enabled before warm-up are not duplicated.

## Steering safety

- `steer_rise` and `steer_fall` limit the rate in normalized units per second.
- EMA and lerp remove high-frequency AI jitter.
- The output is clamped to `[-1, 1]`.
- Warm-up sway is clamped to `0.035` and is reset when AI takes over.
- `seed_zero` prevents a manual full-lock position from becoming the AI's initial steering target.

## Pedal safety

- Brake and throttle use separate rate limits.
- Predictive braking uses lead time and release hysteresis.
- Brake arbitration starts at `brake_start` and reaches full at `brake_full`.
- Watchdog/stuck detection prevents a stale override from holding a pedal forever.

## Damage and recovery

The vehicle reports damage requests; GE reads `getSectionDamageSum`. When the threshold is crossed:

1. ignore damage briefly;
2. reset the vehicle;
3. restore pedals/wheel at reduced rate;
4. optionally teleport to the last road;
5. optionally restore AI traffic mode.

All recovery steps are guarded and logged.

## Adding a feature

1. Add an explicit command table in the vehicle layer (`soulPilot<Feature>Cmd`).
2. Add a GE module with an English log surface.
3. Register public and `apl_*` aliases in `commands.lua`.
4. Add a golden/audit test.
5. Add documentation under `docs/en` and `docs/ru`.
