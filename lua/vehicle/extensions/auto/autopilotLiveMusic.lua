-- AutopilotLive — Фаза 11.2: Spotify/Audio-Reactive (vehicle-слой)
-- Загружается автоматически (lua/vehicle/extensions/auto).
--
-- Ответственность:
--   * принимать bass/beat/bpm/night от GE (autopilotLiveMusicCmd.set);
--   * на стоянке/прогреве: лёгкий качок руля (bass_smooth) и микро-толчок
--     руля на фронт beat; фары от музыки отключены (lights_pulse=0);
--   * в движении: микро-вибрация руля vibration_amp*bass_smooth на
--     vibration_hz — добавляется ПОСЛЕ сглаживания (хук в wheel);
--   * bass сглаживается EMA (dt*5.0), чтобы удары не дёргали руль;
--   * не трогает газ/тормоз/КПП, не вызывает input.event.
--
-- Приоритеты: при петмоде/боли/ручном вождении музыка не вмешивается
-- (качок и вибрация = 0; свет не пульсирует при night и lights_state=2).

local M = {}

local CONF = 'mods/unpacked/AutopilotLive/ai/config/music.json'
local STALE_S = 0.3

local DEFAULTS = {
  stationary_speed_kph = 3.0,
  pulse_ms = 120,
  blink_min_interval_ms = 200,
  sway_amp = 0.005,
  sway_hz = 0.6,
  vibration_amp = 0.001,
  vibration_hz = 6.0,
  vibration_min_speed_kph = 5.0,
  lights_pulse = 0,
  beat_kick_amp = 0.01,
  beat_kick_ms = 90,
}

local cfg = nil
local cfgFromFile = false
local active = false
local t = 0
local dataAge = STALE_S + 1
local bass, beat, bpm = 0, 0, 0
local bassSmooth = 0        -- Фаза 11.3: EMA баса перед применением к рулю
local night = false

local prevBeat = 0
local lightHeld = false
local pulseActive = false
local pulseUntil = 0
local baseLight = 0
local lastPulseT = -1e9
local lastSpeedKph = 0
local kickActive = false    -- Фаза 11.3: затухающий импульс руля на beat
local kickStart = -1e9

local function toGE(level, msg)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if extensions and extensions.autopilotLive_main and extensions.autopilotLive_main.onVehicleLog then extensions.autopilotLive_main.onVehicleLog("%s", "%s") end',
      level, tostring(msg):gsub('\\', '\\\\'):gsub('"', '\\"')))
  end)
end

local function clamp(v, lo, hi, dflt)
  v = tonumber(v)
  if v == nil or v ~= v then return dflt end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function loadConfig()
  local c = {}
  for k, v in pairs(DEFAULTS) do c[k] = v end
  local f = io.open(CONF, 'r')
  if not f then
    toGE('WARN', 'music: конфиг не найден (' .. CONF .. ') — дефолты кода')
    return c, false
  end
  local content = f:read('*all')
  f:close()
  local ok, decoded = pcall(jsonDecode, content, CONF)
  if not ok or type(decoded) ~= 'table' then
    toGE('WARN', 'music: конфиг не распарсен — дефолты кода')
    return c, false
  end
  c.stationary_speed_kph = clamp(decoded.stationary_speed_kph, 0.1, 30, c.stationary_speed_kph)
  c.pulse_ms = clamp(decoded.pulse_ms, 30, 1000, c.pulse_ms)
  c.blink_min_interval_ms = clamp(decoded.blink_min_interval_ms, 200, 5000, c.blink_min_interval_ms)
  c.sway_amp = clamp(decoded.sway_amp, 0, 0.1, c.sway_amp)
  c.sway_hz = clamp(decoded.sway_hz, 0.05, 3, c.sway_hz)
  c.vibration_amp = clamp(decoded.vibration_amp, 0, 0.01, c.vibration_amp)
  c.vibration_hz = clamp(decoded.vibration_hz, 1, 30, c.vibration_hz)
  c.vibration_min_speed_kph = clamp(decoded.vibration_min_speed_kph, 0, 100, c.vibration_min_speed_kph)
  c.lights_pulse = clamp(decoded.lights_pulse, 0, 1, c.lights_pulse)
  c.beat_kick_amp = clamp(decoded.beat_kick_amp, 0, 0.05, c.beat_kick_amp)
  c.beat_kick_ms = clamp(decoded.beat_kick_ms, 20, 500, c.beat_kick_ms)
  return c, true
