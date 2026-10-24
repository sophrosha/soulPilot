-- soulPilot — Фаза 12.1: Parking Mode (P1, GE-слой)
-- Загружается из main.lua: extensions.load('soulPilot/parking').
--
-- Команда: apl_park("auto"|"cancel"|"status").
--   auto   — найти ближайшее свободное место через gameplay_parking,
--            построить маршрут по навграфу и отправить AI;
--   cancel — отменить маршрут/остановку (AI получает stop);
--   status — состояние, цель, дистанция, конфиг.
--
-- P1 НЕ закрывает игру (quit_game игнорируется, это P3).
-- Парковка = остановка у ближайшей дорожной точки к parking spot;
-- точный заезд в узкое место задним ходом — отдельная фаза P2.

local M = {}

local CONF_USER = 'settings/mod_settings/soulPilot/parking.json'
local CONF_MOD = 'mods/unpacked/soulPilot/src/config/parking.json'

local DEFAULTS = {
  poll_hz = 5.0,
  search_radius_m = 999999.0,
  min_spot_radius_m = 5.0,
  max_spot_road_dist_m = 35.0,
  arrival_radius_m = 14.0,
  route_speed_mps = 7.0,
  drive_in_lane = 1,
  avoid_cars = 1,
  stop_speed_mps = 0.35,
  stop_hold_s = 1.2,
  parking_brake = 1,
  engine_off = 1,
  routing_timeout_s = 120.0,
  stopping_timeout_s = 25.0,
  stuck_speed_mps = 0.4,
  stuck_time_s = 8.0,
  quit_game = 0,
  quit_delay_s = 5.0,
}

-- Если рядом с машиной мест нет — ищем по всей карте.
local MAP_WIDE_RADIUS_M = 999999.0

local cfg = nil
local cfgFromFile = false

-- state: idle | searching | routing | stopping | parked | cancelled | failed
local state = 'idle'
local stateT = 0
local pollAcc = 0
local stuckT = 0
local message = ''
local vehId = nil
local targetSpot = nil
local targetSpotId = nil
local targetPos = nil
local targetNode = nil
local targetNodePos = nil
local routePath = nil

local function note(level, msg)
  print('aplPark: ' .. tostring(msg))
  pcall(function()
    if extensions and extensions.soulPilot_main
      and extensions.soulPilot_main.onVehicleLog then
      extensions.soulPilot_main.onVehicleLog(level or 'INFO', 'park: ' .. tostring(msg))
    end
  end)
end

local function clampNum(v, lo, hi, dflt)
  v = tonumber(v)
  if v == nil or v ~= v then return dflt end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function fmtVec(v)
  if v == nil then return 'nil' end
  local ok, x, y, z = pcall(function() return v.x, v.y, v.z end)
  if ok and x ~= nil and y ~= nil and z ~= nil then
    return string.format('(%.1f, %.1f, %.1f)', x, y, z)
  end
  return tostring(v)
end

