-- AutopilotLive — Фаза 5: прогрев машины (vehicle-слой, расширение)
-- Загружается АВТОМАТИЧЕСКИ при спавне машины (vehicle/main.lua:314 →
-- extensions.loadModulesInDirectory("lua/vehicle/extensions/auto")).
--
-- Ответственность (Фаза 5, шаги 5.2-5.4):
--   * apl_warmup("start") → autopilotLiveWarmupCmd.on(conf): машина сама
--     заводится (electrics.setIgnitionLevel(3) для ICE — ignition on + стартёр,
--     контроллер сам снизит до 2 после схватки; для EV — уровень 2, см.
--     api_research_phase5.md §1) и прогревается:
--       - минимум min_time_s (даже если машина уже тёплая — спавн preHeated=80°C);
--       - coolant >= temp_threshold_c И oil >= oil_threshold_c (нефтехимия
--         медленнее — компромиссный порог 60°C, решение координатора 16.10);
--       - либо max_timeout_s (зима/поломка) → done с WARN.
--   * Шаг 5.3 + правки игрока 18.10: sway — покачивание рулём КУБИЧЕСКИМ
--     синусом (amplitude * sin^3 — «плоские пики», эффект дыхания; 0.05 ≈ 5°,
--     0.3 Гц, fade-огибающая 2 с) СЛУЧАЙНЫМ СОБЫТИЕМ: при start() генерируется
--     окно [sway_start_time, +duration_s] (random_delay_min..max от старта) —
--     весь прогрев НЕ качает, момент — случайный при каждом запуске.
--     При wheel engaged — sway отключается (вариант B, wheel.lua не трогаем).
--   * done → ручник снимается штатным API (шаг 5.4, parking_brake_release_at_end),
--     сообщение игроку (print GE + guihooks HUD + txt-лог) и сигнал GE
--     onVehicleWarmupDone → GE при auto_engage_after_warmup=true включает
--     wheel/pedals (если они ещё не включены).
--   * Опциональная надстройка: wheel/pedals НЕ трогает и НЕ подменяет, КПП не
--     трогает ни в одной фазе. Работает state-machine поверх уже включённых
--     модулей (контракт Фазы 5).
--
-- НЕ дёргает input.event напрямую: ручник — только штатный API
-- vehicleController.smartParkingBrake (api_research_phase5.md §2).

local M = {}

-- Конфиг: путь относительный от userPath (sandbox io.open) — GE шлёт в on().
local FALLBACK_CONF = 'mods/unpacked/AutopilotLive/ai/config/warmup.json'

-- === Дефолты конфига (дубль warmup.json — ТОЛЬКО fallback при отсутствии/
-- битом конфиге; источник истины — файл) ===
-- Единицы: *_s — секунды, *_c — градусы Цельсия, amplitude — нормированный
-- руль [-1,1] (0.05 ≈ 5°), freq_hz — Гц.
local DEFAULTS = {
  timing = { min_time_s = 10, max_timeout_s = 120, start_timeout_s = 10 },
  engine = { temp_threshold_c = 85, oil_threshold_c = 60, temp_poll_hz = 1 },
  -- sway: СЛУЧАЙНОЕ окно активности [sway_start_time, sway_start_time+duration_s]
  -- от elapsed — генерируется при start() в [random_delay_min_s, random_delay_max_s]
  -- (правка игрока 18.10: покачивание-событие в случайный момент прогрева).
  sway   = { enabled = 1, amplitude = 0.05, freq_hz = 0.3, fade_time_s = 2,
             duration_s = 4, random_delay_min_s = 1, random_delay_max_s = 8 },
  finish = { parking_brake_release_at_end = 1, auto_engage_after_warmup = 0 },
}

