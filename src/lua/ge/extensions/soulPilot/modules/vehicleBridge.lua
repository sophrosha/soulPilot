-- soulPilot GE vehicle bridge.

local M = {}

local logger = nil
local fallback_vehicle_id = nil

function M.init(logger_module)
  logger = logger_module
end

function M.getVehicle()
  if not (getPlayerVehicle) then
    return nil
  end
  return getPlayerVehicle(0)
end

function M.getFallbackVehicle()
  if not fallback_vehicle_id or not getObjectByID then
    return nil
  end
  local ok, vehicle = pcall(getObjectByID, fallback_vehicle_id)
  if ok then
    return vehicle
  end
  return nil
end

function M.setFallbackVehicle(vehicle_id)
  fallback_vehicle_id = vehicle_id
end

function M.getFallbackVehicleId()
  return fallback_vehicle_id
end

function M.sendToVehicle(command)
  local vehicle = M.getVehicle()
  if not vehicle then
    vehicle = M.getFallbackVehicle()
  end

  if not vehicle then
    if logger then
      logger.logLine("WARN", "Player vehicle not found, command not sent: " .. tostring(command))
    end
    return nil
  end

  local ok, error_message = pcall(function()
    vehicle:queueLuaCommand(command)
  end)
  if not ok then
    if logger then
      logger.logLine("WARN", "queueLuaCommand failed: " .. tostring(command) .. " : " .. tostring(error_message))
    end
    return nil
  end
  return vehicle
end

function M.sendToGameEngine(level, message)
  if logger then
    logger.logLine(level, message, "vehicle")
  end
end

return M
