-- AutopilotLive — Фаза 3: сглаживание педалей (vehicle-слой, расширение машины)
-- Загружается АВТОМАТИЧЕСКИ при спавне машины (vehicle/main.lua:314 →
-- extensions.loadModulesInDirectory("lua/vehicle/extensions/auto")).
--
-- Ответственность (Фаза 3):
--   * перехват throttle/brake/clutch от ванильного AI через штатный Override-
--     механизм (electrics.values.*Override, vehicleController.lua:454-457;
--     ванильный прецедент — cruiseControl.lua);
--   * конвейер rate_limit → ema → lerp (порядок утверждён; обоснование и
--     схема кадра: ai/notes/api_research_phase3.md);
--   * арбитраж brake > throttle, детект нейтрали, плавный старт, мягкая
--     предиктивность — все пороги из ai/config/pedals.json;
--   * сброс Override в NIL при off / когда ИИ не ведёт машину (У1: именно nil,
--     иначе педаль залипает на последнем значении).
--
-- НЕ дёргает input.event. НЕ трогает руль (Фаза 4). НЕ трогает КПП и ручник
-- (parkingbrake-override в ванилле не существует, grep=0 — api_research §6).

local M = {}

-- Конфиг: путь относительный от userPath (sandbox io.open, см. 1.6b) —
-- GE-слой присылает его в команде on(); это значение — fallback.
local FALLBACK_CONF = 'mods/unpacked/AutopilotLive/ai/config/pedals.json'

-- === Дефолты конфига (дубль pedals.json — ТОЛЬКО fallback при отсутствии/
-- битом конфиге; источник истины — файл, как у graph.json/loadGraphConfig) ===
local DEFAULTS = {
  rate_limit   = { throttle_rise = 2.5, throttle_fall = 5.0,
                   brake_rise = 2.5, brake_fall = 2.5,
                   clutch_rise = 3.0, clutch_fall = 5.0 },
  ema_tau      = { throttle = 0.10, brake = 0.08, clutch = 0.10 },
  lerp_tau     = { throttle = 0.15, brake = 0.12, clutch = 0.15 },
  arbitration  = { brake_start = 0.1, brake_full = 0.5 },
  neutral      = { speed_max_mps = 0.5, throttle_min = 0.05, brake = 0.3 },
  smooth_start = { time_s = 3.0, speed_mps = 5.0, throttle_cap = 0.45 },
  predictive   = { brake_threshold = 0.8, lead = 0.12,
                   release_hyst = 0.5, min_speed_mps = 1.5 },
}

-- === Состояние ===
local cfg = nil                 -- параметры (после merge с дефолтами + валидация)
local cfgFromFile = false       -- конфиг реально прочитан из файла
local active = false            -- apl_pedals("on") включён
local needInit = true           -- У2: синхронизировать конвейер с raw на первом кадре
local overridesWritten = false  -- Override писался в прошлый кадр (для nil-сброса)
local clutchWritten = false     -- clutchOverride писался хоть раз (ленивая запись)
local predictiveOn = false      -- флаг предиктивности (гистерезис 0.8/0.5)
local startT = 0                -- накопленное время engaged (для плавного старта)
local smoothStartSkipped = true -- плавный старт снят (уже едем в момент on)

-- Конвейер по каналам: rl — rate-limited цель, ema — инерция, out — дотягивание
local pipe = {
  throttle = { rl = 0, ema = 0, out = 0 },
  brake    = { rl = 0, ema = 0, out = 0 },
  clutch   = { rl = 0, ema = 0, out = 0 },
}

-- Последние значения для статуса/CSV
local lastOut  = { engaged = false, throttle = 0, brake = 0, clutch = 0 }
local lastRaw  = { throttle = 0, brake = 0, clutch = 0 }

-- === Лог событий в GE (паттерн autopilotLive.lua) ===
local function toGE(level, msg)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if autopilotLive_main and autopilotLive_main.onVehicleLog then autopilotLive_main.onVehicleLog("%s", "%s") end',
      level, tostring(msg):gsub('\\', '\\\\'):gsub('"', '\\"')))
  end)