-- === Состояние ===
-- state: 'off' | 'starting_engine' | 'warming_up' | 'done'
local cfg = nil
local cfgFromFile = false
local state = 'off'
local elapsed = 0               -- сек от start (включая фазу старта)
local startTimer = 0            -- сек в starting_engine
local pollTimer = 0             -- до следующего опроса термалов
local lastCoolant = nil         -- последний прочитанный coolantTemperature
local lastOil = nil             -- последний прочитанный oilTemperature
-- Шаг 5.3: sway (покачивание рулём)
local swayTime = 0              -- фаза синуса (непрерывный аккумулятор)
local swayAmp = 0               -- текущая огибающая [0..amplitude]
local swayTarget = 0            -- целевая огибающая (amplitude при прогреве, 0 при off/done)
local swayWritten = false       -- писали ли steering_input в прошлом кадре
local wheelEngagedWarned = false -- INFO «sway отключён: wheel engaged» уже выдан
local swayStart = nil           -- начало случайного окна свея (сек от start)
local swayEnd = nil             -- конец окна свея (swayStart + duration_s)

-- === Лог событий в GE (паттерн autopilotLivePedals.lua) ===
local function toGE(level, msg)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if autopilotLive_main and autopilotLive_main.onVehicleLog then autopilotLive_main.onVehicleLog("%s", "%s") end',
      level, tostring(msg):gsub('\\', '\\\\'):gsub('"', '\\"')))
  end)
end

-- === Утилиты ===
local function safeNum(v)
  v = tonumber(v) or 0
  if v ~= v then return 0 end -- NaN → 0
  if v == math.huge or v == -math.huge then return 0 end
  return v
end

-- Печать чисел через tostring (урок аномалии brake.out 2026-10-16: числовые
-- string.format с многими аргументами в LuaJIT ненадёжны — все статус-выводы
-- идут %s/tostring).
local function fmt(v)
  return tostring(safeNum(v))
end

-- === Конфиг: merge + валидация (паттерн wheel) ===
local function validateConfig(c)
  local function pos(gr, key, dflt, lo, hi)
    local v = c[gr][key]
    if v == nil or v ~= v or v <= 0 then c[gr][key] = dflt; return end
    if lo and v < lo then c[gr][key] = lo end
    if hi and v > hi then c[gr][key] = hi end
  end
  local D = DEFAULTS
  pos('timing', 'min_time_s',       D.timing.min_time_s,       1,    3600)
  pos('timing', 'max_timeout_s',    D.timing.max_timeout_s,    5,    3600)
  pos('timing', 'start_timeout_s',  D.timing.start_timeout_s,  1,    120)
  pos('engine', 'temp_threshold_c', D.engine.temp_threshold_c, 50,   120)
  pos('engine', 'oil_threshold_c',  D.engine.oil_threshold_c,  20,   120)
  pos('engine', 'temp_poll_hz',     D.engine.temp_poll_hz,     0.1,  10)
  pos('sway',   'amplitude',        D.sway.amplitude,          0.001, 0.3)
  pos('sway',   'freq_hz',          D.sway.freq_hz,            0.01, 2.0)
  pos('sway',   'fade_time_s',      D.sway.fade_time_s,        0.1,  30)
  pos('sway',   'duration_s',       D.sway.duration_s,         0.1,  600)
  -- random_delay_s: 0 допустим для min (сразу после start) — pos() не подходит
  -- (он требует > 0), поэтому отдельно; max нормализуется к min (не может
  -- быть меньше него — иначе math.random(min*100, max*100) упадёт).
  do
    local vmin = c.sway.random_delay_min_s
    local vmax = c.sway.random_delay_max_s
    if vmin == nil or vmin ~= vmin or vmin < 0 then vmin = D.sway.random_delay_min_s end
    if vmax == nil or vmax ~= vmax or vmax < 0 then vmax = D.sway.random_delay_max_s end
    if vmin > 600 then vmin = 600 end
    if vmax > 600 then vmax = 600 end
    if vmax < vmin then vmax = vmin end
    c.sway.random_delay_min_s, c.sway.random_delay_max_s = vmin, vmax
  end
  -- max_timeout не может быть меньше min_time (иначе done по таймауту
  -- обгоняет условие «минимум») — тихо поднимаем.
  if c.timing.max_timeout_s < c.timing.min_time_s then
    c.timing.max_timeout_s = c.timing.min_time_s
  end
end

