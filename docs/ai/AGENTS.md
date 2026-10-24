# Agent and Developer Rules

## Language and style

- New comments and logs are English.
- Variables and state fields use `snake_case`.
- Functions use `camelCase`.
- Keep functions small; split files above roughly 300–400 lines.
- Do not duplicate math or bridge helpers.

## Command bridge

- GE sends only `soulPilotWheelCmd`, `soulPilotPedalsCmd`, `soulPilotPopupCmd`, `soulPilotPetCmd`, `soulPilotLightsCmd`, `soulPilotWarmupCmd`, `soulPilotCmd`.
- `autopilotLive*Cmd` remains only as vehicle-side compatibility aliases.
- Every command path must handle a missing player vehicle.
- Wrap BeamNG APIs that may change in `pcall`.

## Warm-up invariants

- `sway.amplitude <= 0.035`.
- Sway phase is relative to `sway_start`; never accumulate phase between warm-ups.
- On finish, clear `steering_input` and reset sway state.
- Auto-engaged wheel uses `{ seed_zero = true }`.

## Popup invariants

- Model names are matched by JBeam basename.
- Normal night blinking is suppressed.
- `debug_force_blink_delay_s > 0` must blink in debug mode at any time.

## Configuration

- Defaults live in `src/config/`.
- User overrides live in `settings/mod_settings/soulPilot/`.
- No `_comment` keys in JSON files.
- Runtime config may be under `config/`; the loader falls back to `src/config/` in development.

## Release workflow

```powershell
python dev_mode.py
python -m unittest discover -s src/tests -v
python build_release.py --dry-run
python build_release.py
```

Release output must stay outside `mods/unpacked`. The zip root contains `lua/`, `ui/`, `mod_info/`, `art/`, `config/`, `scripts/` and `src_music/`; it must not contain `src/` or `dist/`.

## Definition of done

- Tests pass.
- Lua parser passes.
- In-game smoke test covers warm-up, wheel, pedals, popup, pet and autopilot.
- Documentation is updated under `docs/ai` and `docs/lang`.
