-- AutopilotLive — Фаза 7: «Погладить» (vehicle-слой, кнопка/питомец)
-- Подключается штатно (lua/vehicle/extensions/auto — автозагрузка расширений).
--
-- Ответственность vehicle-слоя (Фаза 7а/7б):
--   * микро-подГАЗОВКА: electrics.values.throttleOverride синусоидой 0..amp
--     — ШТАТНЫЙ override из vehicleController.lua:455 (так делают ванильные
--     cruiseControl/drag/crashTest). НЕ дёргаем input.event, НЕ тормоз,
--     НЕ КПП/ручник. По завершении/остановке — nil (управление возвращается
--     чисто, обороты проседают естественно от микро-сброса газа).
--   * руль плавнее: на время эффекта зовём autopilotLiveWheelCmd.setRateScale
--     (наш Фаза-4 модуль), при завершении — возврат к 1.
--   * звук (7б): каждые params.soundInterval секунд шлём GE-мост
--     onVehiclePetSound(pitch, volume) — GE играет FMOD-событие из pet.json
--     (Engine.Audio — только GE-объект). Тон с лёгким «тремором» (синус
--     pitch_wobble), громкость плавно затухает к концу поглаживания.
--   * guard'ы: только на стоянке (скорость < speed_gate_kph), иначе отказ;
--     защита от спама — «кошачье устало» (кулдаун, WARN в консоли).
--
-- Время/звуковое событие/позиционирование звука живут ТОЛЬКО в GE (main.lua).
-- КПП/pedals/CSV — не трогаются.

local M = {}

-- === Дефолты (дубль pet.json — ТОЛЬКО fallback; истина — параметры из GE) ===
local DEFAULTS = {
  duration = 6.0,        -- сек
  amp = 0.05,            -- амплитуда микро-газа (0..1)
  hz = 0.5,              -- частота синусоиды
  rateScale = 0.5,       -- множитель rate_limit руля на время эффекта
  soundInterval = 0,     -- сек между «пыхтениями»; 0 — звук выключен
  soundPitch = 0.7,
  soundWobble = 0.04,
  soundWobbleHz = 6.0,
  soundVolume = 0.8,
  speedGateKph = 5.0,    -- «нельзя гладить на ходу»
}

-- === Состояние ===
local active = false
local elapsed = 0        -- сек от старта эффекта
local nextSound = 0      -- elapsed-момент следующего «пыхта»
local p = nil            -- параметры текущего поглаживания (с клампом)
local spamTimes = {}     -- моменты последних активаций (os.time)
local busyUntil = 0      -- кулдаун «усталости» (os.time)

-- === Лог событий в GE (паттерн autopilotLiveLights.lua) ===
local function toGE(level, msg)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if autopilotLive_main and autopilotLive_main.onVehicleLog then autopilotLive_main.onVehicleLog("%s", "%s") end',
      level, tostring(msg):gsub('\\', '\\\\'):gsub('"', '\\"')))
  end)
end

-- Звуковой «пыхт» в GE (стр 7б-мост; GE играет pet.json sound_event)
local function sendSoundTick(pitch, vol)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if autopilotLive_main and autopilotLive_main.onVehiclePetSound then autopilotLive_main.onVehiclePetSound(%.3f, %.3f) end',
      pitch, vol))
  end)
end

-- === Утилиты ===
local function clampNum(v, lo, hi, dflt)
  v = tonumber(v)
  if v == nil or v ~= v then return dflt end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function nowSec()
  local ok, t = pcall(os.time)
  if ok and type(t) == 'number' then return t end
  return 0
end

local function speedKph()
  local s = 0
  pcall(function() s = electrics.values.wheelspeed or 0 end)
  s = tonumber(s) or 0
  if s ~= s then return 0 end
  return math.max(0, s) * 3.6
end

