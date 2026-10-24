-- soulPilot GE diagnostics commands.

local M = {}

local logger = nil
local config_loader = nil

function M.init(config_module, logger_module)
  config_loader = config_module
  logger = logger_module
end

function M.aplDiag()
  local user_path = (FS and FS:getUserPath() or ""):gsub("\\", "/")
  print("--- soulPilot diagnostics ---")
  print("userPath = " .. (user_path ~= "" and user_path or "(unavailable)"))
  print("configPath(wheel.json) = " .. tostring(config_loader.configPath("wheel.json")))
  print("configPath(pedals.json) = " .. tostring(config_loader.configPath("pedals.json")))
  print("-----------------------------")
  return true
end

function M.aplMapDiag()
  local map_data = map and map.getMap and map.getMap() or nil
  local nodes = map_data and map_data.nodes or nil
  local count = 0
  if nodes then
    for _ in pairs(nodes) do
      count = count + 1
    end
  end
  print("--- soulPilot map diagnostics ---")
  print("nodes=" .. tostring(count) .. ", buildSerial=" .. tostring(map_data and map_data.buildSerial or "?"))
  print("--------------------------------")
  return true
end

function M.aplExportGraph()
  print("apl_exportGraph: graph export is not available in the modular GE build")
  if logger then
    logger.logLine("WARN", "graph export is not available")
  end
  return false
end

function M.aplMark(comment)
  print("apl_mark: " .. tostring(comment or ""))
  return true
end

return M
