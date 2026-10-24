-- AutopilotLive — Фаза 4: сглаживание руля AI (vehicle-слой, расширение машины)
-- Загружается АВТОМАТИЧЕСКИ при спавне машины (vehicle/main.lua:314 →
-- extensions.loadModulesInDirectory("lua/vehicle/extensions/auto")).
--
-- Ответственность (Фаза 4):
--   * перехват руля AI через ЗАМЕНУ движкового сглаживания своим (вариант (c),
--     api_research_phase4.md §2): читаем raw из input.state.steering.val,
--     CLIP к [-1,1] (репликация input.lua:613), гладим, перезаписываем
--     electrics.values.steering_input в хуке extensions.hook("updateGFX")
--     (main.lua:90) — ДО hydros (main.lua:91, читает steering_input → колёса).
--     Движковый FILTER_AI (input.lua:643) отменяется перезаписью. Нулевая
--     добавочная латентность (перезапись и hydros — в одном кадре).
--   * конвейер rate_limit → ema → lerp (цель ВСЕГДА clipped-raw, «не срезаем
--     углы»); направление капа — по МОДУЛЮ (от центра/в центр); всё из
--     ai/config/wheel.json (единицы: нормированные [-1,1], НЕ рад/с — §1).
--   * gate по ai.isDriving(); off → просто НЕ перезаписываем (движок сам
--     затирает steering_input каждый кадр — input.lua:678 — nil-восстановление,
--     в отличие от педалей, НЕ нужно, §4).
--
-- НЕ дёргает input.event. НЕ трогает педали/КПП/ручник (Фаза 3). Не строит
-- граф-предиктивный тормоз (vanilla AI уже тормозит предиктивно — §5).

local M = {}

-- Конфиг: путь относительный от userPath (sandbox io.open) — GE шлёт в on().
local FALLBACK_CONF = 'mods/unpacked/AutopilotLive/ai/config/wheel.json'

-- === Дефолты конфига (дубль wheel.json — ТОЛЬКО fallback при отсутствии/
-- битом конфиге; источник истины — файл) ===
-- Единицы: rate — нормированные [-1,1] единицы/сек (1.0 = полный упор);
-- tau — секунды. steer_rise = от центра к упору, steer_fall = возврат в центр.
local DEFAULTS = {
  rate_limit = { steer_rise = 6.0, steer_fall = 8.0 },
  ema_tau    = { steer = 0.08 },
  lerp_tau   = { steer = 0.05 },
}

-- === Состояние ===
local cfg = nil
local cfgFromFile = false
local active = false            -- apl_wheel("on") включён
local activeConfPath = nil      -- путь конфига активного wheel (для идемпотентного on)
local rateScale = 1.0           -- множитель rate_limit (Фаза 7: pet временно
                                -- ставит 0.5 — «руль плавнее»; возврат в 1.0)
local needInit = true           -- синхронизировать конвейер с raw на первом кадре
local pipe = { rl = 0, ema = 0, out = 0 }
local lastOut = { engaged = false, steer = 0 }
local lastRaw = 0               -- clipped-raw последнего кадра (для статуса)
local rateRaw = 0               -- сглаженная скорость изменения raw (ед/с)
local rateOut = 0               -- сглаженная скорость изменения out (ед/с)
local prevRateRaw = nil
local prevRateOut = nil
local RATE_EMA_TAU = 0.15       -- окно оценки скорости в status

-- === Лог событий в GE (паттерн autopilotLivePedals.lua) ===
local function toGE(level, msg)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if extensions and extensions.autopilotLive_main and extensions.autopilotLive_main.onVehicleLog then extensions.autopilotLive_main.onVehicleLog("%s", "%s") end',
      level, tostring(msg):gsub('\\', '\\\\'):gsub('"', '\\"')))
  end)
end