-- === Завершение эффекта (общее для off/таймайута/respawn) ===
local function finish(reason)
  -- Газ возвращаем первым: управление игроку — без задержек.
  pcall(function() electrics.values.throttleOverride = nil end)
  -- Руль: rate_scale → 1 (если wheel-модуль активен — он применил быстрее;
  -- если нет — функция всё равно безопасна).
  pcall(function()
    if autopilotLiveWheelCmd and autopilotLiveWheelCmd.setRateScale then
      autopilotLiveWheelCmd.setRateScale(1)
    end
  end)
  if active then
    local msg = 'ПОГЛАЖИВАНИЕ ЗАВЕРШЕНО (' .. string.format('%.1f', elapsed) .. ' с' ..
      (reason and (', ' .. reason) or '') .. ') — управление возвращено'
    print('aplPet: ' .. msg)
    toGE('INFO', 'pet done: ' .. string.format('%.1f', elapsed) .. 's' ..
      (reason and (' (' .. reason .. ')') or ''))
  end
  active = false
  p = nil
  elapsed = 0
end

-- === Кадр ===
function M.updateGFX(dt)
  if not active or p == nil then return end
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then return end -- NaN/перерывы
  elapsed = elapsed + dt

  -- Огибающая: плавный вход (0.5 с) + плавный спад в последние 25% эффекта
  local progress = elapsed / p.duration
  local envIn = math.min(elapsed / 0.5, 1)
  local envOut = 1
  if progress > 0.75 then envOut = math.max(0, 1 - (progress - 0.75) / 0.25) end
  local env = envIn * envOut

  -- Микро-подгазовка: синусоида 0..amp («педали слегка подёргиваются»)
  local phase = 2 * math.pi * p.hz * elapsed
  local thr = p.amp * env * (0.5 - 0.5 * math.cos(phase))
  pcall(function() electrics.values.throttleOverride = thr end)

  -- Звук: «пыхтения» с интервалом; тон с кошачьим «тремором», громкость —
  -- плавное затухание к концу поглаживания (с 60% времени)
  if p.soundInterval > 0 then
    if elapsed >= nextSound then
      local volEnv = 1
      if progress > 0.6 then volEnv = math.max(0, 1 - (progress - 0.6) / 0.4) end
      if volEnv > 0.02 then
        local pitch = p.soundPitch + p.soundWobble * math.sin(2 * math.pi * p.soundWobbleHz * elapsed)
        sendSoundTick(pitch, p.soundVolume * volEnv)
      end
      nextSound = nextSound + p.soundInterval
    end
  end

  if elapsed >= p.duration then finish() end
end

-- === Публичные команды (GE шлёт через queueLuaCommand) ===
autopilotLivePetCmd = {}

