-- AutopilotLive — Фаза 7: «Погладить» (vehicle-слой, кнопка/питомец)
-- Подключается штатно (lua/vehicle/extensions/auto — автозагрузка расширений).
--
-- Ответственность vehicle-слоя (правки после теста 3, 18.10):
--   * ГАЗ ЛЁГКИЙ: electrics.values.throttleOverride = env * (offset 0.05 +
--     amp 0.05*sin(2*pi*hz*t)) — колеблется 0.0..0.1 («еле слышно урчит»,
--     не рвёт). ШТАТНЫЙ override из vehicleController.lua:455 (как
--     cruiseControl/drag). НЕ дёргаем input.event напрямую.
--   * ТОРМОЗ brakeOverride НЕ ИСПОЛЬЗУЕТСЯ ВООБЩЕ (из-за него машина
--     полетела назад во 2-м тесте).
--   * ФИКСАЦИЯ РУЧНИКОМ: на время эффекта controller.mainController.
--     smartParkingBrake(1) (штатный путь vehicleController.lua:428, прямое
--     parkingbrake-событие с FILTER_DIRECT), в конце — smartParkingBrake(0).
--     Машина не катится даже при лёгком газовании.
--   * руль плавнее: autopilotLiveWheelCmd.setRateScale (Фаза-4 модуль),
--     при завершении — возврат к 1.
--   * guard'ы: только на стоянке (< speed_gate_kph), иначе отказ (в GE —
--     колбэк onVehiclePetRejected, там же гасится звук), защита от спама.
--   * ЗВУК живёт ТОЛЬКО в GE (playOnce-оверлап с позицией машины):
--     vehicle шлёт колбэки done/rejected, GE останавливает звук.

local M = {}

-- === Дефолты (дубль pet.json — ТОЛЬКО fallback; истина — параметры из GE) ===
local DEFAULTS = {
  duration = 6.0,        -- сек
  offset = 0.05,         -- оффсет микро-газа (0..1) — база дрожания
  amp = 0.05,            -- амплитуда дрожания (0..1) — итог 0.0..(offset+amp)=0.1
  moveOffset = 0.02,     -- газ в ДВИЖЕНИИ (ИИ ведёт): микро, чтобы мотор урчал
  moveAmp = 0.03,        -- случайная добавка в движении (0.02..0.05)
  hz = 2.5,              -- частота дрожания (вибрация, не покачивание)
  rateScale = 0.5,       -- множитель rate_limit руля на время эффекта
  randomInterval = 0.2,  -- сек: как часто новая случайная цель газа (0.05+rand*0.05)
  rampS = 1.5,           -- сек: плавное снижение жёсткости руля (1 → rateScale)
  speedGateKph = 5.0,    -- «нельзя гладить на ходу»
}

-- === Состояние ===
local active = false
local elapsed = 0        -- сек от старта эффекта
local p = nil            -- параметры текущего поглаживания (с клампом)
local spamTimes = {}     -- моменты последних активаций (os.time)
local busyUntil = 0      -- кулдаун «усталости» (os.time)
local curScale = 1       -- текущий множитель руля (плавно 1 → rateScale)
local lastAppliedScale = 1
local thrRandT = 0       -- таймер смены случайной цели газа
local thrRandVal = 0     -- случайная цель (0.05..0.10)
local thrRandCur = 0     -- текущее сглаженное значение
local thrOverrideWritten = false -- писали ли throttleOverride в этом кадре/сеансе

-- === Лог событий в GE (паттерн autopilotLiveLights.lua) ===
local function toGE(level, msg)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if autopilotLive_main and autopilotLive_main.onVehicleLog then autopilotLive_main.onVehicleLog(\"%s\", \"%s\") end',
      level, tostring(msg):gsub('\\\\', '\\\\'):gsub('"', '\\"')))
  end)
end

