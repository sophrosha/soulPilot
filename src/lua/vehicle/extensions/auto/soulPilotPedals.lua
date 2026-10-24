-- soulPilot pedals vehicle extension.
-- Thin entry point: load modules, wire the frame, expose commands.

local M = {}

local vehicle_bridge = require("extensions.soulPilot.utils.vehicleBridge")
local math_utils = require("extensions.soulPilot.utils.mathUtils")
local pedals_config = require("extensions.soulPilot.pedals.pedalsConfig")
local pedals_state = require("extensions.soulPilot.pedals.pedalsState")
local pedals_pipeline = require("extensions.soulPilot.pedals.pedalsPipeline")
local pedals_modifiers = require("extensions.soulPilot.pedals.pedalsModifiers")
local pedals_arbitration = require("extensions.soulPilot.pedals.pedalsArbitration")
local pedals_watchdog = require("extensions.soulPilot.pedals.pedalsWatchdog")
local pedals_diagnostics = require("extensions.soulPilot.pedals.pedalsDiagnostics")
local pedals_overrides = require("extensions.soulPilot.pedals.pedalsOverrides")
local pedals_status = require("extensions.soulPilot.pedals.pedalsStatus")

local state = pedals_state.create()

local function notify(level, message)
  vehicle_bridge.sendToGameEngine(level, message)
end

state.notify = notify

local function readRaw(name)
  local input_state = input and input.state
  if not input_state or not input_state[name] then
    return 0
  end
  return math_utils.safeNumber(input_state[name].val)
end

local function getSpeed()
  local ok, value = pcall(function()
    return obj:getVelocity():length()
  end)
  if not ok then
    return 0
  end
  return math_utils.safeNumber(value)
end

local function isAiDriving()
  local driving = false
  pcall(function()
    driving = (ai ~= nil and ai.isDriving ~= nil) and (ai.isDriving() or false)
  end)
  return driving
end

local function updateRateScaleTimer(dt)
  if state.rate_scale_time <= 0 then
    return
  end

  state.rate_scale_time = state.rate_scale_time - dt
  if state.rate_scale_time > 0 then
    return
  end

  state.rate_scale = 1.0
  state.rate_scale_time = 0
  print("soulPilotPedals: rateScale restored to 1.00 - recovery mode finished")
  notify("INFO", "pedals rateScale restored to 1.0")
end

local function getGear()
  local gear = "?"
  pcall(function()
    gear = tostring(electrics.values.gear)
  end)
  return gear
end

local function getRpm()
  local rpm = 0
  pcall(function()
    rpm = tonumber(electrics.values.rpm) or 0
  end)
  return rpm
end

function M.updateGFX(dt)
  if not state.active then
    return
  end
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then
    return
  end

  updateRateScaleTimer(dt)

  if not isAiDriving() then
    if state.ai_was_driving then
      state.ai_was_driving = false
      print("soulPilotPedals: AI PAUSE - override cleared, lastOut " ..
        pedals_diagnostics.formatUnit(state.last_out.throttle))
    end
    pedals_overrides.clear(state)
    state.need_init = true
    state.init_from_zero = false
    return
  end

  local throttle_raw = readRaw("throttle")
  local brake_raw = readRaw("brake")
  local clutch_raw = readRaw("clutch")
  state.last_raw.throttle = throttle_raw
  state.last_raw.brake = brake_raw
  state.last_raw.clutch = clutch_raw

  local speed = getSpeed()
  local gear = getGear()
  local rpm = getRpm()

  if not state.ai_was_driving then
    state.ai_was_driving = true
    state.resume_time = 0
    if state.cfg then
      print(string.format(
        "soulPilotPedals: AI RESUME - raw %s, lastOut %s, cap %s, gear %s",
        pedals_diagnostics.formatUnit(throttle_raw),
        pedals_diagnostics.formatUnit(state.last_out.throttle),
        pedals_diagnostics.formatUnit(
          pedals_modifiers.smoothStartFactor(state, state.cfg, speed)),
        gear))
    end
  end
  state.resume_time = state.resume_time + dt

  pedals_watchdog.updateRawHold(state, throttle_raw, dt)
  pedals_modifiers.updateShift(state, state.cfg, gear, throttle_raw, rpm)
  pedals_modifiers.decrementShiftHold(state, dt)

  pedals_modifiers.seedPipeline(state, state.cfg, throttle_raw, brake_raw, speed)

  local throttle_target = throttle_raw
  local brake_target = brake_raw

  throttle_target, brake_target = pedals_modifiers.applyNeutral(
    throttle_target,
    brake_target,
    gear,
    speed,
    state.cfg)

  brake_target = pedals_modifiers.applyPredictive(
    state,
    brake_target,
    speed,
    state.cfg)

  state.start_time = state.start_time + dt
  throttle_target = pedals_modifiers.applyShiftHold(state, throttle_target)
  throttle_target = pedals_modifiers.applySmoothStart(
    state,
    state.cfg,
    throttle_target,
    speed)

  local rate = state.cfg.rate_limit
  local ema = state.cfg.ema_tau
  local lerp = state.cfg.lerp_tau

  pedals_pipeline.stepChannel(
    state,
    "throttle",
    throttle_target,
    dt,
    rate.throttle_rise * state.rate_scale,
    rate.throttle_fall * state.rate_scale,
    ema.throttle,
    lerp.throttle)

  pedals_pipeline.stepChannel(
    state,
    "brake",
    brake_target,
    dt,
    rate.brake_rise,
    rate.brake_fall,
    ema.brake,
    lerp.brake)

  local throttle_out = pedals_arbitration.arbitrate(
    state.cfg,
    state.pipe.throttle.output,
    state.pipe.brake.output)

  local brake_out = state.pipe.brake.output

  throttle_out = pedals_diagnostics.sanitizeOut(
    state,
    throttle_out,
    throttle_raw,
    "throttle_out")
  brake_out = pedals_diagnostics.sanitizeOut(
    state,
    brake_out,
    brake_raw,
    "brake_out")

  throttle_out = pedals_arbitration.hardClampThrottle(
    state,
    state.cfg,
    throttle_out,
    dt,
    state.rate_scale)
  brake_out = pedals_arbitration.hardClampBrake(
    state,
    state.cfg,
    brake_out,
    dt)

  pedals_watchdog.updateHighThrottle(state, throttle_out, dt, gear, rpm)
  pedals_watchdog.updateRamp(state, throttle_out, throttle_raw, dt, gear, rpm)
  throttle_out = pedals_watchdog.updateStuck(
    state,
    throttle_out,
    throttle_raw,
    dt,
    pedals_diagnostics)

  pedals_overrides.write(state, throttle_out, brake_out, clutch_raw)

  pedals_diagnostics.recordBrakeFrame(
    state,
    dt,
    brake_target,
    brake_raw,
    throttle_out,
    brake_out)
  pedals_diagnostics.checkOutputs(state, throttle_out, brake_out)

  state.last_out = {
    engaged = true,
    throttle = throttle_out,
    brake = brake_out,
    clutch = math_utils.clampUnit(clutch_raw),
  }
