-- AutopilotLive — Фаза 8: pop-up фары / «глазки» (vehicle-слой)
-- Подключается штатно (lua/vehicle/extensions/auto — автозагрузка расширений).
--
-- Ответственность vehicle-слоя (Фаза 8):
--   * СЛУЧАЙНОЕ МОРГАНИЕ днём при ВЫКЛЮЧЕННОМ свете: один цикл —
--     electrics.setLightsState(1) → пауза blink (случайно 1.5-2 с, ванильный
--     hydro выдвигает фару ~1.4 с) → setLightsState(0). Один выезд/заезд —
--     без лишних переключений (ТЗ). Штатный API (как радиал-меню/Ф6), БЕЗ
--     input.event. Выезд фар — ванильный hydro от lowhighbeam (jbeam), свет
--     — тем же setLightsState: глазки выезжают и МИГАЮТ светом (Вариант А,
--     утверждён координатором 19.10).
--   * ИНТЕРВАЛЫ: днём 120-180 с (чаще), ночью 180-300 с (реже) — когда свет
--     включён (глазки выеханы ванилью) — моргание ПОДАВЛЕНО, таймер стоит.
--     Ночной auto-свет Ф6 включает фары сам (один ванильный выезд) — мы не
--     мешаем (правило безотказности).
--   * РУЧНОЕ ВМЕШАТЕЛЬСТВО: игрок сам изменил свет (не Ф6-auto) →
--     popup auto OFF + WARN (ТЗ: «не мешаем»).
--   * СОВМЕСТИМОСТЬ с Ф6: перед мигком ставим autopilotLiveLightsCmd.
--     setSuppress(true) — их auto-логика молчит (мигок не считается их
--     interrupt'ом, target не применяется); внешние переходы Ф6-auto
--     отличаем через isAuto() — это НЕ вмешательство.
--   * Включается ТОЛЬКО командой игрока GE (apl_popup("auto")), модель —
--     только Bolide/Wigeon (guard по veh.JBeam в GE).

local M = {}

-- === Дефолты (дубль popup.json — ТОЛЬКО fallback; истина — параметры из GE) ===
local DEFAULTS = {
  dayMin = 120, dayMax = 180,       -- сек, интервал днём
  nightMin = 180, nightMax = 300,   -- сек, интервал ночью
  blinkMin = 1.5, blinkMax = 2.0,   -- сек, глазки открыты при моргании
  debugDelay = 0,                   -- >0 — тест-режим: ВСЕ интервалы = N сек
}

-- === Состояние ===
local active = false
local cfg = nil           -- параметры текущего сеанса (с клампом)
local night = false       -- ночь/день от GE (выбор интервала)
local phase = 'wait'      -- 'wait' (таймер) | 'open' (глазки открыты, мигок)
local timer = 0           -- сек до следующего события
local lastSeen = 0        -- последний наблюдённый lights_state (след)
local suppressHeld = false -- держим ли suppress у Ф6

-- === Лог событий в GE (паттерн autopilotLiveLights.lua) ===
local function toGE(level, msg)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if autopilotLive_main and autopilotLive_main.onVehicleLog then autopilotLive_main.onVehicleLog("%s", "%s") end',
      level, tostring(msg):gsub('\\', '\\\\'):gsub('"', '\\"')))
  end)
end

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

local function curState()
  local s = 0
  pcall(function() s = electrics.values.lights_state or 0 end)
  s = tonumber(s) or 0
  if s ~= s then return 0 end
  return math.floor(s + 0.5)
end

local function applyLights(v)
  if curState() == v then return end -- guard Ф6/techCore: без лишних щелчков
  pcall(function() electrics.setLightsState(v) end)
end

-- Случайный интервал по фазе (ночь/день) либо тест-режим debugDelay
local function nextDelay()
  local c = cfg
  if c.debugDelay > 0 then return c.debugDelay end
  local lo, hi
  if night then lo, hi = c.nightMin, c.nightMax else lo, hi = c.dayMin, c.dayMax end
  return lo + (hi - lo) * math.random()
end

local function randBlink()
  return cfg.blinkMin + (cfg.blinkMax - cfg.blinkMin) * math.random()
end

