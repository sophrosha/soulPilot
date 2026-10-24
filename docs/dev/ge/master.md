# GE: master.lua

`modules/master.lua` implements the autopilot state machine.

## State

- `state = "off" | "waiting_warmup" | "on"`;
- `pending` — warm-up handover is expected;
- `wait_time` — timeout counter;
- `poll_acc` — fallback warm-up polling timer.

## Functions

| Function | Purpose |
|---|---|
| `init(config_loader, vehicle_bridge, logger)` | Store dependencies. |
| `setCommands(command_module)` | Late-bind the commands module to avoid a circular require. |
| `isOn()` / `getState()` | Read the current state. |
| `aplAutopilot(mode)` | `on`, `off`, `toggle`, `status`. |
| `onWheelOn()` | Mark the wheel as requested after a vehicle callback. |
| `onWarmupDone(...)` | Finish warm-up, auto-engage wheel/pedals and enable modules. |
| `onWarmupState(state)` | Fallback finish when the warm-up state becomes `done`. |
| `update(dt)` | Poll warm-up state every 2 s and cancel after 60 s. |
| `reset()` | Return to `off` for a mission change. |

## `aplAutopilot("on")`

1. Check that a player vehicle exists.
2. Load `master.json`.
3. Auto-start `soulPilotWarmupCmd.on(...)`.
4. Set `waiting_warmup` and mark warm-up requested.
5. On warm-up completion:
   - enable wheel and pedals unless already requested;
   - enable lights, popup and pain if configured;
   - set the AI mode from `master.json`;
   - mark master `on`.

## `aplAutopilot("off")`

- cancel warm-up;
- disable wheel, pedals, lights, popup and pain;
- set AI mode to `disabled`;
- reset master state.

## Failure behavior

A warm-up timeout or missing callback cancels the pending state after 60 seconds. The system does not leave the master waiting forever.

## Algorithm

`aplAutopilot("on")` starts warm-up and enters `waiting_warmup`. A vehicle callback or the 2-second fallback poll finishes the handover. `finish()` enables modules, sets AI mode and marks master `on`; a 60-second guard cancels a stuck wait.

## State ownership

Master owns `state`, `pending`, `wait_time` and `poll_acc`; enabled flags stay in `commands.lua` so direct module commands and master auto-engagement do not fight each other.