local function loadConfig()
  local c = {}
  for k, v in pairs(DEFAULTS) do c[k] = v end
  local path = CONF_USER
  local f = io.open(path, 'r')
  if not f then
    path = CONF_MOD
    f = io.open(path, 'r')
  end
  if not f then
    note('WARN', 'конфиг не найден (' .. path .. ') — дефолты кода')
    return c, false
  end
  local content = f:read('*all')
  f:close()
  local ok, decoded = pcall(jsonDecode, content, path)
  if not ok or type(decoded) ~= 'table' then
    note('WARN', 'конфиг не распарсен — дефолты кода')
    return c, false
  end
  c.poll_hz = clampNum(decoded.poll_hz, 1, 20, c.poll_hz)
  c.search_radius_m = clampNum(decoded.search_radius_m, 10, 999999, c.search_radius_m)
  c.min_spot_radius_m = clampNum(decoded.min_spot_radius_m, 0, 100, c.min_spot_radius_m)
  c.max_spot_road_dist_m = clampNum(decoded.max_spot_road_dist_m, 2, 100, c.max_spot_road_dist_m)
  c.arrival_radius_m = clampNum(decoded.arrival_radius_m, 3, 100, c.arrival_radius_m)
  c.route_speed_mps = clampNum(decoded.route_speed_mps, 1, 40, c.route_speed_mps)
  c.drive_in_lane = clampNum(decoded.drive_in_lane, 0, 1, c.drive_in_lane)
  c.avoid_cars = clampNum(decoded.avoid_cars, 0, 1, c.avoid_cars)
  c.stop_speed_mps = clampNum(decoded.stop_speed_mps, 0.05, 3, c.stop_speed_mps)
  c.stop_hold_s = clampNum(decoded.stop_hold_s, 0.2, 10, c.stop_hold_s)
  c.parking_brake = clampNum(decoded.parking_brake, 0, 1, c.parking_brake)
  c.engine_off = clampNum(decoded.engine_off, 0, 1, c.engine_off)
  c.routing_timeout_s = clampNum(decoded.routing_timeout_s, 10, 900, c.routing_timeout_s)
  c.stopping_timeout_s = clampNum(decoded.stopping_timeout_s, 5, 120, c.stopping_timeout_s)
  c.stuck_speed_mps = clampNum(decoded.stuck_speed_mps, 0.05, 5, c.stuck_speed_mps)
  c.stuck_time_s = clampNum(decoded.stuck_time_s, 2, 120, c.stuck_time_s)
  c.quit_game = clampNum(decoded.quit_game, 0, 1, c.quit_game)
  c.quit_delay_s = clampNum(decoded.quit_delay_s, 1, 60, c.quit_delay_s)
  return c, true
end

local function playerVehicle()
  local ok, veh = pcall(function()
    return getPlayerVehicle and getPlayerVehicle(0)
  end)
  if ok and veh then return veh end
  return nil
end

local function send(cmd)
  local veh = playerVehicle()
  if not veh or not veh.queueLuaCommand then return false end
  local ok = pcall(function() veh:queueLuaCommand(cmd) end)
  return ok
end

local function setState(newState, msg)
  state = newState
  stateT = 0
  stuckT = 0
  if msg then message = msg end
end

local function fail(msg)
  if state == 'idle' or state == 'cancelled' or state == 'failed' then return end
  message = tostring(msg or 'ошибка')
  note('WARN', 'FAIL: ' .. message)
  send('soulPilotParkCmd.cancel()')
  send('ai.setMode("stop")')
  setState('failed', message)
end

local function vehicleSpeed(veh)
  local ok, len = pcall(function()
    local vel = veh:getVelocity()
    return vel:length()
  end)
  if not ok then return 0 end
  local v = tonumber(len)
  if v == nil or v ~= v then return 0 end
  return v
end

local function vehiclePos(veh)
  local ok, pos = pcall(function() return veh:getPosition() end)
  if ok then return pos end
  return nil
end

-- === Поиск парковочного места ===
local function querySpots(pp, pos, radius)
  if not pp or not pp.findParkingSpots then return {} end
  local ok, list = pcall(function()
    return pp.findParkingSpots(pos, cfg.min_spot_radius_m, radius)
  end)
  if not ok or type(list) ~= 'table' then return {} end

  if pp.filterParkingSpots then
    local okF, filtered = pcall(function()
      return pp.filterParkingSpots(list, {
        standardSize = true,
        checkVehicles = true,
        useProbability = false,
      })
    end)
    if okF and type(filtered) == 'table' then list = filtered end
  end
  return list
end

