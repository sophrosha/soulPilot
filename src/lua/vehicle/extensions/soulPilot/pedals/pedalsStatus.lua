-- soulPilot pedals status output and CSV snapshot.

local diagnostics = require("extensions.soulPilot.pedals.pedalsDiagnostics")
local modifiers = require("extensions.soulPilot.pedals.pedalsModifiers")

local M = {}

local function getSpeed()
  local ok, value = pcall(function()
    return obj:getVelocity():length()
  end)
  if not ok then
    return 0
  end
  local number = tonumber(value)
  if number == nil or number ~= number then
    return 0
  end
  return number
end

local function isAiDriving()
  local driving = false
  pcall(function()
    driving = (ai ~= nil and ai.isDriving ~= nil) and (ai.isDriving() or false)
  end)
  return driving
end

local function configLabel(state)
  if state.cfg_from_file then
    return "file"
  end
  if state.cfg then
    return "DEFAULTS"
  end
  return "not loaded"
end

function M.getState(state)
  return {
    active = state.active,
    engaged = state.last_out.engaged,
    throttle = state.last_out.throttle,
    brake = state.last_out.brake,
    clutch = state.last_out.clutch,
  }
end

function M.printStatus(state)
  local smooth_cap = 1
  if state.cfg then
    smooth_cap = modifiers.smoothStartFactor(state, state.cfg, getSpeed())
  end

  local lines = {
    "--- soulPilot pedals status ---",
    string.format(
      "active=%s engaged=%s aiDriving=%s config=%s",
      tostring(state.active),
      tostring(state.last_out.engaged),
      tostring(isAiDriving()),
      configLabel(state)),
    state.rate_scale < 1.0
      and string.format(
        "mode: recovery (rateScale=%.2f, remaining=%.1f s)",
        state.rate_scale,
        state.rate_scale_time)
      or "mode: normal (rateScale=1.00)",
    string.format(
      "throttle: raw %s -> out %s | brake: raw %s -> out %s | clutch: raw %s -> out %s (written: %s)",
      diagnostics.formatUnit(state.last_raw.throttle),
      diagnostics.formatUnit(state.last_out.throttle),
      diagnostics.formatUnit(state.last_raw.brake),
      diagnostics.formatUnit(state.last_out.brake),
      diagnostics.formatUnit(state.last_raw.clutch),
      diagnostics.formatUnit(state.last_out.clutch),
      tostring(state.clutch_written)),
    "predictive=" .. tostring(state.predictive_on) ..
      " smoothStartCap=" .. diagnostics.formatUnit(smooth_cap) ..
      " startTime=" .. tostring(state.start_time) .. "s",
  }

  local source, override, input_value, controller_name = "?", "nil", "?", "?"
  pcall(function()
    source = tostring(input.state.throttle.source)
  end)
  pcall(function()
    override = electrics.values.throttleOverride
  end)
  pcall(function()
    input_value = input.throttle
  end)
  pcall(function()
    local controller = controller and controller.getController
      and controller.getController("vehicleController")
    if controller then
      controller_name = tostring(controller.name or "vehicleController")
    end
  end)
  table.insert(lines, "gas: input=" .. tostring(input_value) ..
    " override=" .. tostring(override) ..
    " source=" .. source ..
    " controller=" .. controller_name ..
    " | watchdog: rawHold=" .. string.format("%.1f", state.raw_hold_time) ..
    "s stuck=" .. string.format("%.1f", state.stuck_time) .. "s")

  local gear, rpm, controller_throttle, controller_brake = "?", 0, "nil", "nil"
  pcall(function()
    gear = tostring(electrics.values.gear)
  end)
  pcall(function()
    rpm = tonumber(electrics.values.rpm) or 0
  end)
  pcall(function()
    controller_throttle = electrics.values.throttle
  end)
  pcall(function()
    controller_brake = electrics.values.brakeOverride
  end)
  table.insert(lines, "shift: gear=" .. gear .. " rpm=" .. string.format("%.0f", rpm) ..
    " | controller: throttle=" .. tostring(controller_throttle) ..
    " brakeOvr=" .. tostring(controller_brake) ..
    " | gasHigh=" .. string.format("%.1f", state.throttle_high_time) .. "s" ..
    " | lastGear=" .. state.last_gear ..
    " shiftHold=" .. string.format("%.1f", state.shift_hold_time) .. "s" ..
    " rateScale=" .. string.format("%.2f", state.rate_scale) ..
    " (" .. string.format("%.1f", state.rate_scale_time) .. "s)")

  table.insert(lines, string.format(
    "DIAG exact: thr=%s brk=%s clt=%s | pipe.brake rl=%s ema=%s out=%s",
    diagnostics.formatUnit(state.last_out.throttle),
    diagnostics.formatUnit(state.last_out.brake),
    diagnostics.formatUnit(state.last_out.clutch),
    diagnostics.formatUnit(state.pipe.brake.rate_limited),
    diagnostics.formatUnit(state.pipe.brake.ema),
    diagnostics.formatUnit(state.pipe.brake.output)))

  if diagnostics.diagBad(state.last_out.brake)
    or diagnostics.diagBad(state.last_out.throttle)
    or diagnostics.diagBad(state.last_out.clutch) then
    diagnostics.dumpBrakeHistory(
      state,
      "STATUS found garbage in last_out",
      string.format(
        "lastOut.brk=%s thr=%s clt=%s",
        tostring(state.last_out.brake),
        tostring(state.last_out.throttle),
        tostring(state.last_out.clutch)))
  end

  for _, line in ipairs(lines) do
    print("soulPilotPedals: " .. line)
  end

  if state.notify then
    state.notify("INFO", "pedals status: active=" .. tostring(state.active) ..
      " engaged=" .. tostring(state.last_out.engaged) ..
      " thr " .. diagnostics.formatUnit(state.last_raw.throttle) ..
      "->" .. diagnostics.formatUnit(state.last_out.throttle) ..
      " brk " .. diagnostics.formatUnit(state.last_raw.brake) ..
      "->" .. diagnostics.formatUnit(state.last_out.brake))
  end
end

return M
