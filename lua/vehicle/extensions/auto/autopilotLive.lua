-- AutopilotLive — vehicle-слой (расширение машины)
-- Загружается АВТОМАТИЧЕСКИ при спавне машины:
--   vehicle/main.lua:314 → extensions.loadModulesInDirectory("lua/vehicle/extensions/auto")
--   loadAtRoot(file, "") даёт имя расширения = имя файла: "autopilotLive".
--
-- Ответственность (Фаза 1):
--   * сбор данных CSV с дискретизацией 20 Гц (схема: ai/notes/phase1_csv_schema.md);
--   * запись CSV в файл, буферизация + flush каждые ~2 сек;
--   * приём команд от GE-слоя через глобальную таблицу autopilotLiveCmd.*;
--   * отправка событий/ошибок в GE-лог: obj:queueGameEngineLua(...).
-- НЕ сглаживает ничего (Фаза 1): *_smoothed = *_raw (У4).
-- НЕ трогает input.event, КПП, электронику.

local M = {}

local logTag = 'aplVehicle'

-- === Состояние CSV-сессии ===
local csvActive = false
local csvFile = nil            -- handle файла CSV
local csvPath = nil            -- путь текущего CSV (для лога)
local buf = {}                 -- буфер строк перед flush
local bufBytes = 0
local timeAcc = 0              -- нарастающее время CSV (сек)
local sampleAcc = 0            -- аккумулятор дискретизации (20 Гц → 0.05 c)
local SAMPLE_DT = 0.05         -- период выборки, сек (20 Гц, решение пользователя)

-- предыдущая выборка — для производных d_*/dt
local prev = nil               -- {t, steer, throttle, brake}

-- thermals кэшируем: powertrain ищется не каждый кадр
local engineThermals = nil     -- device.thermals первого combustionEngine (или nil)
local thermalsWarned = false

-- === CSV-колонки (ровно как в ai/notes/phase1_csv_schema.md, 24 шт.) ===
local CSV_HEADER = table.concat({
  'time', 'pos_x', 'pos_y', 'pos_z', 'speed', 'accel',
  'steer_raw', 'steer_smoothed', 'throttle_raw', 'throttle_smoothed',
  'brake_raw', 'brake_smoothed', 'clutch_raw', 'clutch_smoothed',
  'gear', 'gear_index', 'rpm',
  'engine_temp', 'oil_temp', 'water_temp', 'engine_thermal',
  'd_steer_dt', 'd_throttle_dt', 'd_brake_dt',
}, ',')

-- === Лог событий в GE (txt-лог мода пишет GE-слой) ===
local function toGE(level, msg)
  -- pcall обязателен: ошибка здесь не должна ронять фрейм-цикл машины
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if autopilotLive_main and autopilotLive_main.onVehicleLog then autopilotLive_main.onVehicleLog("%s", "%s") end',
      level, tostring(msg):gsub('\\', '\\\\'):gsub('"', '\\"')))
  end)
end

-- === Термополы движка (У1, колонки 18 и 21) ===
local function refreshEngineThermals()
  if engineThermals then return engineThermals end
  if thermalsWarned then return nil end
  local ok, res = pcall(function()
    local devices = powertrain.getDevicesByType('combustionEngine')
    for _, dev in pairs(devices or {}) do
      if dev.thermals then return dev.thermals end
    end
    return nil
  end)
  if ok and res then
    engineThermals = res
    return res
  end
  -- Нет движка (электрокар?) — WARN один раз, дальше молчим (колонки = 0)
  thermalsWarned = true
  toGE('WARN', 'combustionEngine thermals не найдены (электрокар или позднее чтение) — колонки engine_temp/engine_thermal = 0')
  return nil
end

-- === Формирование строки CSV ===
local function fmtNumber(v)
  if v == nil or v ~= v then return '0' end -- nil или NaN → 0 (нет NaN в CSV!)
  return string.format('%.6g', v)
end

local function buildRow(dt)
  timeAcc = timeAcc + dt

  -- позиция и скорость (У1: telemetryLogger.lua:21,25)
  local pos = obj:getPosition()
  local speed = obj:getVelocity():length()

  -- ввод: raw из input.state.<k>.val, итог из input.<k> (У3)
  -- В Фазе 1 *_smoothed читается из input.* — при AI это == raw (У4)
  local steerRaw = (input.state and input.state.steering and input.state.steering.val) or 0
  local thrRaw = (input.state and input.state.throttle and input.state.throttle.val) or 0
  local brkRaw = (input.state and input.state.brake and input.state.brake.val) or 0
  local cltRaw = (input.state and input.state.clutch and input.state.clutch.val) or 0

  local steerSm = input.steering or steerRaw
  local thrSm = input.throttle or thrRaw
  local brkSm = input.brake or brkRaw
  local cltSm = input.clutch or cltRaw

  -- электроника (У1)
  local gear = tostring(electrics.values.gear or '')
  local gearIndex = electrics.values.gearIndex or 0
  local rpm = electrics.values.rpm or 0
  local oilTemp = electrics.values.oiltemp or 0
  local waterTemp = electrics.values.watertemp or 0

  -- thermals (У1: колонки 18, 21)
  local th = refreshEngineThermals()
  local engineTemp = (th and th.coolantTemperature) or 0
  local engineThermal = (th and th.engineBlockTemperature) or 0

  -- производные d_*/dt (между нашими 20 Гц-выборками)
  local dSteer, dThr, dBrk = 0, 0, 0
  local accel = 0
  if prev then
    local ddt = timeAcc - prev.t
    if ddt > 1e-6 then
      dSteer = (steerRaw - prev.steer) / ddt
      dThr = (thrRaw - prev.throttle) / ddt
      dBrk = (brkRaw - prev.brake) / ddt
      accel = (speed - prev.speed) / ddt
    end
  end
  prev = { t = timeAcc, steer = steerRaw, throttle = thrRaw, brake = brkRaw, speed = speed }

  local row = table.concat({
    fmtNumber(timeAcc),
    fmtNumber(pos.x), fmtNumber(pos.y), fmtNumber(pos.z),
    fmtNumber(speed), fmtNumber(accel),
    fmtNumber(steerRaw), fmtNumber(steerSm),
    fmtNumber(thrRaw), fmtNumber(thrSm),
    fmtNumber(brkRaw), fmtNumber(brkSm),
    fmtNumber(cltRaw), fmtNumber(cltSm),
    '"' .. gear .. '"', fmtNumber(gearIndex), fmtNumber(rpm),
    fmtNumber(engineTemp), fmtNumber(oilTemp), fmtNumber(waterTemp), fmtNumber(engineThermal),
    fmtNumber(dSteer), fmtNumber(dThr), fmtNumber(dBrk),
  }, ',')
  return row