local function loadConfig(path)
  local c = {}
  for gr, kv in pairs(DEFAULTS) do
    c[gr] = {}
    for k, v in pairs(kv) do c[gr][k] = v end
  end
  local f = io.open(path, 'r')
  if not f then
    toGE('WARN', 'warmup: конфиг не найден (' .. tostring(path) .. ') — используются дефолты кода')
    return c, false
  end
  local content = f:read('*all')
  f:close()
  local ok, decoded = pcall(jsonDecode, content, path)
  if not ok or type(decoded) ~= 'table' then
    toGE('WARN', 'warmup: конфиг не распарсен — используются дефолты кода')
    return c, false
  end
  for gr, kv in pairs(DEFAULTS) do
    local decGr = type(decoded[gr]) == 'table' and decoded[gr] or nil
    if decGr then
      for k in pairs(kv) do
        local v = decGr[k]
        if type(v) == 'boolean' then v = v and 1 or 0 end -- флаги допускают true/false
        v = tonumber(v)
        if v ~= nil then c[gr][k] = v end
      end
    end
  end
  validateConfig(c)
  return c, true
end

-- === Двигатель и термалы ===
-- «Заведена?»: electrics.values.engineRunning (vehicleController:565).
local function engineRunning()
  local ok, v = pcall(function() return electrics.values.engineRunning or 0 end)
  return ok and v > 0 or false
end

-- Термалы combustionEngine: powertrain.getDevicesByType → dev.thermals
-- (паттерн autopilotLive.lua:61-79 для CSV). Ищем каждый опрос (1 Гц), пока
-- не найдём: ранний вызов до init powertrain не должен отрубить поиск навсегда.
local function refreshThermals()
  local ok, res = pcall(function()
    local devices = powertrain.getDevicesByType('combustionEngine')
    for _, dev in pairs(devices or {}) do
      if dev.thermals then return dev.thermals end
    end
    return nil
  end)
  return ok and res or nil
end

-- Завод: ICE — уровень 3 (ignition on + стартёр; после схватки контроллер
-- сам понизит до 2 — vehicleController:303-304); EV — уровень 2 (стартёр
-- бессмысленен, у EV isEngineRunning=1 после ignition-on).
local function startEngine()
  local th = refreshThermals()
  pcall(function()
    if th then
      electrics.setIgnitionLevel(3)
    else
      electrics.setIgnitionLevel(2)
    end
  end)
  return th ~= nil
end

local function readTemps()
  local th = refreshThermals()
  if th then
    lastCoolant = safeNum(th.coolantTemperature)
    lastOil = safeNum(th.oilTemperature)
  end
end

-- Условие «прогрета»: coolant >= порога И oil >= порога (решение координатора
-- 16.10). Если термалов нет (EV/нет движка) — условие по температуре не
-- требуется, прогрев идёт только по таймингу.
local function tempOk()
  if lastCoolant == nil then return true end -- термалов нет — только тайминги
  return lastCoolant >= cfg.engine.temp_threshold_c
     and lastOil >= cfg.engine.oil_threshold_c
end

-- === Шаг 5.4: снятие ручника ===
-- Штатный API vehicleController.smartParkingBrake(0) — разрешён координатором
-- 16.10 (api_research_phase5.md §2): input.event("parkingbrake", 0, ...)
-- делает контроллер машины, НЕ наш модуль. Вызывается в finish() перед
-- сообщением «готова»; при parking_brake_release_at_end=0 — ничего не делаем.
local function releaseParkingBrake()
  if cfg.finish.parking_brake_release_at_end <= 0 then return end
  local pb = 0
  pcall(function() pb = electrics.values.parkingbrake or 0 end)
  if pb <= 0.5 then
    toGE('INFO', 'warmup: ручник не поднят — снимать нечего')
    return
  end
  local ok, err = pcall(function()
    local vc = controller.getControllerSafe('vehicleController')
    vc.smartParkingBrake(0)
  end)
  if ok then
    toGE('INFO', 'warmup: ручник снят (smartParkingBrake(0))')
  else
    toGE('WARN', 'warmup: не удалось снять ручник: ' .. tostring(err))
  end
end

