-- soulPilot pedals diagnostics and logging helpers.

local diagnostics_utils = require("extensions.soulPilot.utils.diagnosticsUtils")

local M = {}

local HISTORY_SIZE = 5

local function notify(state, level, message)
  if state.notify then
    state.notify(level, message)
  end
end

local function isBadPre(value)
  return value == nil or value ~= value or value == math.huge or value == -math.huge
end

function M.formatUnit(value)
  return diagnostics_utils.formatUnit(value)
end

function M.formatRate(value)
  return diagnostics_utils.formatRate(value)
end

function M.diagBad(value)
  return not diagnostics_utils.isValidRange(value, 0, 1)
end

function M.warnPipelineGarbage(state, tag, target, dt, rate, channel)
  local bad_pre = isBadPre(channel.rate_limited)
    or isBadPre(channel.ema)
    or isBadPre(channel.output)
    or isBadPre(target)

  if bad_pre and not state.step_garbage_warned[tag] then
    state.step_garbage_warned[tag] = true
    notify(state, "WARN", string.format(
      "pedals: GARBAGE in pipeline [%s] before clamp: rl=%s ema=%s out=%s target=%s dt=%s rate=%s",
      tag,
      M.formatUnit(channel.rate_limited),
      M.formatUnit(channel.ema),
      M.formatUnit(channel.output),
      M.formatUnit(target),
      tostring(dt),
      tostring(rate)))
  elseif not bad_pre then
    state.step_garbage_warned[tag] = nil
  end
end

function M.sanitizeOut(state, value, raw_fallback, tag)
  return diagnostics_utils.sanitizeUnit(
    value,
    raw_fallback,
    tag,
    state.out_garbage_warned,
    function(message)
      notify(state, "WARN", "pedals: " .. message)
    end)
end

function M.dumpBrakeHistory(state, reason, extra)
  local lines = { "BRAKE TRAP: " .. reason .. (extra and (" | " .. extra) or "") }
  for index = 1, HISTORY_SIZE do
    lines[#lines + 1] = "  frame-" .. index .. ": " ..
      (state.diag_hist[(state.diag_n - index) % HISTORY_SIZE + 1] or "n/a")
  end

  notify(state, "WARN", "pedals DIAG: " .. table.concat(lines, " || "))
  print("soulPilotPedals DIAG: " .. table.concat(lines, "\n"))

  pcall(function()
    local file = io.open("mods/unpacked/soulPilot/ai/logs/brake_anomaly.txt", "a")
    if file then
      file:write(os.date("%Y-%m-%d %H:%M:%S") .. "\n" .. table.concat(lines, "\n") .. "\n")
      file:close()
    end
  end)
end

function M.recordBrakeFrame(state, dt, brake_target, brake_raw, throttle_out, brake_out)
  state.diag_n = state.diag_n + 1
  state.diag_hist[(state.diag_n - 1) % HISTORY_SIZE + 1] =
    "dt=" .. tostring(dt) ..
    " tgt=" .. tostring(brake_target) ..
    " raw.brk=" .. tostring(brake_raw) ..
    " | rl=" .. tostring(state.pipe.brake.rate_limited) ..
    " ema=" .. tostring(state.pipe.brake.ema) ..
    " out=" .. tostring(state.pipe.brake.output) ..
    " | thrOut=" .. tostring(throttle_out) ..
    " brkOut=" .. tostring(brake_out)
end

function M.checkOutputs(state, throttle_out, brake_out)
  if not M.diagBad(brake_out) and not M.diagBad(throttle_out) then
    return
  end
  M.dumpBrakeHistory(
    state,
    "FINAL CHECK caught garbage before electrics/last_out",
    string.format("brkOut=%s thrOut=%s", tostring(brake_out), tostring(throttle_out)))
end

function M.clearWarnings(state)
  state.step_garbage_warned = {}
  state.out_garbage_warned = {}
end

return M