-- suppress у Ф6 (мигок не должен выключать их auto по interrupt)
local function setSuppress(v)
  if v == suppressHeld then return end
  suppressHeld = v
  pcall(function()
    if autopilotLiveLightsCmd and autopilotLiveLightsCmd.setSuppress then
      autopilotLiveLightsCmd.setSuppress(v)
    end
  end)
end

local function isLightsAuto()
  local ok, r = pcall(function()
    if autopilotLiveLightsCmd and autopilotLiveLightsCmd.isAuto then
      return autopilotLiveLightsCmd.isAuto()
    end
    return false
  end)
  return ok and r == true
end

local function releaseOpen()
  -- Завершение/прерывание мигка: возвращаем выключенный свет (если это мы
  -- включили) и снимаем suppress.
  if lastSeen ~= 0 then applyLights(0); lastSeen = 0 end
  setSuppress(false)
end

local function autoOff(reason)
  releaseOpen()
  active = false
  phase = 'wait'
  print('aplPopup: АВТО-РЕЖИМ ОТКЛЮЧЁН — ' .. reason)
  toGE('WARN', 'popup auto off: ' .. reason)
  notifyGE('onVehiclePopupAutoOff')
end

-- === Кадр ===
function M.updateGFX(dt)
  if not active or cfg == nil then return end
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then return end -- NaN/перерывы

  local cur = curState()

  if phase == 'wait' then
    -- Внешнее изменение света (не наше моргание)?
    if cur ~= lastSeen then
      if isLightsAuto() then
        lastSeen = cur -- переход Ф6-auto (ночь/день) — НЕ вмешательство
        toGE('INFO', 'popup: переход Ф6-auto (lights_state=' .. tostring(cur) ..
          ') — моргание подавлено, пока свет не выключен')
      else
        autoOff('игрок сам трогает фары (lights_state=' .. tostring(cur) .. ')')
        return
      end
    end
    -- Моргаем ТОЛЬКО когда свет выключен (глазки закрыты) и таймер истёк
    if lastSeen == 0 then
      timer = timer - dt
      if timer <= 0 then
        -- Старт мигка: suppress Ф6, фары выезжают и мигают
        setSuppress(true)
        applyLights(1)
        lastSeen = 1
        phase = 'open'
        timer = randBlink()
        local mode = night and 'ночь' or 'день'
        print('aplPopup: МОРГАНИЕ (' .. mode .. ', глазки открыты ' ..
          string.format('%.1f', timer) .. ' с)')
        toGE('INFO', 'popup blink: ' .. (night and 'night' or 'day') ..
          ' open=' .. string.format('%.1f', timer) .. 's')
      end
    end
  elseif phase == 'open' then
    -- Глазки открыты: следим за внешним вмешательством во время мигка
    if cur ~= lastSeen then
      if isLightsAuto() then
        -- Ф6 под suppress молчит, но подстраховка: принять как своё
        lastSeen = cur
      else
        autoOff('игрок изменил свет во время моргания (lights_state=' ..
          tostring(cur) .. ')')
        return
      end
    end
    timer = timer - dt
    if timer <= 0 then
      applyLights(0)
      lastSeen = 0
      setSuppress(false)
      phase = 'wait'
      timer = nextDelay()
      print('aplPopup: моргание завершено, следующее через ' ..
        string.format('%.0f', timer) .. ' с')
      toGE('INFO', 'popup: blink done, next in ' .. string.format('%.0f', timer) .. 's')
    end
  end
end

-- === Публичные команды (GE шлёт через queueLuaCommand) ===
autopilotLivePopupCmd = {}

