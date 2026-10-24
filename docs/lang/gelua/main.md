# GE: main.lua

`src/lua/ge/extensions/soulPilot/main.lua` is the thin extension entrypoint.

## Responsibilities

- `require` the GE modules;
- initialize logger, bridge, CSV and UI bridge;
- initialize lights, pet, popup, pain, master and diagnostics;
- wire `master` to `commands`;
- register public commands and aliases;
- forward BeamNG lifecycle hooks.

## Public hooks

| Function | Purpose |
|---|---|
| `M.onExtensionLoaded()` | Initialize the logger, load debug state, load optional extensions (`quickAccessMenu`, `music`, `parking`, `uiConfig`) and publish `extensions.soulPilot_main`. |
| `M.onExtensionUnloaded()` | Stop CSV and close the log. |
| `M.onShutdown()` | Stop CSV and close the log. |
| `M.onUpdate(dt)` | Tick pain, master, popup and lights. |
| `M.onClientPostStartMission()` | Reset command flags and module state, stop CSV. |
| `M.onVehicleLog(level, message)` | Route vehicle logs to the GE logger; open the file log on `ERROR`. |
| `M.onVehicleWheelOn()` | Mark the wheel as requested. |
| `M.onVehicleWarmupDone(...)` | Finish master warm-up and auto-engage modules. |
| `M.onVehicleWarmupState(state)` | Poll fallback warm-up state. |
| `M.onVehiclePain(kind, info)` | Trigger recovery. |
| `M.onVehiclePainDamageRequest()` | Push current vehicle damage to the vehicle layer. |
| `M.onVehiclePetDone()` | Stop purr audio. |
| `M.onVehiclePetRejected()` | Stop purr audio after a guard rejection. |
| `M.onVehiclePopupAutoOff()` | Synchronize popup auto state. |
| `M.onVehicleLightsAutoOff()` | Synchronize lights auto state. |
| `M.onVehicleReady(id)` | Send the current debug flag to the vehicle VM. |
| `M.onConsoleExecuteCommand(context, command)` | Handle bare `apl_debug` / `apl_status`. |
| `M.isNightNow()` | Expose the lights night calculation. |
| `M.onSerialize()` | Return `nil`; module state is not serialized. |

## Wiring order

1. logger;
2. vehicle bridge;
3. CSV and UI bridge;
4. lights, pet, popup, pain;
5. master;
6. commands;
7. diagnostics.

`commands.register()` is called at load time so console commands exist before the first mission tick.
