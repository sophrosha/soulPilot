-- soulPilot GE auto lights.

local M = {}

local config_loader = nil
local bridge = nil
local logger = nil

local auto_enabled = false
local target = nil
local poll_acc = 0
local config = nil
local window = nil
local is_night = nil

local function gameTodHours()
  local ok, value = pcall(function()
    local time_obj = core_environment.getTimeOfDay()
    if time_obj and time_obj.time then
      return tonumber(time_obj.time)
    end
    return nil
  end)
  if not ok then
    return nil
  end
  return value
end

local function gameTodString()
  local hour = gameTodHours()
  if hour == nil then
    return nil
  end
  return string.format("%02d:%02d", math.floor(hour % 24), math.floor((hour % 1) * 60))
end

local function currentMapId()
  local ok, value = pcall(function()
    if getCurrentLevelIdentifier == nil then
      return nil
    end
    return getCurrentLevelIdentifier()
  end)
  if ok and type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function windowForCurrentMap(cfg)
  local map_id = currentMapId()
  local map_window = map_id and cfg.maps[map_id:lower()] or nil
  if map_window then
    return { start = map_window.start, ["end"] = map_window["end"] }, map_id, true
  end
  return { start = cfg.night_window.start, ["end"] = cfg.night_window["end"] }, map_id, false
end

local function computeTarget(cfg, active_window)
  local hour = gameTodHours()
  if hour == nil then
    return nil
  end
  local start_hour = config_loader.parseTime(active_window.start)
  local end_hour = config_loader.parseTime(active_window["end"])
  if start_hour == nil or end_hour == nil then
    return nil
  end
  local hysteresis = (cfg.timing.hysteresis_min or 0) / 60
  local in_window = config_loader.inNightWindow(hour, start_hour, end_hour)
  local in_extended = config_loader.inNightWindow(
    hour,
    config_loader.normalizeHour(start_hour - hysteresis),
    config_loader.normalizeHour(end_hour + hysteresis))
  local previous = is_night
  if previous == nil then
    is_night = in_window
  elseif previous then
    if not in_extended then
      is_night = false
    end
  elseif in_window then
    is_night = true
  end
  local value = is_night and cfg.modes.night_state or cfg.modes.day_state
  local transition = nil
  if previous ~= nil and previous ~= is_night then
    transition = is_night and "night" or "day"
  end
  return math.floor(value + 0.5), transition, hour
end

function M.init(config_module, vehicle_bridge, logger_module)
  config_loader = config_module
  bridge = vehicle_bridge
  logger = logger_module
end

function M.isAuto()
  return auto_enabled
end

function M.isNightNow()
  local cfg = config_loader.loadLightsConfig()
  local active_window = windowForCurrentMap(cfg)
  local hour = gameTodHours()
  if hour == nil then
    return false
  end
  local start_hour = config_loader.parseTime(active_window.start)
  local end_hour = config_loader.parseTime(active_window["end"])
  if start_hour == nil or end_hour == nil then
    return false
  end
  return config_loader.inNightWindow(hour, start_hour, end_hour)
end

