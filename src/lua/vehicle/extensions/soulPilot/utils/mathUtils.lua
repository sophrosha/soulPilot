-- soulPilot vehicle math helpers.
-- Pure functions only: no vehicle state, no logging, no side effects.

local M = {}

local function isFiniteNumber(value)
  value = tonumber(value)
  if value == nil or value ~= value then
    return false
  end
  if value == math.huge or value == -math.huge then
    return false
  end
  return true
end

function M.isFiniteNumber(value)
  return isFiniteNumber(value)
end

function M.safeNumber(value, fallback)
  local number = tonumber(value)
  if number == nil or number ~= number then
    return fallback or 0
  end
  if number == math.huge or number == -math.huge then
    return fallback or 0
  end
  return number
end

function M.clampNumber(value, min_value, max_value, fallback)
  local number = tonumber(value)
  if number == nil or number ~= number then
    return fallback or 0
  end
  if min_value ~= nil and number < min_value then
    return min_value
  end
  if max_value ~= nil and number > max_value then
    return max_value
  end
  return number
end

function M.clampUnit(value)
  return M.clampNumber(value, 0, 1, 0)
end

function M.clampSymmetric(value)
  return M.clampNumber(value, -1, 1, 0)
end

function M.moveToward(current, target, max_step)
  local delta = target - current
  if delta > max_step then
    return current + max_step
  end
  if delta < -max_step then
    return current - max_step
  end
  return target
end

local function exponentialStep(current, target, dt, tau, snap_epsilon)
  if tau == nil or tau <= 0 or dt == nil or dt <= 0 then
    return target
  end

  local next_value = current + (target - current) * (1 - math.exp(-dt / tau))
  if snap_epsilon ~= nil and math.abs(next_value - target) < snap_epsilon then
    return target
  end
  return next_value
end

function M.emaStep(current, target, dt, tau, snap_epsilon)
  return exponentialStep(current, target, dt, tau, snap_epsilon)
end

function M.lerpStep(current, target, dt, tau, snap_epsilon)
  return exponentialStep(current, target, dt, tau, snap_epsilon)
end

function M.exponentialAlpha(dt, tau)
  if tau == nil or tau <= 0 or dt == nil or dt <= 0 then
    return 1
  end
  return 1 - math.exp(-dt / tau)
end

return M