end

-- === Утилиты ===
local function safeVal(v)
  v = tonumber(v) or 0
  if v ~= v then return 0 end -- NaN → 0
  return v
end

local function clamp01(v)
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

local function readRaw(key)
  local st = input and input.state
  if not st or not st[key] then return 0 end
  return safeVal(st[key].val)
end

-- Скорость машины, м/с (тот же источник, что в CSV: velocity:length)
local function getSpeed()
  local ok, v = pcall(function() return obj:getVelocity():length() end)
  return (ok and safeVal(v)) or 0
end

-- === Конфиг: merge + валидация ===
local function validateConfig(c)
  -- положительные (rate/tau/min_speed): 0 или мусор → дефолт
  local function pos(gr, key, dflt)
    local v = c[gr][key]
    if v == nil or v ~= v or v <= 0 then c[gr][key] = dflt end
  end
  -- ненулевые (могут быть 0 = «отключено»): мусор/минус → дефолт
  local function nonneg(gr, key, dflt)
    local v = c[gr][key]
    if v == nil or v ~= v or v < 0 then c[gr][key] = dflt end
  end
  -- в диапазоне [0,1]
  local function unit01(gr, key, dflt)
    local v = c[gr][key]
    if v == nil or v ~= v or v < 0 or v > 1 then c[gr][key] = dflt end
  end
  local D = DEFAULTS
  pos('rate_limit', 'throttle_rise', D.rate_limit.throttle_rise)
  pos('rate_limit', 'throttle_fall', D.rate_limit.throttle_fall)
  pos('rate_limit', 'brake_rise', D.rate_limit.brake_rise)
  pos('rate_limit', 'brake_fall', D.rate_limit.brake_fall)
  pos('rate_limit', 'clutch_rise', D.rate_limit.clutch_rise)
  pos('rate_limit', 'clutch_fall', D.rate_limit.clutch_fall)
  pos('ema_tau', 'throttle', D.ema_tau.throttle)
  pos('ema_tau', 'brake', D.ema_tau.brake)
  pos('ema_tau', 'clutch', D.ema_tau.clutch)
  pos('lerp_tau', 'throttle', D.lerp_tau.throttle)
  pos('lerp_tau', 'brake', D.lerp_tau.brake)
  pos('lerp_tau', 'clutch', D.lerp_tau.clutch)
  unit01('arbitration', 'brake_start', D.arbitration.brake_start)
  unit01('arbitration', 'brake_full', D.arbitration.brake_full)
  if c.arbitration.brake_full <= c.arbitration.brake_start then
    c.arbitration.brake_start = D.arbitration.brake_start
    c.arbitration.brake_full = D.arbitration.brake_full
  end
  nonneg('neutral', 'speed_max_mps', D.neutral.speed_max_mps)
  unit01('neutral', 'throttle_min', D.neutral.throttle_min)
  unit01('neutral', 'brake', D.neutral.brake)
  nonneg('smooth_start', 'time_s', D.smooth_start.time_s)
  nonneg('smooth_start', 'speed_mps', D.smooth_start.speed_mps)
  unit01('smooth_start', 'throttle_cap', D.smooth_start.throttle_cap)
  unit01('predictive', 'brake_threshold', D.predictive.brake_threshold)
  unit01('predictive', 'lead', D.predictive.lead)
  unit01('predictive', 'release_hyst', D.predictive.release_hyst)
  nonneg('predictive', 'min_speed_mps', D.predictive.min_speed_mps)
end

