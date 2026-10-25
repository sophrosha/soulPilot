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
local AUTO_DOOR_FILTER = "soulPilotAutoDoorLock"
local DOOR_ACTIONS = { "toggleWalkingMode" }
local auto_door_locked = false
local door_check_acc = 0
local last_door_message = 0

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

local function isSmoothAiEnabled()
  if not config_loader then
    return false
  end
  local config = config_loader.loadMasterConfig()
  return config ~= nil and tonumber(config.smooth_ai_cars) == 1
end

local function isUnicycle(vehicle)
  local ok, name = pcall(function()
    return vehicle and vehicle:getJBeamFilename() or ""
  end)
  return (ok and tostring(name):lower() == "unicycle") or false
end

local function sendWheelCommand(vehicle_id, path, enabled)
  if not bridge or not bridge.sendToVehicleById then
    return nil
  end
  local command
  if enabled then
    command = string.format('soulPilotWheelCmd.on("%s")', tostring(path or ""))
  else
    command = "soulPilotWheelCmd.off()"
  end
  return bridge.sendToVehicleById(vehicle_id, command)
end

local function broadcastWheel(path, enabled)
  if type(getAllVehicles) ~= "function" then
    return 0
  end
  local ok, vehicles = pcall(getAllVehicles)
  if not ok or type(vehicles) ~= "table" then
    return 0
  end
  local count = 0
  for _, vehicle in ipairs(vehicles) do
    if vehicle and not isUnicycle(vehicle) then
      local id_ok, id = pcall(function()
        return vehicle:getID()
      end)
      if id_ok and id then
        if sendWheelCommand(id, path, enabled) then
          count = count + 1
        end
      end
    end
  end
  return count
end

function M.onVehicleReady(vehicle_id)
  if not wheel_requested or not isSmoothAiEnabled() then
    return false
  end
  local path = config_loader and config_loader.configPath("wheel.json") or nil
  if not path then
    return false
  end
  return sendWheelCommand(vehicle_id, path, true) ~= nil
end

function M.aplWheel(mode)
  mode = tostring(mode or ""):lower()
  local path = config_loader.configPath("wheel.json")

  if mode == "on" then
    if not configExists(path) then
      print("WARN apl_wheel: config not found (" .. tostring(path) .. "), vehicle will use defaults")
    end
    local vehicle = bridge.sendToVehicle(string.format('soulPilotWheelCmd.on("%s")', path))
    local smooth_ai = isSmoothAiEnabled()
    if vehicle or smooth_ai then
      wheel_requested = true
      local ai_count = 0
      if smooth_ai then
        ai_count = broadcastWheel(path, true)
      end
      logger.debugPrint("apl_wheel: ON (config: " .. tostring(path)
        .. ", smooth_ai=" .. tostring(smooth_ai) .. ", vehicles=" .. tostring(ai_count) .. ")")
      if logger then
        logger.logLine("INFO", "apl_wheel ON, conf=" .. tostring(path)
          .. ", smooth_ai=" .. tostring(smooth_ai) .. ", vehicles=" .. tostring(ai_count))
      end
      autoCsv("apl_wheel")
    end
    return true
  end

  if mode == "off" then
    local command = 'local ok, off = pcall(function() return soulPilotWheelCmd.off() end); '
      .. 'print("soulPilotWheel: off round-trip ok=" .. tostring(ok) .. " off=" .. tostring(off)); '
      .. 'pcall(function() soulPilotWheelCmd.status() end)'
    local player_vehicle = bridge.sendToVehicle(command)
    local ai_count = broadcastWheel(path, false)
    if player_vehicle or ai_count > 0 then
      wheel_requested = false
      logger.debugPrint("apl_wheel: OFF sent (vehicles=" .. tostring(ai_count) .. ")")
      if logger then
        logger.logLine("INFO", "apl_wheel OFF sent (vehicles=" .. tostring(ai_count) .. ")")
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

function M.aplPetAll()
  if type(getAllVehicles) ~= "function" then
    print("apl_petAll: getAllVehicles is not available")
    return false
  end

  local ok, vehicles = pcall(getAllVehicles)
  if not ok or type(vehicles) ~= "table" then
    print("apl_petAll: could not enumerate vehicles")
    return false
  end

  local sent = 0
  for _, vehicle in ipairs(vehicles) do
    if vehicle and not isUnicycle(vehicle) then
      local id_ok, id = pcall(function()
        return vehicle:getID()
      end)
      if id_ok and id and bridge and bridge.sendToVehicleById then
        if bridge.sendToVehicleById(id, "soulPilotCustomLightsCmd.playCatSquint()") then
          sent = sent + 1
        end
      end
    end
  end

  print("apl_petAll: sent squint to " .. tostring(sent) .. " vehicle(s)")
  return sent > 0
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

local function playerInCar()
  if not bridge then
    return false
  end
  local vehicle = bridge.getVehicle()
  if not vehicle then
    return false
  end
  local walking = false
  pcall(function()
    walking = gameplay_walk
      and gameplay_walk.isWalking
      and gameplay_walk.isWalking(0) == true
  end)
  if walking then
    return false
  end
  local ok, name = pcall(function()
    return vehicle:getJBeamFilename()
  end)
  return not (ok and name and tostring(name):lower() == "unicycle")
end

local function vehicleSpeedKph()
  if not bridge then
    return 0
  end
  local vehicle = bridge.getFallbackVehicle and bridge.getFallbackVehicle() or nil
  if not vehicle then
    vehicle = bridge.getVehicle()
  end
  if not vehicle then
    return 0
  end
  local speed = 0
  pcall(function()
    speed = vehicle:getVelocity():length()
  end)
  return math.max(0, tonumber(speed) or 0) * 3.6
end