-- Печать pipeline-значений через %s (фикс 2026-10-16, аномалия brake.out:
-- %.3f в LuaJIT string.format при большом числе аргументов читает не тот
-- слот стека). Дубль хелпера из autopilotLivePedals.lua — модули
-- независимы, общий util не вводим (архитектура загрузки).
-- |v| < 1e-6 → 0.000000; мусор (nil/NaN/±inf/вне [-1,1] для руля считаем
-- через общий [0,1]-предикат не будем — здесь значения нормированы [-1,1],
-- поэтому сверяем только финитность и кламп-допуск ±1.0001).
local function diagFmt(x)
  if x == nil or x ~= x or x == math.huge or x == -math.huge or x < -1.0001 or x > 1.0001 then
    return tostring(x) .. ' <МУСОР>'
  end
  if math.abs(x) < 1e-6 then
    return '0.000000'
  end
  return tostring(x)
end

-- === Утилиты ===
local function safeVal(v)
  v = tonumber(v) or 0
  if v ~= v then return 0 end -- NaN → 0
  return v
end

-- Для скоростей/rate: diagFmt рассчитан на steering [-1,1], а rate может быть
-- больше единицы, поэтому здесь свой формат без метки «МУСОР».
local function fmtRate(v)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return 'n/a' end
  return string.format('%.3f', v)
end

local function clampSym(v) -- симметричный кламп [-1,1] (руль знаковый)
  if v < -1 then return -1 end
  if v > 1 then return 1 end
  return v
end

-- Raw руля: input.state.steering.val (радианы ±1.57 от AI) → CLIP к [-1,1].
-- Это и есть ЦЕЛЬ конвейера (нормированный clipped-raw, §1/§8).
local function readSteerRawNorm()
  local st = input and input.state
  if not st or not st.steering then return 0 end
  return clampSym(safeVal(st.steering.val))
end

-- === Конфиг: merge + валидация ===
local function validateConfig(c)
  local function pos(gr, key, dflt)
    local v = c[gr][key]
    if v == nil or v ~= v or v <= 0 then c[gr][key] = dflt end
  end
  local function nonneg(gr, key, dflt)
    local v = c[gr][key]
    if v == nil or v ~= v or v < 0 then c[gr][key] = dflt end
  end
  local D = DEFAULTS
  pos('rate_limit', 'steer_rise', D.rate_limit.steer_rise)
  pos('rate_limit', 'steer_fall', D.rate_limit.steer_fall)
  pos('ema_tau', 'steer', D.ema_tau.steer)
  pos('lerp_tau', 'steer', D.lerp_tau.steer) -- 0 => lerp отключён (см. wheel.json)
end

local function loadConfig(path)
  local c = {}
  for gr, kv in pairs(DEFAULTS) do
    c[gr] = {}
    for k, v in pairs(kv) do c[gr][k] = v end
  end
  local f = io.open(path, 'r')
  if not f then
    toGE('WARN', 'wheel: конфиг не найден (' .. tostring(path) .. ') — используются дефолты кода')
    return c, false
  end
  local content = f:read('*all')
  f:close()
  local ok, decoded = pcall(jsonDecode, content, path)
  if not ok or type(decoded) ~= 'table' then
    toGE('WARN', 'wheel: конфиг не распарсен — используются дефолты кода')
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
  -- Режим руля: comfort — мягко/вязко (4.0/6.0, 0.15/0.12),
  -- sport — жёстче (6.0/7.0, 0.04/0.05).
  -- Строка верхнего уровня wheel.json; числа rate_limit/ema/lerp при этом
  -- заменяются пресетом (mode имеет приоритет).
  local PRESETS = {
    comfort = { rise = 4.0, fall = 6.0, ema = 0.15, lerp = 0.12 },
    sport   = { rise = 6.0, fall = 7.0, ema = 0.04, lerp = 0.05 },
  }
  local mode = type(decoded.mode) == 'string' and decoded.mode:lower() or 'comfort'
  local pr = PRESETS[mode]
  if pr then
    c.rate_limit.steer_rise, c.rate_limit.steer_fall = pr.rise, pr.fall
    c.ema_tau.steer, c.lerp_tau.steer = pr.ema, pr.lerp
    c.mode = mode
  else
    c.mode = 'custom'
    if mode ~= 'custom' then
      toGE('WARN', 'wheel: неизвестный mode="' .. tostring(mode) .. '" — числа из wheel.json')
    end
  end
  validateConfig(c)
  return c, true
