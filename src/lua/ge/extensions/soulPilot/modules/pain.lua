-- soulPilot GE pain recovery.

local M = {}

local config_loader = nil
local bridge = nil
local logger = nil

local auto_enabled = false
local damage_acc = 0
local damage_seq = 0
local last_damage = nil
local verify_t = 0
local teleport_pending = false
local teleport_delay = 0
local teleport_from = nil
local last_tp = -1
local master_is_on = function()
  return false
end

local function playerJBeam(vehicle)
  local ok, value = pcall(function()
    return vehicle.JBeam
  end)
  if ok and type(value) == "string" then
    return value:lower()
  end
  return nil
end

local function thresholdFor(vehicle, config)
  local jbeam = vehicle and playerJBeam(vehicle) or nil
  if jbeam and config.damage_threshold_by_model[jbeam] then
    return config.damage_threshold_by_model[jbeam], jbeam
  end
  return config.damage_threshold, jbeam
end

local function roadPose(vehicle)
  local map_data = map and map.getMap and map.getMap() or nil
  if not map_data or not map_data.nodes then
    return nil
  end
  local position = vehicle:getPosition()
  local first_id, second_id = map.findClosestRoad(position)
  local first = first_id and map_data.nodes[first_id] or nil
  local second = second_id and map_data.nodes[second_id] or nil
  if not first or not first.pos then
    return nil
  end
  local qx, qy, qz, qw = 0, 0, 0, 1
  if second and second.pos and first.normal then
    local direction = second.pos - first.pos
    if direction:length() > 0.5 then
      local quaternion = quatFromDir(direction, first.normal)
      qx, qy, qz, qw = quaternion.x, quaternion.y, quaternion.z, quaternion.w
    end
  end
  return first.pos.x, first.pos.y, first.pos.z + 0.2, qx, qy, qz, qw
end

local function teleportToRoad(vehicle)
  local x, y, z, qx, qy, qz, qw = roadPose(vehicle)
  if not x then
    return false
  end
  pcall(function()
    vehicle:setVelocity(vec3(0, 0, 0))
  end)
  pcall(function()
    vehicle:applyAngularVelocity(vec3(0, 0, 0))
  end)
  local ok = pcall(function()
    vehicle:setPosRot(x, y, z, qx, qy, qz, qw)
  end)
  pcall(function()
    vehicle:setVelocity(vec3(0, 0, 0))
  end)
  return ok
end

local function recover(vehicle, kind)
  local position = vehicle:getPosition()
  teleport_from = vec3(position.x, position.y, position.z)
  local reset_ok = pcall(function()
    be:resetVehicle(0)
  end)
  teleport_pending = true
  teleport_delay = 0.2
  bridge.sendToVehicle("soulPilotPainCmd.ignoreDamage(3.0)")
  bridge.sendToVehicle("soulPilotPedalsCmd.setRateScale(0.2, 3.0)")
  logger.debugPrint(string.format("apl_pain: recover %s - resetVehicle=%s", tostring(kind), tostring(reset_ok)))
end

function M.init(config_module, vehicle_bridge, logger_module)
  config_loader = config_module
  bridge = vehicle_bridge
  logger = logger_module
end

function M.setMasterProvider(provider)
  master_is_on = provider
end

function M.aplPain(mode)
  mode = tostring(mode or ""):lower()
  local vehicle = bridge.getVehicle()
  if not vehicle then
    print("apl_pain: player vehicle not found")
    return false
  end

  if mode == "auto" then
    if auto_enabled then
      logger.debugPrint("apl_pain: already enabled")
      return false
    end
    local config = config_loader.loadPainConfig()
    local threshold, jbeam = thresholdFor(vehicle, config)
    config.damage_threshold = threshold
    auto_enabled = true
    damage_acc = 0
    bridge.sendToVehicle(string.format(
      "soulPilotPainCmd.start({check_hz=%.2f,damage_threshold=%.3f,"
        .. "stuck_speed_kph=%.1f,stuck_time_s=%.1f,stuck_throttle_min=%.2f,"
        .. "flipped_up_dot=%.2f,flipped_time_s=%.1f,cooldown_s=%.1f})",
      config.check_hz,
      config.damage_threshold,
      config.stuck_speed_kph,
      config.stuck_time_s,
      config.stuck_throttle_min,
      config.flipped_up_dot,
      config.flipped_time_s,
      config.cooldown_s))
    logger.debugPrint("apl_pain: auto ON, threshold=" .. string.format("%.0f", threshold)
      .. " model=" .. tostring(jbeam or "?"))
    if logger then
      logger.logLine("INFO", "pain auto ON")
    end
    return true
  end

  if mode == "off" then
    if not auto_enabled then
      logger.debugPrint("apl_pain: already disabled")
      return false
    end
    auto_enabled = false
    bridge.sendToVehicle("soulPilotPainCmd.stop()")
    logger.debugPrint("apl_pain: OFF")
    if logger then
      logger.logLine("INFO", "pain auto OFF")
    end
    return true
  end

  if mode == "status" then
    local config = config_loader.loadPainConfig()
    local damage = "?"
    if vehicle.getSectionDamageSum then
      local ok, value = pcall(function()
        return vehicle:getSectionDamageSum()
      end)
      if ok and value ~= nil then
        damage = string.format("%.1f", tonumber(value) or 0)
      end
    end
    print("--- apl_pain status ---")
    print("auto=" .. tostring(auto_enabled) .. ", damage=" .. tostring(damage)
      .. ", lastTeleport=" .. string.format("%.1f", last_tp))
    bridge.sendToVehicle("soulPilotPainCmd.status()")
    return true
  end

  print("Usage: apl_pain(\"auto\"|\"off\"|\"status\")")
  return false
