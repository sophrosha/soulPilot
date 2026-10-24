-- soulPilot vehicle-to-GE bridge.
-- Keeps the vehicle modules free of duplicated queueGameEngineLua snippets.

local M = {}

local function quoteLuaString(value)
  local escaped = tostring(value):gsub('\\', '\\\\')
  escaped = escaped:gsub('"', '\\"')
  escaped = escaped:gsub('\r', '\\r')
  escaped = escaped:gsub('\n', '\\n')
  return '"' .. escaped .. '"'
end

function M.sendToGameEngine(level, message)
  local normalized_level = tostring(level or 'INFO'):upper()
  local ok = pcall(function()
    obj:queueGameEngineLua(string.format(
      'if extensions and extensions.soulPilot_main and extensions.soulPilot_main.onVehicleLog then extensions.soulPilot_main.onVehicleLog(%s, %s) end',
      quoteLuaString(normalized_level),
      quoteLuaString(message)))
  end)
  return ok
end

function M.quoteLuaString(value)
  return quoteLuaString(value)
end

return M
