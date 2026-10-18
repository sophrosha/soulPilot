-- AutopilotLive — Фаза 7: «Погладить» (vehicle-слой, кнопка/питомец)
-- Подключается штатно (lua/vehicle/extensions/auto — автозагрузка расширений).
--
-- Ответственность vehicle-слоя (правки после 2-го теста 18.10):
--   * ФИЗИКУ НЕ ТРОГАЕМ ВООБЩЕ (после провала: brakeOverride=1 сломал
--     поведение — машина поехала назад; throttleOverride убран тоже).
--     Педали/КПП/ручник — НЕ наша зона; машина стоит как стояла.
--   * руль плавнее: на время эффекта autopilotLiveWheelCmd.setRateScale
--     (Фаза-4 модуль, rate ×0.5), при завершении — возврат к 1.
--   * таймлайн (6 с) + guard'ы: только на стоянке (< speed_gate_kph),
--     защита от спама («кошачье устало»). По завершении — колбэк в GE
--     onVehiclePetDone (GE гасит звуковой луп); guard-отказы — rejected.
--   * ЗВУК живёт ТОЛЬКО в GE (луп createSource + позиция машины + «дыхание»
--     громкости): vehicle звук не производит.

local M = {}

-- === Дефолты (дубль pet.json — ТОЛЬКО fallback; истина — параметры из GE) ===
local DEFAULTS = {
  duration = 6.0,        -- сек
  rateScale = 0.5,       -- множитель rate_limit руля на время эффекта
  speedGateKph = 5.0,    -- «нельзя гладить на ходу»
}

-- === Состояние ===
local active = false
local elapsed = 0        -- сек от старта эффекта
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

-- Колбэки в GE: поглаживание завершено / отклонено (GE гасит звуковой луп)
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

-- === Завершение эффекта (общее для off/таймайута/respawn) ===
local function finish(reason)
  -- Руль: rate_scale → 1 (единственная наша физика — безопасный множитель)
  pcall(function()
    if autopilotLiveWheelCmd and autopilotLiveWheelCmd.setRateScale then
      autopilotLiveWheelCmd.setRateScale(1)
    end
  end)
  if active then
    local msg = 'ПОГЛАЖИВАНИЕ ЗАВЕРШЕНО (' .. string.format('%.1f', elapsed) .. ' с' ..
      (reason and (', ' .. reason) or '') .. ') — руль в штатном rate'
    print('aplPet: ' .. msg)
    toGE('INFO', 'pet done: ' .. string.format('%.1f', elapsed) .. 's' ..
      (reason and (' (' .. reason .. ')') or ''))
    notifyGE('onVehiclePetDone') -- GE гасит звуковой луп (fade)
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
  -- Физику НЕ трогаем (педали/тормоз — как штатно): только таймлайн + звук-мост
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
    rateScale = clampNum(t.rateScale, 0.1, 1, D.rateScale),
    speedGateKph = clampNum(t.speedGateKph, 0, 120, D.speedGateKph),
    spamMax = clampNum(t.spamMax, 1, 50, 4),
    spamWindow = clampNum(t.spamWindow, 1, 600, 30),
    cooldown = clampNum(t.cooldown, 0, 600, 20),
  }

  local function refuse(msg, logMsg)
    print('aplPet: ' .. msg)
    toGE('WARN', 'pet refused: ' .. logMsg)
    notifyGE('onVehiclePetRejected') -- GE гасит уже запущенный луп
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

  -- Guard 3: «нельзя гладить на ходу»
  local v = speedKph()
  if v >= cfg.speedGateKph then
    return refuse('НЕЛЬЗЯ гладить на ходу (' .. string.format('%.0f', v) ..
      ' км/ч, гейт ' .. string.format('%.0f', cfg.speedGateKph) .. ' км/ч)',
      'moving ' .. string.format('%.1f', v) .. ' kph')
  end

  -- Старт эффекта: физику НЕ трогаем — только руль плавнее
  p = cfg
  elapsed = 0
  active = true
  pcall(function()
    if autopilotLiveWheelCmd and autopilotLiveWheelCmd.setRateScale then
      autopilotLiveWheelCmd.setRateScale(cfg.rateScale)
    end
  end)
  print('aplPet: ПОГЛАЖИВАНИЕ НАЧАТО (' .. string.format('%.0f', cfg.duration) ..
    ' с, руль ×' .. string.format('%.2f', cfg.rateScale) ..
    ', урчание в GE, физика штатная)')
  toGE('INFO', 'pet start: dur=' .. string.format('%.1f', cfg.duration) ..
    ' scale=' .. string.format('%.2f', cfg.rateScale) .. ' (без вмешательства в педали)')
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
        string.format('%.1f', p.duration) .. ' с, руль ×' .. string.format('%.2f', p.rateScale)) or
        ' (физика не трогается)'),
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
  -- Respawn: эффект прерываем (мультипликатор руля — к 1)
  if active then finish('respawn') end
end

function M.onVehicleDestroyed()
  active = false
  p = nil
  elapsed = 0
end

return M
