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

function M.init(config_module, vehicle_bridge, logger_module)
  config_loader = config_module
  bridge = vehicle_bridge
  logger = logger_module
end

function M.setCommands(command_module)
  commands = command_module
end

function M.isOn()
  return state == "on"
end

function M.getState()
  return state
end

local function finish()
  if not pending then
    return
  end
  pending = false
  state = "on"
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

  local mode = config.ai_mode ~= "" and config.ai_mode or "traffic"
  bridge.sendToVehicle(string.format('if ai and ai.setMode then ai.setMode("%s") end', mode))
  logger.debugPrint('apl_autopilot: ready - modules enabled, AI="' .. mode .. '"')
  if logger then
    logger.logLine("INFO", "master ON: modules enabled, ai=" .. mode)
  end
end

function M.aplAutopilot(mode)
  mode = tostring(mode or ""):lower()
  if mode == "toggle" then
    mode = state == "on" and "off" or "on"
  end

  if mode == "on" then
    if state == "on" then
      logger.debugPrint("apl_autopilot: already enabled")
      return false
    end
    if state == "waiting_warmup" then
      logger.debugPrint("apl_autopilot: already waiting for warmup")
      return false
    end
    local vehicle = bridge.getVehicle()
    if not vehicle then
      print("apl_autopilot: player vehicle not found")
      return false
    end

    local config = config_loader.loadMasterConfig()
    pending = true
    state = "waiting_warmup"
    wait_time = 0
    poll_acc = 0
    local command = string.format(
      "soulPilotWarmupCmd.on('%s', {noSway=false, skipIfWarm=%s})",
      config_loader.configPath("warmup.json"),
      tostring(config.skip_warmup_if_warm == 1))
    if not bridge.sendToVehicle(command) then
      pending = false
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
    pending = false
    state = "off"
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
  if commands then
    commands.setWheelRequested(true)
  end
end

function M.onWarmupDone(vehicle_id, elapsed, temperature, auto_engage, timed_out)
  local message = string.format(
    "MASTER: warmup done (pending=%s, state=%s, veh=%s, elapsed=%s, temp=%s)",
    tostring(pending), tostring(state), tostring(vehicle_id), tostring(elapsed), tostring(temperature))
  logger.debugPrint(message)
  if logger then
    logger.logLine(timed_out and "WARN" or "INFO", message)
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
  warmup_state = tostring(warmup_state or "")
  if pending and warmup_state == "done" then
    logger.debugPrint("MASTER: warmup state done -> finish")
    finish()
  end
end

function M.update(dt)
  if not pending then
    return
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
    pending = false
    state = "off"
    print("apl_autopilot: WARN warmup timeout 60 s, master cancelled")
    if logger then
      logger.logLine("WARN", "master timeout waiting warmup")
    end
  end
end

function M.reset()
  state = "off"
  pending = false
  wait_time = 0
  poll_acc = 0
end

return M