function M.aplLights(mode, value)
  mode = tostring(mode or ""):lower()

  if mode == "auto" then
    local vehicle = bridge.getVehicle()
    if not vehicle then
      print("WARN apl_lights: player vehicle not found")
      return false
    end
    local cfg = config_loader.loadLightsConfig()
    local active_window, map_id, from_map = windowForCurrentMap(cfg)
    config = cfg
    window = active_window
    is_night = nil
    local computed = computeTarget(cfg, active_window)
    if computed == nil then
      print("WARN apl_lights: game time unavailable, auto not enabled")
      return false
    end
    if bridge.sendToVehicle(string.format("soulPilotLightsCmd.autoOn(%d)", computed)) then
      auto_enabled = true
      target = computed
      poll_acc = 0
      print("apl_lights: AUTO ON - time " .. tostring(gameTodString() or "?")
        .. ", window " .. active_window.start .. "-" .. active_window["end"]
        .. (from_map and (" (map " .. tostring(map_id) .. ")") or "")
        .. ", target=" .. tostring(computed))
      if logger then
        logger.logLine("INFO", "lights auto ON: map=" .. tostring(map_id)
          .. " window=" .. active_window.start .. "-" .. active_window["end"]
          .. " target=" .. tostring(computed) .. " night=" .. tostring(is_night))
      end
    end
    return true
  end

  if mode == "far" or mode == "near" or mode == "off" then
    local state = mode == "far" and 2 or (mode == "near" and 1 or 0)
    if bridge.sendToVehicle(string.format("soulPilotLightsCmd.setManual(%d)", state)) then
      auto_enabled = false
      target = nil
      is_night = nil
      print("apl_lights: " .. mode:upper() .. " -> state " .. tostring(state))
    end
    return true
  end

  if mode == "night_state" or mode == "day_state" then
    local minimum = mode == "night_state" and 1 or 0
    local numeric = tonumber(value)
    if numeric == nil or numeric ~= numeric or numeric ~= math.floor(numeric)
      or numeric < minimum or numeric > 2 then
      print("Usage: apl_lights(\"" .. mode .. "\", " .. tostring(minimum) .. "..2)")
      return false
    end
    local decoded = config_loader.readJsonFile(config_loader.configPath("lights.json"))
    if not decoded then
      print("ERROR apl_lights: lights.json not found")
      return false
    end
    decoded.modes = decoded.modes or {}
    decoded.modes[mode] = numeric
    pcall(function()
      if FS and FS.directoryCreate then
        FS:directoryCreate(config_loader.USER_CONFIG_DIR, true)
      end
    end)
    local path = config_loader.USER_CONFIG_DIR .. "lights.json"
    if not jsonWriteFile(path, decoded, true) then
      print("ERROR apl_lights: could not write " .. path)
      return false
    end
    print("apl_lights: " .. mode .. "=" .. tostring(numeric) .. " saved")
    if auto_enabled and window ~= nil then
      config = config_loader.loadLightsConfig()
      local computed = computeTarget(config, window)
      if computed ~= nil and computed ~= target then
        if bridge.sendToVehicle(string.format("soulPilotLightsCmd.setTarget(%d)", computed)) then
          target = computed
        end
      end
    end
    return true
  end

  if mode == "status" then
    local cfg = config_loader.loadLightsConfig()
    local active_window, map_id, from_map = windowForCurrentMap(cfg)
    print("apl_lights GE: auto=" .. tostring(auto_enabled) .. ", target=" .. tostring(target))
    print("  map=" .. tostring(map_id or "?") .. (from_map and " (map window)" or " (default window)"))
    print("  time=" .. tostring(gameTodString() or "n/a") .. ", window="
      .. active_window.start .. "-" .. active_window["end"]
      .. ", hysteresis=" .. tostring(cfg.timing.hysteresis_min) .. " min")
    bridge.sendToVehicle("soulPilotLightsCmd.status()")
    return true
  end

  print("Usage: apl_lights(\"auto\"|\"far\"|\"near\"|\"off\"|\"status\")")
  return false
end

function M.onVehicleAutoOff()
  auto_enabled = false
  target = nil
  is_night = nil
  print("apl_lights: manual control detected, auto disabled")
  if logger then
    logger.logLine("INFO", "lights auto disabled by manual control")
  end
end

function M.update(dt)
  if not auto_enabled then
    return
  end
  local poll = config and tonumber(config.timing.poll_hz) or 1
  if poll ~= poll or poll < 0.1 then
    poll = 0.1
  elseif poll > 10 then
    poll = 10
  end
  poll_acc = poll_acc + dt
  if poll_acc < 1 / poll then
    return
  end
  poll_acc = 0
  if config == nil or window == nil then
    return
  end
  local computed, transition = computeTarget(config, window)
  if computed == nil then
    return
  end
  if transition then
    print("apl_lights: " .. (transition == "night" and "NIGHT" or "DAY")
      .. " (" .. tostring(gameTodString() or "?") .. ") -> target=" .. tostring(computed))
    if logger then
      logger.logLine("INFO", "lights " .. transition .. " at " .. tostring(gameTodString() or "?")
        .. " target=" .. tostring(computed))
    end
  end
  if computed ~= target then
    if bridge.sendToVehicle(string.format("soulPilotLightsCmd.setTarget(%d)", computed)) then
      target = computed
    end
  end
end

function M.reset()
  auto_enabled = false
  target = nil
  config = nil
  window = nil
  is_night = nil
  poll_acc = 0
end

return M