local function findSpot(veh)
  local pp = extensions and extensions.gameplay_parking
  if not pp then return nil, 'gameplay_parking не загружен' end
  if not pp.findParkingSpots then return nil, 'gameplay_parking.findParkingSpots недоступен' end

  local pos = vehiclePos(veh)
  if not pos then return nil, 'нет позиции машины' end

  -- getParkingSpots() лениво вызывает loadSites(); без этого findParkingSpots пуст.
  pcall(function() if pp.getParkingSpots then pp.getParkingSpots() end end)

  local list = querySpots(pp, pos, cfg.search_radius_m)
  if #list == 0 and cfg.search_radius_m < MAP_WIDE_RADIUS_M then
    note('INFO', 'в радиусе ' .. tostring(cfg.search_radius_m) ..
      ' м мест нет — ищу по всей карте')
    list = querySpots(pp, pos, MAP_WIDE_RADIUS_M)
  end
  if #list == 0 then
    return nil, 'на карте нет parking spots (sites не загружены или карта без них)'
  end

  local mapData = map and map.getMap and map.getMap() or nil
  local nodes = mapData and mapData.nodes or nil
  local myId = nil
  pcall(function() myId = veh:getID() end)

  for _, entry in ipairs(list) do
    local ps = entry.ps or entry
    if ps and ps.pos then
      local free = true
      if ps.vehicle ~= nil and ps.vehicle ~= 0 and ps.vehicle ~= myId then
        free = false
      end
      if free and ps.vehicleFits then
        local okFit, fits = pcall(function() return ps:vehicleFits(myId) end)
        if okFit and fits == false then free = false end
      end
      if free then
        local n1, n2, roadDist = nil, nil, nil
        if map and map.findClosestRoad then
          local okR, a, b, d = pcall(map.findClosestRoad, ps.pos, cfg.max_spot_road_dist_m + 20)
          if okR then n1, n2, roadDist = a, b, d end
        end
        if n1 and roadDist and roadDist <= cfg.max_spot_road_dist_m then
          -- Проверяем, что узлы реально есть в карте.
          if nodes and nodes[n1] then
            return ps, nil, n1, n2
          end
        end
      end
    end
  end

  return nil, 'нет свободных мест рядом с дорогой'
end

-- === Маршрут ===
local function closerNode(pos, n1, n2)
  local mapData = map and map.getMap and map.getMap()
  local nodes = mapData and mapData.nodes
  if not nodes then return n1 end
  if not nodes[n1] then return n2 end
  if not n2 or not nodes[n2] then return n1 end
  local d1 = pos:squaredDistance(nodes[n1].pos)
  local d2 = pos:squaredDistance(nodes[n2].pos)
  return (d2 < d1) and n2 or n1
end

