# Development

## Repository layout

```text
soulPilot/
├─ src/                 editable runtime source
│  ├─ lua/              GE + vehicle Lua
│  ├─ ui/               Vue HUD app
│  ├─ mod_info/         mod metadata
│  ├─ art/              runtime art
│  ├─ config/           default JSON configs
│  └─ tests/            Python golden tests
├─ scripts/             BeamNG modScript.lua
├─ locales/             UI translations
├─ src_music/           optional Python music bridge
├─ dev_mode.py          src/ -> mod root deploy
└─ build_release.py     flat release zip builder
```

## Dev loop

```powershell
python dev_mode.py
python -m unittest discover -s src/tests -v
```

`dev_mode.py` performs a mirror copy and removes stale files inside the five runtime folders. It never creates `dist` inside the mod.

## Release

```powershell
python build_release.py --dry-run
python build_release.py
```

Default output is outside the unpacked mod:

```text
...\BeamNG.drive\current\mods\soulPilot-dist\soulPilot-<version>.zip
```

The zip has runtime folders at its root. `src/` must never appear inside the archive.

## Tests

The suite covers:

- JSON/config contracts;
- wheel and pedal golden calculations;
- real GE extension command routing through Lua;
- GE → vehicle command-name audit;
- vehicle command tables and legacy aliases.

Run all tests from the repository root.

## GE ↔ vehicle bridge

GE:

```lua
bridge.sendToVehicle('soulPilotWheelCmd.on("mods/unpacked/soulPilot/config/wheel.json")')
```

Vehicle:

```lua
soulPilotWheelCmd = {}
function soulPilotWheelCmd.on(path) ... end
```

Rules:

- command names are `soulPilot*Cmd`;
- `autopilotLive*Cmd` aliases exist only for backward compatibility;
- commands must tolerate a missing player vehicle;
- use `pcall` around engine APIs that may change between BeamNG versions.

## Code style

- English comments and logs in new code;
- `snake_case` variables and state fields;
- `camelCase` functions;
- no duplicated math or bridge helpers;
- do not edit BeamNG's own `lua/` files.

## Cache and debugging

In-game console:

```lua
apl_debug_set(true)
apl_status()
apl_wheel("status")
apl_pedals("status")
apl_popup("status")
```

Logs are written under the writable data directory (normally `ai/logs/` in development).
