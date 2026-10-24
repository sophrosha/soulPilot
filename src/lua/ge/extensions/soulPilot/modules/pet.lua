-- soulPilot GE pet mode.

local M = {}

local config_loader = nil
local bridge = nil
local logger = nil

local active = false
local sound_event = ""
local sound_ids = {}

local function stopSound()
  for _, id in ipairs(sound_ids) do
    pcall(function()
      Engine.Audio.deleteSource(id)
    end)
  end
  sound_ids = {}
  sound_event = ""
end

local function playPurr(config)
  if type(config.sound_event) ~= "string" or config.sound_event == "" then
    return false
  end

  local options = {
    volume = config.sound_volume,
    pitch = config.pitch,
  }
  if config.sound_no_pos then
    options.no_pos = true
  end

  -- The VFS path (art/sound/...) is the normal form. The file: form is a
  -- fallback for older GE builds that need an explicit file prefix.
  local attempts = { config.sound_event }
  if not config.sound_event:match("^file:") then
    attempts[#attempts + 1] = "file:" .. config.sound_event
  end

  for _, sound_name in ipairs(attempts) do
    local ok, source = pcall(function()
      return Engine.Audio.playOnce("AudioGui", sound_name, options)
    end)
    if ok and source ~= nil then
      sound_ids[#sound_ids + 1] = source
      sound_event = config.sound_event
      print("apl_pet: playOnce " .. sound_name .. " -> OK")
      return true
    end
    print("apl_pet: playOnce " .. sound_name .. " -> failed")
  end

  return false
end

function M.init(config_module, vehicle_bridge, logger_module)
  config_loader = config_module
  bridge = vehicle_bridge
  logger = logger_module
end

function M.aplPet(mode)
  mode = tostring(mode or ""):lower()

  if mode == "on" then
    local vehicle = bridge.getVehicle()
    if not vehicle then
      print("WARN apl_pet: player vehicle not found")
      return false
    end

    local config = config_loader.loadPetConfig()
    local command = string.format(
      "soulPilotPetCmd.start({duration=%.2f, offset=%.3f, amp=%.3f, hz=%.3f, "
        .. "rateScale=%.2f, speedGateKph=%.1f, spamMax=%d, spamWindow=%.1f, cooldown=%.1f, "
        .. "soundEvent=\"%s\", soundInterval=%.2f, soundVolume=%.2f})",
      config.duration_s,
      config.offset,
      config.amp,
      config.hz,
      config.steer_rate_scale,
      config.speed_gate_kph,
      config.spam_max,
      config.spam_window_s,
      config.cooldown_s,
      (config.sound_event or ""):gsub('"', '\\"'),
      config.sound_interval,
      config.sound_volume)

    if not bridge.sendToVehicle(command) then
      return false
    end

    active = true
    playPurr(config)

    print("apl_pet: command sent (config=" .. (config.from_file and "file" or "DEFAULTS") .. ")")
    if logger then
      logger.logLine("INFO", "pet start sent, sound=" .. tostring(config.sound_event))
    end
    return true
  end

  if mode == "off" then
    stopSound()
    active = false
    bridge.sendToVehicle("soulPilotPetCmd.stop()")
    print("apl_pet: petting stopped")
    if logger then
      logger.logLine("INFO", "pet stop sent")
    end
    return true
  end

  if mode == "status" then
    local config = config_loader.loadPetConfig()
    print("apl_pet GE: sound=" .. tostring(config.sound_event ~= "" and config.sound_event or "off")
      .. ", interval=" .. string.format("%.2f", config.sound_interval)
      .. ", config=" .. (config.from_file and "file" or "DEFAULTS"))
    bridge.sendToVehicle("soulPilotPetCmd.status()")
    return true
  end

  print("Usage: apl_pet(\"on\"|\"off\"|\"status\")")
  return false
end

function M.onVehiclePetDone()
  stopSound()
  active = false
  if logger then
    logger.logLine("INFO", "pet finished by vehicle")
  end
end

function M.onVehiclePetRejected()
  stopSound()
  active = false
  if logger then
    logger.logLine("INFO", "pet rejected by vehicle")
  end
end

function M.isActive()
  return active
end

function M.reset()
  stopSound()
  active = false
end

return M
