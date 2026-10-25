-- soulPilot custom cat-squint cover controller.
-- The controller writes a normalized 0..1 value to the custom JBeam hydro input.
--
-- The game's popup covers still use lights_state for the normal blink cycle.
-- This module mirrors lights_state into soulPilotPopupFloat and only overrides
-- the covers while a cat-squint animation or an absent-driver hold is active.

local M = {}

local DEFAULT_MIN = 0.27
local DEFAULT_MAX = 0.50
local DEFAULT_DURATION = 6.0
local MOVE_RATE = 1.5
local IDLE_DELAY = 6.0
local DRIVER_RETURN_WAIT = 10.0
local STOP_SPEED_MPS = 0.20
local FEATURE_WARN_DELAY = 1.5

local DEFAULT_MODELS = { "bolide", "wigeon", "bx", "wendover", "barstow" }

local squint_min = DEFAULT_MIN
local squint_max = DEFAULT_MAX
local squint_duration = DEFAULT_DURATION
local popup_models = DEFAULT_MODELS

local current = 0.0
local target = 0.0
local initialized = false
local squint_active = false
local squint_elapsed = 0.0

local managed = false
local custom_available = nil
local feature_warned = false
local managed_time = 0.0

local idle_timer = 0.0
local was_seated = false
local absent_hold = false
local return_grace = 0.0
local seated_wait = 0.0
local waiting_for_warmup = false
local door_lock_requested = false
local door_locked = false
local door_close_acc = 0.0
local door_message_cooldown = 0.0

local function moveToward(value, wanted, max_step)
  if value < wanted then
    return math.min(value + max_step, wanted)
  end
  if value > wanted then
    return math.max(value - max_step, wanted)
  end
  return value
end

local function lightsTarget()
  local lights = 0
  pcall(function()
    lights = tonumber(electrics.values.lights_state) or 0
  end)
  return lights > 0 and 1.0 or 0.0
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

