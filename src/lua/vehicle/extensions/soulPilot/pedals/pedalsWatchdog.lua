-- soulPilot pedals watchdogs and frame diagnostics.

local M = {}

local function notify(state, level, message)
  if state.notify then
    state.notify(level, message)
  end
end

function M.updateRawHold(state, throttle_raw, dt)
  if math.abs(throttle_raw - state.last_raw_sample) > 1e-6 then
    state.last_raw_sample = throttle_raw
    state.raw_hold_time = 0
  else
    state.raw_hold_time = state.raw_hold_time + dt
  end
end

function M.updateHighThrottle(state, throttle_out, dt, gear, rpm)
  if throttle_out > 0.9 then
    state.throttle_high_time = state.throttle_high_time + dt
  else
    state.throttle_high_time = 0
    state.throttle_high_warn_acc = 0
  end

  if state.throttle_high_time >= 5.0 then
    state.throttle_high_warn_acc = state.throttle_high_warn_acc + dt
    if state.throttle_high_warn_acc >= 5.0 then
      state.throttle_high_warn_acc = 0
      print(string.format(
        "soulPilotPedals: WARN throttle %.0f%% for %.0f s - gear=%s rpm=%.0f",
        throttle_out * 100,
        state.throttle_high_time,
        gear,
        rpm))
      notify(state, "WARN", string.format(
        "pedals: throttle %.0f%% for %.0f s, gear=%s rpm=%.0f",
        throttle_out * 100,
        state.throttle_high_time,
        gear,
        rpm))
    end
  end
end

function M.updateRamp(state, throttle_out, throttle_raw, dt, gear, rpm)
  local previous = tonumber(state.last_out.throttle) or 0
  if throttle_out > previous + 1e-6 and throttle_out > 0.02 and throttle_out < 0.98 then
    state.ramp_time = state.ramp_time + dt
    if state.ramp_time >= 0.2 then
      state.ramp_time = 0
      aplPrint(string.format(
        "soulPilotPedals: ramp out=%.2f raw=%.2f gear=%s rpm=%.0f",
        throttle_out,
        throttle_raw,
        gear,
        rpm))
    end
  else
    state.ramp_time = 0
  end
end

function M.updateStuck(state, throttle_out, throttle_raw, dt, diagnostics)
  if state.resume_time > 0.5 and throttle_out > 0.9 and throttle_raw < 0.05 then
    state.stuck_time = state.stuck_time + dt
  else
    state.stuck_time = 0
    state.stuck_warned = false
  end

  if state.stuck_time <= 2.0 then
    return throttle_out
  end

  if not state.stuck_warned then
    state.stuck_warned = true
    local source = "?"
    pcall(function()
      source = tostring(input.state.throttle.source)
    end)
    notify(state, "WARN", string.format(
      "pedals: THROTTLE STUCK - out=%s with raw=%s (raw unchanged %.1f s, source=%s), resync to raw",
      diagnostics.formatUnit(throttle_out),
      diagnostics.formatUnit(throttle_raw),
      state.raw_hold_time,
      source))
    print("soulPilotPedals: WARN throttle stuck - resync pipeline to raw")
    diagnostics.dumpBrakeHistory(
      state,
      "WATCHDOG: throttle stuck",
      string.format(
        "raw=%s out=%s pipe.rl=%s pipe.ema=%s pipe.out=%s rawHold=%.1f",
        tostring(throttle_raw),
        tostring(throttle_out),
        tostring(state.pipe.throttle.rate_limited),
        tostring(state.pipe.throttle.ema),
        tostring(state.pipe.throttle.output),
        state.raw_hold_time))
  end

  state.pipe.throttle.rate_limited = throttle_raw
  state.pipe.throttle.ema = throttle_raw
  state.pipe.throttle.output = throttle_raw
  return throttle_raw
end

return M
