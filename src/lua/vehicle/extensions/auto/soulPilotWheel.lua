-- soulPilot wheel vehicle extension.
-- Thin entry point: load modules, run one frame, expose commands.

local M = {}

local vehicle_bridge = require("extensions.soulPilot.utils.vehicleBridge")
local math_utils = require("extensions.soulPilot.utils.mathUtils")
local wheel_config = require("extensions.soulPilot.wheel.wheelConfig")
local wheel_state = require("extensions.soulPilot.wheel.wheelState")
local wheel_pipeline = require("extensions.soulPilot.wheel.wheelPipeline")
local wheel_overrides = require("extensions.soulPilot.wheel.wheelOverrides")
local wheel_diagnostics = require("extensions.soulPilot.wheel.wheelDiagnostics")

local state = wheel_state.create()

local function notify(level, message)
  vehicle_bridge.sendToGameEngine(level, message)
end

state.notify = notify

local function readSteerRawNorm()
  local input_state = input and input.state
  if not input_state or not input_state.steering then
    return 0
  end
  return wheel_diagnostics.sanitizeSteering(input_state.steering.val)
end

local function isAiDriving()
  local driving = false
  pcall(function()
    driving = (ai ~= nil and ai.isDriving ~= nil) and (ai.isDriving() or false)
  end)
  return driving
end

function M.updateGFX(dt)
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then
    return
  end

  if not state.active then
    wheel_overrides.applyParkMusic(state)
    wheel_diagnostics.resetRateStats(state)
    return
  end

  if not isAiDriving() then
    wheel_overrides.applyParkMusic(state)
    state.need_init = true
    state.last_out.engaged = false
    wheel_diagnostics.resetRateStats(state)
    return
  end

  local target = readSteerRawNorm()
  state.last_raw = target

  wheel_overrides.initialize(state, target)
  wheel_pipeline.stepWheel(state, target, dt)

  local vibe = wheel_overrides.getMusicOffset("soulPilotMusicGetDriveOffset")
  local kick = wheel_overrides.getMusicOffset("soulPilotMusicGetBeatKick")
  local output = math_utils.clampSymmetric(state.pipe.output + vibe + kick)

  wheel_diagnostics.updateRateStats(state, target, output, dt)
  wheel_overrides.write(state, output)
end

-- Public commands are kept under the current extension name for compatibility.
soulPilotWheelCmd = {}

-- Legacy migration alias; new code must use soulPilotWheelCmd.
autopilotLiveWheelCmd = soulPilotWheelCmd

function soulPilotWheelCmd.on(config_path)
  local path = type(config_path) == "string" and config_path or wheel_config.FALLBACK_CONFIG

  if state.active and state.active_config_path == path then
    print("soulPilotWheel: ON already active - duplicate call ignored")
    return true
  end

  local was_active = state.active
  state.cfg, state.cfg_from_file = wheel_config.load(path, notify)
  state.active = true
  state.active_config_path = path

  if not was_active then
    state.need_init = true
    state.rate_scale = 1.0
    wheel_diagnostics.resetRateStats(state)
  else
    print("soulPilotWheel: ON already active - config reloaded, needInit preserved")
  end

  pcall(function()
    obj:queueGameEngineLua(
      "if extensions and extensions.soulPilot_main and extensions.soulPilot_main.onVehicleWheelOn then extensions.soulPilot_main.onVehicleWheelOn() end")
  end)

  local rate = state.cfg.rate_limit
  local config_label = state.cfg_from_file and "file" or "DEFAULTS"
  print(string.format(
    "soulPilotWheel: ON - mode=%s, rate %s/%s, ema %s, lerp %s",
    tostring(state.cfg.mode or "custom"),
    tostring(rate.steer_rise),
    tostring(rate.steer_fall),
    tostring(state.cfg.ema_tau.steer),
    tostring(state.cfg.lerp_tau.steer)))
  notify("INFO", string.format(
    "wheel ON (%s, mode=%s): rate rise/fall %s/%s, ema %s s, lerp %s s",
    config_label,
    tostring(state.cfg.mode or "custom"),
    tostring(rate.steer_rise),
    tostring(rate.steer_fall),
    tostring(state.cfg.ema_tau.steer),
    tostring(state.cfg.lerp_tau.steer)))
  return true
end

function soulPilotWheelCmd.off()
  if not state.active then
    return false
  end

  state.active = false
  state.active_config_path = nil
  state.rate_scale = 1.0
  wheel_diagnostics.resetRateStats(state)
  state.last_out.engaged = false
  notify("INFO", "wheel OFF: steering_input rewrite stopped, vanilla FILTER_AI restored")
  return true
end

function soulPilotWheelCmd.setRateScale(scale)
  scale = math_utils.clampNumber(scale, 0.1, 1.0, 1.0)
  state.rate_scale = scale
  notify("INFO", "wheel rateScale -> " .. string.format("%.2f", scale))
  return true
end

function soulPilotWheelCmd.status()
  wheel_diagnostics.printStatus(state)
  return true
end

function soulPilotWheelGetState()
  return wheel_diagnostics.getState(state)
end

function M.onReset()
  state.need_init = true
  state.last_out.engaged = false
  wheel_diagnostics.resetRateStats(state)
end

function M.onVehicleDestroyed()
  state.active = false
  state.active_config_path = nil
  state.last_out.engaged = false
  wheel_diagnostics.resetRateStats(state)
end

return M
