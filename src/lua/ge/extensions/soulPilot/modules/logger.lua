-- soulPilot GE logger: console, file and data-directory resolution.

local M = {}

local LOG_TAG = "soulPilot"

M.debug_enabled = false
M.data_dir = nil
M.dirs_tried = {}
M.log_file_handle = nil
M.log_file_path = nil

local function getDataDirs()
  return {
    {
      name = "mod",
      csv = "mods/unpacked/soulPilot/ai/csv/",
      logs = "mods/unpacked/soulPilot/ai/logs/",
    },
    {
      name = "fallback",
      csv = "soulPilot_logs/csv/",
      logs = "soulPilot_logs/logs/",
    },
  }
end

local function dirWritable(directory)
  local created = pcall(function()
    if not FS:directoryExists(directory) then
      FS:directoryCreate(directory, true)
    end
  end)
  if not created then
    return false
  end

  local probe = directory .. ".__soul_pilot_probe"
  local file = io.open(probe, "w")
  if not file then
    return false
  end
  file:write("probe")
  file:close()
  os.remove(probe)
  return true
end

function M.resolveDataDir()
  for _, candidate in ipairs(getDataDirs()) do
    M.dirs_tried[#M.dirs_tried + 1] = candidate.name .. "=" .. candidate.csv
    if dirWritable(candidate.csv) and dirWritable(candidate.logs) then
      return candidate
    end
  end
  return nil
end

function M.logLine(level, message, tag)
  local line = string.format(
    "%s [%s] [%s] %s",
    os.date("%Y-%m-%d %H:%M:%S"),
    level,
    tag or LOG_TAG,
    tostring(message))

  if level == "ERROR" or level == "WARN" or M.debug_enabled then
    log(level == "ERROR" and "E" or (level == "WARN" and "W" or "I"), LOG_TAG, message)
  end

  if not M.log_file_handle then
    return
  end
  M.log_file_handle:write(line .. "\r\n")
  M.log_file_handle:flush()
end

function M.openLogFile()
  if M.log_file_handle then
    return true
  end

  if not M.data_dir then
    M.data_dir = M.resolveDataDir()
    if not M.data_dir then
      log("E", LOG_TAG, "No writable data directory. Tried: " .. table.concat(M.dirs_tried, "; "))
      return false
    end
    M.logLine("INFO", "Data directory: " .. M.data_dir.name .. " (" .. M.data_dir.logs .. ")")
  end

  local path = M.data_dir.logs .. os.date("%Y-%m-%d_%H-%M-%S") .. "_mod.txt"
  local file, error_message = io.open(path, "w")
  if not file then
    log("E", LOG_TAG, "Could not open log file: " .. tostring(path) .. " : " .. tostring(error_message))
    return false
  end

  M.log_file_handle = file
  M.log_file_path = path
  M.logLine("INFO", "Log file opened: " .. path)
  return true
end

function M.closeLogFile()
  if not M.log_file_handle then
    return
  end
  M.log_file_handle:write(string.format(
    "%s [INFO] [%s] Log file closed\r\n",
    os.date("%Y-%m-%d %H:%M:%S"),
    LOG_TAG))
  M.log_file_handle:close()
  M.log_file_handle = nil
end

function M.setDebug(enabled)
  M.debug_enabled = enabled == true
  if M.debug_enabled then
    M.openLogFile()
  else
    M.closeLogFile()
  end
  return M.debug_enabled
end

function M.isDebug()
  return M.debug_enabled
end

function M.debugPrint(...)
  if M.debug_enabled then
    print(...)
  end
end

function M.getDataDir()
  return M.data_dir
end

function M.getLogPath()
  return M.log_file_path
end

function M.getDirsTried()
  return M.dirs_tried
end

function M.init()
  M.data_dir = M.resolveDataDir()
  if M.data_dir then
    M.logLine("INFO", "soulPilot GE layer loaded, data directory: " .. M.data_dir.name)
  else
    log("E", LOG_TAG, "No data directories available. Tried: " .. table.concat(M.dirs_tried, "; "))
  end
end

return M