end

function M.onVehiclePain(kind, info)
  if not auto_enabled then
    return
  end
  local config = config_loader.loadPainConfig()
  local vehicle = bridge.getVehicle()
  if logger then
    logger.logLine("WARN", "pain " .. tostring(kind) .. ": " .. tostring(info))
  end
  if not vehicle then
    print("apl_pain: recover impossible, vehicle not found")
    return
  end
  recover(vehicle, kind)
  verify_t = 2.0
  if config.warmup_after > 0 then
    bridge.sendToVehicle(string.format(
      "soulPilotWarmupCmd.on('%s', {noSway=%s})",
      config_loader.configPath("warmup.json"),
      tostring(config.warmup_sway == 0)))
  end
  if config.restore_ai > 0 and master_is_on() then
    bridge.sendToVehicle('if ai and ai.setMode then ai.setMode("traffic") end')
  end
end

function M.onVehiclePainDamageRequest()
  local vehicle = bridge.getVehicle()
  if not vehicle or not vehicle.getSectionDamageSum then
    return
  end
  local ok, value = pcall(function()
    return vehicle:getSectionDamageSum()
  end)
  if not ok or value == nil then
    return
  end
  local damage = tonumber(value)
  damage_seq = damage_seq + 1
  local command = string.format("soulPilotPainCmd.setDamage(%.6f, %d)", damage, damage_seq)
  pcall(function()
    vehicle:queueLuaCommand(command)
  end)
  last_damage = damage
end

function M.update(dt)
  if auto_enabled then
    damage_acc = damage_acc + dt
    if damage_acc >= 2 then
      damage_acc = 0
      local vehicle = bridge.getVehicle()
      if vehicle and vehicle.getSectionDamageSum then
        local ok, value = pcall(function()
          return vehicle:getSectionDamageSum()
        end)
        if ok and value ~= nil then
          damage_seq = damage_seq + 1
          local damage = tonumber(value) or 0
          local command = string.format("soulPilotPainCmd.setDamage(%.6f, %d)", damage, damage_seq)
          bridge.sendToVehicle(command)
          last_damage = damage
        end
      end
    end
  end

  if verify_t > 0 then
    verify_t = verify_t - dt
    if verify_t <= 0 then
      local vehicle = bridge.getVehicle()
      local damage = 0
      if vehicle and vehicle.getSectionDamageSum then
        local ok, value = pcall(function()
          return vehicle:getSectionDamageSum()
        end)
        if ok and value then
          damage = tonumber(value) or 0
        end
      end
      local threshold = thresholdFor(vehicle, config_loader.loadPainConfig())
      if damage >= threshold and spawn and spawn.teleportToLastRoad and vehicle then
        pcall(function()
          spawn.teleportToLastRoad(vehicle, { resetVehicle = true })
        end)
      end
    end
  end

  if teleport_pending then
    teleport_delay = teleport_delay - dt
    if teleport_delay <= 0 then
      teleport_pending = false
      local vehicle = bridge.getVehicle()
      if vehicle then
        teleportToRoad(vehicle)
        last_tp = 1.0
      end
    end
  end
end

function M.reset()
  auto_enabled = false
  damage_acc = 0
  verify_t = 0
  teleport_pending = false
  teleport_delay = 0
  teleport_from = nil
  last_tp = -1
end

function M.isActive()
  return auto_enabled
end

return M
