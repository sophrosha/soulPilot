# GE: commands.lua

`modules/commands.lua` is the public command surface and owns the legacy `apl_*` aliases.

## State flags

- `wheel_requested`;
- `pedals_requested`;
- `warmup_requested`.

## Public commands

| Function | Description |
|---|---|
| `aplWheel("on"|"off"|"status")` | Sends `soulPilotWheelCmd` to the player vehicle and starts CSV on enable. |
| `aplPedals("on"|"off"|"status")` | Sends `soulPilotPedalsCmd`. |
| `aplWarmup("start"|"off"|"status")` | Sends `soulPilotWarmupCmd`. |
| `aplAutopilot(mode)` | Delegates to `master.aplAutopilot`. |
| `aplAutopilotState()` | Returns the master state. |
| `aplLights(mode, value)` | Delegates to `lights.aplLights`. |
| `aplPet(mode)` | Delegates to `pet.aplPet`. |
| `aplPetActive()` | Returns pet activity. |
| `aplPopup(mode)` | Delegates to `popup.aplPopup`. |
| `aplPain(mode)` | Delegates to `pain.aplPain`. |
| `aplDebug()` | Toggles logger/CSV/vehicle debug. |
| `aplDebugSet(enabled)` | Sets debug state explicitly. |
| `aplLock("on"|"off"|"status")` | Blocks/unblocks the walking-mode action used to leave the driver seat. |
| `aplStatus()` | Prints a compact system status. |
| `aplDiag()` | Delegates to diagnostics. |
| `aplMapDiag()` | Delegates to graph/map diagnostics. |
| `aplExportGraph()` | Delegates to graph export. |
| `aplMark(comment)` | Delegates to marks CSV. |

## Aliases

`register()` exposes the `apl_*` names globally:

```text
apl_autopilot, apl_autopilotState, apl_wheel, apl_pedals,
apl_warmup, apl_lights, apl_pet, apl_petActive, apl_popup,
apl_pain, apl_debug, apl_debug_set, apl_lock, apl_status, apl_diag,
apl_mapDiag, apl_exportGraph, apl_mark
```

The aliases are intentionally retained during migration. New internal code should call the module methods directly.

## Command names

GE must send the current namespace:

```lua
soulPilotWheelCmd.on(path)
soulPilotPedalsCmd.on(path)
soulPilotPopupCmd.start(params)
soulPilotPetCmd.start(params)
soulPilotWarmupCmd.on(path)
```

Do not add new `autopilotLive*Cmd` calls.

## Algorithm

Each enable command resolves the config path, queues a `soulPilot*Cmd` call and optionally starts CSV. Each disable command queues an `off` plus a status round-trip. The module never calls vehicle globals directly; it goes through `vehicleBridge`.

## State ownership

`wheel_requested`, `pedals_requested` and `warmup_requested` mirror vehicle state. They are reset on mission changes and updated by vehicle callbacks.
