-- AutopilotLive — Фаза 3: сглаживание педалей (vehicle-слой, расширение машины)
-- Загружается АВТОМАТИЧЕСКИ при спавне машины (vehicle/main.lua:314 →
-- extensions.loadModulesInDirectory("lua/vehicle/extensions/auto")).
--
-- Ответственность (Фаза 3):
--   * перехват throttle/brake от ванильного AI через штатный Override-механизм
--     (electrics.values.*Override, vehicleController.lua:454-457; ванильный
--     прецедент — cruiseControl.lua); clutch — ТОЛЬКО passthrough: raw > 0 →
--     raw, raw = 0 → nil (AI сам не пишет, но ванильная КПП-автоматика пишет
--     clutch — данные P1 2026-10-15, §15 api_research; ноль вреда);
--   * конвейер rate_limit → ema → lerp для throttle/brake (порядок утверждён;
--     обоснование и схема кадра: ai/notes/api_research_phase3.md);
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
-- clutch-ключей НЕТ: clutch — только passthrough (решение 2026-10-12,
-- api_research_phase3.md §15; актуализация 2026-10-15 по данным P1): AI сам
-- clutch НЕ пишет через driveCar/scriptai, НО ванильный трансмиссионный стек
-- (КПП-автоматика/защита при переключениях) пишет clutch при определённых
-- условиях — воспроизводится в OFF-прогонах (4.7-B: 95 строк, 4.8: 77).
-- Наш модуль — пассивный passthrough: raw > 0 → проброс raw (лаг 1 кадр),
-- raw = 0 → nil (штатная КПП). Ноль вреда; нажатие действует мгновенно.
local DEFAULTS = {
  rate_limit   = { throttle_rise = 2.5, throttle_fall = 5.0,
                   brake_rise = 2.5, brake_fall = 2.5 },
  ema_tau      = { throttle = 0.10, brake = 0.08 },
  lerp_tau     = { throttle = 0.15, brake = 0.12 },
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
local needInit = true           -- У2: синхронизировать конвейер на первом кадре
local initFromZero = true       -- Fix 5: при on/onReset начинаем с 0 (плавный старт);
                                -- при распаузе AI — false (синхронизация с raw)
local overridesWritten = false  -- Override писался в прошлый кадр (для nil-сброса)
local clutchWritten = false     -- clutchOverride писался (passthrough raw>0 → снять nil при 0)
local predictiveOn = false      -- флаг предиктивности (гистерезис 0.8/0.5)
local startT = 0                -- накопленное время engaged (для плавного старта)
local smoothStartSkipped = true -- плавный старт снят (уже едем в момент on)

-- Fix 4 (диагностика): ловим мусор ДО клампа, но не спамим лог — флаг «предупреждён»
-- сбрасывается, когда канал снова стал чистым. Благодаря этому прогон 5 покажет
-- ИСТОЧНИК garbage-значения (rl/ema/out/target/dt), а не только его след.
local stepGarbageWarned = {}   -- [tag]=true после первого WARN о мусоре в канале
local outGarbageWarned = {}    -- [tag]=true после первого WARN о мусоре на выходе

-- Конвейер по каналам: rl — rate-limited цель, ema — инерция, out — дотягивание
-- (clutch в конвейере НЕТ — passthrough, см. DEFAULTS-комментарий)
local pipe = {
  throttle = { rl = 0, ema = 0, out = 0 },
  brake    = { rl = 0, ema = 0, out = 0 },
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

-- Fix 2: жёсткий кламп в [0,1] с детектом мусора на ВЫХОДЕ конвейера.
-- Возвращает безопасное значение и пишет WARN один раз на канал (не спамит),
-- если исходное было NaN/±inf/вне [0,1]. rawFallback — что подставить при мусоре
-- (обычно raw-значение, оно всегда финитно и в [0,1] после safeVal+клампа).
local function sanitizeOut(v, rawFallback, tag)
  local bad = (v == nil) or (v ~= v)                -- nil / NaN
    or v == math.huge or v == -math.huge            -- ±inf
    or v < 0 or v > 1                               -- вне диапазона
  if bad then
    if not outGarbageWarned[tag] then
      outGarbageWarned[tag] = true
      toGE('WARN', string.format(
        'pedals: МУСОР на выходе %s = %s -> fallback raw %.3f (кламп в [0,1])',
        tag, tostring(v), clamp01(safeVal(rawFallback))))
    end
    return clamp01(safeVal(rawFallback))
  end
  outGarbageWarned[tag] = nil -- канал чист — снимаем флаг, WARN сработает при следующем мусоре
  return v
end

-- Fix 1: полный сброс состояния конвейера и последних значений. Вызывается из
-- off()/onReset(), чтобы после выключения в status/CSV НЕ оставался мусор или
-- устаревшие значения (в частности brake, который игрок видел = 5.8e17).
local function resetState()
  pipe.throttle.rl, pipe.throttle.ema, pipe.throttle.out = 0, 0, 0
  pipe.brake.rl, pipe.brake.ema, pipe.brake.out = 0, 0, 0
  lastOut = { engaged = false, throttle = 0, brake = 0, clutch = 0 }
  lastRaw = { throttle = 0, brake = 0, clutch = 0 }
  predictiveOn = false
  startT = 0
  stepGarbageWarned = {}
  outGarbageWarned = {}
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
  pos('ema_tau', 'throttle', D.ema_tau.throttle)
  pos('ema_tau', 'brake', D.ema_tau.brake)
  pos('lerp_tau', 'throttle', D.lerp_tau.throttle)
  pos('lerp_tau', 'brake', D.lerp_tau.brake)
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
local function stepChannel(st, target, dt, rateUp, rateDown, tauEma, tauLerp, tag)
  local rate = (target > st.rl) and rateUp or rateDown
  st.rl = moveToward(st.rl, target, rate * dt)
  st.ema = st.ema + (st.rl - st.ema) * (1 - math.exp(-dt / tauEma))
  st.out = st.out + (st.ema - st.out) * (1 - math.exp(-dt / tauLerp))
  if math.abs(st.ema - st.out) < 1e-3 then st.out = st.ema end -- снап «дотянули»
  -- Fix 3+4 (диагностика): ловим мусор ДО клампа. clamp01 всё равно обрезает
  -- до [0,1], но мы хотим ЗНАТЬ источник: если rl/ema/out/target вдруг стали
  -- NaN/±inf — пишем WARN с полным контекстом (канал, все стадии, dt, rate).
  -- Иначе мусор молча «лечится» клампом и причину найти невозможно.
  local badPre = (st.rl ~= st.rl or st.ema ~= st.ema or st.out ~= st.out)
    or st.rl == math.huge or st.rl == -math.huge
    or st.ema == math.huge or st.ema == -math.huge
    or st.out == math.huge or st.out == -math.huge
    or target ~= target or target == math.huge or target == -math.huge
  if badPre and not stepGarbageWarned[tag] then
    stepGarbageWarned[tag] = true
    toGE('WARN', string.format(
      'pedals: МУСОР в конвейере [%s] ДО клампа: rl=%.4g ema=%.4g out=%.4g target=%.4g dt=%.4g rate=%.4g',
      tag, st.rl, st.ema, st.out, target, dt, rate))
  elseif not badPre then
    stepGarbageWarned[tag] = nil -- канал чист — WARN сработает заново при новом мусоре
  end
  st.out = clamp01(st.out)
  st.rl = clamp01(st.rl)   -- Fix 2: держим и промежуточные стадии в [0,1],
  st.ema = clamp01(st.ema) -- чтобы мусор не размножался между кадрами
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

-- === ЛОВУШКА АНОМАЛИИ brake (диагностика 2026-10-15, по команде координатора) ===
-- Контекст: три случая apl_pedals("status") показали brake out ~1e17
-- (5.8e17 после off / 1.9e17 / 8.67e17 15.10 19:11, game 280.91); физика НЕ
-- задета, WARN «МУСОР» нет, CSV чист. Статический анализ кода: lastOut.brake
-- пишется ТОЛЬКО из sanitizeOut (он ∈ [0,1]); rl/ema/out клампятся в stepChannel.
-- Доказательство по кадру аномалии 8.67e17: throttle out=1.000 ⇒ cut=1 ⇒
-- pipe.brake.out ≤ 0.1 В МОМЕНТ записи lastOut, т.е. в lastOut уходило чистое
-- значение — мусор появляется при ВЫВОДЕ (формат %.3f в status), а не в
-- конвейере. Ловушка докажет это: (1) буфер 5 кадров конвейера brake;
-- (2) «последний рубеж» — контроль brkOut/thrOut ПОСЛЕ sanitize, ДО записи в
-- electrics/lastOut; (3) в status() — дубль значений через tostring() (%.14g):
-- если %.3f даст ~1e17, а tostring() — 0.0x, виноват форматтер, не код.
local diagHist, diagN = {}, 0

local function diagDump(reason, extra)
  local lines = { 'ЛОВУШКА brake: ' .. reason .. (extra and (' | ' .. extra) or '') }
  for i = 1, 5 do
    lines[#lines + 1] = '  кадр-' .. i .. ': ' .. (diagHist[(diagN - i) % 5 + 1] or 'n/a')
  end
  toGE('WARN', 'pedals DIAG: ' .. table.concat(lines, ' || '))
  print('aplPedals DIAG: ' .. table.concat(lines, '\n'))
  pcall(function() -- дубль в файл (vehicle-io сандайлен — если нельзя, WARN/print уже ушли)
    local f = io.open('mods/unpacked/AutopilotLive/ai/logs/brake_anomaly.txt', 'a')
    if f then
      f:write(os.date('%Y-%m-%d %H:%M:%S') .. '\n' .. table.concat(lines, '\n') .. '\n')
      f:close()
    end
  end)
end

local function diagBad(x) -- мусор «последнего рубежа»: nil/NaN/±inf/вне [0,1]
  return x == nil or x ~= x or x == math.huge or x == -math.huge or x < 0 or x > 1
end

-- Косметика DIAG-печати (2026-10-15, по заказу): человек не должен читать
-- асимптотические хвосты ema (2.45e-59, 1e-222 — это ФАКТИЧЕСКИ ноль, но не
-- ноль в double: после сброса brake до 0 ema подходит к нулю экспоненциально).
-- |v| < 1e-6 → печатаем 0.000000. НО реальный мусор НЕ глушим: nil/NaN/±inf/
-- вне [0,1] печатаем как есть + маркер «<МУСОР>» (ловушка ~1e17 не ослепнет).
local function diagFmt(x)
  if x == nil or x ~= x or x == math.huge or x == -math.huge or x < 0 or x > 1 then
    return tostring(x) .. ' <МУСОР>'
  end
  if math.abs(x) < 1e-6 then
    return '0.000000'
  end
  return tostring(x)
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
    initFromZero = false -- распауза: уже едем, синхронизируемся с raw (Fix 5)
    return
  end

  -- Raw — цель AI на ЭТОТ кадр (input.state.<k>.val, свежий input.event)
  local thrRaw = readRaw('throttle')
  local brkRaw = readRaw('brake')
  local cltRaw = readRaw('clutch')
  lastRaw.throttle, lastRaw.brake, lastRaw.clutch = thrRaw, brkRaw, cltRaw

  local speed = getSpeed()
  local gear = tostring(electrics.values.gear or '')

  -- У2/Fix 5: первый кадр после on/резюме — инициализация конвейера.
  -- Fix 5 (разделение двух сценариев):
  --   * СВЕЖЕЕ ВКЛЮЧЕНИЕ (on/onReset, initFromZero=true): throttle начинается с 0
  --     и плавно идёт к цели через rate_limit + ema + smooth_start_cap. Раньше
  --     pipe:=raw прыгал в 1.0 в обход капа 0.45 => «резкий старт».
  --   * РАСПАУЗА AI (initFromZero=false): уже едем, pipe:=raw чтобы не сбрасывать
  --     педали (иначе газ мгновенно 0 => подёргивание на ходу).
  -- brake: ВСЕГДА pipe:=raw — тормоз не задерживаем ни при каком включении
  -- (безопасность: при on с активным тормозом AI не отпускаем его на кадр).
  if needInit then
    if initFromZero then
      pipe.throttle.rl, pipe.throttle.ema, pipe.throttle.out = 0, 0, 0
    else
      pipe.throttle.rl, pipe.throttle.ema, pipe.throttle.out = thrRaw, thrRaw, thrRaw
    end
    pipe.brake.rl, pipe.brake.ema, pipe.brake.out = brkRaw, brkRaw, brkRaw
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

  -- === Конвейер (только throttle/brake — clutch passthrough ниже) ===
  local rl, et, lt = cfg.rate_limit, cfg.ema_tau, cfg.lerp_tau
  stepChannel(pipe.throttle, thrT, dt, rl.throttle_rise, rl.throttle_fall, et.throttle, lt.throttle, 'throttle')
  stepChannel(pipe.brake, brkT, dt, rl.brake_rise, rl.brake_fall, et.brake, lt.brake, 'brake')

  -- === Арбитраж brake > throttle (ПОСЛЕ сглаживания, непрерывно) ===
  local bs, bf = cfg.arbitration.brake_start, cfg.arbitration.brake_full
  local cut = 1
  if pipe.brake.out > bs then
    cut = 1 - (pipe.brake.out - bs) / (bf - bs)
    if cut < 0 then cut = 0 end
  end
  local thrOut = pipe.throttle.out * cut

  -- Fix 2: жёсткий кламп + детект мусора ПЕРЕД записью в electrics/lastOut.
  -- Если pipe.*.out вдруг вышел за [0,1]/NaN — подставляем raw (финитный, в [0,1])
  -- и пишем WARN. Гарантирует, что brakeOverride/throttleOverride и CSV-состояние
  -- НИКОГДА не унесут мусор (5.8e17 и т.п.) в контроллер.
  thrOut = sanitizeOut(thrOut, thrRaw, 'throttle_out')
  local brkOut = sanitizeOut(pipe.brake.out, brkRaw, 'brake_out')

  -- === Запись Override — КАЖДЫЙ кадр при engaged (У1) ===
  -- Fix 2: пишем САНИТИЗИРОВАННЫЕ значения (brkOut, thrOut) — мусор не уходит
  -- в контроллер и не залипает в lastOut/CSV.
  electrics.values.throttleOverride = thrOut
  electrics.values.brakeOverride = brkOut
  -- Clutch — ТОЛЬКО passthrough (решение 2026-10-12, api_research §15;
  -- актуализация 2026-10-15): AI сам clutch не пишет через driveCar/scriptai
  -- (ai.lua:427-436), НО ванильная КПП-автоматика/защита пишет его при
  -- определённых условиях — данные P1: clutch-пульсы ЕСТЬ в OFF-прогонах
  -- (4.7-B: 95 строк, 4.8: 77), т.е. без участия модуля и игрока. Любое
  -- clutch-нажатие (игрока ИЛИ ванильной КПП) пробрасываем ровно raw БЕЗ
  -- инерции конвейера: raw > 0 → clutchOverride = raw (латентность только
  -- архитектурная 1 кадр, main.lua:88 vs :90), raw == 0 → снимаем в nil
  -- (КПП снова штатная). Никаких «плавных 0.3 с» — иначе машина едет «внатяг».
  local cltOut = clamp01(cltRaw) -- Fix 2: clutch тоже держим в [0,1]
  if cltOut > 0 then
    electrics.values.clutchOverride = cltOut
    clutchWritten = true
  elseif clutchWritten then
    electrics.values.clutchOverride = nil
    clutchWritten = false
  end
  overridesWritten = true

  -- ЛОВУШКА: буфер кадра + «последний рубеж» (см. блок комментария выше updateGFX)
  diagN = diagN + 1
  diagHist[((diagN - 1) % 5) + 1] = string.format(
    'dt=%.4f tgt=%.3f raw.brk=%.3f | rl=%.17g ema=%.17g out=%.17g | thrOut=%.17g brkOut=%.17g',
    dt, brkT, brkRaw, pipe.brake.rl, pipe.brake.ema, pipe.brake.out, thrOut, brkOut)
  if diagBad(brkOut) or diagBad(thrOut) then
    diagDump('ПОСЛЕДНИЙ РУБЕЖ поймал мусор ДО записи electrics/lastOut',
      string.format('brkOut=%s thrOut=%s', tostring(brkOut), tostring(thrOut)))
  end

  lastOut = { engaged = true, throttle = thrOut, brake = brkOut, clutch = cltOut }
end

-- === Публичные команды (GE шлёт через queueLuaCommand) ===
autopilotLivePedalsCmd = {}

function autopilotLivePedalsCmd.on(confPath)
  cfg, cfgFromFile = loadConfig(type(confPath) == 'string' and confPath or FALLBACK_CONF)
  active = true
  resetState()     -- Fix 1: чистый старт — не тянем мусор/lastOut от прошлой сессии
  needInit = true
  initFromZero = true -- Fix 5: свежее включение — throttle с 0, плавный старт
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
  resetState()     -- Fix 1: полный сброс lastOut/pipe — статус/CSV после off
                   -- НЕ показывают устаревший/мусорный brake (5.8e17 и т.п.)
  toGE('INFO', 'pedals OFF: Override снят (nil), состояние сброшено')
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
    -- ЛОВУШКА (диагностика 2026-10-15): ДУБЛЬ тех же значений. Если строка
    -- %.3f выше покажет ~1e17, а эта — 0.0x, мусор рождается в форматировании
    -- LuaJIT, НЕ в конвейере: lastOut пишется только из sanitizeOut ∈ [0,1]
    -- (по кадру 8.67e17: throttle out=1.000 ⇒ cut=1 ⇒ pipe.brake.out ≤ 0.1).
    -- Печать через diagFmt (косметика 2026-10-15): хвосты ema < 1e-6 →
    -- 0.000000; мусор (вне [0,1]/NaN/inf) — как есть + «<МУСОР>».
    string.format('DIAG exact: thr=%s brk=%s clt=%s | pipe.brake rl=%s ema=%s out=%s',
      diagFmt(lastOut.throttle), diagFmt(lastOut.brake), diagFmt(lastOut.clutch),
      diagFmt(pipe.brake.rl), diagFmt(pipe.brake.ema), diagFmt(pipe.brake.out)),
  }
  if diagBad(lastOut.brake) or diagBad(lastOut.throttle) or diagBad(lastOut.clutch) then
    diagDump('STATUS поймал мусор в lastOut — сравнить DIAG exact (tostring) со строкой %.3f',
      string.format('lastOut.brk=%s thr=%s clt=%s',
        tostring(lastOut.brake), tostring(lastOut.throttle), tostring(lastOut.clutch)))
  end
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
  resetState() -- Fix 1: состояние тоже чисто (нет устаревшего lastOut)
  needInit = true
  initFromZero = true -- Fix 5: после сброса начинаем с 0 (машина обычно на месте)
  smoothStartSkipped = false
end

function M.onVehicleDestroyed()
  -- Таблица electrics уходит вместе с машиной — снимать нечего
  active = false
  overridesWritten = false
  clutchWritten = false
  resetState() -- Fix 1: гигиена — не тянем мусор в перевспавн/статус
end

return M
