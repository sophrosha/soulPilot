-- soulPilot pedals pipeline: rate limit -> EMA -> lerp.

local math_utils = require("extensions.soulPilot.utils.mathUtils")
local diagnostics = require("extensions.soulPilot.pedals.pedalsDiagnostics")

local M = {}

function M.stepChannel(state, name, target, dt, rate_up, rate_down, ema_tau, lerp_tau)
  local channel = state.pipe[name]
  local rate = target > channel.rate_limited and rate_up or rate_down

  channel.rate_limited = math_utils.moveToward(channel.rate_limited, target, rate * dt)
  channel.ema = math_utils.emaStep(channel.ema, channel.rate_limited, dt, ema_tau)
  channel.output = math_utils.lerpStep(
    channel.output,
    channel.ema,
    dt,
    lerp_tau,
    1e-3)

  diagnostics.warnPipelineGarbage(state, name, target, dt, rate, channel)

  channel.output = math_utils.clampUnit(channel.output)
  channel.rate_limited = math_utils.clampUnit(channel.rate_limited)
  channel.ema = math_utils.clampUnit(channel.ema)
end

return M
