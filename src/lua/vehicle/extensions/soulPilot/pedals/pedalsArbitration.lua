-- soulPilot pedals arbitration and output clamps.

local math_utils = require("extensions.soulPilot.utils.mathUtils")

local M = {}

function M.arbitrate(cfg, throttle_out, brake_out)
  local brake_start = cfg.arbitration.brake_start
  local brake_full = cfg.arbitration.brake_full
  local cut = 1

  if brake_out > brake_start then
    cut = 1 - (brake_out - brake_start) / (brake_full - brake_start)
    if cut < 0 then
      cut = 0
    end
  end

  return throttle_out * cut
end

function M.hardClampThrottle(state, cfg, desired, dt, rate_scale)
  local previous = math_utils.clampUnit(state.last_out.throttle)
  local up = (cfg.rate_limit.throttle_rise or 2.0) * rate_scale * dt
  local down = (cfg.rate_limit.throttle_fall or 3.0) * rate_scale * dt

  if desired > previous + up then
    desired = previous + up
  end
  if desired < previous - down then
    desired = previous - down
  end
  return math_utils.clampUnit(desired)
end

function M.hardClampBrake(state, cfg, desired, dt)
  local previous = math_utils.clampUnit(state.last_out.brake)
  local up = (cfg.rate_limit.brake_rise or 1.7) * dt
  local down = (cfg.rate_limit.brake_fall or 2.5) * dt

  if desired > previous + up then
    desired = previous + up
  end
  if desired < previous - down then
    desired = previous - down
  end
  return math_utils.clampUnit(desired)
end

return M
