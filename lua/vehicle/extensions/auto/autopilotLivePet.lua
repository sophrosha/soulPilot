-- AutopilotLive — Фаза 7: «Погладить» (vehicle-слой, кнопка/питомец)
-- Подключается штатно (lua/vehicle/extensions/auto — автозагрузка расширений).
--
-- Ответственность vehicle-слоя (Фаза 7а/7б, правки после теста 18.10):
--   * ДРОЖАНИЕ ПЕДАЛИ: electrics.values.throttleOverride = env * (offset +
--     amp*sin(2*pi*hz*t)) — «дрожит» в 0.0..0.3 на малых оборотах (дефолт
--     0.15+0.15 @ 2.5 Гц). ШТАТНЫЙ override из vehicleController.lua:455
--     (как cruiseControl/drag). НЕ дёргаем input.event, НЕ КПП/ручник.
--   * ТОРМОЗ ЗАЖАТ (главное после теста): пока эффект активен —
--     electrics.values.brakeOverride = 1.0 (полный тормоз), иначе коробка
--     видит газ, включает сцепление и машина УПОЛЗАЕТ. По завершении — nil.
--   * руль плавнее: autopilotLiveWheelCmd.setRateScale (Фаза-4 модуль),
--     при завершении — возврат к 1.
--   * guard'ы: только на стоянке (< speed_gate_kph), иначе отказ (в GE —
--     колбэк onVehiclePetRejected, там же гасится звуковой луп); защита от
--     спама — «кошачье устало» (кулдаун, WARN в консоли).
--   * ЗВУК живёт ТОЛЬКО в GE (createSource-луп + дыхание громкости в
--     M.onUpdate): vehicle шлёт колбэки done/rejected, GE останавливает луп.

local M = {}

-- === Дефолты (дубль pet.json — ТОЛЬКО fallback; истина — параметры из GE) ===
local DEFAULTS = {
  duration = 6.0,        -- сек
  offset = 0.15,         -- оффсет микро-газа (0..1) — база дрожания
  amp = 0.15,            -- амплитуда дрожания (0..1) — 0.0..(offset+amp)
  hz = 2.5,              -- частота дрожания (вибрация, не покачивание)
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
  -- Управление возвращаем первым: газ и тормоз — игроку без задержек.
  pcall(function() electrics.values.throttleOverride = nil end)
  pcall(function() electrics.values.brakeOverride = nil end)
  -- Руль: rate_scale → 1 (безопасно и при активном wheel, и без него).
  pcall(function()
    if autopilotLiveWheelCmd and autopilotLiveWheelCmd.setRateScale then
      autopilotLiveWheelCmd.setRateScale(1)
    end
  end)
  if active then
    local msg = 'ПОГЛАЖИВАНИЕ ЗАВЕРШЕНО (' .. string.format('%.1f', elapsed) .. ' с' ..
      (reason and (', ' .. reason) or '') .. ') — газ/тормоз возвращены'
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

  -- Огибающая: плавный вход (0.5 с) + плавный спад в последние 25% эффекта
  local progress = elapsed / p.duration
  local envIn = math.min(elapsed / 0.5, 1)
  local envOut = 1
  if progress > 0.75 then envOut = math.max(0, 1 - (progress - 0.75) / 0.25) end
  local env = envIn * envOut

  -- Дрожание педали: env * (offset + amp*sin(...)) — плавно колеблется
  -- в 0.0..(offset+amp) на малых оборотах (вибрация @ hz)
  local thr = env * (p.offset + p.amp * math.sin(2 * math.pi * p.hz * elapsed))
  pcall(function() electrics.values.throttleOverride = thr end)
  -- Тормоз держим ЗАЖАТЫМ весь эффект (без огибающей — машина не уползает)
  pcall(function() electrics.values.brakeOverride = 1.0 end)

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
    offset = clampNum(t.offset, 0, 0.5, D.offset),
    amp = clampNum(t.amp, 0, 0.5, D.amp),
    hz = clampNum(t.hz, 0.05, 10, D.hz),
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

  -- Старт эффекта: тормоз — ЗАЖАТ сразу (иначе газ → сцепление → едет)
  p = cfg
  elapsed = 0
  active = true
  pcall(function() electrics.values.brakeOverride = 1.0 end)
  -- Руль: временно плавнее (rate_scale)
  pcall(function()
    if autopilotLiveWheelCmd and autopilotLiveWheelCmd.setRateScale then
      autopilotLiveWheelCmd.setRateScale(cfg.rateScale)
    end
  end)
  print('aplPet: ПОГЛАЖИВАНИЕ НАЧАТО (' .. string.format('%.0f', cfg.duration) ..
    ' с, дрожание газа ' .. string.format('%.2f', cfg.offset) .. '+±' ..
    string.format('%.2f', cfg.amp) .. ' @ ' .. string.format('%.1f', cfg.hz) ..
    ' Гц, тормоз зажат, руль ×' .. string.format('%.2f', cfg.rateScale) .. ')')
  toGE('INFO', 'pet start: dur=' .. string.format('%.1f', cfg.duration) ..
    ' thr=' .. string.format('%.2f', cfg.offset) .. '+±' .. string.format('%.2f', cfg.amp) ..
    ' @' .. string.format('%.2f', cfg.hz) .. 'Hz scale=' .. string.format('%.2f', cfg.rateScale))
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
        string.format('%.1f', p.duration) .. ' с, тормоз=зажат') or ''),
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
  -- Respawn: electrics сброшены (override'ов уже нет) — эффект прерываем.
  if active then finish('respawn') end
end

function M.onVehicleDestroyed()
  active = false
  p = nil
  elapsed = 0
end

return M