end

-- === Конвейер ===
local function moveToward(cur, target, maxStep)
  local d = target - cur
  if d > maxStep then return cur + maxStep end
  if d < -maxStep then return cur - maxStep end
  return target
end

-- Один кадр конвейера руля: rate_limit → ema → lerp.
-- Специфика руля (от педалей): выбор направления капа по МОДУЛЮ
-- (|target| > |rl| => от центра к упору => steer_rise; иначе возврат в центр
-- => steer_fall). Цель — clipped-raw, мы лишь ограничиваем скорость приближения
-- (не срезаем углы). Снап |ema−rl|<1e-4 => ema достигает цели точно (иначе чек
-- 5ж 1e-3 рисковал на крутых углах); снап |out−ema|<1e-3 => дотянули.
local function stepWheel(target, dt)
  local rl = cfg.rate_limit
  -- rateScale (Фаза 7): pet-эффект временно снижает скорость вращения руля.
  local rate = ((math.abs(target) > math.abs(pipe.rl)) and rl.steer_rise or rl.steer_fall) * rateScale
  pipe.rl = moveToward(pipe.rl, target, rate * dt)

  local te = cfg.ema_tau.steer
  pipe.ema = pipe.ema + (pipe.rl - pipe.ema) * (1 - math.exp(-dt / te))
  if math.abs(pipe.ema - pipe.rl) < 1e-4 then pipe.ema = pipe.rl end

  local tl = cfg.lerp_tau.steer
  if tl > 0 then
    pipe.out = pipe.out + (pipe.ema - pipe.out) * (1 - math.exp(-dt / tl))
    if math.abs(pipe.ema - pipe.out) < 1e-3 then pipe.out = pipe.ema end
  else
    pipe.out = pipe.ema -- lerp отключён
  end
  pipe.out = clampSym(pipe.out)
end

-- ИИ реально ведёт машину? (ai.lua:6167-6169; fallback false)
local function updateRateStats(raw, out, dt)
  if prevRateRaw ~= nil and dt > 0 then
    local alpha = 1 - math.exp(-dt / RATE_EMA_TAU)
    local rawInstant = (raw - prevRateRaw) / dt
    local outInstant = (out - prevRateOut) / dt
    rateRaw = rateRaw + (rawInstant - rateRaw) * alpha
    rateOut = rateOut + (outInstant - rateOut) * alpha
  end
  prevRateRaw, prevRateOut = raw, out
end

local function resetRateStats()
  rateRaw, rateOut = 0, 0
  prevRateRaw, prevRateOut = nil, nil
end

local function aiDriving()
  local ok, v = pcall(function()
    return (ai ~= nil and ai.isDriving ~= nil) and (ai.isDriving() or false)
  end)
  return (ok and v) or false
end

-- === Музыка (Фаза 11.3): добавка ПОСЛЕ сглаживания ===
-- Глобальные функции определены в autopilotLiveMusic.lua (загружается
-- автоматически). pcall — музыка не должна ломать руль.
-- park = качок+beat-envelope на стоянке; drive = вибрация+beat-envelope.
local function musicOffset(fname)
  local fn = _G[fname]
  if type(fn) ~= 'function' then return 0 end
  local ok, v = pcall(fn)
  if not ok then return 0 end
  v = tonumber(v)
  if v == nil or v ~= v then return 0 end
  return v
end

-- Стоянка/прогрев: добавляем качок к текущему steering_input (его мог
-- записать warmup-sway; wheel идёт позже в порядке хуков).
local function applyParkMusic()
  local off = musicOffset('autopilotLiveMusicGetParkOffset')
    + musicOffset('autopilotLiveMusicGetBeatKick')
  if off == 0 then return end
  local cur = tonumber(electrics.values.steering_input) or 0
  electrics.values.steering_input = clampSym(cur + off)
