-- AutopilotLive — Фаза 12.1: Parking Mode (P1, GE-слой)
-- Загружается из main.lua: extensions.load('autopilotLive/parking').
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

local CONF = 'mods/unpacked/AutopilotLive/ai/config/parking.json'

local DEFAULTS = {
  poll_hz = 5.0,
  search_radius_m = 200.0,
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
    if extensions and extensions.autopilotLive_main
      and extensions.autopilotLive_main.onVehicleLog then
      extensions.autopilotLive_main.onVehicleLog(level or 'INFO', 'park: ' .. tostring(msg))
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

local function loadConfig()
  local c = {}
  for k, v in pairs(DEFAULTS) do c[k] = v end
  local f = io.open(CONF, 'r')
  if not f then
    note('WARN', 'конфиг не найден (' .. CONF .. ') — дефолты кода')
    return c, false
  end
  local content = f:read('*all')
  f:close()
  local ok, decoded = pcall(jsonDecode, content, CONF)
  if not ok or type(decoded) ~= 'table' then
    note('WARN', 'конфиг не распарсен — дефолты кода')
    return c, false
  end
  c.poll_hz = clampNum(decoded.poll_hz, 1, 20, c.poll_hz)
  c.search_radius_m = clampNum(decoded.search_radius_m, 10, 1000, c.search_radius_m)
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
  send('autopilotLiveParkCmd.cancel()')
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
local function findSpot(veh)
  local pp = extensions and extensions.gameplay_parking
  if not pp then return nil, 'gameplay_parking не загружен' end
  if not pp.findParkingSpots then return nil, 'gameplay_parking.findParkingSpots недоступен' end

  local pos = vehiclePos(veh)
  if not pos then return nil, 'нет позиции машины' end

  -- getParkingSpots() лениво вызывает loadSites(); без этого findParkingSpots пуст.
  pcall(function() if pp.getParkingSpots then pp.getParkingSpots() end end)

  local ok, list = pcall(function()
    return pp.findParkingSpots(pos, cfg.min_spot_radius_m, cfg.search_radius_m)
  end)
  if not ok or type(list) ~= 'table' or #list == 0 then
    return nil, 'рядом нет parking spots (sites не загружены или карта без них)'
  end

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

  local nodes = map and map.getMap and map.getMap().nodes or nil
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
  local nodes = map.getMap().nodes
  if not nodes then return n1 end
  if not nodes[n1] then return n2 end
  if not n2 or not nodes[n2] then return n1 end
  local d1 = pos:squaredDistance(nodes[n1].pos)
  local d2 = pos:squaredDistance(nodes[n2].pos)
  return (d2 < d1) and n2 or n1
end

local function buildRoute(veh, ps)
  if not map or not map.getMap then return nil, 'map недоступен' end
  local pos = vehiclePos(veh)
  if not pos then return nil, 'нет позиции машины' end

  local n1, n2 = map.findClosestRoad(ps.pos, cfg.max_spot_road_dist_m + 20)
  if not n1 then return nil, 'не найдена дорога у parking spot' end
  local node = closerNode(ps.pos, n1, n2)
  local nodes = map.getMap().nodes
  if not nodes or not nodes[node] then return nil, 'нет узла навграфа у parking spot' end

  local path = nil
  if map.getPointNodePath then
    local okP, p = pcall(function()
      return map.getPointNodePath(pos, node, 1, 1e4)
    end)
    if okP and type(p) == 'table' and #p > 0 then path = p end
  end

  if not path then
    local s1 = map.findClosestRoad(pos)
    if s1 and map.getPath then
      local okP, p = pcall(function()
        return map.getPath(s1, node, 1, 1e4)
      end)
      if okP and type(p) == 'table' and #p > 0 then path = p end
    end
  end

  if not path or #path == 0 then
    return nil, 'маршрут к parking spot не построен'
  end
  -- Не добавляем targetNode в конец, если путь уже закончился соседним узлом:
  -- иначе AI развернётся и поедет назад. Цель — последний узел маршрута.
  local finalNode = path[#path]
  local finalPos = (nodes[finalNode] and nodes[finalNode].pos) or nodes[node].pos
  return path, nil, finalNode, finalPos
end

local function routeCommand(path)
  local route = {
    wpTargetList = path,
    noOfLaps = 1,
    avoidCars = (cfg.avoid_cars > 0) and 'on' or 'off',
    driveInLane = (cfg.drive_in_lane > 0) and 'on' or 'off',
    routeSpeed = cfg.route_speed_mps,
    routeSpeedMode = 'limit',
  }
  return 'ai.driveUsingPath(' .. serialize(route) .. ')'
end

-- === Запуск auto ===
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
    fail(err)
    return false
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

  if not send(routeCommand(path)) then
    fail('не удалось отправить ai.driveUsingPath')
    return false
  end
  send('ai.setAvoidCars("' .. ((cfg.avoid_cars > 0) and 'on' or 'off') .. '")')
  setState('routing', 'едем к parking spot')
  note('INFO', 'маршрут отправлен: ' .. #path .. ' узлов, targetNode=' .. tostring(node) ..
    ', speed=' .. tostring(cfg.route_speed_mps) .. ' м/с')
  return true
end

local function requestStop()
  local opts = {
    stop_speed_mps = cfg.stop_speed_mps,
    stop_hold_s = cfg.stop_hold_s,
    stopping_timeout_s = cfg.stopping_timeout_s,
    parking_brake = cfg.parking_brake,
    engine_off = cfg.engine_off,
  }
  local ok = send('autopilotLiveParkCmd.beginStop(' .. serialize(opts) .. ')')
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
local function status()
  if not cfg then cfg = loadConfig() end
  print('--- apl_park status ---')
  print('state=' .. state .. ' (' .. string.format('%.1f', stateT) .. ' с) — ' .. tostring(message))
  print('конфиг: ' .. (cfgFromFile and 'parking.json' or 'ДЕФОЛТЫ') ..
    ', poll=' .. tostring(cfg.poll_hz) .. ' Гц, radius=' .. tostring(cfg.search_radius_m) ..
    ' м, arrival=' .. tostring(cfg.arrival_radius_m) .. ' м')
  if targetSpot then
    print('spot: id=' .. tostring(targetSpotId) .. ' name=' .. tostring(targetSpot.name) ..
      ' pos=' .. tostring(targetSpot.pos))
  else
    print('spot: нет')
  end
  if targetNode then
    print('targetNode=' .. tostring(targetNode) .. ' pathNodes=' ..
      tostring(routePath and #routePath or 0))
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
  send('autopilotLiveParkCmd.status()')
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
    send('autopilotLiveParkCmd.cancel()')
    send('ai.setMode("stop")')
    setState('cancelled', 'отменено игроком')
    note('INFO', 'CANCEL: маршрут/остановка отменены, AI stop')
    return true
  end
  if mode == 'status' then
    status()
    return true
  end
  print('Использование: apl_park("auto"|"cancel"|"status")')
  return false
end

-- === Жизненный цикл ===
function M.onExtensionLoaded()
  cfg, cfgFromFile = loadConfig()
  print('aplPark: GE-модуль загружен (Parking P1, quit отключён)')
end

function M.onClientPostStartMission()
  if state == 'routing' or state == 'stopping' then
    send('autopilotLiveParkCmd.cancel()')
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
    send('autopilotLiveParkCmd.cancel()')
  end
end

return M
