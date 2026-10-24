-- AutopilotLive — Фаза 12.1: Parking Mode (P1, vehicle-слой)
-- Загружается автоматически (lua/vehicle/extensions/auto).
--
-- Ответственность:
--   * по команде GE (autopilotLiveParkCmd.beginStop) включить ai.setMode("stop");
--   * дождаться реальной остановки (speed <= stop_speed_mps в течение stop_hold_s);
--   * поставить ручник smartParkingBrake(1) и заглушить двигатель
--     (electrics.setIgnitionLevel(0)); автомат сам выберет P/N;
--   * сообщить GE onVehicleParked / onVehicleParkFailed.
--
-- НЕ трогает газ/тормоз/КПП напрямую, НЕ вызывает input.event,
-- НЕ закрывает игру (P3 — quit).

local M = {}

local DEFAULTS = {
  stop_speed_mps = 0.35,
  stop_hold_s = 1.2,
  stopping_timeout_s = 25.0,
  parking_brake = 1,
  engine_off = 1,
}

-- phase: idle | stopping | parked | failed
local phase = 'idle'
local opts = nil
local elapsed = 0
local holdT = 0

local function clampNum(v, lo, hi, dflt)
  v = tonumber(v)
  if v == nil or v ~= v then return dflt end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function q(s)
  return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

local function notify(method, args)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if extensions and extensions.autopilotLive_parking and extensions.autopilotLive_parking.%s then extensions.autopilotLive_parking.%s(%s) end',
      method, method, args or ''))
  end)
end

local function logGE(msg)
  print('aplPark(vehicle): ' .. tostring(msg))
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if extensions and extensions.autopilotLive_main and extensions.autopilotLive_main.onVehicleLog then extensions.autopilotLive_main.onVehicleLog("INFO", %s) end',
      q('park: ' .. tostring(msg))))
  end)
end

local function speedMps()
  local v = 0
  pcall(function() v = obj:getVelocity():length() end)
  v = tonumber(v) or 0
  if v ~= v then return 0 end
  return v
end

local function finishPark()
  local pbOk, pbErr = pcall(function()
    controller.mainController.smartParkingBrake(1, FILTER_DIRECT, true)
  end)
  print('aplPark(vehicle): ручник=' .. tostring(pbOk) ..
    (pbOk and '' or (' (' .. tostring(pbErr) .. ')')))

  local ignOk, ignErr = false, nil
  if opts.engine_off > 0 then
    ignOk, ignErr = pcall(function()
      electrics.setIgnitionLevel(0)
    end)
    print('aplPark(vehicle): зажигание 0=' .. tostring(ignOk) ..
      (ignOk and ' (автомат выберет P/N)' or (' (' .. tostring(ignErr) .. ')')))
  else
    print('aplPark(vehicle): engine_off=0 — двигатель оставлен')
  end

  phase = 'parked'
  local id = 0
  pcall(function() id = obj:getID() end)
  local info = string.format('brake=%s,ignition=%s,speed=%.3f',
    tostring(pbOk), tostring(ignOk), speedMps())
  notify('onVehicleParked', string.format('%d, %s', id, q(info)))
  logGE('припарковано: ' .. info)
end

local function failPark(reason)
  if phase ~= 'stopping' then return end
  phase = 'failed'
  notify('onVehicleParkFailed', q(reason))
  logGE('FAIL: ' .. tostring(reason))
end

-- === Публичные команды (GE шлёт через queueLuaCommand) ===
autopilotLiveParkCmd = {}

function autopilotLiveParkCmd.beginStop(newOpts)
  if phase == 'stopping' then return false end
  local o = type(newOpts) == 'table' and newOpts or {}
  opts = {
    stop_speed_mps = clampNum(o.stop_speed_mps, 0.05, 3.0, DEFAULTS.stop_speed_mps),
    stop_hold_s = clampNum(o.stop_hold_s, 0.2, 10.0, DEFAULTS.stop_hold_s),
    stopping_timeout_s = clampNum(o.stopping_timeout_s, 5.0, 120.0, DEFAULTS.stopping_timeout_s),
    parking_brake = clampNum(o.parking_brake, 0, 1, DEFAULTS.parking_brake),
    engine_off = clampNum(o.engine_off, 0, 1, DEFAULTS.engine_off),
  }
  phase = 'stopping'
  elapsed = 0
  holdT = 0
  pcall(function() ai.setMode('stop') end)
  print(string.format(
    'aplPark(vehicle): STOP — ждём %.2f м/с %.1f с (timeout %.0f с), brake=%d, engine_off=%d',
    opts.stop_speed_mps, opts.stop_hold_s, opts.stopping_timeout_s,
    opts.parking_brake, opts.engine_off))
  return true
end

function autopilotLiveParkCmd.cancel()
  if phase == 'idle' then return false end
  if phase == 'parked' then
    print('aplPark(vehicle): уже припарковано; cancel не снимает ручник')
    return false
  end
  phase = 'idle'
  elapsed = 0
  holdT = 0
  pcall(function() ai.setMode('stop') end)
  print('aplPark(vehicle): отменено (ручник/зажигание не трогаем)')
  return true
end

function autopilotLiveParkCmd.status()
  print('--- apl_park status (vehicle) ---')
  print('phase=' .. phase .. string.format(' elapsed=%.2f hold=%.2f', elapsed, holdT))
  print(string.format('speed=%.3f м/с', speedMps()))
  if opts then
    print(string.format('opts: stop=%.2f hold=%.1f timeout=%.0f brake=%d engine_off=%d',
      opts.stop_speed_mps, opts.stop_hold_s, opts.stopping_timeout_s,
      opts.parking_brake, opts.engine_off))
  end
  return true
end

-- === Кадр ===
function M.updateGFX(dt)
  if phase ~= 'stopping' then return end
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then return end

  elapsed = elapsed + dt
  local speed = speedMps()

  if speed <= opts.stop_speed_mps then
    holdT = holdT + dt
  else
    holdT = 0
  end

  if holdT >= opts.stop_hold_s then
    finishPark()
    return
  end

  if elapsed >= opts.stopping_timeout_s then
    failPark('stopping timeout ' .. string.format('%.0f', opts.stopping_timeout_s) .. 's')
  end
end

-- === Жизненный цикл ===
function M.onReset()
  if phase == 'stopping' then
    phase = 'idle'
    elapsed = 0
    holdT = 0
  end
end

function M.onVehicleDestroyed()
  phase = 'idle'
  elapsed = 0
  holdT = 0
  opts = nil
end

return M
