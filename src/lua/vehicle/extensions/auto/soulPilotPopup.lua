-- soulPilot — Фаза 8: pop-up фары / «глазки»
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
local musicHold = false     -- Фаза 11.2: музыка временно владеет светом
local lastSeen = 0          -- ожидаемый/наблюдённый lights_state (след)
local warmupHold = false    -- sleep() от прогрева (работает и без auto)
local savedState = nil      -- состояние света до сна (для wake без auto)
local graceT = 0            -- сек: после нашей команды не считаем смену «ручной»
local dbgT = 0              -- аккумулятор диагностического print (10 с)
local lastNightCmd = '—'    -- последнее значение setNight от GE (диагностика)

local function toGE(level, msg)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if extensions and extensions.soulPilot_main and extensions.soulPilot_main.onVehicleLog then extensions.soulPilot_main.onVehicleLog("%s", "%s") end',
      level, tostring(msg):gsub('\\', '\\\\'):gsub('"', '\\"')))
  end)
end

local function notifyGE(fname)
  pcall(function()
    obj:queueGameEngineLua(
      'if extensions and extensions.soulPilot_main and extensions.soulPilot_main.' .. fname .. ' then extensions.soulPilot_main.' .. fname .. '() end')
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
    if soulPilotLightsCmd and soulPilotLightsCmd.setSuppress then
      soulPilotLightsCmd.setSuppress(v)
    end
  end)
end

local function isLightsAuto()
  local ok, r = pcall(function()
    return soulPilotLightsCmd and soulPilotLightsCmd.isAuto
      and soulPilotLightsCmd.isAuto() or false
  end)
  return ok and r == true
end