local function loadConfig(path)
  -- deep copy дефолтов
  local c = {}
  for gr, kv in pairs(DEFAULTS) do
    c[gr] = {}
    for k, v in pairs(kv) do c[gr][k] = v end
  end
  local f = io.open(path, 'r')
  if not f then
    toGE('WARN', 'pedals: конфиг не найден (' .. tostring(path) .. ') — используются дефолты кода')
    return c, false
  end
  local content = f:read('*all')
  f:close()
  local ok, decoded = pcall(jsonDecode, content, path)
  if not ok or type(decoded) ~= 'table' then
    toGE('WARN', 'pedals: конфиг не распарсен — используются дефолты кода')
    return c, false
  end
  for gr, kv in pairs(DEFAULTS) do
    local decGr = type(decoded[gr]) == 'table' and decoded[gr] or nil
    if decGr then
      for k in pairs(kv) do
        local v = tonumber(decGr[k])
        if v ~= nil then c[gr][k] = v end
      end
    end
  end
  validateConfig(c)
  return c, true
end

-- === Конвейер ===
-- Движение к цели не быстрее maxStep (rate_limit: жёсткий кап скорости)
local function moveToward(cur, target, maxStep)
  local d = target - cur
  if d > maxStep then return cur + maxStep end
  if d < -maxStep then return cur - maxStep end
  return target -- дошли точно
end

-- Один кадр конвейера канала: rate_limit → ema → lerp.
-- Все коэффициенты — time-constant формы (k = 1-exp(-dt/tau)) ⇒ frame-rate
-- независимые. rate_limit ПЕРВЫМ: ступень AI превращается в линейную рампу
-- (жёсткий кап «не за 1 кадр»); ema скругляет края; lerp дотягивает остаток
-- (ema асимптотически не доходит) — кормится уже «медленным» сигналом, кап
-- не нарушается (У5, обоснование: api_research_phase3.md §13).
local function stepChannel(st, target, dt, rateUp, rateDown, tauEma, tauLerp)
  local rate = (target > st.rl) and rateUp or rateDown
  st.rl = moveToward(st.rl, target, rate * dt)
  st.ema = st.ema + (st.rl - st.ema) * (1 - math.exp(-dt / tauEma))
  st.out = st.out + (st.ema - st.out) * (1 - math.exp(-dt / tauLerp))
  if math.abs(st.ema - st.out) < 1e-3 then st.out = st.ema end -- снап «дотянули»
  st.out = clamp01(st.out)
end

-- Плавный старт: кап = cap + (1-cap)*min(time/T, speed/V). Обе рампы должны
-- пройти, чтобы кап снялся (время даёт предсказуемость, скорость гарантирует,
-- что кап не спадёт, пока машина реально не пошла). Если в момент on машина
-- уже едет — старт снят (это не «начало поездки», кап лишь подрезал бы ход).
local function smoothStartFactor(speed)
  if smoothStartSkipped then return 1 end
  local ss = cfg.smooth_start
  if ss.time_s <= 0 or ss.speed_mps <= 0 then return 1 end
  if startT >= ss.time_s and speed >= ss.speed_mps then
    smoothStartSkipped = true -- обе рампы завершены — навсегда
    return 1
  end
  local tRamp = math.min(1, startT / ss.time_s)
  local vRamp = math.min(1, speed / ss.speed_mps)
  return ss.throttle_cap + (1 - ss.throttle_cap) * math.min(tRamp, vRamp)
end

-- === Сброс Override (У1: ИМЕННО nil, не 0 и не последнее значение!) ===
-- nil → контроллер возвращается на штатный input.<k> («or input.throttle»,
-- vehicleController.lua:455). Пишем nil один раз (флаг), не каждый кадр.
local function clearOverrides()
  if not overridesWritten and not clutchWritten then return end
  electrics.values.throttleOverride = nil
  electrics.values.brakeOverride = nil
  electrics.values.clutchOverride = nil
  overridesWritten = false
  clutchWritten = false
  lastOut.engaged = false
end