-- start(params): GE присылает параметры popup.json (см. DEFAULTS) + ночь.
function autopilotLivePopupCmd.start(params)
  if active then return false end
  local t = type(params) == 'table' and params or {}
  local D = DEFAULTS
  local c = {
    dayMin = clampNum(t.dayMin, 5, 3600, D.dayMin),
    dayMax = clampNum(t.dayMax, 5, 3600, D.dayMax),
    nightMin = clampNum(t.nightMin, 5, 3600, D.nightMin),
    nightMax = clampNum(t.nightMax, 5, 3600, D.nightMax),
    blinkMin = clampNum(t.blinkMin, 0.2, 10, D.blinkMin),
    blinkMax = clampNum(t.blinkMax, 0.2, 10, D.blinkMax),
    debugDelay = clampNum(t.debugDelay, 0, 600, D.debugDelay),
  }
  if c.dayMax < c.dayMin then c.dayMax = c.dayMin end
  if c.nightMax < c.nightMin then c.nightMax = c.nightMin end
  if c.blinkMax < c.blinkMin then c.blinkMax = c.blinkMin end
  cfg = c
  night = t.night == true
  lastSeen = curState() -- базовая точка: свет при старте не наш
  phase = 'wait'
  timer = nextDelay()
  active = true
  print('aplPopup: АВТО-МОРГАНИЕ ВКЛ (' ..
    (c.debugDelay > 0 and ('ТЕСТ-РЕЖИМ: каждые ' .. string.format('%.0f', c.debugDelay) .. ' с')
      or ('день ' .. string.format('%.0f', c.dayMin) .. '-' .. string.format('%.0f', c.dayMax) ..
          ' с, ночь ' .. string.format('%.0f', c.nightMin) .. '-' .. string.format('%.0f', c.nightMax) .. ' с')) ..
    '; первый миг через ' .. string.format('%.0f', timer) .. ' с; ' ..
    (night and 'сейчас НОЧЬ' or 'сейчас ДЕНЬ') ..
    '; моргание только при выключенном свете; ручное вмешательство отключает')
  toGE('INFO', 'popup auto ON, first in ' .. string.format('%.0f', timer) ..
    's, night=' .. tostring(night) ..
    (c.debugDelay > 0 and (', DEBUG every ' .. string.format('%.0f', c.debugDelay) .. 's') or ''))
  return true
end

function autopilotLivePopupCmd.stop()
  if not active then return false end
  releaseOpen()
  active = false
  phase = 'wait'
  cfg = nil
  print('aplPopup: авто-моргание ВЫКЛ (глазки — штатно)')
  toGE('INFO', 'popup auto OFF (команда)')
  return true
end

-- Смена ночь/день от GE (влияет на СЛЕДУЮЩИЙ интервал)
function autopilotLivePopupCmd.setNight(v)
  night = v == true
  return true
end

function autopilotLivePopupCmd.status()
  local lines = {
    '--- apl_popup status (vehicle) ---',
    'active=' .. tostring(active) ..
      (active and (' phase=' .. phase .. ' timer=' .. string.format('%.1f', timer) .. ' с') or ''),
    'night=' .. tostring(night) .. ' lights_state=' .. tostring(curState()) ..
      ' (моргание только при 0)',
    cfg and ('интервалы: день ' .. string.format('%.0f', cfg.dayMin) .. '-' ..
      string.format('%.0f', cfg.dayMax) .. ' с, ночь ' .. string.format('%.0f', cfg.nightMin) .. '-' ..
      string.format('%.0f', cfg.nightMax) .. ' с, blink ' .. string.format('%.1f', cfg.blinkMin) .. '-' ..
      string.format('%.1f', cfg.blinkMax) .. ' с' ..
      (cfg.debugDelay > 0 and ('; ТЕСТ каждые ' .. string.format('%.0f', cfg.debugDelay) .. ' с') or ''))
      or nil,
    'Ф6 suppress=' .. tostring(suppressHeld),
  }
  for _, l in ipairs(lines) do if l then print('aplPopup: ' .. l) end end
  toGE('INFO', 'popup status: active=' .. tostring(active) ..
    ' phase=' .. phase .. ' lights=' .. tostring(curState()))
  return true
end

-- === Жизненный цикл ===
function M.onReset()
  -- Respawn: electrics сброшены (свет 0) — мигок прерываем, suppress снимаем
  if active then
    suppressHeld = false
    pcall(function()
      if autopilotLiveLightsCmd and autopilotLiveLightsCmd.setSuppress then
        autopilotLiveLightsCmd.setSuppress(false)
      end
    end)
    lastSeen = 0
    phase = 'wait'
    timer = nextDelay() -- ждём заново (cfg может быть nil после stop — guard)
  end
end

function M.onVehicleDestroyed()
  active = false
  cfg = nil
  phase = 'wait'
  suppressHeld = false
end

return M
