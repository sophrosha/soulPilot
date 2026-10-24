-- AutopilotLive — GE-слой (глобальное расширение мода)
-- Загружается из scripts/modScript.lua: extensions.load('autopilotLive/main')
-- Имя расширения после загрузки: autopilotLive_main (luaPathToExtName, extensions.lua:55-62).
--
-- Ответственность GE-слоя (Фаза 1 + Фаза 3):
--   * консольные команды: apl_debug(), apl_status(), apl_pedals("on"|"off"|"status");
--   * txt-лог событий мода ai/logs/*.txt (уровни INFO/WARN/ERROR);
--   * вычисление относительных путей записи от userPath (У2: с fallback);
--   * запуск/остановка CSV-записи в vehicle-слое (через queueLuaCommand);
--   * приём сообщений об ошибках от vehicle-слоя (obj:queueGameEngineLua).
-- НЕ содержит логики сглаживания — она в vehicle-слое (autopilotLivePedals.lua).

local M = {}

local logTag = 'autopilotLive'

-- === Состояние мода ===
local debugEnabled = false        -- дебаг вкл/выкл (apl_debug toggle)
local logFileHandle = nil         -- handle открытого txt-лога
local logFilePath = nil           -- путь текущего лога (для apl_status)
local csvActive = false           -- идёт ли сейчас CSV-запись в vehicle-слое
local csvVehicleId = nil           -- id машины, начавшей CSV (fallback для stop)
local pedalsRequested = false      -- Фаза 3: запрошено ли apl_pedals("on") (для apl_status)
local wheelRequested = false       -- Фаза 4: запрошено ли apl_wheel("on") (для apl_status)
local warmupRequested = false      -- Фаза 5: идёт ли сейчас прогрев (apl_warmup start→done/off)
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
-- Основной путь — getPlayerVehicle(0) (машина игрока); fallback —
-- getObjectByID(csvVehicleId), если машина не видна GE в момент команды.
-- Команды — глобальные функции vehicle-слоя autopilotLiveCmd.*,
-- которые определит lua/vehicle/extensions/auto/autopilotLive.lua (шаг 1.3).
local function getVehicle()
  local veh = getPlayerVehicle and getPlayerVehicle(0)
  if veh then return veh end
  return nil
end

local function sendToVehicle(cmd)
  local veh = getVehicle()
  -- Fallback: если машина игрока не видна GE (выход в меню/перезагрузка на
  -- момент команды) — шлём тому объекту, с которого стартовала CSV-запись.
  if not veh and csvVehicleId and getObjectByID then
    local ok, byId = pcall(getObjectByID, csvVehicleId)
    if ok and byId then veh = byId end
  end
  if not veh then
    logLine('WARN', 'Машина игрока не найдена, команда не отправлена: ' .. cmd)
    return nil
  end
  local ok, err = pcall(function() veh:queueLuaCommand(cmd) end)
  if not ok then
    logLine('WARN', 'queueLuaCommand упал: ' .. cmd .. ' : ' .. tostring(err))
    return nil
  end
  return veh
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
  local vehSent = sendToVehicle(string.format('autopilotLiveCmd.startCsv("%s")', path))
  if vehSent then
    csvActive = true
    -- Запоминаем id машины: по нему уйдёт stopCsv, даже если к моменту
    -- остановки getPlayerVehicle(0) уже пуст (меню/перезагрузка).
    local okId, id = pcall(function() return vehSent:getID() end)
    csvVehicleId = (okId and id) or nil
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
    csvVehicleId = nil
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

-- === Фаза 2: экспорт графа дорог (шаг 2.3) ===
-- apl_exportGraph() — строит ai/road/graph.json из навиграфа уровня
-- (map.nodes, ge/map.lua). Схема: ai/road/graph_schema.md.
-- ВНИМАНИЕ: все пути — ТОЛЬКО относительные от userPath (sandbox io.open,
-- диагностика apl_diag в Фазе 1).

local GRAPH_DIR = 'mods/unpacked/AutopilotLive/ai/road/'
local GRAPH_CONF = 'mods/unpacked/AutopilotLive/ai/config/graph.json'

-- jsonEncodePretty пропускает ключи со значением nil (utils.lua:402), а
-- НЕизвестные типы пишет как null (utils.lua:417) — этим пользуемся для
-- явных null-полей схемы (angle_deg при degree ~= 2 и т.п.)
local JSON_NULL = function() end

local function loadGraphConfig()
  local defaults = { friction_mu = 0.75, turn_angle_threshold_deg = 20, speed_round_kph = 5 }
  local f = io.open(GRAPH_CONF, 'r')
  if not f then
    logLine('WARN', 'Конфиг графа не найден (' .. GRAPH_CONF .. ') — дефолты: mu=0.75, порог 20°, шаг 5 км/ч')
    return defaults
  end
  local content = f:read('*all')
  f:close()
  local ok, decoded = pcall(jsonDecode, content, GRAPH_CONF)
  if not ok or type(decoded) ~= 'table' then
    logLine('WARN', 'Конфиг графа не распарсен — дефолты: mu=0.75, порог 20°, шаг 5 км/ч')
    return defaults
  end
  return {
    friction_mu = tonumber(decoded.friction_mu) or defaults.friction_mu,
    turn_angle_threshold_deg = tonumber(decoded.turn_angle_threshold_deg) or defaults.turn_angle_threshold_deg,
    speed_round_kph = tonumber(decoded.speed_round_kph) or defaults.speed_round_kph,
  }
end

-- --- векторные утилиты (только чтение геометрии, ничего не дёргаем) ---
local function vecSub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
local function vecLen(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end
local function vecDot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end
local function vecCross(a, b)
  return { x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x }
end

-- Азимут in (dx, dy): 0° = север (+Y), ПО ЧАСОВОЙ стрелке (решение пользователя)
local function azimuthDeg(dx, dy)
  return (math.deg(math.atan2(dx, dy)) + 360) % 360
end

-- Угол между двумя векторами, градусы (0..180); nil, если какой-то нулевой
local function angleBetweenDeg(v1, v2)
  local l1, l2 = vecLen(v1), vecLen(v2)
  if l1 < 1e-9 or l2 < 1e-9 then return nil end
  local c = vecDot(v1, v2) / (l1 * l2)
  c = math.max(-1, math.min(1, c))
  return math.deg(math.acos(c))
end

-- Радиус описанной окружности треугольника (prevP, fromP, toP):
-- R = a·b·c / (4·S), S = площадь через cross; на прямых (S≈0) → nil (схема)
local function circumradius(prevP, fromP, toP)
  local area2 = vecLen(vecCross(vecSub(fromP, prevP), vecSub(toP, prevP))) -- 2·S
  if area2 < 1e-6 then return nil end
  local a = vecLen(vecSub(toP, fromP))
  local b = vecLen(vecSub(toP, prevP))
  local c = vecLen(vecSub(fromP, prevP))
  if a < 1e-9 or b < 1e-9 or c < 1e-9 then return nil end
  return a * b * c / (2 * area2)
end

-- Округление ВНИЗ до шага (рекомендованная скорость)
local function floorToStep(v, step)
  if v == nil or v ~= v or step == nil or step <= 0 then return v end
  return math.floor(v / step + 1e-9) * step
end

-- Детерминированный id ребра: min_max (тот же формат в marks.csv)
local function edgeIdOf(a, b)
  a, b = tostring(a), tostring(b)
  if a < b then return a .. '_' .. b end
  return b .. '_' .. a
end

local function cmpId(a, b) return tostring(a) < tostring(b) end

-- Позиция конца ребра у узла nid (map.lua:174-187): узел-inNode «владеет»
-- inPos, узел-outNode — outPos; несовпадение/nil → pos узла (fallback)
local function edgeEndPos(edge, nid, nodePos)
  if edge.inNode == nid then return edge.inPos or nodePos end
  if edge.outNode == nid then return edge.outPos or nodePos end
  return nodePos
end

function apl_exportGraph()
  -- Доступ к графу ТОЛЬКО через map.getMap() (У1, 2026-10-12): map.nodes —
  -- приватная переменная модуля (map.lua:25), у таблицы API расширения поля
  -- nodes НЕТ; pcall(map.getMap) — вызов со скобками, поле не читаем напрямую.
  -- map.load() — ТОЛЬКО если узлов 0 (У2: на East Coast 5439 уже построены
  -- движком, ленивая загрузка перестраивает граф и меняет buildSerial).
  local okMap, gm = pcall(map.getMap)
  if not okMap or type(gm) ~= 'table' or type(gm.nodes) ~= 'table' or next(gm.nodes) == nil then
    pcall(function() map.load() end) -- единственное разрешённое место map.load()
    okMap, gm = pcall(map.getMap)
  end
  if not okMap or type(gm) ~= 'table' or type(gm.nodes) ~= 'table' or next(gm.nodes) == nil then
    print('WARN apl_exportGraph: граф недоступен (map.getMap() пуст) — карта не загружена?')
    return false
  end
  local nodesMap = gm.nodes

  local conf = loadGraphConfig()
  local warnings = {}
  local function warn(msg)
    warnings[#warnings + 1] = msg
  end

  -- Детерминированный порядок обхода (иначе pairs() даёт разный JSON)
  local ids = {}
  for id in pairs(nodesMap) do ids[#ids + 1] = id end
  table.sort(ids, cmpId)

  -- === Проход A: рёбра (сырые пары) + НЕОРИЕНТИРОВАННАЯ смежность ===
  -- ФИКС после теста 2.7 (East Coast, 2026-10-12): links в навиграфе хранятся
  -- ОДНОСТОРОННЕ (цепочки next от DecalRoad): map.nodes[A].links[B] есть,
  -- обратного map.nodes[B].links[A] может НЕ быть. Доказательство: сумма
  -- |links| по всем узлам == число рёбер ровно (phantom == -E в чекере).
  -- Поэтому НЕОРИЕНТИРОВАННАЯ степень узла = |{B: A.links[B] ИЛИ B.links[A]}| —
  -- строим смежность из собранных рёбер (O(E)), а НЕ по links узла.
  -- Без фикса: цепочка A->B->C даёт «все dead_end», а «приёмники» — isolated
  -- (East Coast: 5098 dead_end, 91% рёбер без radius — артефакт такого degree).
  local rawEdges = {} -- {a=id, b=toId, edge=таблица ребра links[...]}
  local adj = {}      -- id -> set НЕОРИЕНТИРОВАННЫХ соседей
  local seen = {}
  for _, id in ipairs(ids) do
    local n = nodesMap[id]
    for toId in pairs(n.links or {}) do
      local eid = edgeIdOf(id, toId)
      if not seen[eid] then
        seen[eid] = true
        if nodesMap[toId] then
          rawEdges[#rawEdges + 1] = { a = id, b = toId, edge = n.links[toId] }
          adj[id] = adj[id] or {}
          adj[toId] = adj[toId] or {}
          adj[id][toId] = true
          adj[toId][id] = true
        else
          warn('битая ссылка ребра: ' .. tostring(id) .. '->' .. tostring(toId))
        end
      end
    end
  end
  -- Детерминизм JSON: стабильный порядок рёбер по edge_id
  table.sort(rawEdges, function(x, y)
    return edgeIdOf(x.a, x.b) < edgeIdOf(y.a, y.b)
  end)

  -- Срез для example: СВЯЗНЫЙ подграф из 20 узлов (BFS от первого узла
  -- degree==2) — вариант (a), решение пользователя 2026-10-12. Раньше брались
  -- «первые 20 по id» — это давало ~45 «битых ссылок» на узлы вне среза
  -- (связный подграф отражает реальный граф).
  local exampleIdSet = {}
  local exampleNodes = {}
  do
    local function degreeOf(id)
      local c = 0
      for _ in pairs(adj[id] or {}) do c = c + 1 end
      return c
    end
    local startId = ids[1]
    for _, id in ipairs(ids) do
      if degreeOf(id) == 2 then startId = id break end
    end
    local queue = { startId }
    exampleIdSet[startId] = true
    local qi = 1
    while qi <= #queue and #queue < 20 do
      local cur = queue[qi]
      qi = qi + 1
      local nb = {}
      for toId in pairs(adj[cur] or {}) do nb[#nb + 1] = toId end
      table.sort(nb, cmpId)
      for _, toId in ipairs(nb) do
        if #queue >= 20 then break end
        if not exampleIdSet[toId] then
          exampleIdSet[toId] = true
          queue[#queue + 1] = toId
        end
      end
    end
  end

  -- === Проход B: узлы (degree — НЕОРИЕНТИРОВАННЫЙ, из adj) ===
  local nodeInfo = {} -- id -> {pos, degree, angle, sibs}
  local nodesArr = {}
  local isolatedCount = 0
  for _, id in ipairs(ids) do
    local n = nodesMap[id]
    local pos = n.pos
    if type(pos) ~= 'table' and type(pos) ~= 'cdata' then
      warn('узел без pos: id=' .. tostring(id))
      pos = nil -- страховка: ниже все обращения защищены проверкой pos
    end
    local sibs = {}
    for toId in pairs(adj[id] or {}) do sibs[#sibs + 1] = toId end
    table.sort(sibs, cmpId)
    local degree = #sibs

    -- angle_deg — ТОЛЬКО degree == 2 (схема): угол между v_in (prev→u)
    -- и v_out (u→to); порядок соседей не важен (симметрия угла)
    local angle = nil
    if degree == 2 then
      local a = nodesMap[sibs[1]] and nodesMap[sibs[1]].pos
      local b = nodesMap[sibs[2]] and nodesMap[sibs[2]].pos
      if a and b and pos then
        angle = angleBetweenDeg(vecSub(pos, a), vecSub(b, pos))
      end
      if angle == nil then
        warn('битая ссылка соседа у degree==2: id=' .. tostring(id))
      end
    end

    local typeStr, junction = nil, nil
    if degree == 0 then
      typeStr = 'isolated'
      isolatedCount = isolatedCount + 1
      warn('isolated: id=' .. tostring(id))
    elseif degree == 1 then
      typeStr = 'dead_end'
    elseif degree == 3 then
      typeStr, junction = 'fork', 'fork'
    elseif degree >= 4 then
      typeStr, junction = 'crossroads', 'crossroads'
    else -- degree == 2
      if angle and angle > conf.turn_angle_threshold_deg then
        typeStr = 'turn'
      else
        typeStr = 'straight'
      end
    end

    -- links[] — только degree >= 3 (схема): азимуты всех исходящих рёбер
    local linksArr = {}
    if degree >= 3 then
      for _, toId in ipairs(sibs) do
        local tn = nodesMap[toId]
        if tn and tn.pos and pos then
          linksArr[#linksArr + 1] = {
            edge_id = edgeIdOf(id, toId),
            to_id = tostring(toId),
            direction_deg = azimuthDeg(tn.pos.x - pos.x, tn.pos.y - pos.y),
          }
        end
      end
    end

    local out = {
      id = tostring(id),
      x = pos and pos.x or 0,
      y = pos and pos.y or 0,
      z = pos and pos.z or 0,
      type = typeStr,
      degree = degree,
      junction_type = junction or JSON_NULL,
      links = linksArr,
    }
    out.angle_deg = (degree == 2) and angle or JSON_NULL
    nodesArr[#nodesArr + 1] = out
    if exampleIdSet[id] then exampleNodes[#exampleNodes + 1] = out end

    nodeInfo[id] = { pos = pos, degree = degree, angle = angle, sibs = sibs }
  end

  -- === Проход C: рёбра (по сырым парам из прохода A; дедуп уже там) ===
  local edgesArr = {}
  local exampleEdges = {}
  local noRadius, noSpeed = 0, 0

  for _, re in ipairs(rawEdges) do
    local id, toId, edge = re.a, re.b, re.edge
    local eid = edgeIdOf(id, toId)
    local fi, ti = nodeInfo[id], nodeInfo[toId]
    if fi.pos == nil or ti.pos == nil then
      warn('ребро с узлом без pos: edge=' .. eid)
    else
      local pA = edgeEndPos(edge, id, fi.pos)
      local pB = edgeEndPos(edge, toId, ti.pos)
      local length = vecLen(vecSub(pB, pA))

      -- радиус: только если degree(from) == 2 — prev = второй сосед from
      local radius = nil
      if fi.degree == 2 then
        local prevId = (fi.sibs[1] == toId) and fi.sibs[2] or fi.sibs[1]
        local prevNode = nodesMap[prevId]
        if prevNode and prevNode.pos and fi.pos and ti.pos then
          radius = circumradius(prevNode.pos, fi.pos, ti.pos)
        end
      end
      if radius == nil then noRadius = noRadius + 1 end

      -- скорость: игровой лимит (м/с → км/ч) и физика sqrt(μ·g·R)
      local limitKph = nil
      if edge.speedLimit ~= nil then
        limitKph = floorToStep(edge.speedLimit * 3.6, conf.speed_round_kph)
      else
        noSpeed = noSpeed + 1
        warn('нет speedLimit: edge=' .. eid)
      end
      local physKph = nil
      if radius ~= nil then
        physKph = floorToStep(math.sqrt(conf.friction_mu * 9.81 * radius) * 3.6, conf.speed_round_kph)
      end
      local recKph = JSON_NULL
      if limitKph and physKph then recKph = math.min(limitKph, physKph)
      elseif limitKph then recKph = limitKph
      elseif physKph then recKph = physKph end

      local eOut = {
        edge_id = eid,
        from_id = tostring(id),
        to_id = tostring(toId),
        length_m = length,
        -- азимут from→to по pos узлов (схема): 0° = север (+Y), по часовой
        direction_deg = azimuthDeg(ti.pos.x - fi.pos.x, ti.pos.y - fi.pos.y),
        direction = edge.oneWay and 'one-way' or 'both',
        radius_m = radius or JSON_NULL,
        curvature = radius and (1 / radius) or JSON_NULL,
        speed_limit_kph = limitKph or JSON_NULL,
        recommended_speed_kph = recKph,
      }
      -- угол на входе/выходе (дубликаты nodes[].angle_deg, правка схемы)
      eOut.angle_from_deg = (fi.degree == 2) and fi.angle or JSON_NULL
      eOut.angle_to_deg = (ti.degree == 2) and ti.angle or JSON_NULL
      edgesArr[#edgesArr + 1] = eOut

      if exampleIdSet[id] and exampleIdSet[toId] then
        exampleEdges[#exampleEdges + 1] = eOut
      end
    end
  end

  -- === warnings: полный список в файл, в meta — максимум 10 (правка) ===
  if #warnings > 0 then
    local wf = io.open(GRAPH_DIR .. 'warnings.txt', 'w')
    if wf then
      wf:write(table.concat(warnings, '\r\n') .. '\r\n')
      wf:close()
    else
      logLine('WARN', 'Не удалось записать ' .. GRAPH_DIR .. 'warnings.txt')
    end
  end
  local metaWarnings = {}
  for i = 1, math.min(10, #warnings) do metaWarnings[i] = warnings[i] end
  if #warnings > 10 then
    metaWarnings[#metaWarnings + 1] = '... (ещё ' .. (#warnings - 10) .. ', полный список: ai/road/warnings.txt)'
  end

  local levelName = 'unknown'
  pcall(function()
    local li = getLevelInfo and getLevelInfo()
    if li then levelName = li.name or li.levelName or levelName end
  end)

  local data = {
    meta = {
      format_version = 1,
      created = os.date('%Y-%m-%d %H:%M:%S'),
      level = levelName,
      -- У3: build_serial — из АКТУАЛЬНОЙ структуры gm ПОСЛЕ возможного
      -- map.load() в гварде (не предыдущее значение)
      build_serial = tonumber(gm.buildSerial) or 0,
      mu = conf.friction_mu,
      node_count = #nodesArr,
      edge_count = #edgesArr,
      isolated_count = isolatedCount,
      warnings = metaWarnings,
    },
    nodes = nodesArr,
    edges = edgesArr,
  }

  local okW = jsonWriteFile(GRAPH_DIR .. 'graph.json', data, true)
  if not okW then
    print('ERROR apl_exportGraph: jsonWriteFile не смог записать ' .. GRAPH_DIR .. 'graph.json')
    return false
  end

  -- Пример формата: СВЯЗНЫЙ подграф из 20 узлов (BFS) + рёбра между ними —
  -- коммитится. meta example — полная копия meta графа + note: чекер --example
  -- требует mu/warnings и т.п., срез должен демонстрировать ВСЮ схему.
  do
    local exMeta = {}
    for k, v in pairs(data.meta) do exMeta[k] = v end
    exMeta.note = 'срез: связный подграф 20 узлов graph.json (BFS) для примера формата'
    jsonWriteFile(GRAPH_DIR .. 'graph.example.json', {
      meta = exMeta,
      nodes = exampleNodes,
      edges = exampleEdges,
    }, true)
  end

  -- === Отчёт в консоль (первые строки, как требовал пользователь) ===
  local total = #edgesArr
  local pct = total > 0 and math.floor(noRadius * 1000 / total + 0.5) / 10 or 0
  print('graph: узлов ' .. #nodesArr .. ', рёбер ' .. total)
  print('radius_m == null: ' .. noRadius .. ' (' .. tostring(pct) .. '%)')
  if pct > 50 then
    print('WARN: больше 50% рёбер без radius_m — это почти наверняка прямые (null по схеме), но проверь статистику в graph_check.py')
  end
  print('isolated: ' .. isolatedCount)
  if noSpeed > 0 then
    print('без speedLimit: ' .. noSpeed .. ' ребёр (WARN, speed_limit_kph = null)')
  end
  local real = ''
  pcall(function() real = FS:getFileRealPath(GRAPH_DIR .. 'graph.json') or '' end)
  print('graph.json: ' .. (real ~= '' and real or (GRAPH_DIR .. 'graph.json')))
  logLine('INFO', string.format('Граф экспортирован: узлов %d, рёбер %d, isolated %d, без radius %d (%.1f%%)',
    #nodesArr, total, isolatedCount, noRadius, pct))
  return true
end

-- apl_mark("комментарий") — метка в ai/road/marks.csv (шаг 2.5).
-- Схема: graph_schema.md, раздел «Файл меток» (8 колонок). Привязка к графу:
-- ближайший узел (перебор map.nodes, min евклидовой дистанции) + ребро через
-- map.findClosestRoad(pos) → edge_id в формате min_max как в graph.json.
local MARKS_CSV = GRAPH_DIR .. 'marks.csv'
local MARKS_HEADER = 'time,x,y,z,comment,nearest_node_id,node_dist_m,edge_id'

-- Экранирование CSV-поля: всегда в кавычках, внутренние кавычки удваиваем
local function csvQuote(s)
  return '"' .. tostring(s):gsub('"', '""') .. '"'
end

-- Число в CSV: точка как разделитель независимо от локали C-runtime игры
local function csvNum(v, digits)
  if v == nil or v ~= v then return '' end
  local s = string.format('%.' .. digits .. 'f', v)
  return (s:gsub(',', '.'))
end

-- === Фаза 6 (шаг 6.3): игровое время — живёт ТОЛЬКО в GE (в electrics его нет,
-- api_research_phase6.md §2) ===
-- core_environment.getTimeOfDay().time — доля суток 0..1, 0 = полдень
-- (обратная конвертация в ванили: ge_utils.lua:706 setTimeOfDay);
-- ЧЧ = ((time + 0.5) % 1) * 24 — та же формула у ge_utils.lua:679.
local function gameTodHours()
  local ok, tod = pcall(function()
    if core_environment == nil or core_environment.getTimeOfDay == nil then return nil end
    return core_environment.getTimeOfDay()
  end)
  if not ok or type(tod) ~= 'table' or tonumber(tod.time) == nil then return nil end
  local h = ((tonumber(tod.time) + 0.5) % 1) * 24
  if h ~= h or h < 0 or h >= 24 then return nil end -- NaN/границы
  return h
end

-- "ЧЧ:ММ" из игрового времени или nil (вне миссии/меню времени нет)
local function gameTodString()
  local h = gameTodHours()
  if h == nil then return nil end
  local hh = math.floor(h)
  local mm = math.floor((h - hh) * 60)
  if mm > 59 then mm = 59 end -- страховка от плавающей границы
  return string.format('%02d:%02d', hh, mm)
end

function apl_mark(comment)
  comment = comment ~= nil and tostring(comment) or ''

  -- Фаза 6 (шаг 6.3): автодополнение игровым временем «[ЧЧ:ММ]» — игрок
  -- калибрует световые окна lights_by_map.json по меткам: apl_mark("тут
  -- темнеет") → comment="тут темнеет [19:45]". Время читаем в GE
  -- (gameTodString, core_environment); запись marks.csv идёт здесь же в GE.
  do
    local todStr = gameTodString()
    if todStr then
      comment = comment ~= '' and (comment .. ' [' .. todStr .. ']') or ('[' .. todStr .. ']')
    else
      print('WARN apl_mark: игровое время недоступно — метка без [ЧЧ:ММ]')
    end
  end

  local veh = getPlayerVehicle(0)
  if not veh then
    print('WARN apl_mark: машина игрока не найдена')
    return false
  end
  local pos = veh:getPosition()
  if pos == nil then
    print('WARN apl_mark: у машины игрока нет позиции')
    return false
  end

  -- Доступ к графу ТОЛЬКО через map.getMap() (У1, 2026-10-12); map.load() не
  -- зовём: findClosestRoad ниже работает по kd-дереву, которое к моменту
  -- консоли уже построено (диагностика 2.7a: 5439 узлов на East Coast).
  local okMap, gm = pcall(map.getMap)
  if not okMap or type(gm) ~= 'table' or type(gm.nodes) ~= 'table' or next(gm.nodes) == nil then
    print('WARN apl_mark: граф недоступен (map.getMap() пуст) — метка без привязки невозможна')
    return false
  end
  local nodesMap = gm.nodes

  -- Ближайший узел: перебор map.nodes (min евклидовой дистанции)
  local bestId, bestDist = nil, nil
  for id, n in pairs(nodesMap) do
    if n.pos then
      local dx, dy, dz = n.pos.x - pos.x, n.pos.y - pos.y, n.pos.z - pos.z
      local d = math.sqrt(dx * dx + dy * dy + dz * dz)
      if bestDist == nil or d < bestDist then
        bestId, bestDist = id, d
      end
    end
  end

  -- Ребро: map.findClosestRoad(pos) → (n1id, n2id, dist) или nil (map.lua:2691).
  -- Вызов через замыкание (У1: поле не читаем напрямую, только вызов).
  local edgeStr = ''
  local okFc, n1, n2 = pcall(function() return map.findClosestRoad(pos) end)
  if okFc and n1 and n2 then
    edgeStr = edgeIdOf(n1, n2) -- тот же формат min_max, что в graph.json
  else
    print('WARN apl_mark: map.findClosestRoad не вернул ребро — edge_id пуст')
  end

  -- Запись: путь относительный (sandbox io.open), шапка при первом добавлении
  pcall(function() FS:directoryCreate(GRAPH_DIR, true) end)
  local isNew = true
  do
    local probe = io.open(MARKS_CSV, 'r')
    if probe then
      probe:close()
      isNew = false
    end
  end
  local f = io.open(MARKS_CSV, 'a')
  if not f then
    print('ERROR apl_mark: не удалось открыть ' .. MARKS_CSV .. ' на запись')
    return false
  end
  if isNew then
    f:write(MARKS_HEADER .. '\r\n')
  end
  f:write(os.date('%Y-%m-%d %H:%M:%S') .. ',' ..
    csvNum(pos.x, 3) .. ',' .. csvNum(pos.y, 3) .. ',' .. csvNum(pos.z, 3) .. ',' ..
    csvQuote(comment) .. ',' ..
    (bestId and tostring(bestId) or '') .. ',' ..
    csvNum(bestDist, 2) .. ',' ..
    edgeStr .. '\r\n')
  f:close()

  local real = ''
  pcall(function() real = FS:getFileRealPath(MARKS_CSV) or '' end)
  print('метка: узел=' .. (bestId and tostring(bestId) or 'нет') ..
    ' (' .. (bestDist and string.format('%.1f м', bestDist) or '?') .. '), ребро=' ..
    (edgeStr ~= '' and edgeStr or 'нет'))
  print('marks.csv: ' .. (real ~= '' and real or MARKS_CSV))
  logLine('INFO', 'apl_mark: узел=' .. tostring(bestId) ..
    ' дист=' .. tostring(bestDist) .. ' ребро=' .. (edgeStr ~= '' and edgeStr or 'нет'))
  return true
end

-- === Фаза 2 (шаг 2.7a): диагностика навиграфа ===
-- apl_mapDiag() — временная команда (как apl_diag в Фазе 1): печатает
-- состояние навиграфа, НИЧЕГО не чинит.
-- Найдено по исходникам ПЕРЕД написанием: глобальное имя расширения `map` —
-- это таблица API модуля (M), у НЕЁ нет поля nodes; структура с узлами —
-- локальная переменная модуля (map.lua:25 `local map = {nodes = {}}`),
-- наружу её отдаёт map.getMap() (map.lua:3793-3795); deprecated-ветка
-- map.map (4001-4012) — только для ключа 'map'. Ленивая загрузка:
-- map.load() = Mload с флагом loadedMap (map.lua:3642-3646), сброс флага —
-- onMissionLoaded. Источники навиграфа: DecalRoad сцены (map.lua:587+)
-- + map.json «manual road segments» (map.lua:786-795, отсутствие файла —
-- не ошибка, просто без manual-сегментов).
function apl_mapDiag()
  local function countNodes(t)
    if type(t) ~= 'table' then return -1 end
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
  end

  print('--- apl_mapDiag: навиграф ---')

  -- 1. Уровень
  local missionFn = ''
  pcall(function() missionFn = getMissionFilename() or '' end)
  print('mission: ' .. (missionFn ~= '' and missionFn or '(getMissionFilename недоступен)'))
  local levelDir = missionFn:match('^(.*[/\\])') or ''
  print('levelDir: ' .. (levelDir ~= '' and levelDir or '(не вычислен)'))

  -- 2. API модуля map (что доступно из GE-контекста).
  -- Чтение полей здесь НАМЕРЕННОЕ (отчёт диагностики): показываем тип поля,
  -- в рабочем коде поля читать нельзя — только вызовы (У1).
  print('map API: type=' .. type(map) ..
    ', getMap(поле)=' .. tostring(type(map) == 'table' and type(map.getMap) or 'nil') ..
    ', findClosestRoad(поле)=' .. tostring(type(map) == 'table' and type(map.findClosestRoad) or 'nil') ..
    ', load(поле)=' .. tostring(type(map) == 'table' and type(map.load) or 'nil'))

  -- 3. Прямой доступ map.nodes — ровно то, что использовал apl_exportGraph
  local directNodes = nil
  pcall(function() directNodes = map and map.nodes end)
  print('map.nodes (прямой доступ): ' .. tostring(directNodes) ..
    '  <-- если nil: nodes не поле API, нужен map.getMap()')

  -- 4. map.getMap().nodes ДО ручной загрузки
  local gm = nil
  pcall(function() gm = map.getMap() end)
  local nodesBefore = type(gm) == 'table' and gm.nodes or nil
  print('nodes ДО map.load(): ' .. countNodes(nodesBefore) ..
    ' узлов (buildSerial=' .. tostring(type(gm) == 'table' and gm.buildSerial or '?') .. ')')

  -- 5. map.json (дополнительный источник manual segments, map.lua:786-795)
  local mapJson = levelDir .. 'map.json'
  local exists, size = nil, nil
  pcall(function() exists = FS:fileExists(mapJson) end)
  if exists then
    pcall(function()
      local f = io.open(mapJson, 'r')
      if f then
        local content = f:read('*all') or ''
        f:close()
        size = #content
      end
    end)
  end
  print('map.json (' .. mapJson .. '): exists=' .. tostring(exists) ..
    (exists and (', байт=' .. tostring(size)) or ''))
  print('  (map.json — ДОПОЛНИТЕЛЬНЫЙ источник manual road segments;' ..
    ' основной навиграф — DecalRoad сцены, map.lua:587+)')

  -- 6. findClosestRoad от позиции игрока (kd-дерево создаётся в loadMap);
  -- вызов через замыкание (У1: поле не читаем напрямую)
  local veh = getPlayerVehicle(0)
  if veh then
    local pos = veh:getPosition()
    local ok, n1, n2, dist = pcall(function() return map.findClosestRoad(pos) end)
    if ok and n1 and n2 then
      print(string.format('findClosestRoad(pos игрока): n1=%s n2=%s dist=%.2f м',
        tostring(n1), tostring(n2), dist or -1))
    else
      print('findClosestRoad(pos игрока): nil (kd-дерева нет — карта не построена?)')
    end
  else
    print('findClosestRoad: машина игрока не найдена — пропущено')
  end

  -- 7. Ручная ленивая загрузка: map.load() — no-op, если уже загружено
  local okLoad, err = pcall(function() map.load() end)
  print('map.load(): ' .. (okLoad and 'вызван' or ('ОШИБКА: ' .. tostring(err))))
  pcall(function() gm = map.getMap() end)
  local nodesAfter = type(gm) == 'table' and gm.nodes or nil
  print('nodes ПОСЛЕ map.load(): ' .. countNodes(nodesAfter) ..
    ' узлов (buildSerial=' .. tostring(type(gm) == 'table' and gm.buildSerial or '?') .. ')')

  print('--- конец диагностики ---')
  logLine('INFO', 'apl_mapDiag: после map.load() узлов ' .. countNodes(nodesAfter))
  return true
end

-- === Консольные команды ===
-- GE-Lua контекст консоли исполняет строку как Lua-код (windowsConsole.lua:13-14),
-- поэтому объявляем глобальные функции с префиксом apl_ (решение пользователя).
-- === Фаза 6 (шаг 6.4): автофары день/ночь ===
-- GE владеет: время (core_environment — только GE, electrics времени не даёт),
-- карта (getCurrentLevelIdentifier), guard pop-up (veh.JBeam) и гистерезисом —
-- и шлёт vehicle ЧИСЛОВОЙ target. Vehicle (autopilotLiveLights.lua) применяет
-- electrics.setLightsState с guard «без дёрганья» и присылает
-- onVehicleLightsAutoOff при ручном вмешательстве игрока (§7.4).
-- Включает auto ТОЛЬКО игрок: apl_lights("auto"|"far"|"near"|"off"|"status").
local LIGHTS_CONF = 'mods/unpacked/AutopilotLive/ai/config/lights.json'
local LIGHTS_MAP_CONF = 'mods/unpacked/AutopilotLive/ai/config/lights_by_map.json'
-- Фаза 7: конфиг «Погладить» (паттерн lights: DEFAULTS = дубль файла)
local PET_CONF = 'mods/unpacked/AutopilotLive/ai/config/pet.json'
-- Фаза 8: конфиг pop-up фар (паттерн lights/pet: DEFAULTS = дубль файла)
local POPUP_CONF = 'mods/unpacked/AutopilotLive/ai/config/popup.json'
-- Фаза 9.1: «Система Боли» — авто-восстановление
local PAIN_CONF = 'mods/unpacked/AutopilotLive/ai/config/pain.json'
-- Фаза 10.1: мастер-переключатель
local MASTER_CONF = 'mods/unpacked/AutopilotLive/ai/config/master.json'

local lightsAuto = false     -- auto включён (только командой игрока)
local lightsTarget = nil     -- последний отправленный vehicle target (0/1/2)
local lightsAcc = 0          -- аккумулятор опроса времени, сек
local lightsCfg = nil        -- кэш конфига (перечитывается при каждом auto/status)
local lightsWindow = nil     -- применённое окно {start=, ['end']=} строками ЧЧ:ММ
local lightsIsNight = nil    -- состояние гистерезиса (nil — не инициализировано)
-- Фаза 7б (правки после теста 3): звук — ПОВТОРЯЮЩИЙСЯ playOnce с позицией
-- машины (createSource-луп не слышался). Каждые interval_s сек playOnce
-- 'AudioGui' c {volume, pitch, position} → наложение (оверлап) звуков даёт
-- непрерывное урчание. no_pos — фолбэк: играть БЕЗ позиции (глобально),
-- чтобы проверить, слышен ли сам файл.
local petSoundEvent = ''     -- FMOD-событие из pet.json ('' — без звука)
local petSoundActive = false -- звук идёт (true между start и stop)
local petSoundPitch = 0.7    -- питч каждой пачки (playOnce штатно умеет)
local petSoundBaseVol = 2.0  -- базовая громкость из конфига
local petSoundInterval = 0.5 -- период playOnce, сек (оверлап)
local petSoundNoPos = false  -- true — играть без позиции (глобально, отладка)
local petSoundBreathHz = 0.3 -- частота «дыхания» громкости
local petSoundBreathDepth = 0.25 -- глубина «дыхания» (0..1)
local petSoundT = 0          -- время звука, сек (для дыхания)
local petSoundTickAcc = 0    -- аккумулятор playOnce, сек
local petSoundIds = {}       -- sourceId играющих пачек (для мгновенного стопа)
local petSoundPosWarned = false -- WARN про позицию выведен
local petSoundResolved = nil  -- рабочий путь 'file:...'/event (кэш, 24.10)
local petActive = false       -- поглаживание активно (для меню/статуса)

-- Мгновенная остановка: удаляем все играющие пачки playOnce (идемпотентно)
local function petSoundStop()
  if not petSoundActive and #petSoundIds == 0 then return end
  petSoundActive = false
  for _, id in ipairs(petSoundIds) do
    pcall(function() Engine.Audio.deleteSource(id) end)
  end
  petSoundIds = {}
  petSoundPosWarned = false
  logLine('INFO', 'pet sound: стоп (все пачки удалены)')
end

-- Старт звука: первая playOnce — сразу, дальше каждые interval_s (onUpdate)
local function petSoundStart()
  petSoundStop() -- страховка от двойного запуска
  petSoundResolved = nil -- событие могло смениться — путь пере-резолвим
  if petSoundEvent == '' then return end
  petSoundActive = true
  petSoundT = 0
  petSoundTickAcc = petSoundInterval -- playOnce случится на ближайшем тике
  print('apl_pet: звук мурчания — playOnce каждые ' ..
    string.format('%.2f', petSoundInterval) .. ' с (оверлап), volume ' ..
    string.format('%.2f', petSoundBaseVol) .. ', питч ' ..
    string.format('%.2f', petSoundPitch) ..
    (petSoundNoPos and ', БЕЗ позиции (фолбэк)' or ', позиция=машина'))
  logLine('INFO', 'pet sound: старт (' .. petSoundEvent .. ', every ' ..
    string.format('%.2f', petSoundInterval) .. 's, vol ' ..
    string.format('%.2f', petSoundBaseVol) ..
    (petSoundNoPos and ', no_pos' or ', pos=vehicle') .. ')')
end

-- === Дефолты конфига (ДУБЛЬ lights.json — ТОЛЬКО fallback; истина — файл) ===
-- night_state: дефолт 1 (ближний); значение 2 в файле читается и включает по
-- ночам дальний (правка координатора 18.10). В auto сам НИКОГДА не включаем
-- дальний — только через night_state либо вручную apl_lights("far").
local LIGHTS_DEFAULTS = {
  timing = { poll_hz = 1, hysteresis_min = 15 },
  modes = { day_state = 1, night_state = 1 },
  night_window = { start = '20:00', ['end'] = '07:00' },
}

-- "ЧЧ:ММ" → часы float (0..24); допускается число/числовой строка. nil — кривизна.
local function parseHHMM(v)
  if type(v) == 'number' then
    if v == v and v >= 0 and v < 24 then return v end
    return nil
  end
  if type(v) ~= 'string' then return nil end
  local h, m = v:match('^(%d%d?):(%d%d)$')
  if h then
    h, m = tonumber(h), tonumber(m)
    if h >= 0 and h < 24 and m >= 0 and m <= 59 then return h + m / 60 end
    return nil
  end
  local n = tonumber(v)
  if n and n == n and n >= 0 and n < 24 then return n end
  return nil
end

local function norm24(v)
  v = v % 24
  if v < 0 then v = v + 24 end
  return v
end

-- Часы в ночном окне [s, e): s > e — окно через полночь (РФ 20:00→07:00).
local function inNightWindow(h, s, e)
  if s == nil or e == nil or s == e then return false end
  if s < e then return h >= s and h < e end
  return h >= s or h < e
end

local function readJsonFile(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*all')
  f:close()
  local ok, decoded = pcall(jsonDecode, content, path)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
end

-- Загрузка lights.json + lights_by_map.json с merge DEFAULTS (паттерн warmup):
-- числа зажимаются валидацией; state-поля — целые 0..2 (night_state 1..2,
-- «0» зажмётся в дефолт 1), окно — строки "ЧЧ:ММ".
local function loadLightsConfig()
  local D = LIGHTS_DEFAULTS
  local c = {
    timing = { poll_hz = D.timing.poll_hz, hysteresis_min = D.timing.hysteresis_min },
    modes = { day_state = D.modes.day_state, night_state = D.modes.night_state },
    night_window = { start = D.night_window.start, ['end'] = D.night_window['end'] },
    maps = {},
    fromFile = false,
  }

  local decoded = readJsonFile(LIGHTS_CONF)
  if decoded then
    c.fromFile = true
    local function clampNum(gr, key, lo, hi, dflt)
      local v = type(decoded[gr]) == 'table' and tonumber(decoded[gr][key]) or nil
      if v == nil or v ~= v then return dflt end
      if v < lo then return lo end
      if v > hi then return hi end
      return v
    end
    c.timing.poll_hz = clampNum('timing', 'poll_hz', 0.1, 10, D.timing.poll_hz)
    c.timing.hysteresis_min = clampNum('timing', 'hysteresis_min', 0, 120, D.timing.hysteresis_min)
    c.modes.day_state = clampNum('modes', 'day_state', 0, 2, D.modes.day_state)
    c.modes.night_state = clampNum('modes', 'night_state', 1, 2, D.modes.night_state)
    if type(decoded.night_window) == 'table' then
      if parseHHMM(decoded.night_window.start) then
        c.night_window.start = tostring(decoded.night_window.start)
      end
      if parseHHMM(decoded.night_window['end']) then
        c.night_window['end'] = tostring(decoded.night_window['end'])
      end
    end
  else
    logLine('WARN', 'lights: конфиг не найден/бит (' .. LIGHTS_CONF .. ') — дефолты кода')
  end

  local decodedMap = readJsonFile(LIGHTS_MAP_CONF)
  if decodedMap and type(decodedMap.maps) == 'table' then
    for id, entry in pairs(decodedMap.maps) do
      if type(id) == 'string' and type(entry) == 'table' and type(entry.night_window) == 'table'
        and parseHHMM(entry.night_window.start) and parseHHMM(entry.night_window['end']) then
        c.maps[id:lower()] = {
          start = tostring(entry.night_window.start),
          ['end'] = tostring(entry.night_window['end']),
        }
      end
    end
  end

  if parseHHMM(c.night_window.start) == parseHHMM(c.night_window['end']) then
    logLine('WARN', 'lights: start окна == end — ночное окно пустое, ночь никогда не наступит')
  end
  return c
end

-- === Фаза 7: конфиг «Погладить» (ДУБЛЬ pet.json — ТОЛЬКО fallback) ===
-- Истина — файл; числа клампятся, sound_event — строка ('' — без звука).
-- Правки после теста 3 18.10: газ ЛЁГКИЙ (0.05±0.05 → 0..0.1, тормоз НЕ
-- используем — brakeOverride сломал физику), фиксация — ручник (vehicle),
-- звук — playOnce-оверлап каждые interval_s с позицией машины + «дыхание»
-- громкости, no_pos — фолбэк без позиции (проверка слышимости файла).
local PET_DEFAULTS = {
  duration_s = 6.0,
  throttle = { offset = 0.05, amp = 0.05, hz = 2.5 },
  steer_rate_scale = 0.5,
  sound = {
    sound_event = '', pitch = 0.7, interval_s = 0.5,
    breath_hz = 0.3, breath_depth = 0.25, volume = 2.0, no_pos = false,
  },
  cooldown = { speed_gate_kph = 5.0, spam_max = 4, spam_window_s = 30.0, cooldown_s = 20.0 },
}

local function loadPetConfig()
  local D = PET_DEFAULTS
  local c = {
    duration_s = D.duration_s,
    offset = D.throttle.offset, amp = D.throttle.amp, hz = D.throttle.hz,
    steer_rate_scale = D.steer_rate_scale,
    sound_event = D.sound.sound_event,
    pitch = D.sound.pitch, sound_interval = D.sound.interval_s,
    breath_hz = D.sound.breath_hz,
    breath_depth = D.sound.breath_depth, sound_volume = D.sound.volume,
    sound_no_pos = D.sound.no_pos,
    speed_gate_kph = D.cooldown.speed_gate_kph,
    spam_max = D.cooldown.spam_max, spam_window_s = D.cooldown.spam_window_s,
    cooldown_s = D.cooldown.cooldown_s,
    fromFile = false,
  }
  local decoded = readJsonFile(PET_CONF)
  if decoded then
    c.fromFile = true
    local function clampNum(gr, key, lo, hi, dflt)
      local v = type(decoded[gr]) == 'table' and tonumber(decoded[gr][key]) or nil
      if v == nil or v ~= v then return dflt end
      if v < lo then return lo end
      if v > hi then return hi end
      return v
    end
    local function clampTop(key, lo, hi, dflt) -- поле верхнего уровня файла
      local v = tonumber(decoded[key])
      if v == nil or v ~= v then return dflt end
      if v < lo then return lo end
      if v > hi then return hi end
      return v
    end
    c.duration_s = clampTop('duration_s', 1, 60, D.duration_s)
    c.offset = clampNum('throttle', 'offset', 0, 0.3, D.throttle.offset)
    c.amp = clampNum('throttle', 'amp', 0, 0.3, D.throttle.amp)
    c.hz = clampNum('throttle', 'hz', 0.05, 10, D.throttle.hz)
    c.steer_rate_scale = clampTop('steer_rate_scale', 0.1, 1, D.steer_rate_scale)
    c.pitch = clampNum('sound', 'pitch', 0.2, 3, D.sound.pitch)
    c.sound_interval = clampNum('sound', 'interval_s', 0.05, 10, D.sound.interval_s)
    c.breath_hz = clampNum('sound', 'breath_hz', 0, 5, D.sound.breath_hz)
    c.breath_depth = clampNum('sound', 'breath_depth', 0, 1, D.sound.breath_depth)
    c.sound_volume = clampNum('sound', 'volume', 0, 3, D.sound.volume) -- 2.0 допустимо
    if type(decoded.sound) == 'table' and type(decoded.sound.no_pos) == 'boolean' then
      c.sound_no_pos = decoded.sound.no_pos
    end
    if type(decoded.sound) == 'table' and type(decoded.sound.sound_event) == 'string' then
      c.sound_event = decoded.sound.sound_event
    end
    c.speed_gate_kph = clampNum('cooldown', 'speed_gate_kph', 0, 120, D.cooldown.speed_gate_kph)
    c.spam_max = clampNum('cooldown', 'spam_max', 1, 50, D.cooldown.spam_max)
    c.spam_window_s = clampNum('cooldown', 'spam_window_s', 1, 600, D.cooldown.spam_window_s)
    c.cooldown_s = clampNum('cooldown', 'cooldown_s', 0, 600, D.cooldown.cooldown_s)
  else
    logLine('WARN', 'pet: конфиг не найден/бит (' .. PET_CONF .. ') — дефолты кода')
  end
  -- Звук выключен, если событие пустое ИЛИ интервал 0
  if c.sound_event == '' or c.sound_interval <= 0 then c.sound_interval = 0 end
  return c
end

local function playerJBeam(veh)
  local ok, j = pcall(function() return veh.JBeam end)
  if ok and type(j) == 'string' then return j:lower() end
  return nil
end

local function currentMapId()
  local ok, id = pcall(function()
    if getCurrentLevelIdentifier == nil then return nil end
    return getCurrentLevelIdentifier()
  end)
  if ok and type(id) == 'string' and id ~= '' then return id end
  return nil
end

-- Выбор окна: lights_by_map.json (maps.<level_id>) → иначе РФ-дефолт lights.json
-- (вопрос 5 координатора: дефолт РФ для всех карт, кроме явно прописанных).
local function windowForCurrentMap(cfg)
  local mapId = currentMapId()
  local mw = mapId and cfg.maps[mapId:lower()] or nil
  if mw then
    return { start = mw.start, ['end'] = mw['end'] }, mapId, true
  end
  return { start = cfg.night_window.start, ['end'] = cfg.night_window['end'] }, mapId, false
end

-- Вычисление target по времени с гистерезисом ±hysteresis_min (Шмитт-триггер,
-- §7.3): день→ночь — как только часы вошли в окно; ночь→день — только когда
-- вышли из окна, РАСШИРЁННОГО на ±hyst (в полосе держим прежнее состояние —
-- на границе фары не мигают). Возвращает: target (целое 0/1/2), transition
-- ('night'/'day'/nil — смена флага), часы; либо nil (времени нет).
local function computeLightsTarget(cfg, window)
  local h = gameTodHours()
  if h == nil then return nil end
  local ws = parseHHMM(window.start)
  local we = parseHHMM(window['end'])
  if ws == nil or we == nil then return nil end
  local hyst = (cfg.timing.hysteresis_min or 0) / 60
  local inW = inNightWindow(h, ws, we)
  local inExp = inNightWindow(h, norm24(ws - hyst), norm24(we + hyst))
  local was = lightsIsNight
  if was == nil then
    lightsIsNight = inW -- инициализация при включении auto — по текущему времени
  elseif was then
    if not inExp then lightsIsNight = false end
  else
    if inW then lightsIsNight = true end
  end
  local t = lightsIsNight and cfg.modes.night_state or cfg.modes.day_state
  t = math.floor(t + 0.5) -- state — всегда целое 0/1/2
  local trans = nil
  if was ~= nil and was ~= lightsIsNight then
    trans = lightsIsNight and 'night' or 'day'
  end
  return t, trans, h
end

function apl_lights(mode, value)
  mode = tostring(mode or ''):lower()
  if mode == 'auto' then
    local veh = getVehicle()
    if not veh then
      print('WARN apl_lights: машина игрока не найдена')
      return false
    end
    local cfg = loadLightsConfig()
    local window, mapId, fromMap = windowForCurrentMap(cfg)
    lightsCfg = cfg
    lightsWindow = window
    lightsIsNight = nil -- пересчёт гистерезиса с нуля по текущему времени
    local t = computeLightsTarget(cfg, window)
    if t == nil then
      print('WARN apl_lights: игровое время недоступно — auto не включён')
      logLine('WARN', 'lights auto refused: core_environment.getTimeOfDay() недоступно')
      return false
    end
    if sendToVehicle(string.format('autopilotLiveLightsCmd.autoOn(%d)', t)) then
      lightsAuto = true
      lightsTarget = t
      lightsAcc = 0
      print('apl_lights: AUTO ON — время ' .. (gameTodString() or '?') ..
        ', окно ' .. window.start .. '-' .. window['end'] ..
        (fromMap and (' (карта ' .. tostring(mapId) .. ', из lights_by_map.json)') or ' (РФ-дефолт)') ..
        ' → ' .. (lightsIsNight and 'НОЧЬ' or 'ДЕНЬ') .. ', target=' .. tostring(t) ..
        ' (0=выкл,1=ближний,2=дальний), конфиг=' .. (cfg.fromFile and 'файл' or 'ДЕФОЛТЫ'))
      print('apl_lights: выключение — apl_lights("off"); статус — apl_lights("status")')
      logLine('INFO', 'lights auto ON: map=' .. tostring(mapId) .. ' window=' .. window.start .. '-' .. window['end'] ..
        ' target=' .. tostring(t) .. ' night=' .. tostring(lightsIsNight))
    end
    return true
  elseif mode == 'far' or mode == 'near' or mode == 'off' then
    local st = mode == 'far' and 2 or (mode == 'near' and 1 or 0)
    if sendToVehicle(string.format('autopilotLiveLightsCmd.setManual(%d)', st)) then
      lightsAuto = false
      lightsTarget = nil
      lightsIsNight = nil
      local names = { [0] = 'выкл', [1] = 'ближний', [2] = 'дальний' }
      print('apl_lights: ' .. mode:upper() .. ' → state ' .. st .. ' (' .. names[st] .. ')')
      logLine('INFO', 'lights manual: mode=' .. mode .. ' state=' .. st)
    end
    return true
  elseif mode == 'night_state' or mode == 'day_state' then
    -- Быстрая правка конфига из игры (разрешение координатора 18.10):
    -- apl_lights("night_state", 2) — пишет значение в modes lights.json и,
    -- если auto включён, применяет target к машине сразу (без правки файла
    -- в блокноте). Диапазон — как clamp в loadLightsConfig: night 1..2,
    -- day 0..2. Сам auto дальний сам НИКОГДА не включает — только это
    -- значение из файла (гистерезис не трогаем, lightsIsNight сохраняется).
    local key = mode
    local lo = key == 'night_state' and 1 or 0
    local v = tonumber(value)
    if v == nil or v ~= v or v ~= math.floor(v) or v < lo or v > 2 then
      print('Использование: apl_lights("' .. key .. '", ' .. lo .. '..2) — 0=выкл, 1=ближний, 2=дальний')
      return false
    end
    local decoded = readJsonFile(LIGHTS_CONF)
    if not decoded then
      print('ERROR apl_lights: ' .. LIGHTS_CONF .. ' не найден/бит — восстановите файл мода')
      return false
    end
    if type(decoded.modes) ~= 'table' then decoded.modes = {} end
    decoded.modes[key] = v
    if not jsonWriteFile(LIGHTS_CONF, decoded, true) then
      print('ERROR apl_lights: не удалось записать ' .. LIGHTS_CONF)
      logLine('WARN', 'lights config write failed: ' .. key .. '=' .. tostring(v))
      return false
    end
    print('apl_lights: ' .. key .. '=' .. v .. ' сохранён в lights.json')
    if lightsAuto and lightsWindow ~= nil then
      lightsCfg = loadLightsConfig() -- перечитать то, что реально записалось
      local t = computeLightsTarget(lightsCfg, lightsWindow)
      if t ~= nil and t ~= lightsTarget then
        if sendToVehicle(string.format('autopilotLiveLightsCmd.setTarget(%d)', t)) then
          lightsTarget = t
          print('apl_lights: target → ' .. tostring(t) .. ' (0=выкл,1=ближний,2=дальний), применено к машине')
          logLine('INFO', 'lights config: ' .. key .. '=' .. v .. ', auto target → ' .. tostring(t))
        end
      else
        logLine('INFO', 'lights config: ' .. key .. '=' .. v .. ' (auto target без изменений)')
      end
    else
      print('apl_lights: auto выключен — значение применится при следующем apl_lights("auto")')
      logLine('INFO', 'lights config: ' .. key .. '=' .. v .. ' (auto выключен)')
    end
    return true
  elseif mode == 'status' then
    local cfg = loadLightsConfig() -- свежая копия: правки JSON видны сразу
    local window, mapId, fromMap = windowForCurrentMap(cfg)
    print('apl_lights GE: auto=' .. tostring(lightsAuto) .. ', target=' .. tostring(lightsTarget))
    print('  карта=' .. tostring(mapId or '?') ..
      (fromMap and ' (окно из lights_by_map.json)' or ' (окно РФ-дефолт из lights.json)'))
    print('  игровое время=' .. (gameTodString() or 'н/д') ..
      ', окно=' .. window.start .. '-' .. window['end'] ..
      ', гистерезис±' .. tostring(cfg.timing.hysteresis_min) .. ' мин, опрос ' ..
      tostring(cfg.timing.poll_hz) .. ' Гц')
    print('  day_state=' .. tostring(cfg.modes.day_state) ..
      ', night_state=' .. tostring(cfg.modes.night_state) ..
      ' (0=выкл,1=ближний,2=дальний), конфиг=' .. (cfg.fromFile and 'файл' or 'ДЕФОЛТЫ'))
    if not sendToVehicle('autopilotLiveLightsCmd.status()') then
      print('WARN apl_lights: машина игрока не найдена — статус vehicle-слоя недоступен')
    end
    return true
  end
  print('Использование: apl_lights("auto") | apl_lights("far") | apl_lights("near") | apl_lights("off") | apl_lights("status")')
  print('  быстрая правка конфига: apl_lights("night_state", 1|2) или apl_lights("day_state", 0|1|2) — пишет в lights.json и применяет')
  return false
end

-- === Фаза 7 (2026-10-18): «Погладить» — apl_pet("on"|"off"|"status") ===
-- GE владеет: конфигом pet.json, звуковым лупом (Engine.Audio — только GE,
-- с позицией машины). Vehicle владеет: таймлайном эффекта, рулём (rateScale),
-- guard'ами скорости/спама. ФИЗИКА НЕ ТРОГАЕТСЯ (педали убраны после провала).
function apl_pet(mode)
  mode = tostring(mode or ''):lower()
  if mode == 'on' then
    local veh = getVehicle()
    if not veh then
      print('WARN apl_pet: машина игрока не найдена')
      return false
    end
    local cfg = loadPetConfig()
    local cmd = string.format(
      'autopilotLivePetCmd.start({duration=%.2f, offset=%.3f, amp=%.3f, hz=%.3f, ' ..
      'rateScale=%.2f, speedGateKph=%.1f, spamMax=%d, spamWindow=%.1f, cooldown=%.1f, ' ..
      'soundEvent="%s", soundInterval=%.2f, soundVolume=%.2f})',
      cfg.duration_s, cfg.offset, cfg.amp, cfg.hz, cfg.steer_rate_scale,
      cfg.speed_gate_kph, cfg.spam_max, cfg.spam_window_s, cfg.cooldown_s,
      (cfg.sound_event or ''):gsub('"', '\\"'), cfg.sound_interval, cfg.sound_volume)
    if sendToVehicle(cmd) then
      -- Звук теперь в Vehicle-слое (obj:createSFXSource/playSFX, 24.10):
      -- GE playOnce не умеет кастомные .ogg (нет SFX-профиля).
      petSoundEvent = cfg.sound_event
      petSoundActive = false
      petActive = true
      -- Звук: ОДИН playOnce (файл 10 с > 6 с петмода). Рабочий путь — чистый
      -- VFS без file: и без ведущего слэша (проверено: art/sound/apl_pet.wav).
      if cfg.sound_event ~= '' then
        local okSnd, resSnd = pcall(function()
          return Engine.Audio.playOnce('AudioGui', cfg.sound_event,
            { volume = cfg.sound_volume, pitch = cfg.pitch })
        end)
        print('apl_pet: звук playOnce ' .. cfg.sound_event .. ' → ' ..
          (okSnd and resSnd ~= nil and 'OK' or 'nil/ошибка'))
      end
      print('apl_pet: команда отправлена (конфиг=' .. (cfg.fromFile and 'файл' or 'ДЕФОЛТЫ') ..
        ') — guard-отказы vehicle печатает сам (на ходу/усталость)')
      logLine('INFO', 'pet: start sent, conf=' .. (cfg.fromFile and 'file' or 'defaults') ..
        ' sound=' .. (cfg.sound_event ~= '' and cfg.sound_event or 'off'))
    end
    return true
  elseif mode == 'off' then
    petSoundStop() -- звук гасим мгновенно (не дожидаясь vehicle)
    petActive = false
    petSoundEvent = ''
    if sendToVehicle('autopilotLivePetCmd.stop()') then
      print('apl_pet: ПОГЛАЖИВАНИЕ ПРЕРВАНО — газ/ручник/руль штатные')
      logLine('INFO', 'pet: stop sent')
    end
    return true
  elseif mode == 'status' then
    local cfg = loadPetConfig()
    print('apl_pet GE: звук=Vehicle-SFX (' .. (cfg.sound_event ~= '' and cfg.sound_event or 'off') ..
      '), каждые ' .. string.format('%.2f', cfg.sound_interval) .. ' с')
    print('  конфиг=' .. (cfg.fromFile and 'файл' or 'ДЕФОЛТЫ') ..
      ': длительность ' .. string.format('%.1f', cfg.duration_s) .. ' с, газ ' ..
      string.format('%.2f', cfg.offset) .. '+±' .. string.format('%.2f', cfg.amp) ..
      ' @ ' .. string.format('%.2f', cfg.hz) .. ' Гц (0..' ..
      string.format('%.2f', cfg.offset + cfg.amp) .. '), ручник — vehicle' ..
      ', руль ×' .. string.format('%.2f', cfg.steer_rate_scale) ..
      ', тормоз НЕ используется')
    print('  звук: ' .. (cfg.sound_event ~= '' and
      (cfg.sound_event .. ' (питч ' .. string.format('%.2f', cfg.pitch) ..
       ', громкость ' .. string.format('%.2f', cfg.sound_volume) ..
       ', каждые ' .. string.format('%.2f', cfg.sound_interval) .. ' с, ' ..
       (cfg.sound_no_pos and 'БЕЗ позиции' or 'с позицией машины') .. ')')
      or 'выключен (sound_event пуст в pet.json)') ..
      ', гейт скорости ' .. string.format('%.0f', cfg.speed_gate_kph) .. ' км/ч')
    if not sendToVehicle('autopilotLivePetCmd.status()') then
      print('WARN apl_pet: машина игрока не найдена — статус vehicle-слоя недоступен')
    end
    return true
  end
  print('Использование: apl_pet("on") — погладить (6 с) | apl_pet("off") — прервать | apl_pet("status")')
  return false
end

-- Фаза 7б: vehicle сообщает завершение/отклонение — GE гасит луп (fade 1 с).
function M.onVehiclePetDone()
  petSoundStop()
  petActive = false
  logLine('INFO', 'pet: vehicle завершил поглаживание — луп остановлен')
end

function M.onVehiclePetRejected()
  petSoundStop()
  petActive = false
  logLine('INFO', 'pet: vehicle отклонил (guard) — луп остановлен')
end

-- === Фаза 8 (2026-10-19): pop-up фары / «глазки» — случайное моргание ===
-- Утверждено координатором 19.10: вариант А (моргание через setLightsState),
-- интервалы день 120-180 с / ночь 180-300 с, blink 1.5-2 с, guard Ф6
-- (refuse_auto_on_popup) СНЯТ — авто-свет Ф6 на Bolide/Wigeon работает.
local popupAuto = false        -- авто-режим включён игроком (только apl_popup("auto"))
local popupNightLast = false   -- последняя переданная vehicle ночь
local popupNightAcc = 0        -- аккумулятор опроса ночи (тик 5 с)
local popupNightDbgAcc = 0     -- аккумулятор печати keepalive (30 с)

-- === Фаза 9.1: «Система Боли» — авто-восстановление ===
local painAuto = false         -- включается ТОЛЬКО apl_pain("auto")
local painDamageAcc = 0        -- аккумулятор отправки damageSum vehicle (2 с)
local painDbgAcc = 0           -- печать raw damageSum в консоль (10 с)
local painDamageSeq = 0        -- счётчик пакетов setDamage (диагностика моста)
local painVerifyT = 0          -- через сколько проверить, помог ли resetVehicle
local painTpFrom = nil         -- позиция до телепорта (для проверки «переместилась ли»)
local painTpT = 0              -- таймер проверки телепорта
local painTpDelayT = 0         -- задержка setPosRot после resetVehicle (0.2 с)
local painTpPending = false    -- отложенный телепорт ждёт тика
local painLastTp = -1          -- последняя измеренная дельта позиции, м

-- Фаза 10.1: мастер-переключатель (apl_autopilot)
local masterState = 'off'      -- 'off' | 'waiting_warmup' | 'on'
local masterPending = false
local masterWaitT = 0
local masterCfg = nil
local MASTER_DEFAULTS = {
  enable_wheel = 1, enable_pedals = 1, enable_lights = 1,
  enable_popup = 1, enable_pain = 1,
  ai_mode = 'traffic', skip_warmup_if_warm = 1,
}

local function loadMasterConfig()
  local D = MASTER_DEFAULTS
  local c = {}
  for k, v in pairs(D) do c[k] = v end
  local decoded = readJsonFile(MASTER_CONF)
  if decoded then
    local function num(key, dflt)
      local v = tonumber(decoded[key])
      if v == nil or v ~= v then return dflt end
      return (v ~= 0) and 1 or 0
    end
    c.enable_wheel = num('enable_wheel', D.enable_wheel)
    c.enable_pedals = num('enable_pedals', D.enable_pedals)
    c.enable_lights = num('enable_lights', D.enable_lights)
    c.enable_popup = num('enable_popup', D.enable_popup)
    c.enable_pain = num('enable_pain', D.enable_pain)
    c.skip_warmup_if_warm = num('skip_warmup_if_warm', D.skip_warmup_if_warm)
    if type(decoded.ai_mode) == 'string' then
      local m = decoded.ai_mode:lower()
      if m == '' or m == 'traffic' or m == 'span' then c.ai_mode = m end
    end
  end
  return c
end
local PAIN_DEFAULTS = {
  check_hz = 1, damage_threshold = 10000000,
  stuck_speed_kph = 5, stuck_time_s = 5, stuck_throttle_min = 0.5,
  flipped_up_dot = 0.3, flipped_time_s = 2, cooldown_s = 15,
  restore_ai = 1, warmup_after = 1, warmup_sway = 0,
}

local function loadPainConfig()
  local D = PAIN_DEFAULTS
  local c = {}
  for k, v in pairs(D) do c[k] = v end
  local decoded = readJsonFile(PAIN_CONF)
  if decoded then
    local function num(key, lo, hi, dflt)
      local v = tonumber(decoded[key])
      if v == nil or v ~= v then return dflt end
      if v < lo then return lo end
      if v > hi then return hi end
      return v
    end
    c.check_hz = num('check_hz', 0.1, 10, D.check_hz)
    c.damage_threshold = num('damage_threshold', 0, 1e9, D.damage_threshold)
    c.stuck_speed_kph = num('stuck_speed_kph', 0, 200, D.stuck_speed_kph)
    c.stuck_time_s = num('stuck_time_s', 1, 120, D.stuck_time_s)
    c.stuck_throttle_min = num('stuck_throttle_min', 0.1, 1, D.stuck_throttle_min)
    c.flipped_up_dot = num('flipped_up_dot', 0, 0.9, D.flipped_up_dot)
    c.flipped_time_s = num('flipped_time_s', 0.5, 60, D.flipped_time_s)
    c.cooldown_s = num('cooldown_s', 1, 600, D.cooldown_s)
    c.restore_ai = num('restore_ai', 0, 1, D.restore_ai)
    c.warmup_after = num('warmup_after', 0, 1, D.warmup_after)
    c.warmup_sway = num('warmup_sway', 0, 1, D.warmup_sway)
  end
  return c
end

-- Ближайшая точка дороги: позиция + кватернион по направлению ребра.
local function painRoadPose(veh)
  local m = (map and map.getMap) and map.getMap() or nil
  if not m or not m.nodes then return nil end
  local p = veh:getPosition()
  local n1Id, n2Id = map.findClosestRoad(p)
  local n1 = n1Id and m.nodes[n1Id] or nil
  local n2 = n2Id and m.nodes[n2Id] or nil
  if not n1 or not n1.pos then return nil end
  local qx, qy, qz, qw = 0, 0, 0, 1
  if n2 and n2.pos and n1.normal then
    local dir = n2.pos - n1.pos
    if dir:length() > 0.5 then
      local q = quatFromDir(dir, n1.normal)
      qx, qy, qz, qw = q.x, q.y, q.z, q.w
    end
  end
  return n1.pos.x, n1.pos.y, n1.pos.z + 0.2, qx, qy, qz, qw
end

-- Принудительный телепорт: гасим скорости (вода/пляж), setPosRot, снова гасим.
local function painTeleportNow(veh)
  local x, y, z, qx, qy, qz, qw = painRoadPose(veh)
  if not x then return false, 'road pose не найден' end
  pcall(function() veh:setVelocity(vec3(0, 0, 0)) end)
  pcall(function() veh:applyAngularVelocity(vec3(0, 0, 0)) end)
  local okT = pcall(function() veh:setPosRot(x, y, z, qx, qy, qz, qw) end)
  pcall(function() veh:setVelocity(vec3(0, 0, 0)) end)
  return okT, string.format('(%.1f, %.1f, %.1f)', x, y, z)
end

-- Надёжное восстановление: resetVehicle(0) (ремонт + на колёса), затем
-- ОТЛОЖЕННЫЙ на 0.2 с setPosRot (физике нужно обновиться; без повторов).
local function painRecover(veh, kind)
  local p0 = veh:getPosition()
  painTpFrom = vec3(p0.x, p0.y, p0.z) -- позиция ДО восстановления (для проверки)
  local okR = pcall(function() be:resetVehicle(0) end)
  painTpPending = true
  painTpDelayT = 0.2
  -- Фаза 9.5: 3 с неуязвимости в vehicle-слое — падение после телепорта
  -- не должно снова запускать DAMAGE/STUCK/FLIPPED.
  sendToVehicle('autopilotLivePainCmd.ignoreDamage(3.0)')
  -- Фаза 10.3: «режим овоща» — первые 3 с газ вдвое медленнее
  sendToVehicle('autopilotLivePedalsCmd.setRateScale(0.5, 3.0)')
  print(string.format('aplPain: recover %s — resetVehicle=%s, setPosRot через 0.2 с (reset + ближайшая дорога)',
    tostring(kind), tostring(okR)))
end

-- Дефолты конфига (ДУБЛЬ popup.json — ТОЛЬКО fallback; истина — файл)
local POPUP_DEFAULTS = {
  models = { 'bolide', 'wigeon' },
  day_min_s = 120, day_max_s = 180,
  night_min_s = 180, night_max_s = 300,
  blink_min_s = 1.5, blink_max_s = 2.0,
  debug_force_blink_delay_s = 0,
}

-- Чтение popup.json с клампами; fromFile=false — дефолты, файл не найден.
local function loadPopupConfig()
  local D = POPUP_DEFAULTS
  local c = {
    models = {},
    dayMin = D.day_min_s, dayMax = D.day_max_s,
    nightMin = D.night_min_s, nightMax = D.night_max_s,
    blinkMin = D.blink_min_s, blinkMax = D.blink_max_s,
    debugDelay = D.debug_force_blink_delay_s,
    fromFile = false,
  }
  for _, m in ipairs(D.models) do table.insert(c.models, m) end

  local decoded = readJsonFile(POPUP_CONF)
  if decoded then
    c.fromFile = true
    -- Кламп поля верхнего уровня (паттерн loadPetConfig.clampTop)
    local function clampTop(key, lo, hi, dflt)
      local v = tonumber(decoded[key])
      if v == nil or v ~= v then return dflt end
      if v < lo then return lo end
      if v > hi then return hi end
      return v
    end
    if type(decoded.models) == 'table' and decoded.models[1] ~= nil then
      local list = {}
      for _, v in ipairs(decoded.models) do
        if type(v) == 'string' and v ~= '' then table.insert(list, v:lower()) end
      end
      if #list > 0 then c.models = list end
    end
    c.dayMin = clampTop('day_min_s', 5, 3600, c.dayMin)
    c.dayMax = clampTop('day_max_s', 5, 3600, c.dayMax)
    c.nightMin = clampTop('night_min_s', 5, 3600, c.nightMin)
    c.nightMax = clampTop('night_max_s', 5, 3600, c.nightMax)
    c.blinkMin = clampTop('blink_min_s', 0.2, 10, c.blinkMin)
    c.blinkMax = clampTop('blink_max_s', 0.2, 10, c.blinkMax)
    c.debugDelay = clampTop('debug_force_blink_delay_s', 0, 600, c.debugDelay)
  end
  if c.dayMax < c.dayMin then c.dayMax = c.dayMin end
  if c.nightMax < c.nightMin then c.nightMax = c.nightMin end
  if c.blinkMax < c.blinkMin then c.blinkMax = c.blinkMin end
  return c
end

-- Сейчас ночь? Тот же механизм Ф6: игровое время (gameTodHours) против
-- ночного окна карты (windowForCurrentMap из lights.json/lights_by_map.json).
-- Гистерезис Ф6 не нужен — точность ±минуты для выбора интервала не критична.
local function popupIsNightNow()
  local cfg = loadLightsConfig()
  local window = windowForCurrentMap(cfg)
  local h = gameTodHours()
  if h == nil then return false end
  local ws = parseHHMM(window.start)
  local we = parseHHMM(window['end'])
  if ws == nil or we == nil then return false end
  return inNightWindow(h, ws, we)
end

-- vehicle сообщает: авто-режим popup отключён (ручное вмешательство игрока)
function M.onVehiclePopupAutoOff()
  if not popupAuto then return end
  popupAuto = false
  logLine('WARN', 'popup: авто-моргание отключено — игрок сам трогает фары (ТЗ Фазы 8)')
  print('apl_popup: авто-режим отключён (ручное вмешательство в фары)')
end

-- === apl_popup("auto" | "off" | "status") ===
-- Включается ТОЛЬКО командой игрока (по умолчанию выкл, ТЗ Фазы 8).
-- Модели: только Bolide/Wigeon (guard по veh.JBeam; другая — отказ INFO).
function apl_popup(mode)
  mode = tostring(mode or '')
  local veh = getVehicle()
  if veh == nil then
    print('apl_popup: нет игрока за рулём')
    return false
  end

  if mode == 'auto' then
    if popupAuto then
      print('apl_popup: авто-режим УЖЕ включён (apl_popup("off") чтобы выключить)')
      return false
    end
    local jb = playerJBeam(veh)
    local cfg = loadPopupConfig()
    local allowed = false
    if jb then
      for _, m in ipairs(cfg.models) do
        if m == jb then allowed = true break end
      end
    end
    if not allowed then
      print('apl_popup: ' .. tostring(jb or '?') .. ' — pop-up фары не поддерживаются (модель не из popup.json: ' ..
        table.concat(cfg.models, ', ') .. ')')
      logLine('INFO', 'popup refused: jbeam=' .. tostring(jb))
      return false
    end
    local night = popupIsNightNow()
    popupAuto = true
    popupNightLast = night
    popupNightAcc = 0
    sendToVehicle(string.format(
      'autopilotLivePopupCmd.start({dayMin=%.1f,dayMax=%.1f,nightMin=%.1f,nightMax=%.1f,blinkMin=%.2f,blinkMax=%.2f,debugDelay=%.1f,night=%s})',
      cfg.dayMin, cfg.dayMax, cfg.nightMin, cfg.nightMax,
      cfg.blinkMin, cfg.blinkMax, cfg.debugDelay, tostring(night)))
    -- Диагностика (24.10): ПРЯМОЙ setNight сразу после старта (без keepalive) —
    -- проверка, доходит ли команда до vehicle вообще.
    local okNight = sendToVehicle('autopilotLivePopupCmd.setNight(' .. tostring(night) .. ')')
    print('apl_popup: прямой setNight=' .. tostring(night) ..
      ' → ' .. (okNight and 'отправлен' or 'НЕ отправлен (машина не найдена)'))
    print('apl_popup: авто-моргание ВКЛ (' .. jb .. ', ' ..
      (cfg.debugDelay > 0 and ('ТЕСТ-РЕЖИМ: каждые ' .. string.format('%.0f', cfg.debugDelay) .. ' с')
        or ('день ' .. string.format('%.0f', cfg.dayMin) .. '-' .. string.format('%.0f', cfg.dayMax) ..
            ' с, ночь ' .. string.format('%.0f', cfg.nightMin) .. '-' .. string.format('%.0f', cfg.nightMax) .. ' с')) ..
      ', blink ' .. string.format('%.1f', cfg.blinkMin) .. '-' .. string.format('%.1f', cfg.blinkMax) .. ' с; ' ..
      (night and 'сейчас НОЧЬ (моргание подавлено — фары горят постоянно)' or 'сейчас ДЕНЬ') ..
      '; глаза открыты в покое; ручное вмешательство отключает; ' ..
      (cfg.fromFile and 'popup.json' or 'ДЕФОЛТЫ (файл не найден)') .. ')')
    logLine('INFO', 'popup auto ON: model=' .. jb .. ' night=' .. tostring(night) ..
      ' debugDelay=' .. tostring(cfg.debugDelay))
    return true
  end

  if mode == 'off' then
    if not popupAuto then
      print('apl_popup: авто-режим и так выключен')
      return false
    end
    popupAuto = false
    sendToVehicle('autopilotLivePopupCmd.stop()')
    print('apl_popup: авто-моргание ВЫКЛ (глазки — штатно, светом по-прежнему)')
    logLine('INFO', 'popup auto OFF (команда)')
    return true
  end

  if mode == 'status' then
    local cfg = loadPopupConfig()
    print('--- apl_popup status ---')
    print('auto=' .. tostring(popupAuto) .. ', сейчас ' ..
      (popupIsNightNow() and 'НОЧЬ' or 'ДЕНЬ') ..
      ' (ночь по окну ' .. (function()
        local w = windowForCurrentMap(loadLightsConfig())
        return w.start .. '-' .. w['end']
      end)() .. ')')
    print('конфиг: день ' .. string.format('%.0f', cfg.dayMin) .. '-' .. string.format('%.0f', cfg.dayMax) ..
      ' с, ночь ' .. string.format('%.0f', cfg.nightMin) .. '-' .. string.format('%.0f', cfg.nightMax) ..
      ' с, blink ' .. string.format('%.1f', cfg.blinkMin) .. '-' .. string.format('%.1f', cfg.blinkMax) ..
      ' с, debug_force_blink_delay_s=' .. string.format('%.0f', cfg.debugDelay) ..
      ' (' .. (cfg.fromFile and 'popup.json' or 'дефолты') .. ')')
    print('модели: ' .. table.concat(cfg.models, ', ') .. '; guard Ф6 (refuse_auto_on_popup) СНЯТ — ' ..
      'auto-свет Ф6 на этих моделях работает')
    sendToVehicle('autopilotLivePopupCmd.status()')
    return true
  end

  print('Использование: apl_popup("auto"|"off"|"status")')
  return false
end

-- === Фаза 9.1: «Система Боли» — apl_pain("auto"|"off"|"status") ===
function apl_pain(mode)
  mode = tostring(mode or ''):lower()
  local veh = getVehicle()
  if veh == nil then
    print('apl_pain: нет игрока за рулём')
    return false
  end

  if mode == 'auto' then
    if painAuto then
      print('apl_pain: уже включено (apl_pain("off") чтобы выключить)')
      return false
    end
    local cfg = loadPainConfig()
    painAuto = true
    painDamageAcc = 0
    sendToVehicle(string.format(
      'autopilotLivePainCmd.start({check_hz=%.2f,damage_threshold=%.3f,' ..
      'stuck_speed_kph=%.1f,stuck_time_s=%.1f,stuck_throttle_min=%.2f,' ..
      'flipped_up_dot=%.2f,flipped_time_s=%.1f,cooldown_s=%.1f})',
      cfg.check_hz, cfg.damage_threshold, cfg.stuck_speed_kph, cfg.stuck_time_s,
      cfg.stuck_throttle_min, cfg.flipped_up_dot, cfg.flipped_time_s, cfg.cooldown_s))
    print(string.format('apl_pain: АВТО-ВОССТАНОВЛЕНИЕ ВКЛ — damage>=%.2f, stuck %.0f км/ч/%.0f с, ' ..
      'flip up<%.2f, cooldown %.0f с, warmup_after=%d, restore_ai=%d',
      cfg.damage_threshold, cfg.stuck_speed_kph, cfg.stuck_time_s,
      cfg.flipped_up_dot, cfg.cooldown_s, cfg.warmup_after, cfg.restore_ai))
    logLine('INFO', 'pain auto ON')
    return true
  end

  if mode == 'off' then
    if not painAuto then
      print('apl_pain: и так выключено')
      return false
    end
    painAuto = false
    sendToVehicle('autopilotLivePainCmd.stop()')
    print('apl_pain: ВЫКЛ')
    logLine('INFO', 'pain auto OFF')
    return true
  end

  if mode == 'status' then
    local cfg = loadPainConfig()
    local dmg = '?'
    if veh.getSectionDamageSum then
      local ok, v = pcall(function() return veh:getSectionDamageSum() end)
      if ok and v ~= nil then dmg = string.format('%.3f', tonumber(v) or 0) end
    end
    print('--- apl_pain status ---')
    print('auto=' .. tostring(painAuto) .. ', damageSum(raw)=' .. tostring(dmg) ..
      ', порог damage_threshold=' .. string.format('%.3f', cfg.damage_threshold))
    print(string.format('пороги: damage>=%.2f, stuck<=%.0f км/ч %.0f с (газ>=%.2f), flip up<%.2f %.1f с, cooldown %.0f с',
      cfg.damage_threshold, cfg.stuck_speed_kph, cfg.stuck_time_s, cfg.stuck_throttle_min,
      cfg.flipped_up_dot, cfg.flipped_time_s, cfg.cooldown_s))
    print('после: warmup_after=' .. tostring(cfg.warmup_after) ..
      ' (sway=' .. tostring(cfg.warmup_sway) .. '), restore_ai=' .. tostring(cfg.restore_ai))
    print(string.format('последний телепорт: moved=%.1f м (%s)', painLastTp,
      painLastTp >= 2 and 'ok' or (painLastTp < 0 and 'не было' or 'НЕ сработал')))
    sendToVehicle('autopilotLivePainCmd.status()')
    return true
  end

  print('Использование: apl_pain("auto"|"off"|"status")')
  return false
end

-- Vehicle сообщает: STUCK/FLIPPED/DAMAGE — выполняем восстановление
function M.onVehiclePain(kind, info)
  if not painAuto then return end
  local cfg = loadPainConfig()
  local veh = getVehicle()
  print('[aplPain] ' .. tostring(kind) .. ': ' .. tostring(info))
  logLine('WARN', 'pain ' .. tostring(kind) .. ': ' .. tostring(info))

  if veh == nil then
    print('aplPain: recover НЕВОЗМОЖЕН — машина не найдена')
    return
  end
  -- ВСЕ виды (DAMAGE/STUCK/FLIPPED): resetVehicle(0) (ремонт + на колёса),
  -- затем принудительный setPosRot на ближайшую точку дороги.
  painRecover(veh, kind)
  painVerifyT = 2.0 -- через 2 с проверим, вылечился ли

  -- Быстрый прогрев (sway отключается флагом noSway)
  if cfg.warmup_after > 0 then
    sendToVehicle(string.format("autopilotLiveWarmupCmd.on('%s', {noSway=%s})",
      WARMUP_CONF, tostring(cfg.warmup_sway == 0)))
  end
  -- Вернуть автопилот — ТОЛЬКО если мастер включён (иначе машина не должна ехать)
  if cfg.restore_ai > 0 and masterState == 'on' then
    sendToVehicle('if ai and ai.setMode then ai.setMode("traffic") end')
  elseif cfg.restore_ai > 0 then
    print('aplPain: AI не включаю — мастер выключен (masterState=' .. tostring(masterState) .. ')')
  end
end

-- Фаза 10.1: финализация мастера (вызывается после прогрева)
local function masterFinish()
  if not masterPending then return end
  masterPending = false
  masterState = 'on'
  local cfg = masterCfg or loadMasterConfig()
  if cfg.enable_wheel == 1 and not wheelRequested then
    if apl_wheel then apl_wheel('on') end
  end
  if cfg.enable_pedals == 1 and not pedalsRequested then
    if apl_pedals then apl_pedals('on') end
  end
  if cfg.enable_lights == 1 and not lightsAuto then
    if apl_lights then apl_lights('auto') end
  end
  if cfg.enable_popup == 1 and not popupAuto then
    if apl_popup then apl_popup('auto') end
  end
  if cfg.enable_pain == 1 and not painAuto then
    if apl_pain then apl_pain('auto') end
  end
  local mode = (cfg.ai_mode ~= '' and cfg.ai_mode) or 'traffic'
  sendToVehicle(string.format('if ai and ai.setMode then ai.setMode("%s") end', mode))
  print('apl_autopilot: ВСЁ ГОТОВО — wheel/pedals/lights/popup/pain + AI "' .. mode .. '"')
  logLine('INFO', 'master ON: warmup done, modules enabled, ai=' .. mode)
end

-- === Фаза 10.1: мастер-переключатель apl_autopilot("on"|"off"|"toggle"|"status") ===
function apl_autopilot(mode)
  mode = tostring(mode or ''):lower()
  if mode == 'toggle' then
    mode = (masterState == 'on') and 'off' or 'on'
  end

  if mode == 'on' then
    if masterState == 'on' then
      print('apl_autopilot: уже включено (apl_autopilot("off"))')
      return false
    end
    if masterState == 'waiting_warmup' then
      print('apl_autopilot: уже ждём завершения прогрева')
      return false
    end
    local veh = getVehicle()
    if veh == nil then
      print('apl_autopilot: нет игрока за рулём')
      return false
    end
    local cfg = loadMasterConfig()
    masterCfg = cfg
    masterPending = true
    masterState = 'waiting_warmup'
    masterWaitT = 0
    local cmd = string.format(
      "autopilotLiveWarmupCmd.on('%s', {noSway=false, skipIfWarm=%s})",
      WARMUP_CONF, tostring(cfg.skip_warmup_if_warm == 1))
    if not sendToVehicle(cmd) then
      masterPending = false
      masterState = 'off'
      print('apl_autopilot: WARN не удалось запустить прогрев (машина не найдена)')
      return false
    end
    print('apl_autopilot: ON — прогрев запущен; после завершения включу ' ..
      (cfg.enable_wheel == 1 and 'wheel ' or '') ..
      (cfg.enable_pedals == 1 and 'pedals ' or '') ..
      (cfg.enable_lights == 1 and 'lights ' or '') ..
      (cfg.enable_popup == 1 and 'popup ' or '') ..
      (cfg.enable_pain == 1 and 'pain ' or '') .. '+ AI "' .. cfg.ai_mode .. '"')
    logLine('INFO', 'master ON: warmup started, skipIfWarm=' .. tostring(cfg.skip_warmup_if_warm))
    return true
  end

  if mode == 'off' then
    local was = masterState
    masterPending = false
    masterState = 'off'
    masterWaitT = 0
    if wheelRequested and apl_wheel then apl_wheel('off') end
    if pedalsRequested and apl_pedals then apl_pedals('off') end
    if lightsAuto and apl_lights then apl_lights('off') end
    if popupAuto and apl_popup then apl_popup('off') end
    if painAuto and apl_pain then apl_pain('off') end
    sendToVehicle('if ai and ai.setMode then ai.setMode("disabled") end')
    print('apl_autopilot: OFF (было: ' .. tostring(was) .. ') — модули и AI выключены')
    logLine('INFO', 'master OFF (was ' .. tostring(was) .. ')')
    return true
  end

  if mode == 'status' then
    local cfg = loadMasterConfig()
    print('--- apl_autopilot status ---')
    print('state=' .. tostring(masterState) .. ', pending=' .. tostring(masterPending) ..
      ' (ждали ' .. string.format('%.1f', masterWaitT) .. ' с)')
    print('модули: wheel=' .. tostring(wheelRequested) .. ' pedals=' .. tostring(pedalsRequested) ..
      ' lights=' .. tostring(lightsAuto) .. ' popup=' .. tostring(popupAuto) ..
      ' pain=' .. tostring(painAuto))
    print(string.format('конфиг: wheel=%d pedals=%d lights=%d popup=%d pain=%d, ai=%s, skip_warmup_if_warm=%d',
      cfg.enable_wheel, cfg.enable_pedals, cfg.enable_lights, cfg.enable_popup,
      cfg.enable_pain, cfg.ai_mode, cfg.skip_warmup_if_warm))
    return true
  end

  print('Использование: apl_autopilot("on"|"off"|"toggle"|"status")')
  return false
end

function apl_autopilotState()
  return masterState
end

function apl_petActive()
  return petActive
end

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
  print('pedals: ' .. tostring(pedalsRequested))
  print('wheel: ' .. tostring(wheelRequested))
  print('warmup: ' .. tostring(warmupRequested))
  print('lights: auto=' .. tostring(lightsAuto) .. ', target=' .. tostring(lightsTarget) ..
    ', map=' .. tostring(currentMapId() or '?') .. ', tod=' .. (gameTodString() or 'н/д'))
  print('data dir: ' .. tostring(dataDir and dataDir.csv or '(не выбран)'))
  print('vehicle: ' .. (veh and ('ID=' .. tostring(veh:getID())) or '(нет)'))
  print('---------------------------')
  return true
end

-- === Фаза 3: apl_pedals — сглаживание педалей (шаг 3.4) ===
-- Логика сглаживания живёт в vehicle-слое (autopilotLivePedals.lua); GE-слой
-- только шлёт команду и конфиг. Педали 0..1, конвейер rate_limit→ema→lerp,
-- перехват через electrics.values.*Override (api_research_phase3.md).
local PEDALS_CONF = 'mods/unpacked/AutopilotLive/ai/config/pedals.json'

-- Ф8.1 (24.10): авто-старт CSV при включении модулей (надоело забывать apl_debug).
-- 1 = при apl_pedals("on")/apl_wheel("on")/apl_warmup("start") начать запись,
--     если она ещё не идёт. 0 = только вручную через apl_debug().
local AUTO_CSV = 1

local function autoCsv(reason)
  if AUTO_CSV ~= 1 then return end
  if csvActive then
    print('apl: CSV уже пишется — auto_csv пропущен (' .. reason .. ')')
    return
  end
  startCsvRecording()
  if csvActive then
    print('apl: CSV включён АВТОМАТИЧЕСКИ (' .. reason .. ') — apl_debug() не нужен')
    logLine('INFO', 'auto_csv: старт при ' .. reason)
  end
end

function apl_pedals(mode)
  mode = tostring(mode or ''):lower()
  if mode == 'on' then
    -- Диагностика ДО отправки: конфиг читается vehicle-слоем по тому же
    -- относительному пути (CWD общий для GE и vehicle-VM, см. 1.6b)
    local confOk = FS and FS:fileExists(PEDALS_CONF) or false
    if not confOk then
      print('WARN apl_pedals: конфиг не найден (' .. PEDALS_CONF .. ') — vehicle использует дефолты кода')
    end
    local veh = sendToVehicle(string.format('autopilotLivePedalsCmd.on("%s")', PEDALS_CONF))
    if veh then
      pedalsRequested = true
      print('apl_pedals: ON (конфиг: ' .. PEDALS_CONF .. ')')
      print('apl_pedals: статус — apl_pedals("status"); остановка — apl_pedals("off")')
      logLine('INFO', 'apl_pedals ON, conf=' .. PEDALS_CONF .. ', confExists=' .. tostring(confOk))
      autoCsv('apl_pedals')
    end
  elseif mode == 'off' then
    -- Round-trip подтверждение (находка Н1, 2026-10-12): off и status — ОДНОЙ
    -- строкой в vehicle-очередь (FIFO, один тик VM). pcall ловит падение off,
    -- print из VM показывает vehId той машины, где исполнение реально произошло,
    -- status — состояние модуля после off. Если off потеряется — видно ТОЧНО
    -- на каком этапе (отправка GE / исполнение VM / состояние active).
    local offCmd = 'local ok, offRet = pcall(function() return autopilotLivePedalsCmd.off() end); '
      .. 'print("aplPedals: off round-trip: ok=" .. tostring(ok) .. " off=" .. tostring(offRet) .. " vehId=" .. tostring(obj and obj:getId() or -1)); '
      .. 'local ok2, err2 = pcall(function() return autopilotLivePedalsCmd.status() end); '
      .. 'if not ok2 then print("aplPedals: status после off упал: " .. tostring(err2)) end'
    local veh = sendToVehicle(offCmd)
    if veh then
      pedalsRequested = false
      local okId, vehId = pcall(function() return veh:getID() end)
      local idStr = tostring((okId and vehId) or '?')
      print('apl_pedals: OFF отправлен (vehId=' .. idStr .. ')')
      print('apl_pedals: жду round-trip в консоли: "off round-trip: ok=true ... vehId=N" и статус с active=false')
      logLine('INFO', 'apl_pedals OFF отправлен (vehId=' .. idStr .. '), round-trip status в vehicle')
    end
  elseif mode == 'status' then
    print('apl_pedals GE: запрошено=' .. tostring(pedalsRequested) ..
      ', конфиг=' .. PEDALS_CONF ..
      ' (существует=' .. tostring(FS and FS:fileExists(PEDALS_CONF) or false) .. ')')
    if not sendToVehicle('autopilotLivePedalsCmd.status()') then
      print('WARN apl_pedals: машина игрока не найдена — статус vehicle-слоя недоступен')
    end
  else
    print('Использование: apl_pedals("on") | apl_pedals("off") | apl_pedals("status")')
    return false
  end
  return true
end

-- === Фаза 4: apl_wheel — сглаживание руля AI ===
-- Логика сглаживания живёт в vehicle-слое (autopilotLiveWheel.lua); GE-слой
-- только шлёт команду и конфиг. Руль нормированный [-1,1], конвейер
-- rate_limit→ema→lerp, ЗАМЕНА движкового FILTER_AI своим (api_research_phase4.md).
local WHEEL_CONF = 'mods/unpacked/AutopilotLive/ai/config/wheel.json'

function apl_wheel(mode)
  mode = tostring(mode or ''):lower()
  if mode == 'on' then
    local confOk = FS and FS:fileExists(WHEEL_CONF) or false
    if not confOk then
      print('WARN apl_wheel: конфиг не найден (' .. WHEEL_CONF .. ') — vehicle использует дефолты кода')
    end
    local veh = sendToVehicle(string.format('autopilotLiveWheelCmd.on("%s")', WHEEL_CONF))
    if veh then
      wheelRequested = true
      print('apl_wheel: ON (конфиг: ' .. WHEEL_CONF .. ')')
      print('apl_wheel: статус — apl_wheel("status"); остановка — apl_wheel("off")')
      logLine('INFO', 'apl_wheel ON, conf=' .. WHEEL_CONF .. ', confExists=' .. tostring(confOk))
      autoCsv('apl_wheel')
    end
  elseif mode == 'off' then
    -- Round-trip подтверждение (паттерн Н1 Фазы 3): off и status — ОДНОЙ строкой
    -- в vehicle-очередь (FIFO). steering_input движок затирает сам — залипания
    -- не будет, но подтверждаем исполнение (У4).
    local offCmd = 'local ok, offRet = pcall(function() return autopilotLiveWheelCmd.off() end); '
      .. 'print("aplWheel: off round-trip: ok=" .. tostring(ok) .. " off=" .. tostring(offRet) .. " vehId=" .. tostring(obj and obj:getId() or -1)); '
      .. 'local ok2, err2 = pcall(function() return autopilotLiveWheelCmd.status() end); '
      .. 'if not ok2 then print("aplWheel: status после off упал: " .. tostring(err2)) end'
    local veh = sendToVehicle(offCmd)
    if veh then
      wheelRequested = false
      local okId, vehId = pcall(function() return veh:getID() end)
      local idStr = tostring((okId and vehId) or '?')
      print('apl_wheel: OFF отправлен (vehId=' .. idStr .. ')')
      print('apl_wheel: жду round-trip в консоли: "off round-trip: ok=true ... vehId=N" и статус с active=false')
      logLine('INFO', 'apl_wheel OFF отправлен (vehId=' .. idStr .. '), round-trip status в vehicle')
    end
  elseif mode == 'status' then
    print('apl_wheel GE: запрошено=' .. tostring(wheelRequested) ..
      ', конфиг=' .. WHEEL_CONF ..
      ' (существует=' .. tostring(FS and FS:fileExists(WHEEL_CONF) or false) .. ')')
    if not sendToVehicle('autopilotLiveWheelCmd.status()') then
      print('WARN apl_wheel: машина игрока не найдена — статус vehicle-слоя недоступен')
    end
  else
    print('Использование: apl_wheel("on") | apl_wheel("off") | apl_wheel("status")')
    return false
  end
  return true
end

-- === Фаза 5: apl_warmup — прогрев машины (опциональная надстройка) ===
-- Логика живёт в vehicle-слое (autopilotLiveWarmup.lua): завод через
-- electrics.setIgnitionLevel(3) (ICE) и прогрев до coolant/oil порогов
-- (api_research_phase5.md). GE шлёт команду и конфиг. НЕ трогает wheel/pedals:
-- они работают независимо, warmup — state-machine поверх.
local WARMUP_CONF = 'mods/unpacked/AutopilotLive/ai/config/warmup.json'

function apl_warmup(mode)
  mode = tostring(mode or 'start'):lower()
  if mode == 'start' then
    local confOk = FS and FS:fileExists(WARMUP_CONF) or false
    if not confOk then
      print('WARN apl_warmup: конфиг не найден (' .. WARMUP_CONF .. ') — vehicle использует дефолты кода')
    end
    local veh = sendToVehicle(string.format('autopilotLiveWarmupCmd.on("%s")', WARMUP_CONF))
    if veh then
      warmupRequested = true
      print('apl_warmup: START (конфиг: ' .. WARMUP_CONF .. ')')
      print('apl_warmup: статус — apl_warmup("status"); отмена — apl_warmup("off")')
      logLine('INFO', 'apl_warmup START, conf=' .. WARMUP_CONF .. ', confExists=' .. tostring(confOk))
      autoCsv('apl_warmup')
    end
  elseif mode == 'off' then
    local veh = sendToVehicle('autopilotLiveWarmupCmd.off()')
    if veh then
      warmupRequested = false
      local okId, vehId = pcall(function() return veh:getID() end)
      print('apl_warmup: OFF отправлен (vehId=' .. tostring((okId and vehId) or '?') .. ')')
      logLine('INFO', 'apl_warmup OFF отправлен')
    end
  elseif mode == 'status' then
    print('apl_warmup GE: идёт=' .. tostring(warmupRequested) ..
      ', конфиг=' .. WARMUP_CONF ..
      ' (существует=' .. tostring(FS and FS:fileExists(WARMUP_CONF) or false) .. ')')
    if not sendToVehicle('autopilotLiveWarmupCmd.status()') then
      print('WARN apl_warmup: машина игрока не найдена — статус vehicle-слоя недоступен')
    end
  else
    print('Использование: apl_warmup("start") | apl_warmup("off") | apl_warmup("status")')
    return false
  end
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

-- Фаза 5 (шаг 5.4): vehicle сообщает завершение прогрева. GE печатает
-- сообщение игроку и при auto_engage_after_warmup=true включает wheel/pedals
-- (только если они ещё не включены — warmup не мешает уже работающим модулям).
function M.onVehicleWarmupDone(vehId, elapsed, tempC, autoEngage, timedOut)
  print('MASTER: onVehicleWarmupDone получен (pending=' .. tostring(masterPending) ..
    ', state=' .. tostring(masterState) .. ')')
  warmupRequested = false
  local tempStr = (tonumber(tempC) and tonumber(tempC) >= 0) and (tostring(tempC) .. '°C') or 'n/a'
  if timedOut == true or tostring(timedOut) == 'true' then
    print('apl_warmup: ПРОГРЕВ ПО ТАЙМАУТУ — машина готова (прошло ' .. tostring(elapsed) ..
      ' с, coolant ' .. tempStr .. ')')
    logLine('WARN', 'warmup done by timeout: veh=' .. tostring(vehId) .. ' elapsed=' ..
      tostring(elapsed) .. ' temp=' .. tempStr)
  else
    print('apl_warmup: ПРОГРЕВ ЗАВЕРШЁН, машина готова (прошло ' .. tostring(elapsed) ..
      ' с, coolant ' .. tempStr .. ')')
    logLine('INFO', 'warmup done: veh=' .. tostring(vehId) .. ' elapsed=' .. tostring(elapsed) ..
      ' temp=' .. tempStr .. ' autoEngage=' .. tostring(autoEngage))
  end
  if autoEngage == true or tostring(autoEngage) == 'true' then
    -- Шаг 5.4: авто-включение НАШИХ модулей (НЕ ванильный AI — его включит
    -- игрок). GE знает, включены ли уже: повторный on перезапустил бы конфиг
    -- и плавный старт — не дублируем (контракт «warmup не мешает wheel/pedals»).
    if not wheelRequested then
      if sendToVehicle(string.format('autopilotLiveWheelCmd.on("%s")', WHEEL_CONF)) then
        wheelRequested = true
        print('apl_warmup: auto_engage — apl_wheel ВКЛЮЧЁН')
        logLine('INFO', 'warmup auto_engage: wheel ON')
      end
    else
      print('apl_warmup: auto_engage — wheel уже включён, пропуск')
      logLine('INFO', 'warmup auto_engage: wheel уже включён — пропуск')
    end
    if not pedalsRequested then
      if sendToVehicle(string.format('autopilotLivePedalsCmd.on("%s")', PEDALS_CONF)) then
        pedalsRequested = true
        print('apl_warmup: auto_engage — apl_pedals ВКЛЮЧЁН')
        logLine('INFO', 'warmup auto_engage: pedals ON')
      end
    else
      print('apl_warmup: auto_engage — pedals уже включены, пропуск')
      logLine('INFO', 'warmup auto_engage: pedals уже включены — пропуск')
    end
  else
    print('apl_warmup: автопилот вручную: apl_wheel("on") + apl_pedals("on")')
  end
  -- Фаза 10.1: если мастер ждал прогрева — финализируем
  if masterPending then masterFinish() end
end

-- Фаза 10.1-fix: fallback — vehicle раз в секунду шлёт состояние прогрева.
-- Если onVehicleWarmupDone потерялся, мастер всё равно финализируется.
function M.onVehicleWarmupState(st)
  st = tostring(st or '')
  if masterPending and st == 'done' then
    print('MASTER: fallback warmup state=' .. st .. ' → masterFinish')
    logLine('INFO', 'master fallback: warmup state=' .. st)
    masterFinish()
  end
end

-- Фаза 6 (шаг 6.4): vehicle сообщил, что игрок вмешался в фары руками во время
-- auto (клавиша L/радиал-меню/салон) — авто-режим отключаем, фары оставляем
-- как поставил игрок («не дерёмся», §7.4).
function M.onVehicleLightsAutoOff()
  lightsAuto = false
  lightsTarget = nil
  lightsIsNight = nil
  print('apl_lights: Ручное управление, авто-режим отключен')
  logLine('INFO', 'lights: авто-режим отключён (ручное вмешательство игрока в фары)')
end

-- vehicle сообщает, что его расширение активно (шаг 1.3 при спавне)
function M.onVehicleReady(vehId)
  logLine('INFO', 'Vehicle-слой активен (vehId=' .. tostring(vehId) .. ')')
end

-- === Фаза 6 (шаг 6.4): тик авто-режима фар ===
-- Штатный хук GE-расширений (примеры ванили: mcp/tools/spawn.lua:12,
-- core/vehicle/vehicleTriggerHighlight.lua:278). Опрос времени с шагом
-- 1/poll_hz; target шлём vehicle ТОЛЬКО при смене (анти-дёрганье живёт в
-- vehicle-модуле: guard «lights_state ~= lastApplied»).
function M.onUpdate(dtReal)
  if dtReal == nil or dtReal ~= dtReal or dtReal <= 0 or dtReal > 1 then return end
  -- Звук петмода: ОДИН Engine.Audio.playOnce в apl_pet("on") (24.10) —
  -- повторов/тика здесь больше нет.
  -- Фаза 9.1: damageSum доступен только в GE — шлём vehicle каждые 2 с
  if painAuto then
    painDamageAcc = painDamageAcc + dtReal
    if painDamageAcc >= 2 then
      painDamageAcc = 0
      local okAll, errAll = pcall(function()
        local veh = getVehicle() or (getPlayerVehicle and getPlayerVehicle(0))
        local d = nil
        if veh and veh.getSectionDamageSum then
          local ok, v = pcall(function() return veh:getSectionDamageSum() end)
          if ok and v ~= nil then d = tonumber(v) end
        end
        if not veh then
          print('apl_pain: WARN veh=nil — damageSum не прочитать')
        elseif d == nil then
          print('apl_pain: WARN getSectionDamageSum вернул nil/ошибку')
        end
        if d then
          painDamageSeq = painDamageSeq + 1
          local cmd = string.format('autopilotLivePainCmd.setDamage(%.6f, %d)', d, painDamageSeq)
          -- Надёжнее: напрямую в vehicle VM (sendToVehicle — fallback).
          local okq = false
          if veh and veh.queueLuaCommand then
            okq = pcall(function() veh:queueLuaCommand(cmd) end)
          end
          local sent = sendToVehicle(cmd)
          print(string.format('apl_pain: SEND #%d damageSum=%.1f → queueLuaCommand=%s, sendToVehicle=%s',
            painDamageSeq, d, tostring(okq), tostring(sent ~= nil)))
          painDbgAcc = painDbgAcc + 2
          if painDbgAcc >= 10 then
            painDbgAcc = 0
            print(string.format('apl_pain: damageSum(raw)=%.4f (порог %.3f)',
              d, loadPainConfig().damage_threshold))
          end
        end
      end)
      if not okAll then
        print('apl_pain: WARN onUpdate pain error: ' .. tostring(errAll))
      end
    end
  end
  -- Фаза 9.1: проверка, вылечил ли be:resetVehicle(0) тяжёлый урон.
  -- Если через 2 с damageSum всё ещё >= порога — escalation: teleportToLastRoad
  -- (с resetVehicle=true — гарантированный ремонт + постановка на дорогу).
  if painVerifyT > 0 then
    painVerifyT = painVerifyT - dtReal
    if painVerifyT <= 0 then
      local veh = getVehicle()
      local dmg = 0
      if veh and veh.getSectionDamageSum then
        local ok, v = pcall(function() return veh:getSectionDamageSum() end)
        if ok and v then dmg = tonumber(v) or 0 end
      end
      local thrDmg = loadPainConfig().damage_threshold
      if dmg >= thrDmg then
        print(string.format('aplPain: resetVehicle НЕ вылечил (damageSum=%.1f >= %.0f) → teleportToLastRoad',
          dmg, thrDmg))
        if spawn and spawn.teleportToLastRoad and veh then
          local ok2 = pcall(function() spawn.teleportToLastRoad(veh, { resetVehicle = true }) end)
          print('aplPain: escalation teleport ok=' .. tostring(ok2))
        end
      else
        print(string.format('aplPain: ремонт подтверждён (damageSum=%.1f < %.0f)', dmg, thrDmg))
      end
    end
  end
  -- Фаза 9.3: отложенный телепорт (0.2 с после resetVehicle — физике нужно обновиться)
  if painTpPending then
    painTpDelayT = painTpDelayT - dtReal
    if painTpDelayT <= 0 then
      painTpPending = false
      pcall(function()
        local veh = getVehicle()
        if veh then
          local okT, where = painTeleportNow(veh)
          painTpT = 1.0
          print('aplPain: отложенный setPosRot ok=' .. tostring(okT) .. ' ' .. tostring(where or ''))
        end
      end)
    end
  end

  -- Фаза 9.3: проверка телепорта — БЕЗ повторов (визуальный баг «прыжок 3 раза»)
  if painTpT > 0 then
    painTpT = painTpT - dtReal
    if painTpT <= 0 then
      pcall(function()
        local veh = getVehicle()
        local moved = -1
        if veh and painTpFrom then
          local ok, p = pcall(function() return veh:getPosition() end)
          if ok and p then moved = (p - painTpFrom):length() end
        end
        painLastTp = moved
        if moved >= 2 then
          print(string.format('aplPain: ТЕЛЕПОРТ проверка — moved=%.1f м (ok)', moved))
        else
          print(string.format('aplPain: WARN телепорт мог не сработать (moved=%.1f м) — повторов нет', moved))
          logLine('WARN', 'pain teleport moved=' .. string.format('%.1f', moved))
        end
      end)
    end
  end
  -- Фаза 10.1: таймаут ожидания прогрева (мастер)
  if masterPending then
    masterWaitT = masterWaitT + dtReal
    if masterWaitT > 60 then
      masterPending = false
      masterState = 'off'
      print('apl_autopilot: WARN таймаут ожидания прогрева 60 с — мастер отменён')
      logLine('WARN', 'master timeout waiting warmup')
    end
  end
  -- === Фаза 8: ночь popup (влияет на интервал следующего моргания) ===
  -- Опрос раз в ~2 с: считываем ночь по окну (как Ф6) и шлём vehicle ТОЛЬКО
  -- при смене — хронометр моргания не сбрасывается (интервал применится к
  -- следующему мигку). Работает независимо от lightsAuto (Ф8 не требует Ф6).
  if popupAuto then
    popupNightAcc = popupNightAcc + dtReal
    if popupNightAcc >= 5 then
      popupNightAcc = 0
      local okN, n = pcall(popupIsNightNow)
      if not okN then
        logLine('WARN', 'popup night check error: ' .. tostring(n))
      else
        local h = gameTodHours()
        local hs = h and string.format('%02d:%02d', math.floor(h % 24),
          math.floor((h % 1) * 60)) or '?'
        -- KEEPALIVE: шлём каждые 5 с (не только при смене) — потеря пакета не
        -- оставит vehicle в неверном дне/ночи.
        local sent = sendToVehicle('autopilotLivePopupCmd.setNight(' ..
          (n and 'true' or 'false') .. ')')
        if not sent then
          print('apl_popup: WARN setNight НЕ отправлен (машина не найдена)')
        end
        popupNightDbgAcc = popupNightDbgAcc + 5
        if n ~= popupNightLast then
          popupNightLast = n
          popupNightDbgAcc = 0
          logLine('INFO', 'popup: ночь→' .. tostring(n) .. ' (' .. hs .. ')')
          print('apl_popup: ' .. (n and 'НОЧЬ' or 'ДЕНЬ') .. ' (' .. hs ..
            ') — ' .. (n and 'моргание подавлено' or 'моргание разрешено') ..
            ', setNight=' .. tostring(sent))
        elseif popupNightDbgAcc >= 30 then
          popupNightDbgAcc = 0
          print('apl_popup: keepalive — ' .. (n and 'НОЧЬ' or 'ДЕНЬ') .. ' (' .. hs ..
            '), setNight=' .. tostring(sent ~= nil))
        end
      end
    end
  end
  if not lightsAuto then return end
  local poll = lightsCfg and tonumber(lightsCfg.timing.poll_hz) or 1
  if poll ~= poll then poll = 1 end
  if poll < 0.1 then poll = 0.1 elseif poll > 10 then poll = 10 end
  lightsAcc = lightsAcc + dtReal
  if lightsAcc < 1 / poll then return end
  lightsAcc = 0
  if lightsCfg == nil or lightsWindow == nil then return end
  local t, trans = computeLightsTarget(lightsCfg, lightsWindow)
  if t == nil then return end -- времени нет (меню/загрузка) — ждём следующего тика
  if trans then
    local timeStr = gameTodString() or '?'
    print('apl_lights: ' .. (trans == 'night' and 'НОЧЬ' or 'ДЕНЬ') ..
      ' (' .. timeStr .. ') → target=' .. tostring(t))
    logLine('INFO', 'lights ' .. trans .. ' at ' .. timeStr .. ' target=' .. tostring(t))
  end
  if t ~= lightsTarget then
    if sendToVehicle(string.format('autopilotLiveLightsCmd.setTarget(%d)', t)) then
      lightsTarget = t
      logLine('INFO', 'lights target → ' .. tostring(t) .. ' (' .. (gameTodString() or '?') .. ')')
    end
  end
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

-- === TODO Фазы 2: авто-stopCsv (2026-10-12) ===
-- Защита от закрытия игры/смены миссии без явного apl_debug() (в тесте №2
-- Фазы 1 стоп не дёрнулся, спас только flush каждые ~2 с в vehicle-слое).
function M.onShutdown()
  -- На выключении машины ещё живы: команда может успеть; если нет — спасёт
  -- flush vehicle-слоя. Лог закрываем всегда.
  stopCsvRecording()
  closeLogFile()
end

function M.onClientPostStartMission()
  -- Смена миссии: машина игрока уходит, vehicle-слой перезагружается целиком
  -- (autopilotLivePedals.active=false по умолчанию — Override'ов не остаётся)
  pedalsRequested = false
  wheelRequested = false
  warmupRequested = false
  lightsAuto = false
  lightsTarget = nil
  lightsIsNight = nil
  lightsCfg = nil
  lightsWindow = nil
  lightsAcc = 0
  popupAuto = false -- Фаза 8: авто-моргание не переживает смену миссии
  popupNightLast = false
  popupNightAcc = 0
  painAuto = false -- Фаза 9.1: авто-восстановление не переживает смену миссии
  painDamageAcc = 0
  painVerifyT = 0
  painTpT = 0
  painTpDelayT = 0
  painTpPending = false
  painTpFrom = nil
  painLastTp = -1
  masterState = 'off' -- Фаза 10.1: мастер не переживает смену миссии
  masterPending = false
  masterWaitT = 0
  petActive = false
  petSoundStop() -- Фаза 7б: луп не переживает смену миссии
  petSoundEvent = '' -- звук мурчания — только по явному on
  if not csvActive then return end
  stopCsvRecording()
  if csvActive then
    -- машина уже недоступна — команда не долетела; сбрасываем состояние сами
    csvActive = false
    csvVehicleId = nil
    logLine('WARN', 'Смена миссии: машина недоступна, состояние CSV сброшено принудительно')
  end
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

-- Фаза 10.2: встроенное радиальное меню (Quick Access)
pcall(function() extensions.load('autopilotLive/quickAccessMenu') end)

return M
