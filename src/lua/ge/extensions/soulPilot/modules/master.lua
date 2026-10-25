-- soulPilot GE master mode.

local M = {}

local config_loader = nil
local bridge = nil
local logger = nil
local commands = nil

local state = "off"
local pending = false
local wait_time = 0
local poll_acc = 0
local autopilot_requested = false
local driver_wait = 0
local last_warmup_state = "off"
local hold_acc = 0

local DRIVER_WAIT_S = 10.0

function M.init(config_module, vehicle_bridge, logger_module)
  config_loader = config_module
  bridge = vehicle_bridge
  logger = logger_module
end

function M.setCommands(command_module)
  commands = command_module
end

local function hud(key, ttl)
  pcall(function()
    guihooks.message({ txt = key, context = {} }, ttl or 4, key)
  end)
end

local function playerInCar()
  local vehicle = bridge and bridge.getVehicle()
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

  local okName, name = pcall(function()
    return vehicle:getJBeamFilename()
  end)
  if okName and name and tostring(name):lower() == "unicycle" then
    return false
  end

  local okPresence, presence = pcall(function()
    return gameplay_seatOccupants
      and gameplay_seatOccupants.getPlayerPresence
      and gameplay_seatOccupants.getPlayerPresence(0)
  end)
  if okPresence and presence and presence.vehicleId == vehicle:getID() and presence.seatId == nil then
    return false
  end

  return true
end

local function sendToDriversVehicle(command)
  if not bridge then
    return
  end
  local fallback_id = bridge.getFallbackVehicleId and bridge.getFallbackVehicleId()
  if fallback_id and bridge.sendToVehicleById then
    if bridge.sendToVehicleById(fallback_id, command) then
      return
    end
  end
  bridge.sendToVehicle(command)
end

local function disableDriverlessVehicle()
  sendToDriversVehicle(
    'if ai and ai.setMode then ai.setMode("disabled") end; '
    .. 'pcall(function() if controller and controller.mainController then '
    .. 'controller.mainController.smartParkingBrake(1) end end)')
end

local function enterWaitingDriver()
  pending = false
  wait_time = 0
  driver_wait = 0
  hold_acc = 0
  state = autopilot_requested and "waiting_driver" or "off"
  if commands and commands.setWarmupRequested then
    commands.setWarmupRequested(false)
  end
  disableDriverlessVehicle()
  if logger then
    logger.logLine("WARN", "Warmup finished, but driver is outside. AI is disabled.")
  end
end

local function enforceDriverless(dt)
  hold_acc = hold_acc + dt
  if hold_acc >= 0.5 then
    hold_acc = 0
    disableDriverlessVehicle()
  end
end

function M.isOn()
  return state == "on"
end

function M.isWaitingDriver()
  return state == "waiting_driver"
end

function M.isAutopilotRequested()
  return autopilot_requested
end

function M.getState()
  return state
end

local function enableConfiguredModules()
  local config = config_loader.loadMasterConfig()

  if config.enable_wheel == 1 and not commands.isWheelRequested() then
    commands.aplWheel("on")
  end
  if config.enable_pedals == 1 and not commands.isPedalsRequested() then
    commands.aplPedals("on")
  end
  if config.enable_lights == 1 and not commands.isLightsAuto() then
    commands.aplLights("auto")
  end
  if config.enable_popup == 1 and not commands.isPopupAuto() then
    commands.aplPopup("auto")
  end
  if config.enable_pain == 1 and not commands.isPainAuto() then
    commands.aplPain("auto")
  end
  if config.enable_music == 1 and apl_music then
    apl_music("on")
  end
  return config
end

local function releaseToTraffic(config)
  local mode = config.ai_mode ~= "" and config.ai_mode or "traffic"
  sendToDriversVehicle(string.format(
    'if playerInfo and playerInfo.anyPlayerSeated == true then '
    .. 'pcall(function() if controller and controller.mainController then '
    .. 'controller.mainController.smartParkingBrake(0) end end); '
    .. 'if ai and ai.setMode then ai.setMode("%s") end '
    .. 'else '
    .. 'if ai and ai.setMode then ai.setMode("disabled") end; '
    .. 'pcall(function() if controller and controller.mainController then '
    .. 'controller.mainController.smartParkingBrake(1) end end) '
    .. 'end', mode))
  return mode
