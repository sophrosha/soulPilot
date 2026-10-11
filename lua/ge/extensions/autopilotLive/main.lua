-- AutopilotLive — GE-слой (глобальное расширение мода)
-- Загружается из scripts/modScript.lua: extensions.load('autopilotLive/main')
-- Имя расширения после загрузки: autopilotLive_main (luaPathToExtName, extensions.lua:55-62).
--
-- Ответственность GE-слоя (Фаза 1):
--   * консольные команды: apl_debug(), apl_status();
--   * txt-лог событий мода ai/logs/*.txt (уровни INFO/WARN/ERROR);
--   * вычисление относительных путей записи от userPath (У2: с fallback);
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
-- Диагностика apl_diag (2026-10-12): io.open в GE-Lua sandbox принимает
-- ТОЛЬКО пути, относительные от userPath (CWD фактически = userPath);
-- абсолютные 'C:/...' — FAIL (пробы 3-4). Поэтому все пути здесь
-- относительные и с '/'; CWD — свойство процесса ОС, общее для GE и
-- vehicle-VM, поэтому vehicle-слой откроет тот же файл.

-- Каталоги данных по приоритету (У2):
--   A: mods/unpacked/AutopilotLive/ai/...   (папка мода, основной путь)
--   B: autopilotLive_logs/...               (fallback-страховка: папка мода
--      недоступна — например, удалена; главное — чтобы писалось)
local function getDataDirs()
  return {
    {
      name = 'mod',
      csv = 'mods/unpacked/AutopilotLive/ai/csv/',
      logs = 'mods/unpacked/AutopilotLive/ai/logs/',
    },
    {
      name = 'fallback',
      csv = 'autopilotLive_logs/csv/',
      logs = 'autopilotLive_logs/logs/',
    },
  }
end

-- Проверка, что каталог доступен на запись:
-- 1) создаём папку штатным FS API — io.open папки сам не создаёт;
-- 2) пробный файл-зонд через io.open (реальная проверка записи);
-- 3) зонд удаляется сразу после проверки — в папке ничего не валяется.
local function dirWritable(dir)
  local created = pcall(function()
    if not FS:directoryExists(dir) then
      FS:directoryCreate(dir, true)
    end
  end)
  if not created then return false end
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
  -- Относительный от userPath путь отдаём vehicle-слою ГОТОВЫМ (на '/'),
  -- vehicle-слой сам путь не вычисляет (У2). Абсолютные пути в sandbox
  -- io.open не работают — см. диагностику apl_diag.
  local path = (dataDir.csv .. stamp .. '_drive.csv'):gsub('\\', '/')
  -- Передача строки: кавычки и обратные слэши безопасны после gsub на '/'
  if sendToVehicle(string.format('autopilotLiveCmd.startCsv("%s")', path)) then
    csvActive = true
    -- Реальный (абсолютный) путь — сразу в консоль, чтобы не искать файл.
    -- Если файл ещё не создан vehicle-слоем, резолвим каталог (он уже есть).
    local realPath = ''
    pcall(function()
      realPath = FS:getFileRealPath(path) or ''
      if realPath == '' then
        local realDir = FS:getFileRealPath(dataDir.csv) or ''
        if realDir ~= '' then realPath = realDir .. stamp .. '_drive.csv' end
      end
    end)
    if realPath == '' then realPath = path end
    print('CSV: ' .. realPath)
    logLine('INFO', 'CSV-запись запрошена: ' .. path .. ' (real: ' .. realPath .. ')')
  end
end

local function stopCsvRecording()
  if not csvActive then return end
  if sendToVehicle('autopilotLiveCmd.stopCsv()') then
    csvActive = false
    logLine('INFO', 'CSV-запись остановлена')
  end
end

-- === Диагностика io.open / FS (часть Фазы 1.6) ===
-- Временная команда: apl_diag() в консоли (GE-Lua).
-- Печатает таблицу: какой вариант записи работает в sandbox BeamNG.
-- Ничего не исправляет — только отчёт (кода минимум, отчёта максимум).
function apl_diag()
  local out = {}
  local function p(s) out[#out + 1] = s print(s) end

  local USER = (FS and FS:getUserPath() or ''):gsub('\\', '/')
  if USER ~= '' and USER:sub(-1) ~= '/' then USER = USER .. '/' end

  p('--- AutopilotLive diagnostics ---')
  p('userPath = ' .. tostring(USER ~= '' and USER or '(FS:getUserPath() пуст/недоступен)'))

  -- каждая проба: независимый pcall, свой файл, свой отчёт OK/FAIL
  local function tryIo(label, path, mkdirPath)
    local res, err = pcall(function()
      -- опциональное создание папки штатным FS API
      if mkdirPath then
        local okDir, dirErr = pcall(function() return FS:directoryCreate(mkdirPath, true) end)
        if not okDir then error('directoryCreate упал: ' .. tostring(dirErr)) end
      end
      local f, oerr = io.open(path, 'w')
      if not f then error('io.open: ' .. tostring(oerr)) end
      f:write('apl_diag')
      f:close()
    end)
    if res then
      -- верификация независимым API (не доверяем только io.open)
      local exists = 'n/a'
      pcall(function() exists = tostring(FS:fileExists(path)) end)
      p('[' .. label .. '] OK (fileExists=' .. exists .. ') ' .. path)
    else
      p('[' .. label .. '] FAIL: ' .. tostring(err))
    end
  end

  -- 1: относительный путь без папок (CWD)
  tryIo('1 rel-nodir', 'apl_test.txt')

  -- 2: относительный с папкой (папку создаёт FS:directoryCreate)
  tryIo('2 rel-dir', 'autopilotLive_logs/apl_test.txt', 'autopilotLive_logs')

  -- 3: абсолютный, прямые слэши
  tryIo('3 abs-fwd', USER .. 'autopilotLive_logs/apl_test_abs.txt',
        USER ~= '' and USER .. 'autopilotLive_logs' or nil)

  -- 4: абсолютный, бэкслэши
  local absBs = (USER:gsub('/', '\\')) .. 'autopilotLive_logs\\apl_test_bs.txt'
  tryIo('4 abs-bs', absBs)

  -- 5: writeFile с VFS-путём (паттерн ui/options.lua:46)
  pcall(function()
    local ok = writeFile('/autopilotLive_logs/apl_test_vfs.txt', 'apl_diag')
    p('[5 writeFile-VFS] ' .. (ok and 'OK' or 'FAIL: writeFile вернул nil/false') ..
      ' (fileExists=' .. tostring(FS:fileExists('autopilotLive_logs/apl_test_vfs.txt')) .. ')')
  end)

  -- 6: writeFile с относительным путём
  pcall(function()
    local ok = writeFile('autopilotLive_logs/apl_test_rel.txt', 'apl_diag')
    p('[6 writeFile-rel] ' .. (ok and 'OK' or 'FAIL: writeFile вернул nil/false') ..
      ' (fileExists=' .. tostring(FS:fileExists('autopilotLive_logs/apl_test_rel.txt')) .. ')')
  end)

  -- 7: ГЛАВНЫЙ кандидат writer'а — папка мода, относительный от userPath,
  -- папка создаётся FS:directoryCreate (будет ли работать CSV в ai/csv/)
  tryIo('7 mod-csv', 'mods/unpacked/AutopilotLive/ai/csv/apl_test_mod.txt',
        'mods/unpacked/AutopilotLive/ai/csv')

  -- Блок Б: где реально лежают файлы (поиск CWD)
  local function real(label, vp)
    local r = ''
    pcall(function() r = FS:getFileRealPath(vp) or '' end)
    p('real(' .. label .. ') = ' .. (r ~= '' and r or '(пусто)'))
  end
  real('apl_test.txt', 'apl_test.txt')
  real('autopilotLive_logs/apl_test.txt', 'autopilotLive_logs/apl_test.txt')
  real('vfs', '/autopilotLive_logs/apl_test_vfs.txt')
  real('abs', USER .. 'autopilotLive_logs/apl_test_abs.txt')
  real('mod-csv', 'mods/unpacked/AutopilotLive/ai/csv/apl_test_mod.txt')

  -- Блок В: уборка
  local removed, left = 0, {}
  local function cleanup(path)
    local ok = pcall(function()
      if FS:fileExists(path) or io.open(path, 'r') then
        if os.remove(path) then removed = removed + 1 else left[#left+1] = path end
      end
    end)
    if not ok then left[#left+1] = path .. ' (exception)' end
  end
  cleanup('apl_test.txt')
  cleanup('autopilotLive_logs/apl_test.txt')
  cleanup(USER .. 'autopilotLive_logs/apl_test_abs.txt')
  cleanup(absBs)
  cleanup('autopilotLive_logs/apl_test_vfs.txt')
  cleanup('autopilotLive_logs/apl_test_rel.txt')
  cleanup('mods/unpacked/AutopilotLive/ai/csv/apl_test_mod.txt')
  p('cleanup: удалено ' .. removed .. ', остались: ' ..
    (#left > 0 and table.concat(left, '; ') or 'нет'))

  p('--------------------------------')
  return true
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
