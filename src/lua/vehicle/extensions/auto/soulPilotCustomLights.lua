-- soulPilot custom cat-squint cover controller.
-- Writes a normalized 0..1 value to the custom JBeam hydro input source.

local M = {}

local TIMELINE = {
  0.0, 0.2, 0.5, 0.75, 0.85, 0.85, 0.82, 0.85, 0.84,
  0.70, 0.55, 0.40, 0.30, 0.25, 0.27, 0.20, 0.10, 0.0,
}
local TIMELINE_STEP = 0.1
local DEFAULT_RATE = 4.0
local IDLE_DELAY = 30.0
local SEATED_GRACE = 7.0

local current = 1.0
local target = 1.0
local rate = DEFAULT_RATE
local timeline = nil
local timeline_index = 1
local timeline_timer = 0
local playing = false

local idle_timer = 0
local seated_grace = 0
local was_seated = false

local function clamp(value)
  value = tonumber(value)
  if value == nil or value ~= value then
    return current
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

local function startTimeline()
  timeline = TIMELINE
  timeline_index = 2
  timeline_timer = 0
  playing = true
  target = timeline[1]
  if aplPrint then
    aplPrint("soulPilotCustomLights: cat squint started")
  end
end

function M.playCatSquint()
  startTimeline()
  return true
end

function M.release()
  playing = false
  timeline = nil
  timeline_index = 1
  timeline_timer = 0
  target = 1.0
  return true
end

function M.setTarget(value)
  playing = false
  timeline = nil
  target = clamp(value)
  return target
end

function M.getState()
  return {
    current = current,
    target = target,
    playing = playing,
    idle_timer = idle_timer,
    seated = isSeated(),
    warm = isWarm(),
  }
end

function M.updateGFX(dt)
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then
    return
  end

  if playing and timeline then
    timeline_timer = timeline_timer + dt
    while timeline_timer >= TIMELINE_STEP do
      timeline_timer = timeline_timer - TIMELINE_STEP
      if timeline_index <= #timeline then
        target = timeline[timeline_index]
        timeline_index = timeline_index + 1
      else
        playing = false
        timeline = nil
        target = 1.0
        break
      end
    end
  end

  current = moveToward(current, target, rate * dt)
  writeValue(current)

  local seated = isSeated()
  if seated then
    if not was_seated then
      seated_grace = SEATED_GRACE
    end
    was_seated = true
    idle_timer = 0
    return
  end

  was_seated = false
  if seated_grace > 0 then
    seated_grace = math.max(0, seated_grace - dt)
  end

  if not playing and isWarm() and isEngineRunning() and seated_grace <= 0 then
    idle_timer = idle_timer + dt
    if idle_timer >= IDLE_DELAY then
      idle_timer = 0
      startTimeline()
    end
  else
    idle_timer = 0
  end
end

function M.onReset()
  current = 1.0
  target = 1.0
  playing = false
  timeline = nil
  timeline_index = 1
  timeline_timer = 0
  idle_timer = 0
  seated_grace = 0
  was_seated = false
  writeValue(current)
end

function M.onVehicleDestroyed()
  M.onReset()
end

-- Public command table for future GE/UI integrations.
soulPilotCustomLightsCmd = {}

function soulPilotCustomLightsCmd.playCatSquint()
  return M.playCatSquint()
end

function soulPilotCustomLightsCmd.release()
  return M.release()
end

function soulPilotCustomLightsCmd.status()
  local state = M.getState()
  print(string.format(
    "soulPilotCustomLights: current=%.2f target=%.2f playing=%s idle=%.1f seated=%s warm=%s",
    state.current,
    state.target,
    tostring(state.playing),
    state.idle_timer,
    tostring(state.seated),
    tostring(state.warm)))
  return true
end

return M