end

local function finish()
  if not pending then
    return
  end
  if not playerInCar() then
    enterWaitingDriver()
    return
  end
  pending = false
  state = "on"
  driver_wait = 0
  local config = enableConfiguredModules()
  local mode = releaseToTraffic(config)
  logger.debugPrint('apl_autopilot: ready - modules enabled, AI="' .. mode .. '"')
  if logger then
    logger.logLine("INFO", "master ON: modules enabled, ai=" .. mode)
  end
end

local function releaseAndTraffic()
  if not playerInCar() then
    enterWaitingDriver()
    return
  end
  pending = true
  finish()
  driver_wait = 0
end

-- The player got back into the car on which autopilot was requested. Never
-- force the master off here: if warmup is still running, let it finish; if the
-- car is already waiting, arm the same 10 second return timer again.
function M.onAutopilotVehicleEntered(vehicle_id)
  if not autopilot_requested then
    return false
  end

  local current = bridge and bridge.getVehicle()
  if not current or not vehicle_id then
    return false
  end
  local ok, current_id = pcall(function()
    return current:getID()
  end)
  if not ok or tonumber(current_id) ~= tonumber(vehicle_id) then
    return false
  end

  if state == "waiting_warmup" then
    driver_wait = 0
    if logger then
      logger.logLine("INFO", "same autopilot vehicle entered during warmup; keeping warmup")
    end
    return true
  end

  if state == "waiting_driver" or state == "off" or state == "on" then
    pending = false
    state = "waiting_driver"
    wait_time = 0
    driver_wait = DRIVER_WAIT_S
    hold_acc = 0
    disableDriverlessVehicle()
    if logger then
      logger.logLine("INFO", "same autopilot vehicle entered; waiting 10s before AI enable")
    end
    return true
  end

  return false
end

-- The vehicle layer also runs a return timer based on playerInfo.anyPlayerSeated.
-- This callback is the authoritative end of that timer: it must move the master
-- out of waiting_driver even if the GE seat query lags behind by a frame or two.
function M.onDriverReturnWaitDone(vehicle_id)
  if not autopilot_requested or state ~= "waiting_driver" then
    return false
  end

  local current = bridge and bridge.getVehicle()
  if current and vehicle_id then
    local ok, current_id = pcall(function()
      return current:getID()
    end)
    if ok and tonumber(current_id) ~= tonumber(vehicle_id) then
      return false
    end
  end

  pending = false
  state = "on"
  driver_wait = 0
  last_warmup_state = "done"
  if commands then
    commands.setWarmupRequested(false)
  end

  local config = enableConfiguredModules()
  local mode = releaseToTraffic(config)
  logger.debugPrint('apl_autopilot: driver returned after wait - AI="' .. mode .. '"')
  if logger then
    logger.logLine("INFO", "master ON: driver returned after 10s wait, ai=" .. mode)
  end
  return true
end