end

-- === Буферизация и flush ===
local FLUSH_BYTES = 64 * 1024 -- flush каждые 64 КБ или по таймеру (~2 сек)

local function flushBuffer()
  if not csvFile or #buf == 0 then return end
  local ok, err = pcall(function()
    csvFile:write(table.concat(buf, '\r\n'))
    csvFile:write('\r\n')
    csvFile:flush()
  end)
  buf = {}
  bufBytes = 0
  if not ok then
    toGE('ERROR', 'Ошибка записи CSV: ' .. tostring(err))
  end
end

-- === Публичные команды (вызывает GE-слой через queueLuaCommand) ===
-- Глобальная таблица: GE шлёт строку 'autopilotLiveCmd.startCsv("...")',
-- она исполняется в VM машины как обычный Lua-код.
autopilotLiveCmd = {}

function autopilotLiveCmd.startCsv(path)
  if csvActive then
    toGE('WARN', 'startCsv: уже записывается (' .. tostring(csvPath) .. ')')
    return false
  end
  if type(path) ~= 'string' or path == '' then
    toGE('ERROR', 'startCsv: путь пуст')
    return false
  end
  -- Нормализуем '\' → '/' (путь приходит абсолютным из GE, У2)
  local normalized = path:gsub('\\', '/')
  local f, err = io.open(normalized, 'w')
  if not f then
    toGE('ERROR', 'startCsv: io.open не смог открыть: ' .. normalized .. ' : ' .. tostring(err))
    return false
  end
  csvFile = f
  csvPath = normalized
  csvActive = true
  timeAcc = 0
  sampleAcc = 0
  prev = nil
  buf = { CSV_HEADER }
  bufBytes = #CSV_HEADER
  toGE('INFO', 'CSV запись начата: ' .. normalized)
  return true
end

function autopilotLiveCmd.stopCsv()
  if not csvActive then return false end
  flushBuffer()
  if csvFile then
    csvFile:close()
  end
  csvFile = nil
  local p = csvPath
  csvPath = nil
  csvActive = false
  toGE('INFO', 'CSV запись остановлена: ' .. tostring(p))
  return true
end

-- Запрос статуса (GE apl_status может дернуть)
function autopilotLiveCmd.status()
  return { active = csvActive, path = csvPath, buffered = #buf }
end

-- === Жизненный цикл расширения ===
function M.onInit()
  engineThermals = nil
  thermalsWarned = false
  pcall(function()
    obj:queueGameEngineLua(
      'if autopilotLive_main and autopilotLive_main.onVehicleReady then autopilotLive_main.onVehicleReady(' ..
      tostring(obj and obj:getID() or -1) .. ') end')
  end)
end

M.onReset = M.onInit

-- Главный цикл сбора: updateGFX — кадровый тик vehicle-расширений
-- (паттерн: telemetryLogger.lua:13, csvMetrics.lua:82)
function M.updateGFX(dt)
  if not csvActive then return end
  if dt == nil or dt ~= dt or dt > 1 then return end -- защита от NaN/перерывов (таб-меню)

  sampleAcc = sampleAcc + dt
  if sampleAcc < SAMPLE_DT then return end

  local rowDt = sampleAcc
  sampleAcc = 0

  local row = buildRow(rowDt)
  buf[#buf + 1] = row
  bufBytes = bufBytes + #row + 2

  if bufBytes >= FLUSH_BYTES then
    flushBuffer()
  end
end

-- Периодический flush по времени: срабатывает даже если 64 КБ не набралось
-- (куда-то ~2 сек при 20 Гц). Вызывается из updateGFX через таймер буфера —
-- проще: flush по количеству строк.
local flushCounter = 0
local FLUSH_ROWS = 40 -- 40 строк × 0.05 c = 2 c
local updateGFXInner = M.updateGFX
M.updateGFX = function(dt)
  updateGFXInner(dt)
  if csvActive then
    flushCounter = flushCounter + 1
    if flushCounter >= FLUSH_ROWS then
      flushCounter = 0
      flushBuffer()
    end
  end
end

function M.onVehicleDestroyed()
  if csvActive then
    autopilotLiveCmd.stopCsv()
  end
end

return M
