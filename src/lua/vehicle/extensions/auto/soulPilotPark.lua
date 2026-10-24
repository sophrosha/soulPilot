-- soulPilot — Фаза 12.1: Parking Mode (P1, vehicle-слой)
-- Загружается автоматически (lua/vehicle/extensions/auto).
--
-- Ответственность:
--   * по команде GE (soulPilotParkCmd.beginStop) включить ai.setMode("stop");
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

-- Аварийный выход: AI выбрал R, но машина не может сдвинуться.
local REVERSE_STUCK_TIME_S = 3.0
local REVERSE_STUCK_SPEED_MPS = 0.5 / 3.6 -- 0.5 км/ч

-- phase: idle | stopping | parked | failed
local phase = 'idle'
local opts = nil
local elapsed = 0
local holdT = 0
local reverseStuckT = 0

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
      'if extensions and extensions.soulPilot_parking and extensions.soulPilot_parking.%s then extensions.soulPilot_parking.%s(%s) end',
      method, method, args or ''))
  end)
end

local function logGE(msg)
  aplPrint('aplPark(vehicle): ' .. tostring(msg))
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if extensions and extensions.soulPilot_main and extensions.soulPilot_main.onVehicleLog then extensions.soulPilot_main.onVehicleLog("INFO", %s) end',
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

-- Поддержка разных КПП: gearIndex < 0, gear == -1/"-1"/"R".
local function isReverseGear()
  local gear, gearIndex
  pcall(function()
    gear = electrics.values.gear
    gearIndex = electrics.values.gearIndex
  end)
  local index = tonumber(gearIndex)
  if index ~= nil and index < 0 then return true end
  local value = tostring(gear or ''):upper()
  return value == 'R' or value == '-1' or value == 'REVERSE'
end

local function finishPark()
  local pbOk, pbErr = pcall(function()
    controller.mainController.smartParkingBrake(1, FILTER_DIRECT, true)
  end)
  aplPrint('aplPark(vehicle): ручник=' .. tostring(pbOk) ..
    (pbOk and '' or (' (' .. tostring(pbErr) .. ')')))

  local ignOk, ignErr = false, nil
  if opts.engine_off > 0 then
    ignOk, ignErr = pcall(function()
      electrics.setIgnitionLevel(0)
    end)
    aplPrint('aplPark(vehicle): зажигание 0=' .. tostring(ignOk) ..
      (ignOk and ' (автомат выберет P/N)' or (' (' .. tostring(ignErr) .. ')')))
  else
    aplPrint('aplPark(vehicle): engine_off=0 — двигатель оставлен')
  end

  phase = 'parked'
  reverseStuckT = 0
  holdT = 0
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
soulPilotParkCmd = {}

function soulPilotParkCmd.beginStop(newOpts)
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
  reverseStuckT = 0
  pcall(function() ai.setMode('stop') end)
  aplPrint(string.format(
    'aplPark(vehicle): STOP — ждём %.2f м/с %.1f с (timeout %.0f с), brake=%d, engine_off=%d',
    opts.stop_speed_mps, opts.stop_hold_s, opts.stopping_timeout_s,
    opts.parking_brake, opts.engine_off))
  return true
end

function soulPilotParkCmd.cancel()
  if phase == 'idle' then return false end
  if phase == 'parked' then
    aplPrint('aplPark(vehicle): уже припарковано; cancel не снимает ручник')
    return false
  end
  phase = 'idle'
  elapsed = 0
  holdT = 0
  reverseStuckT = 0
  pcall(function() ai.setMode('stop') end)
  aplPrint('aplPark(vehicle): отменено (ручник/зажигание не трогаем)')
  return true
end

function soulPilotParkCmd.status()
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
  local reversing = isReverseGear()

  -- AI включил заднюю, но машина стоит: на мосту/в узком месте
  -- заезд невозможен. Через 3 с просто паркуемся на месте.
  if reversing and speed < REVERSE_STUCK_SPEED_MPS then
    reverseStuckT = reverseStuckT + dt
  else
    reverseStuckT = 0
  end

  if reverseStuckT >= REVERSE_STUCK_TIME_S then
    print("aplPark: застрял на задней передаче, аварийное завершение")
    finishPark()
    return
  end

  if speed <= opts.stop_speed_mps then
    holdT = holdT + dt
  else
    holdT = 0
  end

  -- В режиме R не завершаем по обычному hold: даём шанс выйти
  -- из застревания, затем сработает аварийный таймер выше.
  if holdT >= opts.stop_hold_s
    and not (reversing and speed < REVERSE_STUCK_SPEED_MPS) then
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
    reverseStuckT = 0
  end
end

function M.onVehicleDestroyed()
  phase = 'idle'
  elapsed = 0
  holdT = 0
  reverseStuckT = 0
  opts = nil
end

return M
