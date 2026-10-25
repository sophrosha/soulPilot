-- soulPilot GE commands and legacy aliases.

local M = {}

local logger = nil
local csv = nil
local bridge = nil
local config_loader = nil
local master = nil
local lights = nil
local pet = nil
local popup = nil
local pain = nil
local diagnostics = nil
local ui = nil

local wheel_requested = false
local pedals_requested = false
local warmup_requested = false
local lock_enabled = false

local LOCK_FILTER = "soulPilotLockedActions"

function M.init(context)
  logger = context.logger
  csv = context.csv
  bridge = context.bridge
  config_loader = context.config_loader
  master = context.master
  lights = context.lights
  pet = context.pet
  popup = context.popup
  pain = context.pain
  diagnostics = context.diagnostics
  ui = context.ui
end

function M.isWheelRequested()
  return wheel_requested
end

function M.isPedalsRequested()
  return pedals_requested
end

function M.isLightsAuto()
  return lights ~= nil and lights.isAuto ~= nil and lights.isAuto() or false
end

function M.isPopupAuto()
  return popup ~= nil and popup.isAuto ~= nil and popup.isAuto() or false
end

function M.isPainAuto()
  return pain ~= nil and pain.isActive() or false
end

function M.setWarmupRequested(value)
  warmup_requested = value == true
end

function M.setWheelRequested(value)
  wheel_requested = value == true
end

function M.setPedalsRequested(value)
  pedals_requested = value == true
end

local function configExists(path)
  return FS and FS:fileExists(path) or false
end

local function autoCsv(reason)
  if csv then
    csv.autoStart(reason)
  end
end

function M.aplWheel(mode)
  mode = tostring(mode or ""):lower()
  local path = config_loader.configPath("wheel.json")

  if mode == "on" then
    if not configExists(path) then
      print("WARN apl_wheel: config not found (" .. tostring(path) .. "), vehicle will use defaults")
    end
    local vehicle = bridge.sendToVehicle(string.format('soulPilotWheelCmd.on("%s")', path))
    if vehicle then
      wheel_requested = true
      logger.debugPrint("apl_wheel: ON (config: " .. tostring(path) .. ")")
      if logger then
        logger.logLine("INFO", "apl_wheel ON, conf=" .. tostring(path))
      end
      autoCsv("apl_wheel")
    end
    return true
  end

  if mode == "off" then
    local command = 'local ok, off = pcall(function() return soulPilotWheelCmd.off() end); '
      .. 'print("soulPilotWheel: off round-trip ok=" .. tostring(ok) .. " off=" .. tostring(off)); '
      .. 'pcall(function() soulPilotWheelCmd.status() end)'
    if bridge.sendToVehicle(command) then
      wheel_requested = false
      logger.debugPrint("apl_wheel: OFF sent")
      if logger then
        logger.logLine("INFO", "apl_wheel OFF sent")
      end
    end
    return true
  end

  if mode == "status" then
    print("apl_wheel GE: requested=" .. tostring(wheel_requested)
      .. ", config=" .. tostring(path)
      .. " (exists=" .. tostring(configExists(path)) .. ")")
    if not bridge.sendToVehicle("soulPilotWheelCmd.status()") then
      print("WARN apl_wheel: player vehicle not found")
    end
    return true
  end

  print('Usage: apl_wheel("on"|"off"|"status")')
  return false
end

function M.aplPedals(mode)
  mode = tostring(mode or ""):lower()
  local path = config_loader.configPath("pedals.json")

  if mode == "on" then
    if not configExists(path) then
      print("WARN apl_pedals: config not found (" .. tostring(path) .. "), vehicle will use defaults")
    end
    local vehicle = bridge.sendToVehicle(string.format('soulPilotPedalsCmd.on("%s")', path))
    if vehicle then
      pedals_requested = true
      logger.debugPrint("apl_pedals: ON (config: " .. tostring(path) .. ")")
      if logger then
        logger.logLine("INFO", "apl_pedals ON, conf=" .. tostring(path))
      end
      autoCsv("apl_pedals")
    end
    return true
  end

  if mode == "off" then
    local command = 'local ok, off = pcall(function() return soulPilotPedalsCmd.off() end); '
      .. 'print("soulPilotPedals: off round-trip ok=" .. tostring(ok) .. " off=" .. tostring(off)); '
      .. 'pcall(function() soulPilotPedalsCmd.status() end)'
    if bridge.sendToVehicle(command) then
      pedals_requested = false
      logger.debugPrint("apl_pedals: OFF sent")
      if logger then
        logger.logLine("INFO", "apl_pedals OFF sent")
      end
    end
    return true
  end

  if mode == "status" then
    print("apl_pedals GE: requested=" .. tostring(pedals_requested)
      .. ", config=" .. tostring(path)
      .. " (exists=" .. tostring(configExists(path)) .. ")")
    if not bridge.sendToVehicle("soulPilotPedalsCmd.status()") then
      print("WARN apl_pedals: player vehicle not found")
    end
    return true
  end

  print('Usage: apl_pedals("on"|"off"|"status")')
  return false
end