end

local function speedKph()
  local v = 0
  pcall(function() v = obj:getVelocity():length() end)
  v = tonumber(v) or 0
  if v ~= v then v = 0 end
  return v * 3.6
end

local function curLights()
  local s = 0
  pcall(function() s = electrics.values.lights_state or 0 end)
  s = tonumber(s) or 0
  if s ~= s then return 0 end
  return math.floor(s + 0.5)
end

local function musicReady()
  return active and dataAge <= STALE_S
end

local function lightsAllowed(speed)
  if not musicReady() then return false end
  if cfg == nil or cfg.lights_pulse <= 0 then return false end
  if night then return false end
  if speed > cfg.stationary_speed_kph then return false end
  if not autopilotLivePopupCmd or not autopilotLivePopupCmd.musicOverride then return false end
  return true
end

local function overrideLights(state)
  if autopilotLivePopupCmd and autopilotLivePopupCmd.musicOverride then
    pcall(autopilotLivePopupCmd.musicOverride, state)
    lightHeld = true
    return true
  end
  return false
end

local function releaseLights(restore)
  if not lightHeld then return end
  if restore then
    overrideLights(baseLight)
  end
  lightHeld = false
  pulseActive = false
  if autopilotLivePopupCmd and autopilotLivePopupCmd.musicRelease then
    pcall(autopilotLivePopupCmd.musicRelease)
  end
end

-- Импульс в такт: из 0 открываем 1, из 1 закрываем 0; 2 (дальний) не трогаем.
local function pulseLights(speed)
  if not lightsAllowed(speed) then return false end
  if t - lastPulseT < cfg.blink_min_interval_ms / 1000 then return false end
  local base = curLights()
  if base >= 2 then return false end
  baseLight = base
  local pulseState = (base == 0) and 1 or 0
  if not overrideLights(pulseState) then return false end
  pulseActive = true
  pulseUntil = t + cfg.pulse_ms / 1000
  lastPulseT = t
  return true
end

-- Фаза 11.3: короткий затухающий толчок руля на фронт beat.
-- Направление постоянное (+), амплитуда маленькая; затухание убирает
-- ступеньку и не даёт накапливать смещение.
local function triggerBeatKick()
  if cfg == nil or cfg.beat_kick_amp <= 0 then return end
  kickStart = t
  kickActive = true
end

-- === Публичные команды (GE шлёт через queueLuaCommand) ===
autopilotLiveMusicCmd = {}

local function startInternal(verbose)
  if active then return false end
  cfg, cfgFromFile = loadConfig()
  active = true
  t = 0
  dataAge = STALE_S + 1
  bass, beat, bpm = 0, 0, 0
  bassSmooth = 0
  night = false
  prevBeat = 0
  lightHeld = false
  pulseActive = false
  lastPulseT = -1e9
  kickActive = false
  kickStart = -1e9
  if verbose then
    print(string.format(
      'aplMusic: ON — sway %.3f@%.2fГц, вибрация %.4f@%.0fГц, beat-kick %.3f/%dмс, lights=%d',
      cfg.sway_amp, cfg.sway_hz, cfg.vibration_amp, cfg.vibration_hz,
      cfg.beat_kick_amp, cfg.beat_kick_ms, cfg.lights_pulse))
    toGE('INFO', 'music ON (' .. (cfgFromFile and 'конфиг из файла' or 'ДЕФОЛТЫ') .. ')')
  end
  return true
end

function autopilotLiveMusicCmd.start()
  return startInternal(true)
end

function autopilotLiveMusicCmd.set(b, bt, bpmV, nightV)
  -- GE присылает данные только при включённой фиче; после respawn
  -- автоматически поднимаемся, не дожидаясь 5-секундного rearm.
  if not active then startInternal(true) end
  bass = clamp(b, 0, 1, 0)
  beat = (tonumber(bt) or 0) >= 0.5 and 1 or 0
  bpm = clamp(bpmV, 0, 400, 0)
  night = nightV == true
  dataAge = 0
  return true
end

function autopilotLiveMusicCmd.stop()
  if not active then return false end
  active = false
  releaseLights(true)
  bass, beat, bpm = 0, 0, 0
  bassSmooth = 0
  kickActive = false
  dataAge = STALE_S + 1
  print('aplMusic: OFF')
  toGE('INFO', 'music OFF')
  return true
