-- soulPilot wheel output writer, init seeding and music offsets.

local math_utils = require("extensions.soulPilot.utils.mathUtils")

local M = {}

local function musicOffset(function_name)
  local function_ref = _G[function_name]
  if type(function_ref) ~= "function" then
    return 0
  end

  local ok, value = pcall(function_ref)
  if not ok then
    return 0
  end

  value = tonumber(value)
  if value == nil or value ~= value then
    return 0
  end
  return value
end

function M.initialize(state, target)
  if not state.need_init then
    return false
  end

  state.pipe.rate_limited = target
  state.pipe.ema = target
  state.pipe.output = target
  state.need_init = false
  state.rate_raw = 0
  state.rate_out = 0
  state.prev_rate_raw = target
  state.prev_rate_out = target
  return true
end

function M.write(state, value)
  electrics.values.steering_input = value
  state.last_out = { engaged = true, steer = value }
end

function M.getMusicOffset(function_name)
  return musicOffset(function_name)
end

function M.applyParkMusic(state)
  local offset = musicOffset("soulPilotMusicGetParkOffset")
    + musicOffset("soulPilotMusicGetBeatKick")
  if offset == 0 then
    return
  end

  local current = tonumber(electrics.values.steering_input) or 0
  electrics.values.steering_input = math_utils.clampSymmetric(current + offset)
end

return M