-- === Кадровый цикл ===
function M.updateGFX(dt)
  if not active then return end
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then return end -- NaN/перерывы

  -- ИИ реально ведёт машину? (ai.lua:6167-6169; fallback false = не пишем)
  local aiDriving = false
  pcall(function()
    aiDriving = (ai ~= nil and ai.isDriving ~= nil) and (ai.isDriving() or false)
  end)
  if not aiDriving then
    clearOverrides()  -- У1: игрок/ничья — возврат на штатный ввод
    needInit = true   -- при резюме AI — синхронизация без прыжка (У2)
    return
  end

  -- Raw — цель AI на ЭТОТ кадр (input.state.<k>.val, свежий input.event)
  local thrRaw = readRaw('throttle')
  local brkRaw = readRaw('brake')
  local cltRaw = readRaw('clutch')
  lastRaw.throttle, lastRaw.brake, lastRaw.clutch = thrRaw, brkRaw, cltRaw

  local speed = getSpeed()
  local gear = tostring(electrics.values.gear or '')

  -- У2: первый кадр после on/резюме — конвейер СИНХРОНИЗИРУЕМ с raw
  -- (иначе включение на скорости с газом 0.7 дало бы прыжок 0 → 0.7)
  if needInit then
    for _, k in ipairs({ 'throttle', 'brake', 'clutch' }) do
      local raw = (k == 'throttle' and thrRaw) or (k == 'brake' and brkRaw) or cltRaw
      pipe[k].rl, pipe[k].ema, pipe[k].out = raw, raw, raw
    end
    needInit = false
  end

  -- === Модификаторы ЦЕЛИ (до конвейера) ===
  local thrT, brkT = thrRaw, brkRaw

  -- Детект нейтрали: gear N|0 + газ > eps + почти стоим → газ 0, тормоз >= brake
  -- (gear: automatic "N" / manual gearIndex 0 → "0", api_research §9)
  if (gear == 'N' or gear == '0')
      and thrRaw > cfg.neutral.throttle_min
      and speed < cfg.neutral.speed_max_mps then
    thrT = 0
    if brkT < cfg.neutral.brake then brkT = cfg.neutral.brake end
  end

  -- Мягкая предиктивность: гистерезис 0.8→вкл / 0.5→выкл, аддитивный lead
  -- ТОЛЬКО при скорости > min_speed (против «в горке тупо тормозим»).
  -- Полноценная предиктивность по графу — Фаза 4.
  if predictiveOn then
    if brkRaw < cfg.predictive.release_hyst then predictiveOn = false end
  elseif brkRaw >= cfg.predictive.brake_threshold then
    predictiveOn = true
  end
  if predictiveOn and speed > cfg.predictive.min_speed_mps then
    brkT = math.min(1, brkRaw + cfg.predictive.lead)
  end

  -- Плавный старт (только throttle)
  startT = startT + dt
  thrT = thrT * smoothStartFactor(speed)

  -- === Конвейер ===
  local rl, et, lt = cfg.rate_limit, cfg.ema_tau, cfg.lerp_tau
  stepChannel(pipe.throttle, thrT, dt, rl.throttle_rise, rl.throttle_fall, et.throttle, lt.throttle)
  stepChannel(pipe.brake, brkT, dt, rl.brake_rise, rl.brake_fall, et.brake, lt.brake)
  stepChannel(pipe.clutch, cltRaw, dt, rl.clutch_rise, rl.clutch_fall, et.clutch, lt.clutch)

  -- === Арбитраж brake > throttle (ПОСЛЕ сглаживания, непрерывно) ===
  local bs, bf = cfg.arbitration.brake_start, cfg.arbitration.brake_full
  local cut = 1
  if pipe.brake.out > bs then
    cut = 1 - (pipe.brake.out - bs) / (bf - bs)
    if cut < 0 then cut = 0 end
  end
  local thrOut = pipe.throttle.out * cut

  -- === Запись Override — КАЖДЫЙ кадр при engaged (У1) ===
  electrics.values.throttleOverride = thrOut
  electrics.values.brakeOverride = pipe.brake.out
  -- clutch — лениво: под ИИ raw всегда 0 (AI не шлёт clutch, api_research §7);
  -- если smoothed < 0.001 и раньше не писали — не трогаем штатную КПП
  if pipe.clutch.out > 0.001 or clutchWritten then
    electrics.values.clutchOverride = pipe.clutch.out
    clutchWritten = true
  end
  overridesWritten = true
  lastOut = { engaged = true, throttle = thrOut, brake = pipe.brake.out, clutch = pipe.clutch.out }
