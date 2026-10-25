-- soulPilot GE CSV recording.

local M = {}

local bridge = nil
local logger = nil
local active = false
local vehicle_id = nil
local auto_enabled = true

function M.init(vehicle_bridge, logger_module)
  bridge = vehicle_bridge
  logger = logger_module
end

function M.isActive()
  return active
end

function M.getVehicleId()
  return vehicle_id
end

function M.start()
  if active then
    if logger then
      logger.logLine("INFO", "CSV already recording, duplicate start ignored")
    end
    return false
  end

  local data_dir = logger and logger.getDataDir() or nil
  if not data_dir then
    if logger then
      logger.logLine("ERROR", "CSV did not start: data directory unavailable")
    end
    return false
  end

  local stamp = os.date("%Y-%m-%d_%H-%M-%S")
  local path = (data_dir.csv .. stamp .. "_drive.csv"):gsub("\\", "/")
  local vehicle = bridge.sendToVehicle(string.format('soulPilotCmd.startCsv("%s")', path))
  if not vehicle then
    return false
  end

  active = true
  local ok, id = pcall(function()
    return vehicle:getID()
  end)
  vehicle_id = ok and id or nil

  local real_path = ""
  pcall(function()
    real_path = FS:getFileRealPath(path) or ""
    if real_path == "" then
      local real_dir = FS:getFileRealPath(data_dir.csv) or ""
      if real_dir ~= "" then
        real_path = real_dir .. stamp .. "_drive.csv"
      end
    end
  end)
  if real_path == "" then
    real_path = path
  end

  logger.debugPrint("CSV: " .. real_path)
  if logger then
    logger.logLine("INFO", "CSV requested: " .. path .. " (real: " .. real_path .. ")")
  end
  return true
end

function M.stop()
  if not active then
    return false
  end

  if bridge.sendToVehicle("soulPilotCmd.stopCsv()") then
    active = false
    vehicle_id = nil
    if logger then
      logger.logLine("INFO", "CSV recording stopped")
    end
    return true
  end
  return false
end

function M.autoStart(reason)
  if not auto_enabled then
    return false
  end
  if active then
    logger.debugPrint("soulPilot: CSV already active, auto_csv skipped (" .. tostring(reason) .. ")")
    return false
  end
  if not M.start() then
    return false
  end
  logger.debugPrint("soulPilot: CSV started automatically (" .. tostring(reason) .. ")")
  if logger then
    logger.logLine("INFO", "auto_csv: started for " .. tostring(reason))
  end
  return true
end

return M
