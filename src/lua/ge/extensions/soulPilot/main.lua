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

local function getVehicleById(vehicle_id)
  if not getObjectByID then
    return nil
  end
  local ok, vehicle = pcall(getObjectByID, vehicle_id)
  return ok and vehicle or nil
end

local function isUnicycle(vehicle)
  local ok, name = pcall(function()
    return vehicle and vehicle:getJBeamFilename() or ""
  end)
  return (ok and tostring(name):lower() == "unicycle") or false
end

local function setVehicleManaged(vehicle_id, enabled)
  if not vehicle_id then
    return
  end
  vehicle_bridge.sendToVehicleById(
    vehicle_id,
    "soulPilotCustomLightsCmd.setManaged(" .. tostring(enabled == true) .. ")")
end

local function markCurrentPlayerVehicle()
  local vehicle = vehicle_bridge.getVehicle()
  if vehicle and not isUnicycle(vehicle) then
    setVehicleManaged(vehicle:getID(), true)
    vehicle_bridge.setFallbackVehicle(vehicle:getID())
  end
end

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
  local enabled = false
  local master_config = config_loader.loadMasterConfig()
  if master_config and tonumber(master_config.debug_mode) == 1 then
    enabled = true
  end
  local debug_config = config_loader.readJsonFile(config_loader.USER_CONFIG_DIR .. "debug.json")
  if debug_config and tonumber(debug_config.enabled) == 1 then
    enabled = true
  end
  logger.setDebug(enabled)
  vehicle_bridge.sendToVehicle("soulPilotCmd.setDebug(" .. tostring(enabled) .. ")")
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
    extensions.load("soulPilot/uiConfig")
  end)
  _G.soulPilot_main = M
  extensions.soulPilot_main = M
  markCurrentPlayerVehicle()
end

function M.onExtensionUnloaded()
  if commands then
    commands.resetLock()
  end
  csv.stop()
  logger.closeLogFile()
end

function M.onShutdown()
  if commands then
    commands.resetLock()
  end
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
  commands.update(dt)
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
  commands.resetLock()
  markCurrentPlayerVehicle()
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

function M.onVehicleWarmupDone(vehicle_id, elapsed, temperature, auto_engage, timed_out, driver_seated)
  master.onWarmupDone(vehicle_id, elapsed, temperature, auto_engage, timed_out, driver_seated)
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

function M.onVehicleTriggersExecuteLink(lnk, actionValue, vehicle_id, player)
  if commands and commands.onVehicleTriggersExecuteLink then
    commands.onVehicleTriggersExecuteLink(lnk, actionValue, vehicle_id, player)
  end
end

function M.onVehicleTriggerActionLabel(data)
  if commands and commands.onVehicleTriggerActionLabel then
    commands.onVehicleTriggerActionLabel(data)
  end
end

function M.onVehicleReady(vehicle_id)
  local vehicle = getVehicleById(vehicle_id)
  local player_vehicle = vehicle_bridge.getVehicle()
  local managed = vehicle ~= nil
    and player_vehicle
    and not isUnicycle(vehicle)
    and vehicle:getID() == player_vehicle:getID()

  setVehicleManaged(vehicle_id, managed)
  if managed then
    vehicle_bridge.setFallbackVehicle(vehicle_id)
  end
  -- New AI traffic vehicles must also receive the global steering smoother
  -- when the player has enabled it after this vehicle was spawned.
  if commands and commands.onVehicleReady then
    commands.onVehicleReady(vehicle_id)
  end
  vehicle_bridge.sendToVehicle("soulPilotCmd.setDebug(" .. tostring(logger.isDebug()) .. ")")
  logger.logLine("INFO", "vehicle layer ready (vehId=" .. tostring(vehicle_id) .. ")", "vehicle")
end

function M.onVehicleSwitched(old_id, new_id, player)
  if player ~= nil and tonumber(player) ~= 0 then
    return
  end

  local new_vehicle = getVehicleById(new_id)
  if new_vehicle and not isUnicycle(new_vehicle) then
    -- A manual/auto door lock belongs to one vehicle and one mission only.
    -- Reset it before switching the fallback id, so the old car is unlocked
    -- through the command bridge and the new car starts with a clean state.
    commands.resetLock()

    -- Switching between cars: only the car the player is in may run the
    -- absent-driver / cat-squint logic.
    local old_vehicle = getVehicleById(old_id)
    if old_id and old_id ~= new_id and old_vehicle and not isUnicycle(old_vehicle) then
      setVehicleManaged(old_id, false)
    end
    setVehicleManaged(new_id, true)
    vehicle_bridge.setFallbackVehicle(new_id)
    if commands and commands.onVehicleReady then
      commands.onVehicleReady(new_id)
    end
  elseif new_id == nil or tonumber(new_id) == -1 then
    -- The player left the car into walking/observer mode. Keep the old car
    -- managed so it can stop, apply the handbrake and trigger the squint.
    -- The door lock belongs to the previous seat, not to walking mode.
    commands.resetLock()
  end
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