-- === Завершение ===
-- Сигнал GE: onVehicleWarmupDone(vehId, elapsed, tempC, autoEngage, timedOut) —
-- GE печатает сообщение в консоль игрока и делает авто-engage (шаг 5.4).
local function notifyDone(timedOut)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if autopilotLive_main and autopilotLive_main.onVehicleWarmupDone then autopilotLive_main.onVehicleWarmupDone(%s, %s, %s, %s, %s) end',
      tostring(obj and obj:getId() or -1), fmt(elapsed),
      lastCoolant and fmt(lastCoolant) or '-1',
      tostring(cfg.finish.auto_engage_after_warmup > 0),
      tostring(timedOut)))
  end)
end

local function finish(timedOut)
  state = 'done'
  releaseParkingBrake() -- снятие ручника — ПЕРЕД сообщением «готова» (шаг 5.4)
  local cool = lastCoolant and ('coolant ' .. fmt(lastCoolant) .. '°C, oil ' .. fmt(lastOil) .. '°C')
    or 'термалы недоступны (EV?) — только тайминг'
  if timedOut then
    toGE('WARN', 'warmup: ТАЙМАУТ ' .. fmt(cfg.timing.max_timeout_s) ..
      ' с — условия не выполнены (' .. cool .. '). Переход к «готово».')
  else
    toGE('INFO', 'warmup: ПРОГРЕВ ЗАВЕРШЁН (' .. fmt(elapsed) .. ' с, ' .. cool .. ')')
  end
  -- HUD-сообщение игроку (паттерн electrics.lua:357) + txt-лог уже ушёл toGE.
  pcall(function()
    guihooks.message({ txt = timedOut
        and 'AutopilotLive: прогрев по таймауту — машина готова'
        or 'AutopilotLive: прогрев завершён, машина готова', context = {} }, 5,
      'autopilotLive.warmup')
  end)
  notifyDone(timedOut)
end

-- === Шаг 5.3/5.6: sway — плавное покачивание рулём «как бабушка зарядку делает» ===
-- ФОРМУЛА (правка игрока 18.10): КУБИЧЕСКИЙ СИНОУС —
--   steering_input = amplitude * (sin(2π·freq·t))^3
-- Куб синусы даёт «плоские пики»: в крайних точках руль как бы замирает
-- (производная сходится к 0), создавая эффект живого дыхания вместо
-- механического «демо-режима». Знак сохраняется (нечётная степень).
-- ОКНО АКТИВНОСТИ (правки игрока 18.10, рандом): покачивание НЕ идёт весь
-- прогрев — только пока elapsed ∈ [sway_start_time, sway_start_time +
-- duration_s]; начало генерируется при start() в [random_delay_min_s,
-- random_delay_max_s] — событие в случайный момент прогрева;
-- вне окна целевая огибающая = 0 → плавное затухание за fade_time_s.
-- Огибающая (fade) растёт и тает линейно — без щелчка руля при старте/остановке.
-- Запись electrics.values.steering_input — та же схема Фазы 4 (wheel):
-- переживает кадр и применяется hydros (api_research_phase5.md §5).
-- ВАРИАНТ B (решение координатора 16.10): если wheel engaged (active +
-- ai.isDriving) — свей НЕ пишем (его запись steering_input идёт после нашей
-- и затирала бы sway), wheel.lua не трогаем. INFO выдаётся один раз.
local function swayStep(dt)
  if not cfg or cfg.sway.enabled <= 0 then return end
  swayTime = swayTime + dt

  -- Фаза активности = идёт прогрев И elapsed внутри СЛУЧАЙНОГО окна свея
  -- (сгенерировано при start, см. autopilotLiveWarmupCmd.on); иначе
  -- (start/done/off/вне окна) — плавное затухание до 0.
  local activePhase = (state == 'starting_engine' or state == 'warming_up')
    and swayStart ~= nil
    and elapsed >= swayStart
    and elapsed <= swayEnd
  swayTarget = activePhase and cfg.sway.amplitude or 0
  local step = cfg.sway.amplitude * dt / math.max(cfg.sway.fade_time_s, 0.1)
  if swayAmp < swayTarget then
    swayAmp = math.min(swayAmp + step, swayTarget)
  elseif swayAmp > swayTarget then
    swayAmp = math.max(swayAmp - step, swayTarget)
  end

  if swayAmp <= 1e-6 then
    -- Затухли: ПЕРЕСТАЁМ писать steering_input — движок сам затирает его
    -- каждый кадр (input.lua:678) ⇒ штатный руль возвращается мгновенно.
    swayWritten = false
    return
  end

  local okGet, wstate = pcall(function()
    return autopilotLiveWheelGetState and autopilotLiveWheelGetState()
  end)
  if okGet and wstate and wstate.engaged then
    if not wheelEngagedWarned then
      wheelEngagedWarned = true
      toGE('INFO', 'warmup: sway отключён — wheel перехватывает руль (решение B, 16.10)')
    end
    return
  end
  wheelEngagedWarned = false

  -- Кубический синус: сглаженные «плоские пики» — руль замирает в крайних
  -- точках (эффект дыхания), а не качается синусоидой-маятником.
  local s = math.sin(2 * math.pi * cfg.sway.freq_hz * swayTime)
  local swayVal = swayAmp * (s ^ 3)
  pcall(function() electrics.values.steering_input = swayVal end)
  swayWritten = true
