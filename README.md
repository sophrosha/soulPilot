# soulPilot

**soulPilot** is a driving-assistant overlay for **BeamNG.drive 0.39.4**. It adds a warm-up sequence, smooth AI steering and pedals, automatic lights, expressive pop-up eyes, a petting interaction, pain/recovery logic, music-reactive steering and parking support.

The project is a clean, modular continuation of AutopilotLive. The GE and vehicle layers communicate through explicit `soulPilot*Cmd` tables.

> The settings UI is optional. The core assistant can be controlled from the console with `apl_autopilot("on")` or from Quick Access.

## Features

- **Master mode** — one command enables warm-up, driving modules and AI traffic.
- **Warm-up** — engine start, coolant/oil thresholds, gentle steering sway and a safe handover to AI.
- **Steering pipeline** — `rate limit -> EMA -> lerp`, music offsets and safe re-seeding after warm-up.
- **Pedals** — smooth throttle/brake arbitration, predictive braking and shift handling.
- **Lights** — automatic day/night headlights with per-map windows.
- **Popup eyes** — Bolide/Wigeon eye animation with day/night intervals and a debug blink mode.
- **Pet** — short petting interaction with purring audio and a cooldown.
- **Pain/recovery** — damage detection, reset/teleport recovery and optional AI restore.
- **Music** — optional Spotify/VB-Cable bass analysis feeding the steering layer.
- **Parking** — assisted parking search and stop sequence.

## Requirements

- BeamNG.drive **0.39.4**.
- Windows (the Python music bridge is Windows-first).
- Python **3.10+** for development tools and the optional music bridge.
- The release zip does not require Python for the core Lua features.

## Installation

### Release zip

1. Run `python build_release.py`.
2. Install the generated `soulPilot-<version>.zip` through the BeamNG Mod Manager, or place it in the game's `mods` folder.
3. Enable the mod, restart the game completely and spawn a vehicle.

The zip contains `lua/`, `ui/`, `mod_info/`, `art/`, `config/`, `scripts/`, `src_music/` at the archive root.

### Unpacked development

Close the game, remove the old `AutopilotLive` folder from `mods/unpacked`, then from the repository root run:

```powershell
python dev_mode.py
```

This mirrors `src/lua`, `src/ui`, `src/mod_info`, `src/art` and `src/config` to the mod root. `scripts/`, `locales/` and `src_music/` are already runtime folders and are checked by the same script.

Clear the BeamNG mod cache if the old mod is still listed:

```powershell
Remove-Item -Force "$env:LOCALAPPDATA\BeamNG\BeamNG.drive\current\mods\db.json" -ErrorAction SilentlyContinue
```

## Controls

| Action | Key / command |
|---|---|
| Autopilot on/off | `Ctrl+Shift+A` |
| Pet / purr | `Ctrl+Shift+P` |
| Warm-up | `Ctrl+Shift+W` |
| HUD app catalogue | `Ctrl+Shift+U` |
| Master | Quick Access → soulPilot → Master |
| Parking | Quick Access → soulPilot → Parking |

Useful console commands:

```lua
apl_autopilot("on")
apl_autopilot("status")
apl_wheel("status")
apl_pedals("status")
apl_pet("on")
apl_popup("auto")
apl_status()
```

## Configuration

Default configuration lives in `src/config/`. User overrides are written to:

```text
%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\settings\mod_settings\soulPilot\
```

The runtime config folder is `config/` in a deployed mod. The Lua loader checks the user path, then `src/config/`, then the runtime `config/` folder.

See [docs/en/Settings.md](docs/en/Settings.md) for the full reference.

## Development

```powershell
python dev_mode.py                 # deploy src runtime folders to the mod root
python -m unittest discover -s src/tests -v
python build_release.py --dry-run  # inspect the future zip layout
python build_release.py            # write outside mods/unpacked
```

The source layout is described in [docs/en/Dev.md](docs/en/Dev.md).

## Documentation

- [Documentation index](docs/readme.md)
- [English FAQ](docs/en/FAQ.md)
- [Russian FAQ](docs/ru/FAQ.md)
- [AI architecture](docs/en/AI.md)

## License

MIT. See the project metadata and the upstream credits for third-party assets.