function M.aplAutopilot(mode)
  mode = tostring(mode or ""):lower()
  if mode == "toggle" then
    if state ~= "off" then
      local message = "apl_autopilot: Autopilot is already active (" .. state .. ")"
      print(message)
      if logger then
        logger.logLine("INFO", message)
      end
      hud("soulPilot.autopilot_already_active", 3)
      return false
    end
    mode = "on"
  end

  if mode == "on" then
    if state == "on" then
      logger.debugPrint("apl_autopilot: already enabled")
      return false
    end
    if state == "waiting_warmup" then
      if not playerInCar() then
        hud("soulPilot.get_in_vehicle")
        return false
      end
      logger.debugPrint("apl_autopilot: already waiting for warmup")
      return false
    end
    if state == "waiting_driver" then
      if not playerInCar() then
        hud("soulPilot.get_in_vehicle")
        return false
      end
      if driver_wait <= 0 then
        driver_wait = DRIVER_WAIT_S
      end
      return true
    end
    local vehicle = bridge.getVehicle()
    if not vehicle then
      hud("soulPilot.get_in_vehicle")
      return false
    end
    if not playerInCar() then
      hud("soulPilot.get_in_vehicle")
      return false
    end

    local config = config_loader.loadMasterConfig()
    autopilot_requested = true
    if commands then
      commands.setAutopilotRequested(true)
    end
    driver_wait = 0
    last_warmup_state = "off"
    pending = true
    state = "waiting_warmup"
    wait_time = 0
    poll_acc = 0
    -- Send the request flag in the same vehicle command as the warmup start.
    -- The separate command above can be queued a frame later, which used to
    -- make the first part of the warmup run without the absent-driver gate.
    local command = string.format(
      "if soulPilotCustomLightsCmd and soulPilotCustomLightsCmd.setAutopilotRequested then "
      .. "soulPilotCustomLightsCmd.setAutopilotRequested(true) end; "
      .. "soulPilotWarmupCmd.on('%s', {noSway=false, skipIfWarm=%s})",
      config_loader.configPath("warmup.json"),
      tostring(config.skip_warmup_if_warm == 1))
    if not bridge.sendToVehicle(command) then
      pending = false
      autopilot_requested = false
      if commands then
        commands.setAutopilotRequested(false)
      end
      state = "off"
      print("apl_autopilot: WARN failed to start warmup")
      return false
    end

    if commands then
      commands.setWarmupRequested(true)
    end
    logger.debugPrint("apl_autopilot: ON - warmup started, AI will be enabled after warmup")
    if logger then
      logger.logLine("INFO", "master ON: warmup started")
    end
    return true
  end

  if mode == "off" then
    local previous = state
    autopilot_requested = false
    if commands then
      commands.setAutopilotRequested(false)
    end
    pending = false
    state = "off"
    driver_wait = 0
    wait_time = 0
    if commands then
      if commands.isWheelRequested() then
        commands.aplWheel("off")
      end
      if commands.isPedalsRequested() then
        commands.aplPedals("off")
      end
      if commands.isLightsAuto() then
        commands.aplLights("off")
      end
      if commands.isPopupAuto() then
        commands.aplPopup("off")
      end
      if commands.isPainAuto() then
        commands.aplPain("off")
      end
      commands.setWarmupRequested(false)
    end
    bridge.sendToVehicle('if ai and ai.setMode then ai.setMode("disabled") end')
    logger.debugPrint("apl_autopilot: OFF (was " .. tostring(previous) .. ")")
    if logger then
      logger.logLine("INFO", "master OFF (was " .. tostring(previous) .. ")")
    end
    return true
  end

  if mode == "status" then
    local config = config_loader.loadMasterConfig()
    print("--- apl_autopilot status ---")
    print("state=" .. state .. ", pending=" .. tostring(pending)
      .. ", waited=" .. string.format("%.1f", wait_time) .. " s")
    print("config: wheel=" .. tostring(config.enable_wheel)
      .. " pedals=" .. tostring(config.enable_pedals)
      .. " lights=" .. tostring(config.enable_lights)
      .. " popup=" .. tostring(config.enable_popup)
      .. " pain=" .. tostring(config.enable_pain)
      .. " music=" .. tostring(config.enable_music)
      .. " ai=" .. tostring(config.ai_mode))
    return true
  end

  print('Usage: apl_autopilot("on"|"off"|"toggle"|"status")')
  return false
end

function M.onWheelOn()
  if not autopilot_requested and state == "off" then
    -- Ignore late callbacks from traffic vehicles or a previous mission.
    return
  end
  if commands then
    commands.setWheelRequested(true)
  end
end

