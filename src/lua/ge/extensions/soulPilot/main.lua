-- soulPilot GE extension entrypoint.
-- Loads the GE modules, wires their dependencies and exposes the hooks.

local M = {}

local logger = require("extensions.soulPilot.modules.logger")
local config_loader = require("extensions.soulPilot.modules.configLoader")
local vehicle_bridge = require("extensions.soulPilot.modules.vehicleBridge")
local csv = require("extensions.soulPilot.modules.csv")
local ui_bridge = require("extensions.soulPilot.modules.uiBridge")
local lights = require("extensions.soulPilot.modules.lights")
local pet = require("extensions.soulPilot.modules.pet")
local popup = require("extensions.soulPilot.modules.popup")
local pain = require("extensions.soulPilot.modules.pain")
local master = require("extensions.soulPilot.modules.master")
local commands = require("extensions.soulPilot.modules.commands")
local diagnostics = require("extensions.soulPilot.modules.diagnostics")

logger.init()
vehicle_bridge.init(logger)
csv.init(vehicle_bridge, logger)
ui_bridge.init(logger, csv, vehicle_bridge)
lights.init(config_loader, vehicle_bridge, logger)
pet.init(config_loader, vehicle_bridge, logger)
popup.init(config_loader, vehicle_bridge, logger, lights)
pain.init(config_loader, vehicle_bridge, logger)
master.init(config_loader, vehicle_bridge, logger)
master.setCommands(commands)
pain.setMasterProvider(master.isOn)

commands.init({
  logger = logger,
  csv = csv,
  bridge = vehicle_bridge,
  config_loader = config_loader,
  master = master,
  lights = lights,
  pet = pet,
  popup = popup,
  pain = pain,
  diagnostics = diagnostics,
  ui = ui_bridge,
})
commands.register()

local function loadDebugState()
  local debug_config = config_loader.readJsonFile(config_loader.USER_CONFIG_DIR .. "debug.json")
  if debug_config and tonumber(debug_config.enabled) == 1 then
    logger.setDebug(true)
    vehicle_bridge.sendToVehicle("soulPilotCmd.setDebug(true)")
  end
end

function M.onExtensionLoaded()
  logger.init()
  loadDebugState()
  pcall(function()
    extensions.load("soulPilot/quickAccessMenu")
  end)
  pcall(function()
    extensions.load("soulPilot/music")
  end)
  pcall(function()
    extensions.load("soulPilot/parking")
  end)
  pcall(function()
    extensions.load("soulPilot/uiConfig")
  end)
  _G.soulPilot_main = M
  extensions.soulPilot_main = M
end

function M.onExtensionUnloaded()
  csv.stop()
  logger.closeLogFile()
end

function M.onShutdown()
  csv.stop()
  logger.closeLogFile()
end

function M.onUpdate(dt)
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then
    return
  end
  pain.update(dt)
  master.update(dt)
  popup.update(dt)
  lights.update(dt)
end

function M.onClientPostStartMission()
  commands.setWheelRequested(false)
  commands.setPedalsRequested(false)
  commands.setWarmupRequested(false)
  lights.reset()
  pet.reset()
  popup.reset()
  pain.reset()
  master.reset()
  csv.stop()
end

function M.onVehicleLog(level, message)
  level = tostring(level or "INFO"):upper()
  if level ~= "INFO" and level ~= "WARN" and level ~= "ERROR" then
    level = "INFO"
  end
  if level == "ERROR" and not logger.isDebug() then
    logger.openLogFile()
  end
  logger.logLine(level, message, "vehicle")
end

function M.onVehicleWheelOn()
  master.onWheelOn()
end

function M.onVehicleWarmupDone(vehicle_id, elapsed, temperature, auto_engage, timed_out)
  master.onWarmupDone(vehicle_id, elapsed, temperature, auto_engage, timed_out)
end

function M.onVehicleWarmupState(warmup_state)
  master.onWarmupState(warmup_state)
end

function M.onVehiclePain(kind, info)
  pain.onVehiclePain(kind, info)
end

function M.onVehiclePainDamageRequest()
  pain.onVehiclePainDamageRequest()
end

function M.onVehiclePetDone()
  pet.onVehiclePetDone()
end

function M.onVehiclePetRejected()
  pet.onVehiclePetRejected()
end

function M.onVehiclePopupAutoOff()
  popup.onVehicleAutoOff()
end

function M.onVehicleLightsAutoOff()
  lights.onVehicleAutoOff()
end

function M.onVehicleReady(vehicle_id)
  vehicle_bridge.sendToVehicle("soulPilotCmd.setDebug(" .. tostring(logger.isDebug()) .. ")")
  logger.logLine("INFO", "vehicle layer ready (vehId=" .. tostring(vehicle_id) .. ")", "vehicle")
end

function M.onSerialize()
  return nil
end

function M.onConsoleExecuteCommand(context, command)
  if type(command) ~= "string" then
    return
  end
  local trimmed = command:match("^%s*(.-)%s*$")
  if trimmed == "apl_debug" then
    commands.aplDebug()
  elseif trimmed == "apl_status" then
    commands.aplStatus()
  end
end

function M.isNightNow()
  local ok, value = pcall(function()
    return lights.isNightNow()
  end)
  return ok and value == true
end

return M