-- Колбэки в GE: поглаживание завершено / отклонено (GE гасит звук)
local function notifyGE(fname)
  pcall(function()
    obj:queueGameEngineLua(
      'if autopilotLive_main and autopilotLive_main.' .. fname .. ' then autopilotLive_main.' .. fname .. '() end')
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

-- Штатный ручник (vehicleController.lua:428, экспорт M.smartParkingBrake;
-- без фильтра = FILTER_DIRECT → прямое событие parkingbrake 0|1).
local hbState = -1 -- последнее выставленное состояние (анти-спам)
local function setHandbrake(v, force)
  if hbState == v and not force then return end
  local ok, err = pcall(function()
    if controller and controller.mainController and controller.mainController.smartParkingBrake then
      controller.mainController.smartParkingBrake(v)
    else
      error('smartParkingBrake недоступен')
    end
  end)
  if ok then hbState = v end
  if not ok then
    print('aplPet: WARN ручник не выставлен (' .. tostring(err) .. ')')
    toGE('WARN', 'pet handbrake failed: ' .. tostring(err))
  end
end

-- === Завершение эффекта (общее для off/таймайута/respawn) ===
local function finish(reason)
  -- Газ возвращаем игроку, ручник отпускаем (штатный путь).
  pcall(function() electrics.values.throttleOverride = nil end)
  setHandbrake(0)
  -- Руль: rate_scale → 1 (безопасно и при активном wheel, и без него).
  pcall(function()
    if autopilotLiveWheelCmd and autopilotLiveWheelCmd.setRateScale then
      autopilotLiveWheelCmd.setRateScale(1)
    end
  end)
  if active then
    local msg = 'ПОГЛАЖИВАНИЕ ЗАВЕРШЕНО (' .. string.format('%.1f', elapsed) .. ' с' ..
      (reason and (', ' .. reason) or '') .. ') — газ/ручник/руль штатные'
    print('aplPet: ' .. msg)
    toGE('INFO', 'pet done: ' .. string.format('%.1f', elapsed) .. 's' ..
      (reason and (' (' .. reason .. ')') or ''))
    notifyGE('onVehiclePetDone') -- GE гасит звук
  end
  curScale = 1
  lastAppliedScale = 1
  thrRandT = 0
  thrRandVal = 0
  thrRandCur = 0
  thrOverrideWritten = false
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

  -- Руль: ПЛАВНО снижаем жёсткость 1 → rateScale за p.rampS (не мгновенно).
  local targetScale = p.rateScale
  if math.abs(curScale - targetScale) > 1e-4 then
    local dS = dt / math.max(p.rampS or 1.5, 0.1)
    if curScale > targetScale then curScale = math.max(curScale - dS, targetScale)
    else curScale = math.min(curScale + dS, targetScale) end
    if math.abs(lastAppliedScale - curScale) >= 0.04
        or math.abs(curScale - targetScale) < 1e-4 then
      lastAppliedScale = curScale
      pcall(function()
        if autopilotLiveWheelCmd and autopilotLiveWheelCmd.setRateScale then
          autopilotLiveWheelCmd.setRateScale(curScale)
        end
      end)
    end
  end

  -- Микро-подергивание газа (24.10): режим зависит от того, ЕДЕТ ли машина.
  --   СТОИМ (нет ИИ или speed < 2 км/ч): газ НЕ пишем вовсе (машина не уезжает),
  --     ручник держим каждый кадр (ваниль снимает его при throttle > 0);
  --   ЕДЕМ (ИИ ведёт): микро-газ 0.02 + random*0.03 — мотор слышен, без дёрганья.
  local aiDrv = false
  pcall(function() aiDrv = (ai and ai.isDriving and ai.isDriving()) or false end)
  local standing = (not aiDrv) or (speedKph() < 2.0)

  if standing then
    setHandbrake(1, true) -- форсим КАЖДЫЙ кадр: ваниль снимает ручник при газе
    if thrOverrideWritten then
      pcall(function() electrics.values.throttleOverride = nil end)
      thrOverrideWritten = false
    end
  else
    if hbState ~= 0 then setHandbrake(0) end
    thrRandT = thrRandT + dt
    if thrRandT >= (p.randomInterval or 0.2) or thrRandVal == 0 then
      thrRandT = 0
      thrRandVal = p.moveOffset + math.random() * p.moveAmp
    end
    local stepT = (p.moveOffset + p.moveAmp) * dt / 0.2
    if thrRandCur < thrRandVal then
      thrRandCur = math.min(thrRandCur + stepT, thrRandVal)
    elseif thrRandCur > thrRandVal then
      thrRandCur = math.max(thrRandCur - stepT, thrRandVal)
    end
    pcall(function() electrics.values.throttleOverride = env * thrRandCur end)
    thrOverrideWritten = true
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
    offset = clampNum(t.offset, 0, 0.3, D.offset),
    amp = clampNum(t.amp, 0, 0.3, D.amp),
    moveOffset = clampNum(t.moveOffset, 0, 0.1, D.moveOffset),
    moveAmp = clampNum(t.moveAmp, 0, 0.1, D.moveAmp),
    hz = clampNum(t.hz, 0.05, 10, D.hz),
    rateScale = clampNum(t.rateScale, 0.1, 1, D.rateScale),
    randomInterval = clampNum(t.randomInterval, 0.05, 5, D.randomInterval),
    rampS = clampNum(t.rampS, 0.1, 10, D.rampS),
    speedGateKph = clampNum(t.speedGateKph, 0, 120, D.speedGateKph),
    spamMax = clampNum(t.spamMax, 1, 50, 4),
    spamWindow = clampNum(t.spamWindow, 1, 600, 30),
    cooldown = clampNum(t.cooldown, 0, 600, 20),
  }

  local function refuse(msg, logMsg)
    print('aplPet: ' .. msg)
    toGE('WARN', 'pet refused: ' .. logMsg)
    notifyGE('onVehiclePetRejected') -- GE гасит уже запущенный звук
    return false
  end

  -- Guard 1: уже гладит — не перезапускаем
  if active then
    return refuse('уже идёт поглаживание (' .. string.format('%.1f', elapsed) ..
      ' из ' .. string.format('%.1f', p.duration) .. ' с) — apl_pet("off") прерывает',
      'already active')
  end

  -- Guard 2: «кошачье устало» — кулдаун после серии активаций
  local now = nowSec()
  if now < busyUntil then
    return refuse('кошачье устало — перерыв ещё ' .. tostring(busyUntil - now) .. ' с',
      'cooldown ' .. tostring(busyUntil - now) .. 's left')
  end
  local kept = {}
  for _, ts in ipairs(spamTimes) do
    if now - ts <= cfg.spamWindow then table.insert(kept, ts) end
  end
  spamTimes = kept
  table.insert(spamTimes, now)
  if #spamTimes > cfg.spamMax then
    busyUntil = now + math.floor(cfg.cooldown + 0.5)
    return refuse('кошачье устало (ждали ' .. tostring(#spamTimes) ..
      ' раз за ' .. tostring(cfg.spamWindow) .. ' с) — перерыв ' ..
      tostring(cfg.cooldown) .. ' с, не дёргайте',
      'spam ' .. tostring(#spamTimes) .. 'x in ' .. tostring(cfg.spamWindow) .. 's')
  end

  -- Guard 2.5 (24.10): двигатель не заведён (прогрев/заглушён) — петмод НЕ работает,
  -- чтобы не мешать заводу (throttleOverride на незаведённом двигателе бесполезен).
  local engRunning = 0
  pcall(function() engRunning = electrics.values.engineRunning or 0 end)
  if engRunning <= 0 then
    return refuse('двигатель не заведён — поглаживание недоступно (прогрев/заглушён)',
      'engine off')
  end

  -- Guard 3: «нельзя гладить на ходу» — ТОЛЬКО если не ИИ ведёт.
  -- Под ИИ поглаживание разрешено (микро-газ 0.02–0.05, без дёрганья).
  local aiNow = false
  pcall(function() aiNow = (ai and ai.isDriving and ai.isDriving()) or false end)
  local v = speedKph()
  if (not aiNow) and v >= cfg.speedGateKph then
    return refuse('НЕЛЬЗЯ гладить на ходу (' .. string.format('%.0f', v) ..
      ' км/ч, гейт ' .. string.format('%.0f', cfg.speedGateKph) .. ' км/ч)',
      'moving ' .. string.format('%.1f', v) .. ' kph')
  end

  -- Старт эффекта: ручник ПОДНИМАЕМ (машина не катится), руль плавнее.
  -- Тормоз НЕ трогаем (запрещено после 2-го теста).
  p = cfg
  elapsed = 0
  active = true
  curScale = 1
  lastAppliedScale = 1
  thrRandT = 0
  thrRandVal = 0
  thrRandCur = 0
  -- Стоим — ручник держим (updateGFX удерживает каждый кадр); едем под ИИ —
  -- ручник не трогаем (машина в движении).
  local aiStart = false
  pcall(function() aiStart = (ai and ai.isDriving and ai.isDriving()) or false end)
  if (not aiStart) or speedKph() < 2.0 then
    setHandbrake(1)
  else
    setHandbrake(0)
  end
  thrOverrideWritten = false
  -- Руль снижаем ПЛАВНО в updateGFX (rampS) — не дёргаем setRateScale здесь.
  print('aplPet: ПОГЛАЖИВАНИЕ НАЧАТО (' .. string.format('%.0f', cfg.duration) ..
    ' с; ' .. ((not aiStart) and 'СТОЯНКА: газ НЕ пишем, ручник держим'
      or ('ДВИЖЕНИЕ: микро-газ ' .. string.format('%.2f', cfg.moveOffset) ..
          '+rand*' .. string.format('%.2f', cfg.moveAmp))) ..
    ', руль ×' .. string.format('%.2f', cfg.rateScale) ..
    ' плавно за ' .. string.format('%.1f', cfg.rampS) .. ' с)')
  toGE('INFO', 'pet start: dur=' .. string.format('%.1f', cfg.duration) ..
    ' thr=' .. string.format('%.2f', cfg.offset) .. '+rand*' .. string.format('%.2f', cfg.amp) ..
    ' every ' .. string.format('%.2f', cfg.randomInterval) .. 's handbrake=1 scale=' ..
    string.format('%.2f', cfg.rateScale) .. ' ramp=' .. string.format('%.1f', cfg.rampS) .. 's')
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
        string.format('%.1f', p.duration) .. ' с, газ 0..' ..
        string.format('%.2f', p.offset + p.amp) .. ', ручник поднят, руль ×' ..
        string.format('%.2f', p.rateScale)) or ' (тормоз не используется)'),
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
  -- Respawn: electrics сброшены (override'ов уже нет, ручник штатный) —
  -- эффект прерываем БЕЗ setHandbrake (машина только что заспавнена).
  if active then
    active = false
    p = nil
    elapsed = 0
    print('aplPet: ПОГЛАЖИВАНИЕ ПРЕРВАНО (respawn)')
    notifyGE('onVehiclePetDone')
  end
end

function M.onVehicleDestroyed()
  active = false
  p = nil
  elapsed = 0
end

return M
