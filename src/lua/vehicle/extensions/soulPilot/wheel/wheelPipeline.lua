-- soulPilot wheel pipeline: rate limit -> EMA -> lerp.

local math_utils = require("extensions.soulPilot.utils.mathUtils")

local M = {}

function M.stepWheel(state, target, dt)
  local config = state.cfg
  local pipe = state.pipe
  local rate_limit = config.rate_limit

  local rate = (
    (math.abs(target) > math.abs(pipe.rate_limited))
      and rate_limit.steer_rise
      or rate_limit.steer_fall
  ) * state.rate_scale

  pipe.rate_limited = math_utils.moveToward(pipe.rate_limited, target, rate * dt)
  pipe.ema = math_utils.emaStep(
    pipe.ema,
    pipe.rate_limited,
    dt,
    config.ema_tau.steer,
    1e-4)

  if config.lerp_tau.steer > 0 then
    pipe.output = math_utils.lerpStep(
      pipe.output,
      pipe.ema,
      dt,
      config.lerp_tau.steer,
      1e-3)
  else
    pipe.output = pipe.ema
  end

  pipe.output = math_utils.clampSymmetric(pipe.output)
end

return M