local function lightsTarget()
  local ok, r = pcall(function()
    return soulPilotLightsCmd and soulPilotLightsCmd.getTarget
      and soulPilotLightsCmd.getTarget() or nil
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
  aplPrint('aplPopup: АВТО-ОТКЛЮЧЕНО — ' .. reason)
  toGE('WARN', 'popup auto off: ' .. reason)
  notifyGE('onVehiclePopupAutoOff')
end

-- Можно ли моргать сейчас? (день + не мешаем Ф6, если его target не 1)
local function blinkAllowed()
  -- Debug mode deliberately blinks at any time, including night, so it can be
  -- verified without waiting for the normal 2-3 minute interval.
  if cfg and cfg.debugDelay > 0 then
    return true
  end
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
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then return end
  if musicHold then return end -- Фаза 11.2: светом управляет музыка
  if not active and not warmupHold then return end

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
    -- Глаза открыты. НОЧЬЮ state НЕ трогаем вовсе (игрок/Ф6: 1=ближний, 2=дальний) —
    -- иначе затирали дальний и фары «слабые». Днём открываем 1, если Ф6 не авто.
    if not night and not isLightsAuto() and curState() ~= EYES_OPEN then
      applyEyes(EYES_OPEN)
    end
    timer = timer - dt
    -- Диагностика (24.10): heartbeat раз в 10 с — видно, тикает ли таймер
    dbgT = dbgT + dt
    if dbgT >= 10 then
      dbgT = 0
      aplPrint(string.format('aplPopup: TICK awake — timer=%.1f с, state=%d, night=%s, f6auto=%s, suppress=%s',
        timer, cur, tostring(night), tostring(isLightsAuto()), tostring(suppressHeld)))
    end
    if timer <= 0 then
      local okBlink, why = blinkAllowed()
      if not okBlink then
        timer = nextDelay()
        aplPrint('aplPopup: моргание отложено (' .. why .. ')')
        toGE('INFO', 'popup: моргание отложено (' .. why .. ')')
        return
      end
      setSuppress(true)
      applyEyes(EYES_CLOSED)
      lastSeen = EYES_CLOSED
      phase = 'blink'
      timer = blinkDuration()
      aplPrint('aplPopup: МОРГАНИЕ (закрыты на ' .. string.format('%.1f', timer) .. ' с)')
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
      aplPrint('aplPopup: моргание завершено, следующее через ' ..
        string.format('%.0f', timer) .. ' с')
      toGE('INFO', 'popup blink done, next in ' .. string.format('%.0f', timer) .. 's')
    end
  end
end

soulPilotPopupCmd = {}

-- Legacy migration alias; new code must use soulPilotPopupCmd.
autopilotLivePopupCmd = soulPilotPopupCmd

-- Фаза 11.2: музыка временно управляет светом (пульс в такт beat).
-- Пока musicHold=true, обычная логика popup не трогает lights_state.
function soulPilotPopupCmd.musicOverride(state)
  musicHold = true
  setSuppress(true)
  applyEyes((tonumber(state) or 0) >= 1 and EYES_OPEN or EYES_CLOSED)
  return true
end

function soulPilotPopupCmd.musicRelease()
  if not musicHold then return false end
  musicHold = false
  -- Suppress возвращаем в состояние, нужное обычной логике: сон прогрева
  -- или незавершённый мигок. Иначе Ф6-auto снова начнёт менять свет.
  setSuppress(warmupHold or (active and phase == 'blink'))
  return true
end

function soulPilotPopupCmd.isMusicHold()
  return musicHold
end

function soulPilotPopupCmd.start(params)
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
  aplPrint('aplPopup: ВКЛ. Глаза ОТКРЫТЫ (state=' .. tostring(lastSeen) ..
    '). Следующее моргание через ' .. string.format('%.0f', timer) .. ' с' ..
    (night and ' (сейчас ночь — моргание подавлено)' or ''))
  aplPrint('aplPopup: START получен — night=' .. tostring(t.night) ..
    ', debug=' .. tostring(cfg.debugDelay) .. ' с')
  toGE('INFO', 'popup auto ON, eyes open, first blink in ' ..
    string.format('%.0f', timer) .. 's, night=' .. tostring(night))
  return true
end

-- Сон: прогрев/пауза. Работает и без active (warmup-сценарий).
function soulPilotPopupCmd.sleep()
  if savedState == nil then savedState = curState() end
  local before = curState()
  warmupHold = true
  setSuppress(true) -- Ф6 не откроет фары во время сна
  phase = 'sleep'
  applyEyes(EYES_CLOSED)
  lastSeen = EYES_CLOSED
  aplPrint(string.format('aplPopup: СОН — state %d → %d (команда 0), auto=%s, warmupHold=true, suppress=true',
    before, curState(), tostring(active)))
  return true
end

-- Пробуждение: открыть глаза. Без active — восстановить прежний state
-- (не ломаем дальний свет), иначе 1.
function soulPilotPopupCmd.wake_up()
  if not active and not warmupHold then return false end
  local before = curState()
  setSuppress(false)
  warmupHold = false
  if active then
    if night then
      -- Ночью state не трогаем (дальний/ближний — решение игрока/Ф6)
      lastSeen = curState()
      phase = 'awake'
      timer = nextDelay()
      aplPrint(string.format('aplPopup: ПРОБУЖДЕНИЕ (ночь) — state %d оставлен как есть, моргание подавлено',
        lastSeen))
    else
      applyEyes(EYES_OPEN) -- lastSeen ставит applyEyes (не перечитываем state!)
      phase = 'awake'
      timer = nextDelay()
      aplPrint(string.format('aplPopup: ПРОБУЖДЕНИЕ — state %d → %d, глаза открыты, следующее моргание через %.0f с',
        before, curState(), timer))
    end
  else
    local restore = EYES_OPEN
    if savedState == 1 or savedState == 2 then restore = savedState end
    applyEyes(restore)
    savedState = nil
    aplPrint(string.format('aplPopup: ПРОБУЖДЕНИЕ (warmup) — state %d → %d (восстановлен %d)',
      before, curState(), restore))
  end
  return true
end

-- Ночь/день от GE (keepalive каждые 5 с).
-- ВАЖНО: метод был ПОТЕРЯН при переписывании файла — GE слал setNight в nil,
-- vehicle оставался с night=false (баг 24.10, GE показывал НОЧЬ, vehicle — нет).
function soulPilotPopupCmd.setNight(v)
  local nb = v == true
  -- Явное подтверждение ПРИЁМА (диагностика рассинхрона GE/vehicle 24.10)
  aplPrint('aplPopup: ПОЛУЧЕН setNight=' .. tostring(nb) ..
    ' (было ' .. tostring(night) .. ')')
  if nb ~= night then
    night = nb
    lastNightCmd = tostring(nb)
    aplPrint('aplPopup: setNight ' .. tostring(not nb) .. ' → ' .. tostring(nb) ..
      (nb and ' (НОЧЬ: моргание подавлено)' or ' (ДЕНЬ)'))
  else
    lastNightCmd = tostring(nb)
  end
  return true
end

function soulPilotPopupCmd.stop()
  musicHold = false
  if not active and not warmupHold then return false end
  if phase == 'blink' and curState() == EYES_CLOSED then
    applyEyes(EYES_OPEN) -- не оставляем свет погашенным
  end
  setSuppress(false)
  active = false
  warmupHold = false
  savedState = nil
  phase = 'sleep'
  aplPrint('aplPopup: ВЫКЛ (свет оставлен как есть)')
  toGE('INFO', 'popup auto OFF')
  return true
end

function soulPilotPopupCmd.status()
  local f6auto = isLightsAuto()
  local lines = {
    '--- apl_popup status (vehicle) ---',
    'active=' .. tostring(active) .. (active and (' phase=' .. phase ..
      ' timer=' .. string.format('%.1f', timer) .. ' с') or '') ..
      ' warmupHold=' .. tostring(warmupHold),
    'lights_state=' .. tostring(curState()) .. ' lastSeen=' .. tostring(lastSeen) ..
      ' night=' .. tostring(night) .. ' (setNight=' .. tostring(lastNightCmd) ..
      '; моргание ночью подавлено)',
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
  musicHold = false
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
  musicHold = false
  savedState = nil
  phase = 'sleep'
  setSuppress(false)
end

return M