end

-- === Публичные команды (GE шлёт через queueLuaCommand) ===
autopilotLivePedalsCmd = {}

function autopilotLivePedalsCmd.on(confPath)
  cfg, cfgFromFile = loadConfig(type(confPath) == 'string' and confPath or FALLBACK_CONF)
  active = true
  needInit = true
  startT = 0
  predictiveOn = false
  clutchWritten = false
  -- Плавный старт: если машина уже едет — кап бессмысленен, снимаем сразу
  smoothStartSkipped = getSpeed() >= cfg.smooth_start.speed_mps
  local r = cfg.rate_limit
  toGE('INFO', string.format(
    'pedals ON (%s): rate thr %.1f/%.1f brk %.1f/%.1f, ema %.2f/%.2f с, старт-кап %.2f',
    cfgFromFile and 'конфиг из файла' or 'ДЕФОЛТЫ',
    r.throttle_rise, r.throttle_fall, r.brake_rise, r.brake_fall,
    cfg.ema_tau.throttle, cfg.ema_tau.brake, cfg.smooth_start.throttle_cap))
  return true
end

function autopilotLivePedalsCmd.off()
  if not active then return false end
  active = false
  clearOverrides() -- У1: nil немедленно, не дожидаясь кадра
  predictiveOn = false
  toGE('INFO', 'pedals OFF: Override снят (nil), контроллер на штатном вводе')
  return true
end

function autopilotLivePedalsCmd.status()
  local aiDriving = false
  pcall(function()
    aiDriving = (ai ~= nil and ai.isDriving ~= nil) and (ai.isDriving() or false)
  end)
  local cap = active and smoothStartFactor(getSpeed()) or 1
  local lines = {
    '--- apl_pedals status ---',
    string.format('active=%s engaged=%s aiDriving=%s конфиг=%s',
      tostring(active), tostring(lastOut.engaged), tostring(aiDriving),
      cfgFromFile and 'файл' or (cfg and 'ДЕФОЛТЫ' or 'не загружен')),
    string.format('throttle: raw %.3f -> out %.3f | brake: raw %.3f -> out %.3f | clutch: raw %.3f -> out %.3f (пишется: %s)',
      lastRaw.throttle, lastOut.throttle, lastRaw.brake, lastOut.brake,
      lastRaw.clutch, lastOut.clutch, tostring(clutchWritten)),
    string.format('predictive=%s smoothStartCap=%.2f startT=%.1fс',
      tostring(predictiveOn), cap, startT),
  }
  for _, l in ipairs(lines) do print('aplPedals: ' .. l) end
  toGE('INFO', 'pedals status: active=' .. tostring(active) ..
    ' engaged=' .. tostring(lastOut.engaged) ..
    ' thr ' .. string.format('%.2f->%.2f', lastRaw.throttle, lastOut.throttle) ..
    ' brk ' .. string.format('%.2f->%.2f', lastRaw.brake, lastOut.brake))
  return true
end

-- === Состояние для CSV (autopilotLive.lua: *_smoothed из нашего конвейера) ===
-- Глобальная функция: vehicle-модули не видят locals друг друга.
function autopilotLivePedalsGetState()
  return {
    active = active,
    engaged = lastOut.engaged,
    throttle = lastOut.throttle,
    brake = lastOut.brake,
    clutch = lastOut.clutch,
  }
end

-- === Жизненный цикл ===
function M.onReset()
  -- Машина сброшена: Override снимаем (электроника пересоздаётся не всегда),
  -- конвейер синхронизируем при следующем кадре (needInit)
  clearOverrides()
  needInit = true
  startT = 0
  smoothStartSkipped = false
end

function M.onVehicleDestroyed()
  -- Таблица electrics уходит вместе с машиной — снимать нечего
  active = false
  overridesWritten = false
  clutchWritten = false
end

return M