end

-- === Кадровый цикл ===
function M.updateGFX(dt)
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then return end -- NaN/перерывы

  if not active then
    applyParkMusic()
    resetRateStats()
    return
  end

  if not aiDriving() then
    -- Игрок/ничья: ПЕРЕСТАЁМ перезаписывать steering_input — движок сам затирает
    -- его каждый кадр (input.lua:678) ⇒ штатный ввод мгновенно возвращается.
    -- Nil-восстановление не нужно (нет персистентного Override, §4).
    applyParkMusic() -- музыка на стоянке работает и без AI
    needInit = true -- при резюме AI — синхронизация без прыжка
    lastOut.engaged = false
    resetRateStats()
    return
  end

  local target = readSteerRawNorm() -- clipped-raw (нормированный [-1,1])
  lastRaw = target

  -- Первый кадр после on/резюме — конвейер СИНХРОНИЗИРУЕМ с raw (без прыжка)
  if needInit then
    pipe.rl, pipe.ema, pipe.out = target, target, target
    needInit = false
    resetRateStats()
    prevRateRaw, prevRateOut = target, target
  end

  stepWheel(target, dt)

  -- Микро-вибрация + микро-толчок на beat — ПОСЛЕ сглаживания (Фаза 11.3).
  local vibe = musicOffset('autopilotLiveMusicGetDriveOffset')
  local kick = musicOffset('autopilotLiveMusicGetBeatKick')
  local outVal = clampSym(pipe.out + vibe + kick)
  updateRateStats(target, outVal, dt)

  -- Перезапись steering_input — КАЖДЫЙ кадр при engaged (потребитель hydros,
  -- main.lua:91). Затираем движковое FILTER_AI-значение (main.lua:86 → :678).
  electrics.values.steering_input = outVal
  lastOut = { engaged = true, steer = outVal }
end

-- === Публичные команды (GE шлёт через queueLuaCommand) ===
autopilotLiveWheelCmd = {}

function autopilotLiveWheelCmd.on(confPath)
  local path = type(confPath) == 'string' and confPath or FALLBACK_CONF

  -- Warmup auto-engage и GE могут вызвать on() почти одновременно.
  -- Повторный on не должен сбрасывать needInit и дергать руль.
  if active and activeConfPath == path then
    aplPrint('aplWheel: ON уже активен — повторный вызов проигнорирован')
    return true
  end

  local wasActive = active
  cfg, cfgFromFile = loadConfig(path)
  active = true
  activeConfPath = path
  if not wasActive then
    needInit = true
    rateScale = 1.0 -- защита от «залипшего» pet-масштаба после перезапуска wheel
    resetRateStats()
  else
    aplPrint('aplWheel: ON уже активен — конфиг перечитан, needInit сохранён')
  end

  -- Сообщаем GE, что wheel уже включён (важно для auto-engage warmup).
  pcall(function()
    obj:queueGameEngineLua('if extensions and extensions.autopilotLive_main and extensions.autopilotLive_main.onVehicleWheelOn then extensions.autopilotLive_main.onVehicleWheelOn() end')
  end)

  local r = cfg.rate_limit
  aplPrint('aplWheel: ON — mode=' .. tostring(cfg.mode or 'custom') ..
    ', rate ' .. tostring(r.steer_rise) .. '/' .. tostring(r.steer_fall) ..
    ', ema ' .. tostring(cfg.ema_tau.steer) .. ', lerp ' .. tostring(cfg.lerp_tau.steer))
  toGE('INFO', 'wheel ON (' .. (cfgFromFile and 'конфиг из файла' or 'ДЕФОЛТЫ') ..
    ', mode=' .. tostring(cfg.mode or 'custom') ..
    '): rate rise/fall ' .. tostring(r.steer_rise) .. '/' .. tostring(r.steer_fall) ..
    ' ед/сек, ema ' .. tostring(cfg.ema_tau.steer) .. 'с, lerp ' .. tostring(cfg.lerp_tau.steer) .. 'с')
  return true