end

-- === Кадровый цикл ===
function M.updateGFX(dt)
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then return end -- NaN/перерывы

  if state == 'off' or state == 'done' then
    -- Прогрев не идёт: добиваем затухание свея (если был) — без щелчка руля.
    if cfg and cfg.sway.enabled > 0 and swayAmp > 0 then swayStep(dt) end
    return
  end

  elapsed = elapsed + dt

  if state == 'starting_engine' then
    startTimer = startTimer + dt
    if engineRunning() then
      state = 'warming_up'
      toGE('INFO', 'warmup: двигатель заведён (' .. fmt(elapsed) .. ' с от старта)')
    elseif startTimer >= cfg.timing.start_timeout_s then
      toGE('WARN', 'warmup: двигатель не завёлся за ' .. fmt(cfg.timing.start_timeout_s) ..
        ' с — идём по таймеру (без температурного условия)')
      -- НЕ блокируем: далее tempOk() при отсутствии термалов откатится на
      -- тайминги, таймаут 120 с всё равно завершит прогрев.
      state = 'warming_up'
    end
  elseif state == 'warming_up' then
    pollTimer = pollTimer + dt
    if pollTimer >= 1 / cfg.engine.temp_poll_hz then
      pollTimer = 0
      readTemps()
    end

    if elapsed >= cfg.timing.min_time_s and tempOk() then
      finish(false)
    elseif elapsed >= cfg.timing.max_timeout_s then
      readTemps() -- финальный снимок для сообщения
      finish(true)
    end
  end

  swayStep(dt) -- покачивание на всех активных фазах (включая затухание после done)
end

-- === Сброс состояния (смена машины/respawn) ===
local function resetState()
  state = 'off'
  elapsed = 0
  startTimer = 0
  pollTimer = 0
  lastCoolant = nil
  lastOil = nil
  swayTime = 0
  swayAmp = 0
  swayTarget = 0
  swayWritten = false
  wheelEngagedWarned = false
  swayStart = nil
  swayEnd = nil
end

-- === Публичные команды (GE шлёт через queueLuaCommand) ===
autopilotLiveWarmupCmd = {}