local function applySquintConfig(decoded)
  if type(decoded.models) == "table" then
    local models = {}
    for _, value in ipairs(decoded.models) do
      if type(value) == "string" and value ~= "" then
        models[#models + 1] = value:lower()
      end
    end
    if #models > 0 then
      popup_models = models
    end
  end

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
end

local function loadSquintConfig()
  squint_min = DEFAULT_MIN
  squint_max = DEFAULT_MAX
  squint_duration = DEFAULT_DURATION
  popup_models = DEFAULT_MODELS

  -- Low priority first, user overrides last. Config keys are applied
  -- individually so a user file that only changes one value still works.
  local paths = {
    "mods/unpacked/soulPilot/src/config/popup.json",
    "mods/unpacked/soulPilot/config/popup.json",
    "settings/mod_settings/soulPilot/popup.json",
  }
  for _, path in ipairs(paths) do
    local decoded = readConfigFile(path)
    if decoded then
      applySquintConfig(decoded)
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

local function warmupActive()
  local active = false
  pcall(function()
    if soulPilotWarmupCmd and soulPilotWarmupCmd.isActive then
      active = soulPilotWarmupCmd.isActive() == true
    elseif soulPilotWarmupCmd and soulPilotWarmupCmd.getState then
      local state = soulPilotWarmupCmd.getState()
      active = state == "starting_engine" or state == "warming_up"
    end
  end)
  return active
end

local function warmupFinished()
  local finished = false
  pcall(function()
    if soulPilotWarmupCmd and soulPilotWarmupCmd.isDone then
      finished = soulPilotWarmupCmd.isDone() == true
    elseif soulPilotWarmupCmd and soulPilotWarmupCmd.getState then
      local state = soulPilotWarmupCmd.getState()
      finished = state == "done" or state == "done_outside"
    end
  end)
  return finished
end

local function isWarm()
  return warmupFinished()
end

local function speedMps()
  local speed = 0.0
  pcall(function()
    speed = obj:getVelocity():length()
  end)
  return math.max(0.0, speed)
end

local function aiDriving()
  local driving = false
  pcall(function()
    driving = (ai and ai.isDriving and ai.isDriving()) or false
  end)
  return driving == true
end

local function setObjectPlayerLocked(locked)
  pcall(function()
    if obj and obj.setPlayerLocked then
      obj:setPlayerLocked(locked == true)
    end
  end)
end

local function closeDoors()
  pcall(function()
    if not (controller and controller.getControllersByType) then
      return
    end
    for _, coupler in pairs(controller.getControllersByType("advancedCouplerControl") or {}) do
      if coupler and coupler.tryAttachGroupImpulse then
        pcall(coupler.tryAttachGroupImpulse, coupler)
      end
    end
  end)
end

local function doorsDetached()
  local detached = false
  pcall(function()
    if not (controller and controller.getControllersByType) then
      return
    end
    for _, coupler in pairs(controller.getControllersByType("advancedCouplerControl") or {}) do
      if coupler and coupler.getGroupState then
        local state = coupler:getGroupState()
        if state ~= "attached" and state ~= "coupling" and state ~= "autoCoupling" then
          detached = true
          return
        end
      end
    end
  end)
  return detached
end

local function updateDoorLock(dt)
  local should_lock = door_lock_requested
  if not should_lock and managed then
    should_lock = speedMps() * 3.6 > 5.0 or (isSeated() and aiDriving())
  end

  if should_lock then
    door_message_cooldown = math.max(0.0, door_message_cooldown - dt)
    if door_message_cooldown <= 0.0 and doorsDetached() then
      door_message_cooldown = 1.0
      pcall(function()
        guihooks.message({ txt = "soulPilot.doors_locked", context = {} }, 3, "soulPilot.doorLock")
      end)
    end

    if not door_locked then
      door_locked = true
      setObjectPlayerLocked(true)
      closeDoors()
    end
    door_close_acc = door_close_acc + dt
    if door_close_acc >= 0.25 then
      door_close_acc = 0.0
      closeDoors()
    end
  else
    door_close_acc = 0.0
    if door_locked then
      door_locked = false
      setObjectPlayerLocked(false)
    end
  end
end

local function customInputAvailable()
  local available = false
  pcall(function()
    for _, hydro in pairs(hydros.hydros or {}) do
      if hydro.inputSource == "soulPilotPopupFloat" then
        available = true
        return
      end
    end
  end)
  custom_available = available
  return available
end

local function isPopupModel()
  local model = ""
  pcall(function()
    model = tostring(obj:getJBeamFilename() or ""):lower()
  end)
  for _, allowed in ipairs(popup_models) do
    if model == allowed then
      return true
    end
  end
  return false
end

local function warnMissingOverride()
  if feature_warned or not managed then
    return
  end
  feature_warned = true
  local model = "?"
  pcall(function()
    model = tostring(obj:getJBeamFilename() or "?")
  end)
  if isPopupModel() then
    print("WARN soulPilotCustomLights: soulPilotPopupFloat hydro input not found for "
      .. model .. "; custom covers disabled, lights_state remains in control")
  end
end

local function setParkingBrake(value)
  local applied = false
  pcall(function()
    if controller and controller.mainController and controller.mainController.smartParkingBrake then
      controller.mainController.smartParkingBrake(value)
      applied = true
    end
  end)
  if not applied then
    pcall(function()
      electrics.values.parkingbrake = value
    end)
  end
end

local function setAiMode(mode)
  local applied = false
  pcall(function()
    if ai and ai.setMode then
      ai.setMode(mode)
      applied = true
    end
  end)
  return applied
end

local function forceHeadlights()
  pcall(function()
    if electrics.setLightsState then
      electrics.setLightsState(1)
    else
      electrics.values.lights_state = 1
    end
  end)
end

local function applyAbsentHold()
  if not managed then
    return
  end
  -- Re-assert this every frame. Warmup/master callbacks can otherwise put a
  -- driverless car back into traffic after the first exit.
  absent_hold = true
  setAiMode("disabled")
  setParkingBrake(1)
end

local function releaseAbsentHold()
  if not absent_hold then
    return
  end
  absent_hold = false
  setParkingBrake(0)
end

local function restoreAi()
  -- The player came back: undo the involuntary stop and hand control back
  -- to traffic AI. The player can still override it with their own input.
  releaseAbsentHold()
  setAiMode("traffic")
end

local function startSquint()
  if not customInputAvailable() then
    return false
  end
  loadSquintConfig()
  squint_active = true
  squint_elapsed = 0.0
  target = squint_min
  return true
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

function M.setManaged(value)
  managed = value == true or value == 1
  managed_time = 0.0
  if not managed then
    squint_active = false
    squint_elapsed = 0.0
    idle_timer = 0.0
    was_seated = false
    return_grace = 0.0
    seated_wait = 0.0
    waiting_for_warmup = false
  end
  return managed
end

function M.playCatSquint()
  -- AI traffic vehicles are not managed (they are not the player's car), but
  -- they may still have the popup JBeam override and should squint when the
  -- global pet-all command asks them to. The custom JBeam check in startSquint
  -- makes vehicles without covers ignore the request.
  if not managed and isSeated() then
    managed = true
  end
  return startSquint()
end

function M.release()
  squint_active = false
  squint_elapsed = 0.0
  target = lightsTarget()
  return true
end

function M.setDoorLock(value)
  door_lock_requested = value == true
  if door_lock_requested then
    door_locked = true
    setObjectPlayerLocked(true)
    closeDoors()
  elseif door_locked then
    door_locked = false
    setObjectPlayerLocked(false)
  end
  return door_lock_requested
end

function M.resetDoorLock()
  door_lock_requested = false
  door_locked = false
  door_close_acc = 0.0
  setObjectPlayerLocked(false)
  return true
end

function M.closeDoors()
  closeDoors()
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
    managed = managed,
    custom_input = custom_available,
    door_locked = door_locked,
    door_lock_requested = door_lock_requested,
  }
end

function M.updateGFX(dt)
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then
    return
  end

  if not managed and isSeated() then
    managed = true
  end
  if managed then
    managed_time = managed_time + dt
  end

  local seated_now = isSeated()
  if managed and not seated_now and isEngineRunning() and warmupFinished() then
    forceHeadlights()
  end

  local custom = customInputAvailable()
  if custom then
    if not initialized then
      current = lightsTarget()
      target = current
      initialized = true
    end

    if squint_active then
      local phase = math.max(0.0, math.sin(2.0 * math.pi * squint_elapsed / squint_duration))
      target = squint_min + (phase * phase * phase) * (squint_max - squint_min)
      squint_elapsed = squint_elapsed + dt
      if squint_elapsed >= squint_duration then
        squint_active = false
        target = lightsTarget()
      end
    else
      target = lightsTarget()
    end

    current = moveToward(current, target, MOVE_RATE * dt)
    writeValue(current)
  elseif managed and managed_time >= FEATURE_WARN_DELAY then
    warnMissingOverride()
  end

  updateDoorLock(dt)

  if not managed then
    return
  end

  local seated = seated_now
  if seated then
    if not was_seated then
      if absent_hold then
        if warmupActive() then
          -- The warmup is still running: hold the car but do not start the
          -- driver-return timer yet.
          waiting_for_warmup = true
        else
          waiting_for_warmup = false
          seated_wait = DRIVER_RETURN_WAIT
          startSquint()
        end
      else
        waiting_for_warmup = false
      end
      idle_timer = 0.0
    end
    was_seated = true

    if waiting_for_warmup then
      if warmupFinished() then
        waiting_for_warmup = false
        seated_wait = DRIVER_RETURN_WAIT
        startSquint()
      else
        applyAbsentHold()
        return
      end
    end

    if seated_wait > 0 then
      applyAbsentHold()
      seated_wait = math.max(0.0, seated_wait - dt)
      if seated_wait <= 0 then
        restoreAi()
        return_grace = 1.0
      end
    elseif absent_hold then
      restoreAi()
      return_grace = 1.0
    end
    return
  end

  was_seated = false
  seated_wait = 0.0
  waiting_for_warmup = false

  -- Avoid immediately re-stopping the car if seating state arrives one frame
  -- later than the AI/parking-brake release after the player gets back in.
  if return_grace > 0 then
    return_grace = math.max(0.0, return_grace - dt)
    idle_timer = 0.0
    return
  end

  applyAbsentHold()

  if isEngineRunning() and warmupFinished() then
    forceHeadlights()
  end

  if not squint_active and isEngineRunning() and warmupFinished() then
    if speedMps() <= STOP_SPEED_MPS then
      idle_timer = idle_timer + dt
      if idle_timer >= IDLE_DELAY then
        idle_timer = 0.0
        if custom then
          startSquint()
        end
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
  was_seated = false
  absent_hold = false
  return_grace = 0.0
  seated_wait = 0.0
  waiting_for_warmup = false
  door_locked = false
  door_lock_requested = false
  door_close_acc = 0.0
  door_message_cooldown = 0.0
  setObjectPlayerLocked(false)
  custom_available = nil
  managed_time = 0.0
  -- Keep managed: a respawn of the player's vehicle must keep the feature on.
end

function M.onVehicleDestroyed()
  M.onReset()
end

soulPilotCustomLightsCmd = {}

function soulPilotCustomLightsCmd.setManaged(value)
  return M.setManaged(value)
end

function soulPilotCustomLightsCmd.playCatSquint()
  return M.playCatSquint()
end

function soulPilotCustomLightsCmd.release()
  return M.release()
end

function soulPilotCustomLightsCmd.setDoorLock(value)
  return M.setDoorLock(value)
end

function soulPilotCustomLightsCmd.resetDoorLock()
  return M.resetDoorLock()
end

function soulPilotCustomLightsCmd.closeDoors()
  return M.closeDoors()
end

function soulPilotCustomLightsCmd.configure(minimum, maximum, duration)
  return M.configure(minimum, maximum, duration)
end

function soulPilotCustomLightsCmd.status()
  local state = M.getState()
  print(string.format(
    "soulPilotCustomLights: current=%.2f target=%.2f squint=%s range=%.2f..%.2f duration=%.1f idle=%.1f seated=%s managed=%s custom=%s doors=%s manual=%s",
    state.current,
    state.target,
    tostring(state.squint_active),
    state.squint_min,
    state.squint_max,
    state.duration,
    state.idle_timer,
    tostring(state.seated),
    tostring(state.managed),
    tostring(state.custom_input),
    tostring(state.door_locked),
    tostring(state.door_lock_requested)))
  return true
end

loadSquintConfig()

return M
