-- AutopilotLive — Фаза 8: pop-up фары / «глазки»
-- ИНВЕРТИРОВАННАЯ логика (утв. 24.10): в покое глаза ОТКРЫТЫ (state 1, горят
-- как ДХО), моргание = кратковременное ЗАКРЫТИЕ (state 0) и возврат в 1.
-- Разделить гидравлику и лампы нельзя: lowhighbeam пересчитывается каждый
-- кадр из lights_state (electrics.lua:407/433), hydros читает его же
-- (hydros.lua:301) — выбран вариант «в покое свет 1».
--
-- Режимы: 'sleep' (закрыты; прогрев/выкл) | 'awake' (открыты, ждём таймер) |
-- 'blink' (закрыты blink_s, потом снова 1).
-- Ночь: моргание ПОДАВЛЕНО (не гасим фары на ходу).
-- Ручное вмешательство игрока (не переходы Ф6-auto) → auto OFF + WARN.
-- Совместимость с Ф6: на время мигка/сна setSuppress(true), wake/конец мигка —
-- false; переходы Ф6-auto отличаем через isAuto()/getTarget().

local M = {}

local EYES_OPEN = 1
local EYES_CLOSED = 0

local DEFAULTS = {
  dayMin = 120, dayMax = 180,
  nightMin = 180, nightMax = 300,
  blinkMin = 1.2, blinkMax = 1.2,   -- сколько секунд глаза ЗАКРЫТЫ при мигке
  debugDelay = 0,                   -- 0 = норма; >0 = тест-режим (все интервалы)
}

local active = false
local cfg = nil
local night = false
local phase = 'sleep'
local timer = 0
local suppressHeld = false
local lastSeen = 0          -- ожидаемый/наблюдённый lights_state (след)
local warmupHold = false    -- sleep() от прогрева (работает и без auto)
local savedState = nil      -- состояние света до сна (для wake без auto)
local graceT = 0            -- сек: после нашей команды не считаем смену «ручной»
local dbgT = 0              -- аккумулятор диагностического print (10 с)

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

local function applyEyes(v)
  if curState() ~= v then
    pcall(function() electrics.setLightsState(v) end)
    graceT = 0.5 -- setLightsState применяется не мгновенно — не считаем «ручным»
  end
  lastSeen = v
end

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
    return autopilotLiveLightsCmd and autopilotLiveLightsCmd.isAuto
      and autopilotLiveLightsCmd.isAuto() or false
  end)
  return ok and r == true
end

local function lightsTarget()
  local ok, r = pcall(function()
    return autopilotLiveLightsCmd and autopilotLiveLightsCmd.getTarget
      and autopilotLiveLightsCmd.getTarget() or nil
  end)
  return ok and tonumber(r) or nil
end

local function nextDelay()
  local c = cfg
  if c.debugDelay > 0 then return c.debugDelay end
  local lo, hi
  if night then lo, hi = c.nightMin, c.nightMax else lo, hi = c.dayMin, c.dayMax end
  return lo + (hi - lo) * math.random()
end

local function blinkDuration()
  return cfg.blinkMin + (cfg.blinkMax - cfg.blinkMin) * math.random()
end

-- Авто-стоп по ручному вмешательству (не бьёмся с игроком)
local function autoOff(reason)
  if phase == 'blink' and curState() == EYES_CLOSED then
    applyEyes(EYES_OPEN) -- вернуть свет, который мы сами погасили
  end
  if phase == 'blink' then setSuppress(false) end
  active = false
  warmupHold = false
  phase = 'sleep'
  print('aplPopup: АВТО-ОТКЛЮЧЕНО — ' .. reason)
  toGE('WARN', 'popup auto off: ' .. reason)
  notifyGE('onVehiclePopupAutoOff')
end

-- Можно ли моргать сейчас? (день + не мешаем Ф6, если его target не 1)
local function blinkAllowed()
  if night then return false, 'ночь — фары должны гореть постоянно' end
  if isLightsAuto() then
    local t = lightsTarget()
    if t ~= nil and t ~= 1 then
      return false, 'Ф6-auto target=' .. tostring(t) .. ' — не вмешиваемся'
    end
  end
  return true
end

