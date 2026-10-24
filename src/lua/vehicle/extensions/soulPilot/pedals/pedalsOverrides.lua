-- soulPilot pedals override writer.
-- Nil is intentional: it returns control to the vanilla controller.

local math_utils = require("extensions.soulPilot.utils.mathUtils")

local M = {}

function M.clear(state)
  if not state.overrides_written and not state.clutch_written then
    return
  end

  electrics.values.throttleOverride = nil
  electrics.values.brakeOverride = nil
  electrics.values.clutchOverride = nil
  state.overrides_written = false
  state.clutch_written = false
  state.last_out.engaged = false
end

function M.write(state, throttle_out, brake_out, clutch_raw)
  electrics.values.throttleOverride = throttle_out

  if brake_out >= 0.02 then
    electrics.values.brakeOverride = brake_out
  else
    electrics.values.brakeOverride = nil
  end

  local clutch_out = math_utils.clampUnit(clutch_raw)
  if clutch_out > 0 then
    electrics.values.clutchOverride = clutch_out
    state.clutch_written = true
  elseif state.clutch_written then
    electrics.values.clutchOverride = nil
    state.clutch_written = false
  end

  state.overrides_written = true
end

return M
