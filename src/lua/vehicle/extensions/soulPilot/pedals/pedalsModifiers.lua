-- soulPilot pedals target modifiers.
-- These functions only change requested throttle/brake targets before the
-- smoothing pipeline runs.

local M = {}

local function isNeutralGear(gear)
  return gear == "0" or gear == "N" or gear == ""
end

function M.smoothStartFactor(state, cfg, speed)
  if state.smooth_start_skipped then
    return 1
  end

  local smooth_cfg = cfg.smooth_start
  if smooth_cfg.time_s <= 0 or smooth_cfg.speed_mps <= 0 then
    return 1
  end

  if state.start_time >= smooth_cfg.time_s and speed >= smooth_cfg.speed_mps then
    state.smooth_start_skipped = true
    return 1
  end

  local time_ramp = math.min(1, state.start_time / smooth_cfg.time_s)
  local speed_ramp = math.min(1, speed / smooth_cfg.speed_mps)
  return smooth_cfg.throttle_cap + (1 - smooth_cfg.throttle_cap) * math.min(time_ramp, speed_ramp)
end

function M.updateShift(state, cfg, gear, raw_throttle, rpm)
  if gear ~= state.last_gear then
    local previous_gear = state.last_gear
    state.last_gear = gear

    if previous_gear ~= ""
      and not isNeutralGear(previous_gear)
      and not isNeutralGear(gear)
      and (cfg.shift.hold_s or 0) > 0 then
      state.shift_hold_time = cfg.shift.hold_s
      state.shift_hold_value = state.pipe.throttle.output
      aplPrint(string.format(
        "soulPilotPedals: SHIFT %s->%s out=%.3f raw=%.3f ctrlThr=%s rpm=%.0f hold=%.1fs",
        previous_gear,
        gear,
        state.pipe.throttle.output,
        raw_throttle,
        tostring(electrics.values.throttle),
        tonumber(rpm) or 0,
        state.shift_hold_time))
      if state.notify then
        state.notify("INFO", string.format(
          "pedals shift %s->%s, hold %.1fs",
          previous_gear,
          gear,
          state.shift_hold_time))
      end
    elseif previous_gear ~= "" then
      state.shift_hold_time = 0
      aplPrint(string.format(
        "soulPilotPedals: SHIFT %s->%s out=%.3f raw=%.3f (neutral or hold disabled)",
        previous_gear,
        gear,
        state.pipe.throttle.output,
        raw_throttle))
    end
  end

end

function M.decrementShiftHold(state, dt)
  if state.shift_hold_time > 0 then
    state.shift_hold_time = math.max(0, state.shift_hold_time - dt)
  end
end

function M.seedPipeline(state, cfg, throttle_raw, brake_raw, speed)
  if not state.need_init then
    return
  end

  local seed = 0
  if not state.init_from_zero then
    seed = tonumber(state.last_out.throttle) or 0
    if seed ~= seed or seed < 0 then
      seed = 0
    end
    if seed > throttle_raw then
      seed = throttle_raw
    end
    seed = seed * M.smoothStartFactor(state, cfg, speed)
  end

  state.pipe.throttle.rate_limited = seed
  state.pipe.throttle.ema = seed
  state.pipe.throttle.output = seed
  state.pipe.brake.rate_limited = brake_raw
  state.pipe.brake.ema = brake_raw
  state.pipe.brake.output = brake_raw
  state.need_init = false
  state.resume_time = 0
end

function M.applyNeutral(throttle_target, brake_target, gear, speed, cfg)
  local neutral_cfg = cfg.neutral
  if (gear == "N" or gear == "0")
    and throttle_target > neutral_cfg.throttle_min
    and speed < neutral_cfg.speed_max_mps then
    throttle_target = 0
    if brake_target < neutral_cfg.brake then
      brake_target = neutral_cfg.brake
    end
  end
  return throttle_target, brake_target
end

function M.applyPredictive(state, brake_raw, speed, cfg)
  local predictive_cfg = cfg.predictive
  if state.predictive_on then
    if brake_raw < predictive_cfg.release_hyst then
      state.predictive_on = false
    end
  elseif brake_raw >= predictive_cfg.brake_threshold then
    state.predictive_on = true
  end

  local brake_target = brake_raw
  if state.predictive_on and speed > predictive_cfg.min_speed_mps then
    brake_target = math.min(1, brake_raw + predictive_cfg.lead)
  end
  return brake_target
end

function M.applyShiftHold(state, throttle_target)
  if state.shift_hold_time > 0 and throttle_target > state.shift_hold_value then
    return state.shift_hold_value
  end
  return throttle_target
end

function M.applySmoothStart(state, cfg, throttle_target, speed)
  return throttle_target * M.smoothStartFactor(state, cfg, speed)
end

return M