local function setAutoDoorFilter(enabled, force)
  enabled = enabled == true
  if not force and auto_door_locked == enabled then
    return
  end
  auto_door_locked = enabled
  pcall(function()
    if core_input_actionFilter then
      core_input_actionFilter.setGroup(AUTO_DOOR_FILTER, DOOR_ACTIONS)
      core_input_actionFilter.addAction(0, AUTO_DOOR_FILTER, enabled)
    end
  end)
end

local door_command_state = false

local function sendDoorLock(value)
  value = value == true
  if door_command_state == value then
    return
  end
  door_command_state = value
  if bridge then
    local command = "soulPilotCustomLightsCmd.setDoorLock(" .. tostring(value) .. ")"
    local fallback_id = bridge.getFallbackVehicleId and bridge.getFallbackVehicleId()
    if not (fallback_id and bridge.sendToVehicleById and bridge.sendToVehicleById(fallback_id, command)) then
      bridge.sendToVehicle(command)
    end
    local vehicle = bridge.getVehicle()
    pcall(function()
      if vehicle and vehicle.setPlayerLocked then
        vehicle:setPlayerLocked(value)
      end
    end)
  end
end

local function applyLock(enabled)
  local ok = pcall(function()
    if not core_input_actionFilter then
      error("core_input_actionFilter is not available")
    end
    core_input_actionFilter.setGroup(LOCK_FILTER, DOOR_ACTIONS)
    core_input_actionFilter.addAction(0, LOCK_FILTER, enabled == true)
  end)
  if not ok then
    print("WARN apl_lock: input action filter is not available")
    return false
  end
  lock_enabled = enabled == true
  sendDoorLock(lock_enabled or auto_door_locked)
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
  -- Forced reset: a level change or vehicle switch must never leave the
  -- player locked in (or out of) the previous car. Do not rely on state
  -- transitions here, because the old vehicle may still have playerLocked set.
  lock_enabled = false
  auto_door_locked = false
  door_command_state = false
  door_check_acc = 0

  pcall(function()
    if not core_input_actionFilter then
      return
    end
    core_input_actionFilter.setGroup(LOCK_FILTER, DOOR_ACTIONS)
    core_input_actionFilter.addAction(0, LOCK_FILTER, false)
    core_input_actionFilter.setGroup(AUTO_DOOR_FILTER, DOOR_ACTIONS)
    core_input_actionFilter.addAction(0, AUTO_DOOR_FILTER, false)
  end)

  if not bridge then
    return
  end

  local command = "soulPilotCustomLightsCmd.resetDoorLock()"
  local ids = {}
  local fallback_id = bridge.getFallbackVehicleId and bridge.getFallbackVehicleId()
  if fallback_id then
    ids[#ids + 1] = fallback_id
  end
  local vehicle = bridge.getVehicle()
  if vehicle then
    local ok, id = pcall(function()
      return vehicle:getID()
    end)
    if ok and id then
      ids[#ids + 1] = id
    end
    pcall(function()
      if vehicle.setPlayerLocked then
        vehicle:setPlayerLocked(false)
      end
    end)
  end

  local sent = {}
  for _, id in ipairs(ids) do
    if not sent[id] and bridge.sendToVehicleById then
      if bridge.sendToVehicleById(id, command) then
        sent[id] = true
      end
    end
  end
  if not next(sent) and bridge.sendToVehicle then
    bridge.sendToVehicle(command)
  end
end

function M.isDoorLocked()
  return lock_enabled or auto_door_locked
end

function M.update(dt)
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then
    return
  end
  door_check_acc = door_check_acc + dt
  if door_check_acc < 0.1 then
    return
  end
  door_check_acc = 0

  local inside = playerInCar()
  local should_lock = vehicleSpeedKph() > 5.0
    or (inside and master and master.isOn and master.isOn() == true)
  setAutoDoorFilter(should_lock and inside)
  sendDoorLock(lock_enabled or should_lock)
end

local function isLatchAction(name)
  name = tostring(name or ""):lower()
  return name:find("latch", 1, true) ~= nil
    or name:find("door", 1, true) ~= nil
end

local function isExitAction(name)
  name = tostring(name or ""):lower()
  return name:find("seat", 1, true) ~= nil or name == "togglewalkingmode"
end

local function isDoorAction(name)
  return isLatchAction(name) or isExitAction(name)
end

function M.onVehicleTriggersExecuteLink(lnk, actionValue, vehicleId, player)
  if actionValue == 0 or not M.isDoorLocked() then
    return
  end
  local action = lnk and (lnk.inputAction or lnk.targetEvent) or nil
  if not isDoorAction(action) then
    return
  end

  -- Latch attempts are closed and reported by the vehicle layer (this also
  -- covers direct JBeam door triggers and plain input bindings). The GE hook
  -- is the reliable place to report a blocked seat-exit attempt.
  if isLatchAction(action) then
    if bridge then
      bridge.sendToVehicle("soulPilotCustomLightsCmd.closeDoors()")
    end
    return
  end

  local now = os.clock()
  if now - last_door_message < 1.0 then
    return
  end
  last_door_message = now

  pcall(function()
    guihooks.message({ txt = "soulPilot.doors_locked", context = {} }, 3, "soulPilot.doorLock")
  end)
end

function M.onVehicleTriggerActionLabel(data)
  if not data or not M.isDoorLocked() then
    return
  end
  if isDoorAction(data.actionName) then
    local title = "soulPilot.doors_locked"
    pcall(function()
      if _tr then title = _tr(title) end
    end)
    data.title = title
    data.icon = "circleSlashed"
    data.color = { 1, 0.1, 0.1, 0.8 }
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
  print("auto door lock: " .. tostring(auto_door_locked))
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
  apl_petAll = "aplPetAll",
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