end

function autopilotLiveWheelCmd.off()
  if not active then return false end
  active = false
  activeConfPath = nil
  rateScale = 1.0
  resetRateStats()
  -- steering_input НЕ трогаем: движок затрёт его сам на следующем кадре
  -- (input.lua:678). Nil-восстановление не нужно (§4).
  lastOut.engaged = false
  toGE('INFO', 'wheel OFF: перезапись steering_input прекращена, движок на штатном FILTER_AI')
  return true
end

-- Фаза 7: временный множитель rate_limit (pet-эффект: руль плавнее ×0.5).
-- Безопасен при active=false (просто запоминается). Возврат — setRateScale(1).
function autopilotLiveWheelCmd.setRateScale(s)
  s = tonumber(s) or 1
  if s ~= s then s = 1 end
  if s < 0.1 then s = 0.1 elseif s > 1 then s = 1 end
  rateScale = s
  toGE('INFO', 'wheel rateScale → ' .. string.format('%.2f', s))
  return true
end

function autopilotLiveWheelCmd.status()
  local ad = aiDriving()
  local lines = {
    '--- apl_wheel status ---',
    string.format('active=%s engaged=%s aiDriving=%s конфиг=%s',
      tostring(active), tostring(lastOut.engaged), tostring(ad),
      cfgFromFile and 'файл' or (cfg and 'ДЕФОЛТЫ' or 'не загружен')),
    -- Все числовые поля через diagFmt/%s (фикс 2026-10-16, аномалия brake.out:
    -- %.3f в LuaJIT читал не тот слот стека — аналогичная уязвимость и тут).
    string.format('steer: clipped-raw %s -> out %s (ед. нормир. [-1,1], 1.0=упор)',
      diagFmt(lastRaw), diagFmt(lastOut.steer)),
    string.format('pipe: rl %s ema %s out %s',
      diagFmt(pipe.rl), diagFmt(pipe.ema), diagFmt(pipe.out)),
    string.format('rate (EMA %.2f с): raw %s/s, out %s/s (насколько out отстаёт от raw)',
      RATE_EMA_TAU, fmtRate(rateRaw), fmtRate(rateOut)),
    string.format('raw=%s out=%s |delta|=%s (out должен плавно догонять raw; резкий скачок = кламп не работает)',
      diagFmt(lastRaw), diagFmt(pipe.out),
      diagFmt(math.abs((tonumber(lastRaw) or 0) - pipe.out))),
    string.format('rateScale=%s (Фаза 7: pet временно снижает rate)',
      string.format('%.2f', rateScale)),
  }
  for _, l in ipairs(lines) do print('aplWheel: ' .. l) end
  toGE('INFO', 'wheel status: active=' .. tostring(active) ..
    ' engaged=' .. tostring(lastOut.engaged) ..
    ' steer ' .. diagFmt(lastRaw) .. '->' .. diagFmt(lastOut.steer) ..
    ' rate raw/out ' .. fmtRate(rateRaw) .. '/' .. fmtRate(rateOut) .. '/s')
  return true
end

-- === Состояние для CSV (autopilotLive.lua: steer_smoothed из нашего конвейера) ===
function autopilotLiveWheelGetState()
  return {
    active = active,
    engaged = lastOut.engaged,
    steer = lastOut.steer,
  }
end

-- === Жизненный цикл ===
function M.onReset()
  -- Конвейер синхронизируем при следующем кадре (needInit). steering_input
  -- движок пересоздаёт сам.
  needInit = true
  lastOut.engaged = false
  resetRateStats()
end

function M.onVehicleDestroyed()
  active = false
  activeConfPath = nil
  lastOut.engaged = false
  resetRateStats()
end

return M