function M.aplWarmup(mode)
  mode = tostring(mode or "start"):lower()
  local path = config_loader.configPath("warmup.json")

  if mode == "start" then
    if not configExists(path) then
      print("WARN apl_warmup: config not found (" .. tostring(path) .. "), vehicle will use defaults")
    end
    local vehicle = bridge.sendToVehicle(string.format('soulPilotWarmupCmd.on("%s")', path))
    if vehicle then
      warmup_requested = true
      logger.debugPrint("apl_warmup: START (config: " .. tostring(path) .. ")")
      autoCsv("apl_warmup")
    end
    return true
  end

  if mode == "off" then
    if bridge.sendToVehicle("soulPilotWarmupCmd.off()") then
      warmup_requested = false
      logger.debugPrint("apl_warmup: OFF sent")
    end
    return true
  end

  if mode == "status" then
    print("apl_warmup GE: running=" .. tostring(warmup_requested)
      .. ", config=" .. tostring(path))
    bridge.sendToVehicle("soulPilotWarmupCmd.status()")
    return true
  end

  print('Usage: apl_warmup("start"|"off"|"status")')
  return false
end

function M.aplAutopilot(mode)
  return master.aplAutopilot(mode)
end

function M.aplAutopilotState()
  return master.getState()
end

function M.aplLights(mode, value)
  return lights.aplLights(mode, value)
end

function M.aplPet(mode)
  return pet.aplPet(mode)
end

function M.aplPetActive()
  return pet.isActive()
end

function M.aplPopup(mode)
  return popup.aplPopup(mode)
end

function M.aplPain(mode)
  return pain.aplPain(mode)
end

function M.aplDebug()
  local enabled = not (logger and logger.isDebug())
  if ui then
    ui.setDebug(enabled)
  end
  if logger then
    logger.logLine("INFO", enabled and "=== DEBUG ENABLED ===" or "=== DEBUG DISABLED ===")
  end
  if bridge then
    bridge.sendToVehicle("soulPilotCmd.setDebug(" .. tostring(enabled) .. ")")
  end
  return enabled
end

function M.aplDebugSet(enabled)
  enabled = enabled == true or enabled == 1
  if ui then
    ui.setDebug(enabled)
  end
  if bridge then
    bridge.sendToVehicle("soulPilotCmd.setDebug(" .. tostring(enabled) .. ")")
  end
  print("apl_debug_set: " .. tostring(enabled))
  return enabled
end

local function applyLock(enabled)
  local ok = pcall(function()
    if not core_input_actionFilter then
      error("core_input_actionFilter is not available")
    end
    core_input_actionFilter.setGroup(LOCK_FILTER, { "toggleWalkingMode" })
    core_input_actionFilter.addAction(0, LOCK_FILTER, enabled == true)
  end)
  if not ok then
    print("WARN apl_lock: input action filter is not available")
    return false
  end
  lock_enabled = enabled == true
  return true
end

function M.aplLock(mode)
  mode = tostring(mode or ""):lower()

  if mode == "on" then
    if lock_enabled then
      print("apl_lock: already ON")
      return false
    end
    if not applyLock(true) then
      return false
    end
    print("apl_lock: ON - driver exit is blocked")
    if logger then
      logger.logLine("INFO", "apl_lock ON")
    end
    return true
  end

  if mode == "off" then
    if not lock_enabled then
      print("apl_lock: already OFF")
      return false
    end
    if not applyLock(false) then
      return false
    end
    print("apl_lock: OFF - driver exit is allowed")
    if logger then
      logger.logLine("INFO", "apl_lock OFF")
    end
    return true
  end

  if mode == "status" then
    print("apl_lock: " .. (lock_enabled and "ON" or "OFF"))
    return true
  end

  print('Usage: apl_lock("on"|"off"|"status")')
  return false
end

function M.resetLock()
  if lock_enabled then
    applyLock(false)
  end
end

function M.aplStatus()
  local vehicle = bridge.getVehicle()
  print("--- soulPilot status ---")
  print("debug: " .. tostring(logger and logger.isDebug() or false))
  print("log: " .. tostring(logger and logger.getLogPath() or "(closed)"))
  print("csv active: " .. tostring(csv and csv.isActive() or false))
  print("pedals: " .. tostring(pedals_requested))
  print("wheel: " .. tostring(wheel_requested))
  print("warmup: " .. tostring(warmup_requested))
  print("driver lock: " .. tostring(lock_enabled))
  print("vehicle: " .. (vehicle and ("ID=" .. tostring(vehicle:getID())) or "(none)"))
  print("-----------------------")
  return true
end

function M.aplDiag()
  return diagnostics.aplDiag()
end

function M.aplMapDiag()
  return diagnostics.aplMapDiag()
end

function M.aplExportGraph()
  return diagnostics.aplExportGraph()
end

function M.aplMark(comment)
  return diagnostics.aplMark(comment)
end

local aliases = {
  apl_autopilot = "aplAutopilot",
  apl_autopilotState = "aplAutopilotState",
  apl_wheel = "aplWheel",
  apl_pedals = "aplPedals",
  apl_warmup = "aplWarmup",
  apl_lights = "aplLights",
  apl_pet = "aplPet",
  apl_petActive = "aplPetActive",
  apl_popup = "aplPopup",
  apl_pain = "aplPain",
  apl_debug = "aplDebug",
  apl_debug_set = "aplDebugSet",
  apl_lock = "aplLock",
  apl_status = "aplStatus",
  apl_diag = "aplDiag",
  apl_mapDiag = "aplMapDiag",
  apl_exportGraph = "aplExportGraph",
  apl_mark = "aplMark",
}

function M.register()
  for alias, method in pairs(aliases) do
    _G[alias] = function(...)
      return M[method](...)
    end
  end
end

return M