function M.updateGFX(dt)
  if not active and not warmupHold then return end
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then return end

  if phase == 'sleep' then
    -- Сон (прогрев/старт): держим глаза закрытыми КАЖДЫЙ кадр, даже если
    -- auto не активен (warmupHold) — иначе электрика/Ф6 вернут свет.
    applyEyes(EYES_CLOSED)
    lastSeen = EYES_CLOSED
    return
  end
  if not active or cfg == nil then return end

  -- ВАЖНО: curState() читаем ЗДЕСЬ; после applyEyes НЕ перечитывать (значение
  -- применяется не мгновенно) — иначе ложное «вмешательство» (баг 24.10).
  local cur = curState()

  -- awake/blink: детект вмешательства извне (не наш мигок, не Ф6-auto)
  if graceT > 0 then
    graceT = graceT - dt -- окно после нашей команды
  elseif cur ~= lastSeen then
    if isLightsAuto() then
      lastSeen = cur -- переход Ф6-auto (ночь/день) — не вмешательство
      toGE('INFO', 'popup: переход Ф6-auto (lights_state=' .. tostring(cur) .. ')')
    else
      autoOff('игрок сам трогает фары (lights_state=' .. tostring(cur) .. ')')
      return
    end
  end

  if phase == 'awake' then
    -- Глаза открыты; при активном Ф6 не навязываем 1 (у Ф6 может быть 2)
    if not isLightsAuto() and curState() ~= EYES_OPEN then
      applyEyes(EYES_OPEN)
      lastSeen = EYES_OPEN
    end
    timer = timer - dt
    -- Диагностика (24.10): heartbeat раз в 10 с — видно, тикает ли таймер
    dbgT = dbgT + dt
    if dbgT >= 10 then
      dbgT = 0
      print(string.format('aplPopup: TICK awake — timer=%.1f с, state=%d, night=%s, f6auto=%s, suppress=%s',
        timer, cur, tostring(night), tostring(isLightsAuto()), tostring(suppressHeld)))
    end
    if timer <= 0 then
      local okBlink, why = blinkAllowed()
      if not okBlink then
        timer = nextDelay()
        print('aplPopup: моргание отложено (' .. why .. ')')
        toGE('INFO', 'popup: моргание отложено (' .. why .. ')')
        return
      end
      setSuppress(true)
      applyEyes(EYES_CLOSED)
      lastSeen = EYES_CLOSED
      phase = 'blink'
      timer = blinkDuration()
      print('aplPopup: МОРГАНИЕ (закрыты на ' .. string.format('%.1f', timer) .. ' с)')
      toGE('INFO', 'popup blink close=' .. string.format('%.1f', timer) .. 's')
    end
  elseif phase == 'blink' then
    timer = timer - dt
    if timer <= 0 then
      applyEyes(EYES_OPEN)
      lastSeen = EYES_OPEN
      setSuppress(false)
      phase = 'awake'
      timer = nextDelay()
      print('aplPopup: моргание завершено, следующее через ' ..
        string.format('%.0f', timer) .. ' с')
      toGE('INFO', 'popup blink done, next in ' .. string.format('%.0f', timer) .. 's')
    end
  end
end

autopilotLivePopupCmd = {}

function autopilotLivePopupCmd.start(params)
  if active then return false end
  local t = type(params) == 'table' and params or {}
  local D = DEFAULTS
  cfg = {
    dayMin = clampNum(t.dayMin, 5, 3600, D.dayMin),
    dayMax = clampNum(t.dayMax, 5, 3600, D.dayMax),
    nightMin = clampNum(t.nightMin, 5, 3600, D.nightMin),
    nightMax = clampNum(t.nightMax, 5, 3600, D.nightMax),
    blinkMin = clampNum(t.blinkMin, 0.1, 10, D.blinkMin),
    blinkMax = clampNum(t.blinkMax, 0.1, 10, D.blinkMax),
    debugDelay = clampNum(t.debugDelay, 0, 600, D.debugDelay),
  }
  if cfg.dayMax < cfg.dayMin then cfg.dayMax = cfg.dayMin end
  if cfg.nightMax < cfg.nightMin then cfg.nightMax = cfg.nightMin end
  if cfg.blinkMax < cfg.blinkMin then cfg.blinkMax = cfg.blinkMin end
  night = t.night == true
  active = true
  warmupHold = false
  savedState = nil
  local curBefore = curState()
  if curBefore == EYES_CLOSED then
    applyEyes(EYES_OPEN) -- открыть; 1/2 не понижаем (lastSeen ставит applyEyes)
  else
    lastSeen = curBefore
  end
  phase = 'awake'
  timer = nextDelay()
  print('aplPopup: ВКЛ. Глаза ОТКРЫТЫ (state=' .. tostring(lastSeen) ..
    '). Следующее моргание через ' .. string.format('%.0f', timer) .. ' с' ..
    (night and ' (сейчас ночь — моргание подавлено)' or ''))
  toGE('INFO', 'popup auto ON, eyes open, first blink in ' ..
    string.format('%.0f', timer) .. 's, night=' .. tostring(night))
  return true
