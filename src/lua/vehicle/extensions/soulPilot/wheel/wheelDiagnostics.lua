-- soulPilot wheel diagnostics and status output.

local diagnostics_utils = require("extensions.soulPilot.utils.diagnosticsUtils")
local math_utils = require("extensions.soulPilot.utils.mathUtils")

local M = {}

local RATE_EMA_TAU = 0.15

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

function M.formatSymmetric(value)
  return diagnostics_utils.formatSymmetric(value)
end

function M.formatRate(value)
  return diagnostics_utils.formatRate(value)
end

function M.sanitizeSteering(value)
  local number = tonumber(value)
  if number == nil or number ~= number then
    return 0
  end
  return math_utils.clampSymmetric(number)
end

function M.resetRateStats(state)
  state.rate_raw = 0
  state.rate_out = 0
  state.prev_rate_raw = nil
  state.prev_rate_out = nil
end

function M.updateRateStats(state, raw, output, dt)
  if state.prev_rate_raw ~= nil and dt > 0 then
    local alpha = 1 - math.exp(-dt / RATE_EMA_TAU)
    local raw_instant = (raw - state.prev_rate_raw) / dt
    local out_instant = (output - state.prev_rate_out) / dt
    state.rate_raw = state.rate_raw + (raw_instant - state.rate_raw) * alpha
    state.rate_out = state.rate_out + (out_instant - state.rate_out) * alpha
  end

  state.prev_rate_raw = raw
  state.prev_rate_out = output
end

function M.printStatus(state)
  local lines = {
    "--- soulPilot wheel status ---",
    string.format(
      "active=%s engaged=%s aiDriving=%s config=%s",
      tostring(state.active),
      tostring(state.last_out.engaged),
      tostring(isAiDriving()),
      configLabel(state)),
    string.format(
      "steer: clipped-raw %s -> out %s (normalized [-1,1], 1.0=lock)",
      M.formatSymmetric(state.last_raw),
      M.formatSymmetric(state.last_out.steer)),
    string.format(
      "pipe: rl %s ema %s out %s",
      M.formatSymmetric(state.pipe.rate_limited),
      M.formatSymmetric(state.pipe.ema),
      M.formatSymmetric(state.pipe.output)),
    string.format(
      "rate (EMA %.2f s): raw %s/s, out %s/s",
      RATE_EMA_TAU,
      M.formatRate(state.rate_raw),
      M.formatRate(state.rate_out)),
    string.format(
      "raw=%s out=%s |delta|=%s",
      M.formatSymmetric(state.last_raw),
      M.formatSymmetric(state.pipe.output),
      M.formatSymmetric(math.abs((tonumber(state.last_raw) or 0) - state.pipe.output))),
    string.format(
      "rateScale=%s",
      string.format("%.2f", state.rate_scale)),
  }

  for _, line in ipairs(lines) do
    print("soulPilotWheel: " .. line)
  end

  if state.notify then
    state.notify(
      "INFO",
      "wheel status: active=" .. tostring(state.active)
        .. " engaged=" .. tostring(state.last_out.engaged)
        .. " steer " .. M.formatSymmetric(state.last_raw)
        .. "->" .. M.formatSymmetric(state.last_out.steer)
        .. " rate raw/out " .. M.formatRate(state.rate_raw)
        .. "/" .. M.formatRate(state.rate_out) .. "/s")
  end
end

function M.getState(state)
  return {
    active = state.active,
    engaged = state.last_out.engaged,
    steer = state.last_out.steer,
  }
end

return M
