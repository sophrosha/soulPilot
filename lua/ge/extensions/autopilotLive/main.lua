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
local csvVehicleId = nil           -- id машины, начавшей CSV (fallback для stop)
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
  -- Защита: карта не загружена / map.json невалиден (схема, правка пользователя)
  local okMap, nodesMap = pcall(function() return map and map.nodes end)
  if not okMap or type(nodesMap) ~= 'table' or next(nodesMap) == nil then
    print('WARN apl_exportGraph: карта не загружена или map.json невалиден, подожди загрузки уровня')
    return false
  end

  local conf = loadGraphConfig()
  local warnings = {}
  local function warn(msg)
    warnings[#warnings + 1] = msg
  end

  -- Детерминированный порядок обхода (иначе pairs() даёт разный JSON)
  local ids = {}
  for id in pairs(nodesMap) do ids[#ids + 1] = id end
  table.sort(ids, cmpId)

  -- === Проход 1: узлы ===
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
    for toId in pairs(n.links or {}) do sibs[#sibs + 1] = toId end
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

    nodeInfo[id] = { pos = pos, degree = degree, angle = angle, sibs = sibs }
  end

  -- === Проход 2: рёбра (дедуп по edge_id: связь может лежать у обоих концов) ===
  local edgesArr = {}
  local exampleIds = {}
  for i = 1, math.min(20, #ids) do exampleIds[tostring(ids[i])] = true end
  local exampleEdges = {}
  local seen = {}
  local noRadius, noSpeed = 0, 0

  for _, id in ipairs(ids) do
    local n = nodesMap[id]
    local toList = {}
    for toId in pairs(n.links or {}) do toList[#toList + 1] = toId end
    table.sort(toList, cmpId)
    for _, toId in ipairs(toList) do
      local edge = n.links[toId]
      local eid = edgeIdOf(id, toId)
      if not seen[eid] and nodesMap[toId] then
        seen[eid] = true
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

          if exampleIds[tostring(id)] and exampleIds[tostring(toId)] then
            exampleEdges[#exampleEdges + 1] = eOut
          end
        end
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
      build_serial = (map and map.buildSerial) or 0,
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

  -- Пример формата (срез первых 20 узлов + рёбра между ними) — коммитится
  do
    local exNodes = {}
    for i = 1, math.min(20, #nodesArr) do exNodes[#exNodes + 1] = nodesArr[i] end
    jsonWriteFile(GRAPH_DIR .. 'graph.example.json', {
      meta = { format_version = 1, note = 'срез первых 20 узлов graph.json для примера формата' },
      nodes = exNodes,
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