end

function autopilotLiveMusicCmd.status()
  local lines = {
    '--- apl_music status (vehicle) ---',
    'active=' .. tostring(active) .. ' данные=' ..
      (dataAge <= STALE_S and 'свежие' or 'устарели') ..
      string.format(' (age %.2f с)', dataAge),
    string.format('bass=%.2f smooth=%.2f beat=%d bpm=%.0f night=%s kick=%s',
      bass, bassSmooth, beat, bpm, tostring(night), tostring(kickActive)),
    string.format('speed=%.1f км/ч, свет=%d, musicHold=%s (base=%d, pulse=%s)',
      lastSpeedKph, curLights(), tostring(lightHeld), baseLight, tostring(pulseActive)),
    'конфиг: ' .. (cfg and (cfgFromFile and 'music.json' or 'ДЕФОЛТЫ') or 'не загружен'),
  }
  for _, l in ipairs(lines) do print('aplMusic: ' .. l) end
  toGE('INFO', 'music status: active=' .. tostring(active) ..
    ' bass=' .. string.format('%.2f', bass) .. ' beat=' .. tostring(beat))
  return true
end

-- === Кадр: пульс фар ===
function M.updateGFX(dt)
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then return end
  t = t + dt
  if not active then return end

  dataAge = dataAge + dt
  if dataAge > STALE_S then
    bass, beat, bpm = 0, 0, 0
  end

  -- Фаза 11.3: сглаживание баса (EMA), чтобы удары не дёргали руль.
  bassSmooth = bassSmooth + (bass - bassSmooth) * math.min(dt * 5.0, 1.0)

  lastSpeedKph = speedKph()

  -- Отпускаем свет, если уехали/стало устарело/ночь/фича выключена.
  if lightHeld and not lightsAllowed(lastSpeedKph) then
    releaseLights(true)
  end

  if pulseActive and t >= pulseUntil then
    pulseActive = false
    overrideLights(baseLight) -- вернуть базовое состояние, остаёмся владельцем
  end

  -- Фронт beat (данные приходят 20 Гц, beat держится 120 мс в Python).
  if beat == 1 and prevBeat == 0 then
    triggerBeatKick()          -- Фаза 11.3: beat -> микро-толчок руля
    pulseLights(lastSpeedKph)  -- lights_pulse=0 -> no-op (фары не трогаем)
  end
  prevBeat = beat
end

-- === Хуки для wheel: добавка ПОСЛЕ сглаживания ===
-- Стоянка: медленный качок, амплитуда ~ bass_smooth.
function autopilotLiveMusicGetParkOffset()
  if not musicReady() then return 0 end
  if cfg == nil or lastSpeedKph > cfg.stationary_speed_kph then return 0 end
  local phase = t * 2 * math.pi * cfg.sway_hz
  return math.sin(phase) * cfg.sway_amp * bassSmooth
end

-- Движение: мягкая микро-вибрация 6 Гц, амплитуда 0.001*bass_smooth.
function autopilotLiveMusicGetDriveOffset()
  if not musicReady() then return 0 end
  if cfg == nil or lastSpeedKph < cfg.vibration_min_speed_kph then return 0 end
  return math.sin(t * 2 * math.pi * cfg.vibration_hz) * cfg.vibration_amp * bassSmooth
end

-- Фаза 11.3: затухающий толчок на beat (wheel добавляет его к pipe.out).
function autopilotLiveMusicGetBeatKick()
  if not musicReady() or not kickActive or cfg == nil then return 0 end
  local dur = cfg.beat_kick_ms / 1000
  local age = t - kickStart
  if age < 0 or age >= dur then
    kickActive = false
    return 0
  end
  return cfg.beat_kick_amp * (1 - age / dur)
end

-- === Жизненный цикл ===
function M.onReset()
  releaseLights(true)
  dataAge = STALE_S + 1
  bass, beat, bpm = 0, 0, 0
  bassSmooth = 0
  kickActive = false
  prevBeat = 0
end

function M.onVehicleDestroyed()
  releaseLights(true)
  active = false
  bass, beat, bpm = 0, 0, 0
  bassSmooth = 0
  kickActive = false
  dataAge = STALE_S + 1
end

return M
