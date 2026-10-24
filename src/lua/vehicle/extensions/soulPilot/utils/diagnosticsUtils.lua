-- soulPilot vehicle diagnostics helpers.
-- Formatting and range validation are kept separate from gameplay logic.

local math_utils = require("extensions.soulPilot.utils.mathUtils")

local M = {}

local GARBAGE_MARKER = "<GARBAGE>"

function M.isValidRange(value, min_value, max_value)
  local number = tonumber(value)
  if not math_utils.isFiniteNumber(number) then
    return false
  end
  if min_value ~= nil and number < min_value then
    return false
  end
  if max_value ~= nil and number > max_value then
    return false
  end
  return true
end

function M.formatRange(value, min_value, max_value, garbage_label)
  local number = tonumber(value)
  if not M.isValidRange(number, min_value, max_value) then
    local marker = garbage_label or GARBAGE_MARKER
    return tostring(value) .. ' ' .. marker
  end
  if math.abs(number) < 1e-6 then
    return '0.000000'
  end
  return tostring(number)
end

function M.formatUnit(value)
  return M.formatRange(value, 0, 1)
end

function M.formatSymmetric(value)
  return M.formatRange(value, -1.0001, 1.0001)
end

function M.formatRate(value)
  local number = tonumber(value)
  if not math_utils.isFiniteNumber(number) then
    return 'n/a'
  end
  return string.format('%.3f', number)
end

function M.sanitizeUnit(value, raw_fallback, tag, warned, warn)
  local number = tonumber(value)
  local is_bad = not M.isValidRange(number, 0, 1)

  if is_bad then
    if warned and tag and not warned[tag] then
      warned[tag] = true
      if warn then
        warn(string.format(
          'GARBAGE at output %s = %s -> fallback raw %s (clamped to [0,1])',
          tostring(tag),
          tostring(value),
          M.formatUnit(math_utils.clampUnit(math_utils.safeNumber(raw_fallback)))))
      end
    end
    return math_utils.clampUnit(math_utils.safeNumber(raw_fallback))
  end

  if warned and tag then
    warned[tag] = nil
  end
  return number
end

function M.clearWarnings(warned)
  if warned == nil then
    return
  end
  for key in pairs(warned) do
    warned[key] = nil
  end
end

return M
