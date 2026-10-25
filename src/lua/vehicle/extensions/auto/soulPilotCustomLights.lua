-- soulPilot custom cat-squint cover controller.
-- The controller writes a normalized 0..1 value to the custom JBeam hydro input.

local M = {}

local DEFAULT_MIN = 0.25
local DEFAULT_MAX = 0.40
local DEFAULT_DURATION = 6.0
local MOVE_RATE = 1.5
local IDLE_DELAY = 30.0
local SEATED_GRACE = 7.0
local STOP_SPEED_MPS = 0.20

local squint_min = DEFAULT_MIN
local squint_max = DEFAULT_MAX
local squint_duration = DEFAULT_DURATION

local current = 0.0
local target = 0.0
local initialized = false
local squint_active = false
local squint_elapsed = 0.0

local idle_timer = 0.0
local seated_grace = 0.0
local was_seated = false
local absent_hold = false

local function clampUnit(value)
  value = tonumber(value)
  if value == nil or value ~= value then
    return 0.0
  end
  return math.max(0.0, math.min(1.0, value))
end

local function moveToward(value, wanted, max_step)
  if value < wanted then
    return math.min(value + max_step, wanted)
  end
  if value > wanted then
    return math.max(value - max_step, wanted)
  end
  return value
end

local function writeValue(value)
  pcall(function()
    electrics.values.soulPilotPopupFloat = value
  end)
end

local function readConfigFile(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local content = file:read("*all")
  file:close()
  if not content or content == "" then
    return nil
  end
  local ok, decoded = pcall(jsonDecode, content, path)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function loadSquintConfig()
  local paths = {
    "settings/mod_settings/soulPilot/popup.json",
    "mods/unpacked/soulPilot/config/popup.json",
    "mods/unpacked/soulPilot/src/config/popup.json",
  }
  for _, path in ipairs(paths) do
    local decoded = readConfigFile(path)
    if decoded then
      local minimum = tonumber(decoded.squint_min)
      local maximum = tonumber(decoded.squint_max)
      local duration = tonumber(decoded.squint_duration_s)
      if minimum ~= nil and maximum ~= nil and minimum >= 0 and maximum <= 1 and maximum >= minimum then
        squint_min = minimum
        squint_max = maximum
      end
      if duration ~= nil and duration > 0 then
        squint_duration = duration
      end
      return
    end
  end
end

local function isSeated()
  local seated = false
  pcall(function()
    seated = playerInfo and playerInfo.anyPlayerSeated == true or false
  end)
  return seated
end

local function isEngineRunning()
  local running = false
  pcall(function()
    running = (electrics.values.engineRunning or 0) > 0
  end)
  return running
end

local function isWarm()
  local warm = false
  pcall(function()
    warm = soulPilotWarmupCmd
      and soulPilotWarmupCmd.getState
      and soulPilotWarmupCmd.getState() == "done"
  end)
  return warm
end

local function speedMps()
  local speed = 0.0
  pcall(function()
    speed = obj:getVelocity():length()
  end)
  return math.max(0.0, speed)
end

local function applyAbsentHold()
  if absent_hold then
    return
  end
  absent_hold = true
  pcall(function()
    if ai and ai.setMode then
      ai.setMode("stop")
    end
  end)
  pcall(function()
    if controller and controller.mainController and controller.mainController.smartParkingBrake then
      controller.mainController.smartParkingBrake(1)
    end
  end)
end

local function releaseAbsentHold()
  if not absent_hold then
    return
  end
  absent_hold = false
  pcall(function()
    if controller and controller.mainController and controller.mainController.smartParkingBrake then
      controller.mainController.smartParkingBrake(0)
    end
  end)
end

local function startSquint()
  loadSquintConfig()
  squint_active = true
  squint_elapsed = 0.0
  target = squint_min
end

function M.configure(minimum, maximum, duration)
  local new_min = tonumber(minimum)
  local new_max = tonumber(maximum)
  local new_duration = tonumber(duration)
  if new_min ~= nil and new_max ~= nil and new_min >= 0 and new_max <= 1 and new_max >= new_min then
    squint_min = new_min
    squint_max = new_max
  end
  if new_duration ~= nil and new_duration > 0 then
    squint_duration = new_duration
  end
  return true
end

function M.playCatSquint()
  startSquint()
  return true
end

function M.release()
  squint_active = false
  target = 1.0
  return true
end

function M.getState()
  return {
    current = current,
    target = target,
    squint_active = squint_active,
    squint_min = squint_min,
    squint_max = squint_max,
    duration = squint_duration,
    idle_timer = idle_timer,
    seated = isSeated(),
    warm = isWarm(),
  }
end

function M.updateGFX(dt)
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then
    return
  end

  if not initialized then
    local lights = tonumber(electrics.values.lights_state) or 0
    current = lights > 0 and 1.0 or 0.0
    target = current
    initialized = true
    writeValue(current)
  end

  if squint_active then
    local phase = math.max(0.0, math.sin(2.0 * math.pi * squint_elapsed / squint_duration))
    target = squint_min + (phase * phase * phase) * (squint_max - squint_min)
    squint_elapsed = squint_elapsed + dt
    if squint_elapsed >= squint_duration then
      squint_active = false
      target = 1.0
    end
  end

  current = moveToward(current, target, MOVE_RATE * dt)
  writeValue(current)

  local seated = isSeated()
  if seated then
    if not was_seated then
      seated_grace = SEATED_GRACE
      releaseAbsentHold()
    end
    was_seated = true
    idle_timer = 0.0
    return
  end

  was_seated = false
  if seated_grace > 0 then
    seated_grace = math.max(0.0, seated_grace - dt)
  end

  if not squint_active and isWarm() and isEngineRunning() then
    applyAbsentHold()
    if speedMps() <= STOP_SPEED_MPS and seated_grace <= 0 then
      idle_timer = idle_timer + dt
      if idle_timer >= IDLE_DELAY then
        idle_timer = 0.0
        startSquint()
      end
    else
      idle_timer = 0.0
    end
  else
    idle_timer = 0.0
  end
end

function M.onReset()
  loadSquintConfig()
  current = 0.0
  target = 0.0
  initialized = false
  squint_active = false
  squint_elapsed = 0.0
  idle_timer = 0.0
  seated_grace = 0.0
  was_seated = false
  absent_hold = false
  writeValue(current)
end

function M.onVehicleDestroyed()
  M.onReset()
end

soulPilotCustomLightsCmd = {}

function soulPilotCustomLightsCmd.playCatSquint()
  return M.playCatSquint()
end

function soulPilotCustomLightsCmd.release()
  return M.release()
end

function soulPilotCustomLightsCmd.configure(minimum, maximum, duration)
  return M.configure(minimum, maximum, duration)
end

function soulPilotCustomLightsCmd.status()
  local state = M.getState()
  print(string.format(
    "soulPilotCustomLights: current=%.2f target=%.2f squint=%s range=%.2f..%.2f duration=%.1f idle=%.1f seated=%s",
    state.current,
    state.target,
    tostring(state.squint_active),
    state.squint_min,
    state.squint_max,
    state.duration,
    state.idle_timer,
    tostring(state.seated)))
  return true
end

return M