function autopilotLiveWarmupCmd.on(confPath)
  if state == 'starting_engine' or state == 'warming_up' then
    toGE('WARN', 'warmup: уже идёт (фаза ' .. state .. ', ' .. fmt(elapsed) ..
      ' с) — повторный start игнорирован')
    return false
  end
  cfg, cfgFromFile = loadConfig(type(confPath) == 'string' and confPath or FALLBACK_CONF)
  resetState() -- state='off' → старт ниже
  -- Рандомное окно свея (правка игрока 18.10): покачивание-СОБЫТИЕ в случайный
  -- момент прогрева. sway_start_time = math.random(min*100, max*100)/100
  -- (точность 0.01 с), окно = [start, start + duration_s]; новое окно при
  -- каждом start(). Целые для math.random — через floor (float*100 даёт
  -- хвосты типа 799.9999).
  do
    local rmin = math.floor(math.max(cfg.sway.random_delay_min_s, 0) * 100)
    local rmax = math.floor(math.max(cfg.sway.random_delay_max_s, cfg.sway.random_delay_min_s) * 100)
    if rmax < rmin then rmax = rmin end
    swayStart = math.random(rmin, rmax) / 100
    swayEnd = swayStart + cfg.sway.duration_s
    if cfg.sway.enabled > 0 then
      toGE('INFO', 'warmup: окно sway сгенерировано: ' .. fmt(swayStart) .. '-' ..
        fmt(swayEnd) .. ' с от старта (длительность ' .. fmt(cfg.sway.duration_s) .. ' с)')
    end
  end
  if engineRunning() then
    state = 'warming_up'
    toGE('INFO', 'warmup: двигатель уже заведён — прогрев по температуре (мин ' ..
      fmt(cfg.timing.min_time_s) .. ' с, макс ' .. fmt(cfg.timing.max_timeout_s) .. ' с)')
  else
    state = 'starting_engine'
    local isIce = startEngine()
    toGE('INFO', 'warmup: запуск двигателя (' ..
      (isIce and 'ignition 3: ignition on + стартёр' or 'ignition 2: EV, стартёр не нужен') ..
      '), таймаут запуска ' .. fmt(cfg.timing.start_timeout_s) .. ' с')
  end
  return true
end

function autopilotLiveWarmupCmd.off()
  if state == 'off' then return false end
  local was = state
  state = 'off'
  toGE('INFO', 'warmup: остановлен игроком (фаза ' .. was .. ', прошло ' .. fmt(elapsed) ..
    ' с). Двигатель НЕ глушится, ручник не трогается.')
  return true
end

function autopilotLiveWarmupCmd.status()
  local ign = 0
  pcall(function() ign = electrics.values.ignitionLevel or 0 end)
  local lines = {
    '--- apl_warmup status ---',
    'state=' .. state .. ' elapsed=' .. fmt(elapsed) .. 'с (мин ' ..
      (cfg and fmt(cfg.timing.min_time_s) or '?') .. 'с, макс ' ..
      (cfg and fmt(cfg.timing.max_timeout_s) or '?') .. 'с)',
    'engineRunning=' .. tostring(engineRunning()) .. ' ignitionLevel=' .. fmt(ign),
    'coolant=' .. (lastCoolant and (fmt(lastCoolant) .. '°C') or 'n/a') ..
      ' oil=' .. (lastOil and (fmt(lastOil) .. '°C') or 'n/a') ..
      ' пороги: coolant>=' .. (cfg and fmt(cfg.engine.temp_threshold_c) or '?') .. '°C oil>=' ..
      (cfg and fmt(cfg.engine.oil_threshold_c) or '?') .. '°C',
    'sway: ' .. (cfg and (cfg.sway.enabled > 0 and ('amp=' .. fmt(swayAmp) ..
      ' (цель ' .. fmt(swayTarget) .. '), ' .. fmt(cfg.sway.freq_hz) ..
      'Гц, куб.синус, окно ' .. (swayStart and (fmt(swayStart) .. '-' .. fmt(swayEnd))
        or 'н/д') .. 'с (elapsed ' ..
      fmt(elapsed) .. 'с)')
      or 'выключен') or '?') ..
      (wheelEngagedWarned and ' [wheel engaged — sway отключён]' or ''),
    'конфиг=' .. (cfgFromFile and 'файл' or (cfg and 'ДЕФОЛТЫ' or 'не загружен')),
  }
  for _, l in ipairs(lines) do print('aplWarmup: ' .. l) end
  toGE('INFO', 'warmup status: state=' .. state .. ' elapsed=' .. fmt(elapsed) ..
    ' engineRunning=' .. tostring(engineRunning()))
  return true
end

-- === Жизненный цикл ===
function M.onReset()
  -- Respawn: состояние чистое (движок/температуры пересоздаются движком).
  resetState()
end

function M.onVehicleDestroyed()
  resetState()
end

return M
