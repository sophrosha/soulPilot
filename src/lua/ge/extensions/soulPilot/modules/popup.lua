-- soulPilot GE popup lights.

local M = {}

local config_loader = nil
local bridge = nil
local logger = nil
local lights = nil

local auto_enabled = false
local night_last = false
local night_acc = 0
local debug_acc = 0

local function playerJBeam(vehicle)
  local ok, value = pcall(function()
    return vehicle.JBeam
  end)
  if ok and type(value) == "string" and value ~= "" then
    local normalized = value:gsub("\\", "/"):match("([^/]+)$") or value
    normalized = normalized:gsub("%.jbeam$", "")
    return normalized:lower()
  end
  return nil
end

function M.init(config_module, vehicle_bridge, logger_module, lights_module)
  config_loader = config_module
  bridge = vehicle_bridge
  logger = logger_module
  lights = lights_module
end

function M.isAuto()
  return auto_enabled
end

function M.aplPopup(mode)
  mode = tostring(mode or "")
  local vehicle = bridge.getVehicle()
  if not vehicle then
    print("apl_popup: player vehicle not found")
    return false
  end

  if mode == "auto" then
    if auto_enabled then
      print("apl_popup: auto already enabled")
      return false
    end
    local jbeam = playerJBeam(vehicle)
    local config = config_loader.loadPopupConfig()
    local debug_delay = tonumber(config.debug_force_blink_delay_s) or 0
    print(string.format("popup: loaded config debug_force_blink_delay_s = %.1f", debug_delay))
    if logger then
      logger.logLine("INFO", string.format("popup: loaded config debug_force_blink_delay_s = %.1f", debug_delay))
    end
    local allowed = false
    for _, model in ipairs(config.models) do
      if model == jbeam then
        allowed = true
        break
      end
    end
    if not allowed then
      print("apl_popup: " .. tostring(jbeam or "?") .. " is not supported by popup.json")
      return false
    end

    local night = lights.isNightNow()
    auto_enabled = true
    night_last = night
    night_acc = 0
    debug_acc = 0
    bridge.sendToVehicle(string.format(
      "soulPilotPopupCmd.start({dayMin=%.1f,dayMax=%.1f,nightMin=%.1f,nightMax=%.1f,blinkMin=%.2f,blinkMax=%.2f,debugDelay=%.1f,night=%s})",
      config.day_min_s,
      config.day_max_s,
      config.night_min_s,
      config.night_max_s,
      config.blink_min_s,
      config.blink_max_s,
      config.debug_force_blink_delay_s,
      tostring(night)))
    bridge.sendToVehicle("soulPilotPopupCmd.setNight(" .. tostring(night) .. ")")
    print("apl_popup: auto ON (" .. tostring(jbeam) .. "), night=" .. tostring(night))
    if logger then
      logger.logLine("INFO", "popup auto ON: model=" .. tostring(jbeam) .. " night=" .. tostring(night))
    end
    return true
  end

  if mode == "off" then
    if not auto_enabled then
      print("apl_popup: auto already disabled")
      return false
    end
    auto_enabled = false
    bridge.sendToVehicle("soulPilotPopupCmd.stop()")
    print("apl_popup: auto OFF")
    if logger then
      logger.logLine("INFO", "popup auto OFF")
    end
    return true
  end

  if mode == "status" then
    local config = config_loader.loadPopupConfig()
    print("--- apl_popup status ---")
    print("auto=" .. tostring(auto_enabled) .. ", night=" .. tostring(lights.isNightNow()))
    print("day=" .. string.format("%.0f", config.day_min_s) .. "-"
      .. string.format("%.0f", config.day_max_s) .. " s, night="
      .. string.format("%.0f", config.night_min_s) .. "-"
      .. string.format("%.0f", config.night_max_s) .. " s")
    bridge.sendToVehicle("soulPilotPopupCmd.status()")
    return true
  end

  print("Usage: apl_popup(\"auto\"|\"off\"|\"status\")")
  return false
end

function M.onVehicleAutoOff()
  if not auto_enabled then
    return
  end
  auto_enabled = false
  print("apl_popup: auto disabled by manual light control")
  if logger then
    logger.logLine("WARN", "popup auto disabled by manual light control")
  end
end

function M.update(dt)
  if not auto_enabled then
    return
  end
  night_acc = night_acc + dt
  if night_acc < 5 then
    return
  end
  night_acc = 0

  local ok, night = pcall(function()
    return lights.isNightNow()
  end)
  if not ok then
    return
  end
  bridge.sendToVehicle("soulPilotPopupCmd.setNight(" .. tostring(night) .. ")")

  debug_acc = debug_acc + 5
  if night ~= night_last then
    night_last = night
    debug_acc = 0
    print("apl_popup: " .. (night and "NIGHT" or "DAY") .. " setNight=" .. tostring(night))
    if logger then
      logger.logLine("INFO", "popup night=" .. tostring(night))
    end
  elseif debug_acc >= 30 then
    debug_acc = 0
    print("apl_popup: keepalive night=" .. tostring(night))
  end
end

function M.reset()
  auto_enabled = false
  night_last = false
  night_acc = 0
  debug_acc = 0
end

return M