end

-- Сон: прогрев/пауза. Работает и без active (warmup-сценарий).
function autopilotLivePopupCmd.sleep()
  if savedState == nil then savedState = curState() end
  local before = curState()
  warmupHold = true
  setSuppress(true) -- Ф6 не откроет фары во время сна
  phase = 'sleep'
  applyEyes(EYES_CLOSED)
  lastSeen = EYES_CLOSED
  print(string.format('aplPopup: СОН — state %d → %d (команда 0), auto=%s, warmupHold=true, suppress=true',
    before, curState(), tostring(active)))
  return true
end

-- Пробуждение: открыть глаза. Без active — восстановить прежний state
-- (не ломаем дальний свет), иначе 1.
function autopilotLivePopupCmd.wake_up()
  if not active and not warmupHold then return false end
  local before = curState()
  setSuppress(false)
  warmupHold = false
  if active then
    applyEyes(EYES_OPEN) -- lastSeen ставит applyEyes (не перечитываем state!)
    phase = 'awake'
    timer = nextDelay()
    print(string.format('aplPopup: ПРОБУЖДЕНИЕ — state %d → %d, глаза открыты, следующее моргание через %.0f с',
      before, curState(), timer))
  else
    local restore = EYES_OPEN
    if savedState == 1 or savedState == 2 then restore = savedState end
    applyEyes(restore)
    savedState = nil
    print(string.format('aplPopup: ПРОБУЖДЕНИЕ (warmup) — state %d → %d (восстановлен %d)',
      before, curState(), restore))
  end
  return true
end

function autopilotLivePopupCmd.stop()
  if not active and not warmupHold then return false end
  if phase == 'blink' and curState() == EYES_CLOSED then
    applyEyes(EYES_OPEN) -- не оставляем свет погашенным
  end
  setSuppress(false)
  active = false
  warmupHold = false
  savedState = nil
  phase = 'sleep'
  print('aplPopup: ВЫКЛ (свет оставлен как есть)')
  toGE('INFO', 'popup auto OFF')
  return true
end

function autopilotLivePopupCmd.status()
  local f6auto = isLightsAuto()
  local lines = {
    '--- apl_popup status (vehicle) ---',
    'active=' .. tostring(active) .. (active and (' phase=' .. phase ..
      ' timer=' .. string.format('%.1f', timer) .. ' с') or '') ..
      ' warmupHold=' .. tostring(warmupHold),
    'lights_state=' .. tostring(curState()) .. ' lastSeen=' .. tostring(lastSeen) ..
      ' night=' .. tostring(night) .. ' (моргание ночью подавлено)',
    'Ф6: auto=' .. tostring(f6auto) .. ' target=' .. tostring(lightsTarget()) ..
      ' suppress=' .. tostring(suppressHeld),
    cfg and ('интервалы: день ' .. string.format('%.0f', cfg.dayMin) .. '-' ..
      string.format('%.0f', cfg.dayMax) .. ' с, ночь ' ..
      string.format('%.0f', cfg.nightMin) .. '-' .. string.format('%.0f', cfg.nightMax) ..
      ' с, blink ' .. string.format('%.1f', cfg.blinkMin) .. '-' ..
      string.format('%.1f', cfg.blinkMax) .. ' с' ..
      (cfg.debugDelay > 0 and ('; ТЕСТ каждые ' .. string.format('%.0f', cfg.debugDelay) .. ' с') or '')) or nil,
  }
  for _, l in ipairs(lines) do if l then print('aplPopup: ' .. l) end end
  return true
end

function M.onReset()
  setSuppress(false)
  if active then
    phase = 'awake'
    applyEyes(EYES_OPEN)
    lastSeen = curState()
    timer = nextDelay()
  end
end

function M.onVehicleDestroyed()
  active = false
  warmupHold = false
  savedState = nil
  phase = 'sleep'
  setSuppress(false)
end

return M