end

-- Public commands are kept under the current extension name for compatibility.
soulPilotPedalsCmd = {}

function soulPilotPedalsCmd.on(config_path)
  state.cfg, state.cfg_from_file = pedals_config.load(
    type(config_path) == "string" and config_path or pedals_config.FALLBACK_CONFIG,
    notify)

  state.active = true
  pedals_state.reset(state)
  state.need_init = true
  state.init_from_zero = true
  state.clutch_written = false
  state.smooth_start_skipped = getSpeed() >= state.cfg.smooth_start.speed_mps

  local rate = state.cfg.rate_limit
  local config_label = state.cfg_from_file and "file" or "DEFAULTS"
  print(string.format(
    "soulPilotPedals: ON - rate thr %s/%s (units/s), brk %s/%s, cap %s, dt-independent",
    tostring(rate.throttle_rise),
    tostring(rate.throttle_fall),
    tostring(rate.brake_rise),
    tostring(rate.brake_fall),
    tostring(state.cfg.smooth_start.throttle_cap)))
  notify("INFO", string.format(
    "pedals ON (%s): rate thr %s/%s brk %s/%s, ema %s/%s, start cap %s",
    config_label,
    tostring(rate.throttle_rise),
    tostring(rate.throttle_fall),
    tostring(rate.brake_rise),
    tostring(rate.brake_fall),
    tostring(state.cfg.ema_tau.throttle),
    tostring(state.cfg.ema_tau.brake),
    tostring(state.cfg.smooth_start.throttle_cap)))
  return true
end

function soulPilotPedalsCmd.off()
  if not state.active then
    return false
  end

  state.active = false
  pedals_overrides.clear(state)
  pedals_state.reset(state)
  notify("INFO", "pedals OFF: override cleared (nil), state reset")
  return true
end

function soulPilotPedalsCmd.setRateScale(scale, duration)
  scale = math_utils.clampNumber(scale, 0.1, 1.0, 1.0)
  duration = math_utils.clampNumber(duration, 0, 10, 3.0)
  state.rate_scale = scale
  state.rate_scale_time = duration

  print(string.format(
    "soulPilotPedals: recovery mode ON - pedal rate %s for %.1f s",
    tostring(scale),
    duration))
  notify("INFO", string.format(
    "pedals recovery mode: rateScale %.2f for %.1fs",
    scale,
    duration))
  return true
end

function soulPilotPedalsCmd.status()
  pedals_status.printStatus(state)
  return true
end

function soulPilotPedalsGetState()
  return pedals_status.getState(state)
end

function M.onReset()
  pedals_overrides.clear(state)
  pedals_state.reset(state)
  state.need_init = true
  state.init_from_zero = true
  state.smooth_start_skipped = false
end

function M.onVehicleDestroyed()
  state.active = false
  state.overrides_written = false
  state.clutch_written = false
  pedals_state.reset(state)
end

return M
