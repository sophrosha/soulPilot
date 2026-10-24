# Installing soulPilot

## Release installation

1. Build or download `soulPilot-<version>.zip`.
2. Open BeamNG.drive and use **Mods → Open Mods Folder**, or copy the zip into:

```text
%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\
```

3. Enable **soulPilot** in the Mod Manager.
4. Restart BeamNG completely.
5. Spawn a vehicle and open the soulPilot HUD app or use the console.

The release archive is intentionally flat at the top level:

```text
soulPilot-<version>.zip
├─ lua/
├─ ui/
├─ mod_info/
├─ art/
├─ config/
├─ scripts/
└─ src_music/
```

If your zip contains a top-level `src/` folder, it was built by an old script and will not load correctly.

## Unpacked development installation

The editable source tree is `src/`, but BeamNG expects the runtime folders directly in the unpacked mod folder.

```powershell
Set-Location "C:\Users\<you>\AppData\Local\BeamNG\BeamNG.drive\current\mods\unpacked\soulPilot"
python dev_mode.py
```

`dev_mode.py` mirrors:

```text
src/lua       -> lua
src/ui        -> ui
src/mod_info  -> mod_info
src/art       -> art
src/config    -> config
```

It also checks/copies `scripts/`, `locales/` and `src_music/` when their sources are under `src/`. The current repository keeps those three folders at the root, which is valid.

## Removing the old mod and cache

Before the first test after migration:

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\BeamNG\BeamNG.drive\current\mods\unpacked\AutopilotLive" -ErrorAction SilentlyContinue
Remove-Item -Force "$env:LOCALAPPDATA\BeamNG\BeamNG.drive\current\mods\db.json" -ErrorAction SilentlyContinue
```

`mods/db.json` is the BeamNG mod database/cache. It is recreated at the next game start. Do not delete it while the game is running.

## Verifying the installation

In the in-game console, run:

```lua
print(extensions.soulPilot_main ~= nil)
apl_status()
```

The first line should print `true`. If you see old `autopilotLive_main` messages, the old mod or a stale cache is still active.

## Uninstalling

Disable the mod in the Mod Manager and remove the zip/folder. User settings can be removed separately:

```text
%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\settings\mod_settings\soulPilot\
```