function M.onWarmupDone(vehicle_id, elapsed, temperature, auto_engage, timed_out, driver_seated)
  if not autopilot_requested and not pending and state == "off" then
    if logger then
      logger.logLine("INFO", "stale warmup-done ignored: autopilot is off")
    end
    return
  end
  last_warmup_state = "done"
  local message = string.format(
    "MASTER: warmup done (pending=%s, state=%s, veh=%s, elapsed=%s, temp=%s, seated=%s)",
    tostring(pending), tostring(state), tostring(vehicle_id), tostring(elapsed), tostring(temperature),
    tostring(driver_seated))
  logger.debugPrint(message)
  if logger then
    logger.logLine(timed_out and "WARN" or "INFO", message)
  end

  local seated_flag = not (driver_seated == false or tostring(driver_seated):lower() == "false")
  local seated = seated_flag and playerInCar()
  if not seated then
    enterWaitingDriver()
    return
  end

  if commands then
    commands.setWarmupRequested(false)
  end

  if auto_engage == true or tostring(auto_engage) == "true" then
    if commands then
      if not commands.isWheelRequested() then
        commands.aplWheel("on")
      end
      if not commands.isPedalsRequested() then
        commands.aplPedals("on")
      end
    end
  else
    logger.debugPrint('apl_warmup: manual engage required: apl_wheel("on") + apl_pedals("on")')
  end

  if pending then
    finish()
  end
end

function M.onWarmupState(warmup_state)
  if not autopilot_requested and not pending and state == "off" then
    return
  end
  warmup_state = tostring(warmup_state or "")
  last_warmup_state = warmup_state
  if pending and warmup_state == "done_outside" then
    logger.debugPrint("MASTER: warmup state done_outside -> waiting for driver")
    enterWaitingDriver()
    return
  end
  if pending and warmup_state == "done" then
    if not playerInCar() then
      enterWaitingDriver()
      return
    end
    logger.debugPrint("MASTER: warmup state done -> finish")
    finish()
  end
end

function M.update(dt)
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then
    return
  end

  if state == "waiting_warmup" then
    if last_warmup_state == "done" or last_warmup_state == "done_outside" then
      if last_warmup_state == "done" and playerInCar() then
        finish()
      else
        enterWaitingDriver()
      end
      return
    end

    if not playerInCar() then
      enforceDriverless(dt)
    end

    wait_time = wait_time + dt
    poll_acc = poll_acc + dt
    if poll_acc >= 2 then
      poll_acc = 0
      local vehicle = bridge.getVehicle()
      if vehicle and vehicle.queueLuaCommand then
        pcall(function()
          vehicle:queueLuaCommand(
            "if soulPilotWarmupCmd and soulPilotWarmupCmd.pushState then soulPilotWarmupCmd.pushState() end")
        end)
      end
    end

    if wait_time > 60 then
      if logger then
        logger.logLine("WARN", "master timeout waiting warmup")
      end
      enterWaitingDriver()
    end
    return
  end

  if state == "waiting_driver" then
    if playerInCar() then
      if driver_wait <= 0 then
        driver_wait = DRIVER_WAIT_S
        if logger then
          logger.logLine("INFO", "driver is back, waiting before AI enable")
        end
      end
      driver_wait = math.max(0, driver_wait - dt)
      enforceDriverless(dt)
      if driver_wait <= 0 then
        releaseAndTraffic()
      end
    else
      driver_wait = 0
      enforceDriverless(dt)
    end
    return
  end

  if state == "on" and not playerInCar() then
    state = "waiting_driver"
    driver_wait = 0
    hold_acc = 0
    disableDriverlessVehicle()
    if logger then
      logger.logLine("WARN", "driver is outside, AI disabled; waiting for driver")
    end
  end
end

function M.reset()
  state = "off"
  pending = false
  wait_time = 0
  poll_acc = 0
  autopilot_requested = false
  if commands then
    commands.setAutopilotRequested(false)
  end
  driver_wait = 0
  last_warmup_state = "off"
  hold_acc = 0
end

function M.forceOff()
  local previous = state
  M.reset()
  if commands then
    commands.aplWheel("off")
    commands.aplPedals("off")
    commands.aplLights("off")
    commands.aplPopup("off")
    commands.aplPain("off")
    commands.setWheelRequested(false)
    commands.setPedalsRequested(false)
    commands.setWarmupRequested(false)
  end
  if logger then
    logger.logLine("INFO", "MASTER forced OFF (was " .. tostring(previous) .. ")")
  end
  return true
end

return M
