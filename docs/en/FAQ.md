# FAQ

## The game still prints `autopilotLive_main`

1. Close the game.
2. Remove `mods/unpacked/AutopilotLive`.
3. Remove old `dist` folders from inside the mod.
4. Delete `mods/db.json`.
5. Run `python dev_mode.py`.
6. Start the game and check that the mod list shows **soulPilot**.

## The wheel turns to full lock after warm-up

Warm-up sway is limited to `0.035` normalized steering. At the end of warm-up the sway value is reset and the wheel is re-seeded from zero, so the AI starts from a neutral steering position. If you turned the physical wheel during warm-up, the next AI takeover should ignore that manual position.

If it still happens, check `warmup.json`:

```json
"sway": {
  "enabled": 1,
  "amplitude": 0.035
}
```

Do not raise the amplitude above `0.035` for normal use.

## Popup eyes do not blink

- Popup is supported only on configured JBeam models. The default list is:

```json
"models": ["bolide", "wigeon"]
```

- During the night, normal blinking is intentionally suppressed.
- To test immediately, set a debug interval in `popup.json`:

```json
"debug_force_blink_delay_s": 5
```

Then run `apl_popup("auto")`. Debug mode blinks even at night.

- If the model is correct and the debug value is non-zero but nothing moves, check `soulPilotLightsCmd` and the vehicle console for `aplPopup` messages.

## Pet does not purr

Pet requires a running engine and the vehicle must not be moving while AI is disabled. Check `pet.json`:

```json
"sound_event": "art/sound/apl_pet.wav"
```

The GE layer calls `Engine.Audio.playOnce("AudioGui", ...)` and retries with `file:`. The vehicle layer handles the pet animation; both layers must be current.

## Music does not react

The optional Python bridge writes:

```text
mods/unpacked/soulPilot/src_music/current.json
```

Start it with:

```powershell
.\ai\venv\Scripts\python.exe src_music\main.py --console
```

Select the VB-Cable capture device and start the music in Spotify. The Lua side marks stale data after 0.3 s and safely falls back to neutral.

## Where are my settings?

User settings:

```text
%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\settings\mod_settings\soulPilot\
```

Mod defaults:

```text
src/config/
```

A deployed mod uses the root `config/` folder. The loader checks user, source and runtime paths in that order.
