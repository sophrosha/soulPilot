-- soulPilot GE diagnostics commands.
-- Graph/map/mark implementations live in diagnostics_graph.lua.

local M = {}

local logger = nil
local config_loader = nil
local graph = require("extensions.soulPilot.modules.diagnostics_graph")

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
  print("configPath(graph.json) = " .. tostring(config_loader.configPath("graph.json")))
  print("-----------------------------")
  return true
end

function M.aplExportGraph()
  return graph.aplExportGraph()
end

function M.aplMapDiag()
  return graph.aplMapDiag()
end

function M.aplMark(comment)
  return graph.aplMark(comment)
end

return M