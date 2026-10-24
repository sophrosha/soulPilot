# FAQ

## How do I open the settings menu?

Open the HUD app catalogue with `Ctrl+Shift+U`, then choose **soulPilot**. You can also use Quick Access and select **soulPilot → Master**.

## How do I start autopilot?

Press `Ctrl+Shift+A`, use Quick Access → soulPilot → Master, or run:

```lua
apl_autopilot("on")
```

The car warms up, then the assistant enables steering, pedals, lights and traffic AI according to `master.json`.

## How do I enable music?

Music is optional. Install the Python requirements, start the music bridge, select the VB-Cable capture device and enable **Music** in the soulPilot menu:

```powershell
.\ai\venv\Scripts\python.exe src_music\main.py --console
```

The bridge writes `src_music/current.json`; the vehicle layer reads it and adds a small steering offset.

## How does petting work?

Press `Ctrl+Shift+P` or run `apl_pet("on")`. The car performs a short petting animation (about 6 seconds) with purring. Petting has a speed gate, a spam limit and a cooldown; press `apl_pet("off")` to stop it.

## What are the default keybinds?

| Action | Key |
|---|---|
| Autopilot on/off | `Ctrl+Shift+A` |
| Pet / purr | `Ctrl+Shift+P` |
| Warm-up | `Ctrl+Shift+W` |
| HUD app catalogue | `Ctrl+Shift+U` |

All binds can be changed in BeamNG **Options → Controls**.