-- start(params): GE присылает таблицу параметров из pet.json (см. DEFAULTS).
function autopilotLivePetCmd.start(params)
  local t = type(params) == 'table' and params or {}
  local D = DEFAULTS
  local cfg = {
    duration = clampNum(t.duration, 1, 60, D.duration),
    amp = clampNum(t.amp, 0, 0.3, D.amp),
    hz = clampNum(t.hz, 0.05, 5, D.hz),
    rateScale = clampNum(t.rateScale, 0.1, 1, D.rateScale),
    soundInterval = clampNum(t.soundInterval, 0, 30, D.soundInterval),
    soundPitch = clampNum(t.soundPitch, 0.2, 3, D.soundPitch),
    soundWobble = clampNum(t.soundWobble, 0, 0.5, D.soundWobble),
    soundWobbleHz = clampNum(t.soundWobbleHz, 0, 30, D.soundWobbleHz),
    soundVolume = clampNum(t.soundVolume, 0, 1, D.soundVolume),
    speedGateKph = clampNum(t.speedGateKph, 0, 120, D.speedGateKph),
    spamMax = clampNum(t.spamMax, 1, 50, 4),
    spamWindow = clampNum(t.spamWindow, 1, 600, 30),
    cooldown = clampNum(t.cooldown, 0, 600, 20),
  }

  -- Guard 1: уже гладит — не перезапускаем, продлеваем можно через off/on
  if active then
    print('aplPet: уже идёт поглаживание (' .. string.format('%.1f', elapsed) ..
      ' из ' .. string.format('%.1f', p.duration) .. ' с) — apl_pet("off") прерывает')
    toGE('WARN', 'pet refused: already active')
    return false
  end

  -- Guard 2: «кошачье устало» — кулдаун после серии активаций
  local now = nowSec()
  if now < busyUntil then
    local left = busyUntil - now
    print('aplPet: кошачье устало — перерыв ещё ' .. tostring(left) .. ' с')
    toGE('WARN', 'pet refused: cooldown ' .. tostring(left) .. 's left')
    return false
  end
  -- Счёт спама: сколько активаций за окно
  local kept = {}
  for _, ts in ipairs(spamTimes) do
    if now - ts <= cfg.spamWindow then table.insert(kept, ts) end
  end
  spamTimes = kept
  table.insert(spamTimes, now)
  if #spamTimes > cfg.spamMax then
    busyUntil = now + math.floor(cfg.cooldown + 0.5)
    print('aplPet: кошачье устало (ждали ' .. tostring(#spamTimes) ..
      ' раз за ' .. tostring(cfg.spamWindow) .. ' с) — перерыв ' ..
      tostring(cfg.cooldown) .. ' с, не дёргайте')
    toGE('WARN', 'pet refused: spam ' .. tostring(#spamTimes) .. 'x in ' ..
      tostring(cfg.spamWindow) .. 's, cooldown ' .. tostring(cfg.cooldown) .. 's')
    return false
  end

  -- Guard 3: «нельзя гладить на ходу»
  local v = speedKph()
  if v >= cfg.speedGateKph then
    print('aplPet: НЕЛЬЗЯ гладить на ходу (' .. string.format('%.0f', v) ..
      ' км/ч, гейт ' .. string.format('%.0f', cfg.speedGateKph) .. ' км/ч)')
    toGE('WARN', 'pet refused: moving ' .. string.format('%.1f', v) .. ' kph')
    return false
  end

  -- Старт эффекта
  p = cfg
  elapsed = 0
  nextSound = cfg.soundInterval > 0 and cfg.soundInterval or 0
  active = true
  -- Руль: временно плавнее (rate_scale)
  pcall(function()
    if autopilotLiveWheelCmd and autopilotLiveWheelCmd.setRateScale then
      autopilotLiveWheelCmd.setRateScale(cfg.rateScale)
    end
  end)
  print('aplPet: ПОГЛАЖИВАНИЕ НАЧАТО (' .. string.format('%.0f', cfg.duration) ..
    ' с, микро-газ ' .. string.format('%.2f', cfg.amp) ..
    ', руль ×' .. string.format('%.2f', cfg.rateScale) ..
    (cfg.soundInterval > 0 and (', звук каждые ' .. string.format('%.1f', cfg.soundInterval) .. ' с')
      or ', без звука') .. ')')
  toGE('INFO', 'pet start: dur=' .. string.format('%.1f', cfg.duration) ..
    ' amp=' .. string.format('%.2f', cfg.amp) ..
    ' hz=' .. string.format('%.2f', cfg.hz) ..
    ' scale=' .. string.format('%.2f', cfg.rateScale) ..
    ' sound=' .. (cfg.soundInterval > 0 and string.format('%.1fs', cfg.soundInterval) or 'off'))
  return true
end

-- stop(): немедленное прерывание (apl_pet("off"))
function autopilotLivePetCmd.stop()
  if not active then return false end
  finish('прервано игроком')
  return true
end

function autopilotLivePetCmd.status()
  local lines = {
    '--- apl_pet status (vehicle) ---',
    'active=' .. tostring(active) ..
      (active and (' elapsed=' .. string.format('%.1f', elapsed) .. '/' ..
        string.format('%.1f', p.duration) .. ' с') or ''),
    'speed=' .. string.format('%.1f', speedKph()) .. ' км/ч',
    'кулдаун=' .. tostring(math.max(0, busyUntil - nowSec())) .. ' с, активаций за окно=' ..
      tostring(#spamTimes),
  }
  for _, l in ipairs(lines) do print('aplPet: ' .. l) end
  toGE('INFO', 'pet status: active=' .. tostring(active) ..
    ' speed=' .. string.format('%.1f', speedKph()))
  return true
end

-- === Жизненный цикл ===
function M.onReset()
  -- Respawn: electrics сброшены (override уже нет) — эффект прерываем.
  if active then finish('respawn') end
end

function M.onVehicleDestroyed()
  active = false
  p = nil
  elapsed = 0
end

return M
