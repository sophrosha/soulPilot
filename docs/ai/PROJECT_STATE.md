# soulPilot Project State

## Status

The refactor is in the final integration phase.

- GE layer is modular and `main.lua` is a thin entrypoint.
- Vehicle pedals and wheel pipelines are split into focused modules.
- GE ↔ vehicle commands use the `soulPilot*Cmd` namespace.
- Legacy `autopilotLive*Cmd` names exist only as vehicle-side aliases.
- Warm-up sway is relative to sway start, clamped to `0.035`, and reset before AI handover.
- Wheel startup after warm-up uses `seed_zero` to avoid inheriting a manual full-lock position.
- Popup debug mode bypasses the night blink lock and supports immediate testing.
- The test suite is green: 43 tests.

## Layout

```text
src/lua/ge/extensions/soulPilot/       GE extension and modules
src/lua/vehicle/extensions/auto/       vehicle entrypoints and command tables
src/lua/vehicle/extensions/soulPilot/  vehicle-only wheel/pedal/utils modules
src/ui/modules/apps/soulPilot/         Vue HUD
src/config/                            default JSON configuration
src/tests/                             Python/Lua golden tests
```

## Active work

- Documentation restructuring under `docs/ai` and `docs/dev`.
- Final release zip verification.
- In-game smoke test of warm-up sway and popup debug blinking.

## Non-goals

- Do not replace BeamNG's own traffic AI.
- Do not edit BeamNG's installation `lua/` files.
- Do not commit user CSV/log/road data.
