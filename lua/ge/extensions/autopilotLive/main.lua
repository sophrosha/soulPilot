-- AutopilotLive — GE-слой (глобальное расширение мода)
-- Загружается из scripts/modScript.lua: extensions.load('autopilotLive/main')
-- Имя расширения после загрузки: autopilotLive_main (luaPathToExtName, extensions.lua:55-62).
--
-- Ответственность GE-слоя (Фаза 1):
--   * консольные команды: apl_debug(), apl_status();
--   * txt-лог событий мода ai/logs/*.txt (уровни INFO/WARN/ERROR);
--   * вычисление абсолютных путей записи (У2: с fallback);
--   * запуск/остановка CSV-записи в vehicle-слое (через queueLuaCommand);
--   * приём сообщений об ошибках от vehicle-слоя (obj:queueGameEngineLua).
-- НЕ содержит логики сглаживания — это Экраны 3-4 (Фазы 3-4).

local M = {}

local logTag = 'autopilotLive'

-- === Состояние мода ===
local debugEnabled = false        -- дебаг вкл/выкл (apl_debug toggle)
local logFileHandle = nil         -- handle открытого txt-лога
local logFilePath = nil           -- путь текущего лога (для apl_status)
local csvActive = false           -- идёт ли сейчас CSV-запись в vehicle-слое
local dataDir = nil               -- выбранный базовый каталог данных (У2)
local dirsTried = {}              -- какие варианты путей пробовали (для отчёта)

-- === Утилиты путей (У2) ===
-- Абсолютный userPath: C:\Users\...\BeamNG.drive\current\ (с завершающим sep)
local function getUserRoot()
  return (FS:getUserPath() or ''):gsub('\\', '/')
end

-- Каталоги данных по приоритету (У2):
--   A: mods/unpacked/AutopilotLive/ai/...   (папка мода, основной)
--   B: autopilotLive_logs/...               (fallback: главное — чтобы писалось)
local function getDataDirs()
  local root = getUserRoot()
  return {
    {
      name = 'mod',
      csv = root .. 'mods/unpacked/AutopilotLive/ai/csv/',
      logs = root .. 'mods/unpacked/AutopilotLive/ai/logs/',
    },
    {
      name = 'fallback',
      csv = root .. 'autopilotLive_logs/csv/',
      logs = root .. 'autopilotLive_logs/logs/',
    },
  }
end

-- Проверка, что каталог доступен на запись: пробуем создать файл-заглушку.
-- io.open в Lua на Windows принимает пути с '/', нормализуем перед вызовом.
local function dirWritable(dir)
  local probe = dir .. '.__apl_probe'
  local f = io.open(probe, 'w')
  if not f then return false end
  f:write('probe')
  f:close()
  os.remove(probe)
  return true
end

local function resolveDataDir()
  for _, d in ipairs(getDataDirs()) do
    dirsTried[#dirsTried + 1] = d.name .. '=' .. d.csv
    if dirWritable(d.csv) and dirWritable(d.logs) then
      return d
    end
  end
  return nil
end

-- === txt-лог событий мода ===
-- Формат строки: 2026-10-11 12:00:00 [LEVEL] [tag] сообщение
local function logLine(level, msg, tag)
  local line = string.format('%s [%s] [%s] %s',
    os.date('%Y-%m-%d %H:%M:%S'), level, tag or logTag, tostring(msg))
  -- В консоль игры: ошибки всегда, остальное — только при включённом дебаге
  if level == 'ERROR' or level == 'WARN' or debugEnabled then
    log(level == 'ERROR' and 'E' or (level == 'WARN' and 'W' or 'I'), logTag, msg)
  end
  if not logFileHandle then return end -- без дебага (и без файла) не пишем в файл
  logFileHandle:write(line .. '\r\n')
  logFileHandle:flush() -- события редкие — флушим сразу, не теряем при вылете
end

local function openLogFile()
  if logFileHandle then return true end
  if not dataDir then
    dataDir = resolveDataDir()
    if not dataDir then
      log('E', logTag, 'Ни один каталог данных не доступен на запись! Пробовали: ' .. table.concat(dirsTried, '; '))
      return false
    end
    logLine('INFO', 'Каталог данных: ' .. dataDir.name .. ' (' .. dataDir.logs .. ')')
  end
  local path = dataDir.logs .. os.date('%Y-%m-%d_%H-%M-%S') .. '_mod.txt'
  local f, err = io.open(path, 'w')
  if not f then
    log('E', logTag, 'Не удалось открыть лог-файл: ' .. tostring(path) .. ' : ' .. tostring(err))
    return false
  end
  logFileHandle = f
  logFilePath = path
  logLine('INFO', 'Лог-файл открыт: ' .. path)
  return true
end

local function closeLogFile()
  if not logFileHandle then return end
  logFileHandle:write(string.format('%s [INFO] [%s] Лог-файл закрыт\r\n', os.date('%Y-%m-%d %H:%M:%S'), logTag))
  logFileHandle:close()
  logFileHandle = nil
end

-- === Управление vehicle-слоем ===
-- ВНИМАНИЕ: обращения к vehicle идут ТОЛЬКО через getPlayerVehicle(0)
-- (машина игрока). Команды — глобальные функции vehicle-слоя autopilotLiveCmd.*,
-- которые определит lua/vehicle/extensions/auto/autopilotLive.lua (шаг 1.3).
local function getVehicle()
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if veh then return veh end
  return nil
end

local function sendToVehicle(cmd)
  local veh = getVehicle()
  if not veh then
    logLine('WARN', 'Машина игрока не найдена, команда не отправлена: ' .. cmd)
    return false
  end
  veh:queueLuaCommand(cmd)
  return true
end

local function startCsvRecording()
  if csvActive then
    logLine('INFO', 'CSV уже записывается, повторный старт игнорирован')
    return
  end
  if not dataDir then
    dataDir = resolveDataDir()
    if not dataDir then
      logLine('ERROR', 'CSV не стартует: каталог данных недоступен')
      return
    end
  end
  local stamp = os.date('%Y-%m-%d_%H-%M-%S')
  -- Абсолютный путь отдаём vehicle-слою ГОТОВЫМ (нормализованным на '/'),
  -- vehicle-слой сам путь не вычисляет (У2).
  local path = (dataDir.csv .. stamp .. '_drive.csv'):gsub('\\', '/')
  -- Передача строки: кавычки и обратные слэши безопасны после gsub на '/'
  if sendToVehicle(string.format('autopilotLiveCmd.startCsv("%s")', path)) then
    csvActive = true
    logLine('INFO', 'CSV-запись запрошена: ' .. path)
  end
end

local function stopCsvRecording()
  if not csvActive then return end
  if sendToVehicle('autopilotLiveCmd.stopCsv()') then
    csvActive = false
    logLine('INFO', 'CSV-запись остановлена')
  end
end

-- === Консольные команды ===
-- GE-Lua контекст консоли исполняет строку как Lua-код (windowsConsole.lua:13-14),
-- поэтому объявляем глобальные функции с префиксом apl_ (решение пользователя).
function apl_debug()
  debugEnabled = not debugEnabled
  if debugEnabled then
    openLogFile()
    startCsvRecording()
    logLine('INFO', '=== Дебаг ВКЛЮЧЁН ===')
  else
    logLine('INFO', '=== Дебаг ВЫКЛЮЧЕН ===')
    stopCsvRecording()
    closeLogFile()
  end
  return debugEnabled
end

function apl_status()
  -- Статус печатается в консоль напрямую (print), независимо от дебага
  local veh = getVehicle()
  print('--- AutopilotLive status ---')
  print('debug: ' .. tostring(debugEnabled))
  print('log: ' .. tostring(logFilePath or '(закрыт)'))
  print('csv active: ' .. tostring(csvActive))
  print('data dir: ' .. tostring(dataDir and dataDir.csv or '(не выбран)'))
  print('vehicle: ' .. (veh and ('ID=' .. tostring(veh:getID())) or '(нет)'))
  print('---------------------------')
  return true
end

-- === Приём сообщений от vehicle-слоя ===
-- vehicle вызывает: obj:queueGameEngineLua('autopilotLive_main.onVehicleLog("W","текст")')
function M.onVehicleLog(level, msg)
  level = tostring(level or 'INFO'):upper()
  if level ~= 'INFO' and level ~= 'WARN' and level ~= 'ERROR' then level = 'INFO' end
  -- Файл лога открывается только при дебаге, но ERROR должны попадать всегда (ТЗ):
  if level == 'ERROR' and not logFileHandle then
    openLogFile() -- аварийно открываем лог, чтобы ошибка не потерялась
  end
  logLine(level, msg, 'vehicle')
end

-- vehicle сообщает, что его расширение активно (шаг 1.3 при спавне)
function M.onVehicleReady(vehId)
  logLine('INFO', 'Vehicle-слой активен (vehId=' .. tostring(vehId) .. ')')
end

-- === Жизненный цикл расширения ===
function M.onExtensionLoaded()
  dataDir = resolveDataDir()
  if dataDir then
    log('I', logTag, 'AutopilotLive GE-слой загружен. Каталог данных: ' .. dataDir.name)
  else
    log('E', logTag, 'AutopilotLive: каталоги данных недоступны! Пробовали: ' .. table.concat(dirsTried, '; '))
  end
end

function M.onExtensionUnloaded()
  stopCsvRecording()
  closeLogFile()
end

-- Данные мода не сериализуем (переживают CTRL+L без восстановления) —
-- состояние всегда чистое после перезагрузки Lua.
function M.onSerialize() return nil end

-- Также ловим строки вида "apl_debug" из консоли (хук windowsConsole.lua:11).
-- Для GE-Lua контекста команда ещё и исполняется как Lua — если пользователь
-- ввёл apl_debug() без скобок, сюда придёт строка "apl_debug" (пока не проверено,
-- доходит ли хук для GE-Lua — допилю по результатам теста).
function M.onConsoleExecuteCommand(context, cmd)
  if type(cmd) ~= 'string' then return end
  local trimmed = cmd:match('^%s*(.-)%s*$')
  if trimmed == 'apl_debug' then
    apl_debug()
  elseif trimmed == 'apl_status' then
    apl_status()
  end
end

return M
