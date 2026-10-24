-- soulPilot GE UI/debug bridge.

local M = {}

local logger = nil
local csv = nil
local bridge = nil

function M.init(logger_module, csv_module, vehicle_bridge)
  logger = logger_module
  csv = csv_module
  bridge = vehicle_bridge
end

function M.setDebug(enabled)
  if logger then
    logger.setDebug(enabled)
  end
  if csv and enabled then
    csv.start()
  elseif csv and not enabled then
    csv.stop()
  end
  if bridge then
    bridge.sendToVehicle("soulPilotCmd.setDebug(" .. tostring(enabled) .. ")")
  end
  return enabled
end

function M.getDebug()
  return logger and logger.isDebug() or false
end

function M.getStatus()
  return {
    debug = M.getDebug(),
    log_path = logger and logger.getLogPath() or nil,
    csv_active = csv and csv.isActive() or false,
  }
end

return M