-- Строгая проверка: все узлы существуют, соединены ребром, маршрут
-- начинается рядом с машиной и заканчивается рядом с parking spot.
local function validateRoute(path, nodes, vehPos, spotPos)
  if type(path) ~= 'table' or #path < 2 then
    return false, 'failed_route: getPointNodePath вернул ' ..
      tostring(type(path) == 'table' and #path or 0) .. ' узлов (<2)'
  end

  local clean = {}
  for _, id in ipairs(path) do
    if nodes[id] == nil then
      return false, 'failed_route: узел ' .. tostring(id) .. ' отсутствует в map.nodes'
    end
    if clean[#clean] ~= id then table.insert(clean, id) end
  end
  if #clean < 2 then
    return false, 'failed_route: после удаления дублей осталось <2 узлов'
  end

  for i = 1, #clean - 1 do
    local a, b = clean[i], clean[i + 1]
    local na, nb = nodes[a], nodes[b]
    local linked = (na.links and na.links[b] ~= nil)
      or (nb.links and nb.links[a] ~= nil)
    if not linked then
      return false, 'failed_route: нет связи ' .. tostring(a) .. ' -> ' .. tostring(b)
    end
  end

  -- Машина должна стоять на дороге/у дороги; иначе getPointNodePath
  -- рисует виртуальное ребро через лес до первого узла.
  local vn1, _, vDist = nil, nil, nil
  if map and map.findClosestRoad then
    local okV, a, b, d = pcall(map.findClosestRoad, vehPos, 50)
    if okV then vn1, _, vDist = a, b, d end
  end
  if not vn1 or (vDist and vDist > 15) then
    return false, 'failed_route: машина слишком далеко от дороги (' ..
      string.format('%.1f', tonumber(vDist) or -1) .. ' м)'
  end

  local firstDist = nodes[clean[1]].pos:distance(vehPos)
  if firstDist > 80 then
    return false, 'failed_route: первый узел слишком далеко от машины (' ..
      string.format('%.1f', firstDist) .. ' м)'
  end

  local lastDist = nodes[clean[#clean]].pos:distance(spotPos)
  local maxLast = cfg.max_spot_road_dist_m + cfg.arrival_radius_m
  if lastDist > maxLast then
    return false, 'failed_route: конец маршрута далеко от spot (' ..
      string.format('%.1f', lastDist) .. ' м > ' .. string.format('%.1f', maxLast) .. ' м)'
  end

  return true, clean
end

local function buildRoute(veh, ps)
  if not map or not map.getMap or not map.getPointNodePath then
    return nil, 'failed_route: map API недоступен'
  end
  local pos = vehiclePos(veh)
  if not pos then return nil, 'failed_route: нет позиции машины' end

  local mapData = map.getMap()
  local nodes = mapData and mapData.nodes
  if not nodes then return nil, 'failed_route: map.nodes недоступен' end

  local n1, n2 = map.findClosestRoad(ps.pos, cfg.max_spot_road_dist_m + 20)
  if not n1 then return nil, 'failed_route: нет дороги у parking spot' end
  local node = closerNode(ps.pos, n1, n2)
  if not nodes[node] then
    return nil, 'failed_route: целевой узел отсутствует в map.nodes'
  end

  -- Только getPointNodePath. Никаких fallback-ов через map.getPath:
  -- иначе можно получить несвязанный/пустой путь и поехать напрямик.
  local okP, path = pcall(map.getPointNodePath, pos, node, 0, 1e4, nil, nil, 4)
  if not okP then
    return nil, 'failed_route: getPointNodePath error: ' .. tostring(path)
  end

  local okValidate, validated = validateRoute(path, nodes, pos, ps.pos)
  if not okValidate then return nil, validated end
  path = validated
  node = path[#path]

  return path, nil, node, nodes[node].pos
end

-- wpTargetList — это СПИСОК ЦЕЛЕЙ, а не готовый маршрут. Даём одну
-- достижимую цель; сам AI построит путь от текущей позиции по навграфу.
local function routeCommand(targetNode)
  local route = {
    wpTargetList = { targetNode },
    noOfLaps = 1,
    avoidCars = (cfg.avoid_cars > 0) and 'on' or 'off',
    driveInLane = (cfg.drive_in_lane > 0) and 'on' or 'off',
    routeSpeed = cfg.route_speed_mps,
    routeSpeedMode = 'limit',
  }
  return 'ai.driveUsingPath(' .. serialize(route) .. ')'
end

-- === Запуск auto ===
local requestStop

local function startAuto()
  local veh = playerVehicle()
  if not veh then
    note('WARN', 'нет машины игрока')
    return false
  end
  if state == 'searching' or state == 'routing' or state == 'stopping' then
    note('WARN', 'уже выполняется (' .. state .. '); apl_park("cancel") для отмены')
    return false
  end

  cfg, cfgFromFile = loadConfig()
  targetSpot, targetSpotId, targetPos, targetNode, targetNodePos, routePath = nil, nil, nil, nil, nil, nil
  pcall(function() vehId = veh:getID() end)

  setState('searching', 'поиск parking spot')
  note('INFO', 'поиск места: радиус ' .. tostring(cfg.search_radius_m) .. ' м, max до дороги ' ..
    tostring(cfg.max_spot_road_dist_m) .. ' м')

  local ps, err, n1, n2 = findSpot(veh)
  if not ps then
    local pos = vehiclePos(veh)
    if not pos then
      fail(err)
      return false
    end
    -- На карте нет парковок: не ошибка, а fallback — стоим у обочины.
    note('WARN', 'парковка не найдена (' .. tostring(err) ..
      ') — fallback: остановка у обочины')
    targetSpot, targetSpotId = nil, 'roadside'
    targetPos = pos
    targetNode, targetNodePos, routePath = nil, nil, nil
    requestStop()
    return true
  end

  targetSpot = ps
  targetSpotId = ps.id
  targetPos = ps.pos
  note('INFO', 'место найдено: id=' .. tostring(ps.id) .. ' name=' .. tostring(ps.name) ..
    ' dist=' .. string.format('%.1f', vehiclePos(veh):distance(ps.pos)) .. ' м')

  local path, routeErr, node, nodePos = buildRoute(veh, ps)
  if not path then
    fail(routeErr)
    return false
  end
  routePath = path
  targetNode = node
  targetNodePos = nodePos

  -- ВАЖНО: сначала traffic-режим (инициализирует mapmgr/маршрутизацию),
  -- потом уже маршрут. wpTargetList — одна достижимая цель, не список
  -- всех узлов (иначе AI может трактовать их как отдельные цели).
  if not send('ai.setMode("traffic")') then
    fail('failed_route: не удалось включить ai.setMode("traffic")')
    return false
  end
  send('ai.setPullOver(false)')
  send('ai.setSpeedMode("limit")')

  if not send(routeCommand(node)) then
    fail('failed_route: не удалось отправить ai.driveUsingPath')
    return false
  end
  send('ai.setAvoidCars("' .. ((cfg.avoid_cars > 0) and 'on' or 'off') .. '")')
  setState('routing', 'едем к parking spot')
  note('INFO', 'маршрут отправлен: проверено ' .. #path .. ' узлов, targetNode=' .. tostring(node) ..
    ', speed=' .. tostring(cfg.route_speed_mps) .. ' м/с')
  return true
end

requestStop = function()
  local opts = {
    stop_speed_mps = cfg.stop_speed_mps,
    stop_hold_s = cfg.stop_hold_s,
    stopping_timeout_s = cfg.stopping_timeout_s,
    parking_brake = cfg.parking_brake,
    engine_off = cfg.engine_off,
  }
  local ok = send('soulPilotParkCmd.beginStop(' .. serialize(opts) .. ')')
  if not ok then
    fail('vehicle не принял beginStop')
    return
  end
  setState('stopping', 'остановка и ручник')
  note('INFO', 'arrival: отправлен beginStop (stop ' .. tostring(cfg.stop_speed_mps) ..
    ' м/с, hold ' .. tostring(cfg.stop_hold_s) .. ' с)')
end

-- === Тик GE ===
function M.onUpdate(dtReal)
  if state ~= 'routing' and state ~= 'stopping' then return end
  if dtReal == nil or dtReal ~= dtReal or dtReal <= 0 or dtReal > 1 then return end

  stateT = stateT + dtReal
  pollAcc = pollAcc + dtReal
  local pollDt = 1 / math.max(cfg and cfg.poll_hz or 5, 1)
  if pollAcc < pollDt then return end
  pollAcc = 0

  local veh = playerVehicle()
  if not veh then
    fail('машина игрока пропала')
    return
  end

  local pos = vehiclePos(veh)
  local speed = vehicleSpeed(veh)
  if not pos then
    fail('нет позиции машины')
    return
  end

  if state == 'routing' then
    local dist = pos:distance(targetPos)
    local distNode = targetNodePos and pos:distance(targetNodePos) or dist
    local approach = math.min(dist, distNode)
    if approach <= cfg.arrival_radius_m then
      requestStop()
      return
    end

    if speed < cfg.stuck_speed_mps then
      stuckT = stuckT + pollDt
    else
      stuckT = 0
    end
    if stuckT >= cfg.stuck_time_s then
      fail('AI стоит на месте более ' .. tostring(cfg.stuck_time_s) .. ' с')
      return
    end
    if stateT >= cfg.routing_timeout_s then
      fail('таймаут маршрута ' .. tostring(cfg.routing_timeout_s) .. ' с')
    end
    return
  end

  if state == 'stopping' then
    if stateT >= cfg.stopping_timeout_s then
      fail('таймаут остановки ' .. tostring(cfg.stopping_timeout_s) .. ' с')
    end
  end
end

-- === Коллбэки vehicle-слоя ===
function M.onVehicleParked(id, info)
  if state ~= 'stopping' then return end
  setState('parked', 'припарковано')
  note('INFO', 'ГОТОВО: машина припаркована (veh=' .. tostring(id or vehId) ..
    ', spot=' .. tostring(targetSpotId) .. ', ' .. tostring(info or '') .. ')')
end

function M.onVehicleParkFailed(reason)
  if state == 'stopping' then
    fail('vehicle: ' .. tostring(reason or 'ошибка остановки'))
  end
end

-- === Команда apl_park ===
local function routeDiag()
  if not cfg then cfg = loadConfig() end
  print('--- apl_park route diag ---')
  print('state=' .. state .. ' (' .. tostring(message) .. ')')
  print('routeNodes=' .. tostring(routePath and #routePath or 0) ..
    ', targetNode=' .. tostring(targetNode))
  print('targetNodePos=' .. fmtVec(targetNodePos) ..
    ', targetPos=' .. fmtVec(targetPos))
  local nodes = nil
  if map and map.getMap then
    local ok, mapData = pcall(map.getMap)
    if ok and mapData then nodes = mapData.nodes end
  end
  if routePath and nodes then
    local prev = nil
    for i, id in ipairs(routePath) do
      local n = nodes[id]
      local linked = 'linkPrev=n/a'
      if prev and n and nodes[prev] then
        linked = 'linkPrev=' .. tostring(
          (nodes[prev].links and nodes[prev].links[id] ~= nil)
          or (n.links and n.links[prev] ~= nil))
      end
      print(string.format('[%d] id=%s pos=%s %s', i, tostring(id),
        n and fmtVec(n.pos) or 'NIL', linked))
      prev = id
    end
  end
  if targetSpot and targetPos then
    print('spot=' .. tostring(targetSpotId) .. ' name=' .. tostring(targetSpot.name) ..
      ' pos=' .. fmtVec(targetPos))
  end
  local veh = playerVehicle()
  if veh and targetPos then
    local p = vehiclePos(veh)
    if p then print(string.format('vehDistToSpot=%.1f м', p:distance(targetPos))) end
  end
end

local function status()
  if not cfg then cfg = loadConfig() end
  print('--- apl_park status ---')
  print('state=' .. state .. ' (' .. string.format('%.1f', stateT) .. ' с) — ' .. tostring(message))
  print('конфиг: ' .. (cfgFromFile and 'parking.json' or 'ДЕФОЛТЫ') ..
    ', poll=' .. tostring(cfg.poll_hz) .. ' Гц, radius=' .. tostring(cfg.search_radius_m) ..
    ' м, arrival=' .. tostring(cfg.arrival_radius_m) .. ' м')
  if targetSpot then
    print('spot: id=' .. tostring(targetSpotId) .. ' name=' .. tostring(targetSpot.name) ..
      ' pos=' .. fmtVec(targetSpot.pos))
  else
    print('spot: нет')
  end
  if targetNode then
    print('targetNode=' .. tostring(targetNode) .. ' pos=' .. fmtVec(targetNodePos) ..
      ' pathNodes=' .. tostring(routePath and #routePath or 0))
  end
  local veh = playerVehicle()
  if veh then
    local pos = vehiclePos(veh)
    local speed = vehicleSpeed(veh)
    if pos and targetPos then
      print(string.format('veh: speed=%.2f м/с, distToSpot=%.1f м',
        speed, pos:distance(targetPos)))
    else
      print(string.format('veh: speed=%.2f м/с', speed))
    end
  else
    print('veh: нет машины игрока')
  end
  send('soulPilotParkCmd.status()')
end

function apl_park(mode)
  mode = tostring(mode or 'auto'):lower()
  if mode == '' or mode == 'auto' or mode == 'on' then
    return startAuto()
  end
  if mode == 'cancel' or mode == 'off' then
    if state == 'idle' or state == 'cancelled' or state == 'failed' then
      print('apl_park: нечего отменять (state=' .. state .. ')')
      return false
    end
    if state == 'parked' then
      print('apl_park: уже припарковано; отмена не снимает ручник')
      return false
    end
    send('soulPilotParkCmd.cancel()')
    send('ai.setMode("stop")')
    setState('cancelled', 'отменено игроком')
    note('INFO', 'CANCEL: маршрут/остановка отменены, AI stop')
    return true
  end
  if mode == 'route' or mode == 'diag' then
    routeDiag()
    return true
  end
  if mode == 'status' then
    status()
    return true
  end
  print('Использование: apl_park("auto"|"cancel"|"status"|"route")')
  return false
end

-- === Жизненный цикл ===
function M.onExtensionLoaded()
  cfg, cfgFromFile = loadConfig()
  print('aplPark: GE-модуль загружен (Parking P1, quit отключён)')
end

function M.onClientPostStartMission()
  if state == 'routing' or state == 'stopping' then
    send('soulPilotParkCmd.cancel()')
    send('ai.setMode("stop")')
  end
  state = 'idle'
  stateT = 0
  pollAcc = 0
  stuckT = 0
  message = ''
  targetSpot, targetSpotId, targetPos, targetNode, targetNodePos, routePath = nil, nil, nil, nil, nil, nil
end

function M.onExtensionUnloaded()
  if state == 'routing' or state == 'stopping' then
    send('soulPilotParkCmd.cancel()')
  end
end

return M
