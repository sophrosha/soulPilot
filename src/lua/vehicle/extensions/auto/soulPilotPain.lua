-- soulPilot — Фаза 9.1: «Система Боли» (vehicle-слой)
-- Детекторы: STUCK (AI газует, но не едет), FLIPPED (лежит на боку/крыше),
-- DAMAGE (порог урона — значение приходит из GE: getSectionDamageSum доступен
-- только в GE-слое). Действия (телепорт/ремонт) выполняет GE (vanilla API).

local M = {}

local DEFAULTS = {
  check_hz = 1.0,
  damage_threshold = 50000.0,
  stuck_speed_kph = 5.0,
  stuck_time_s = 5.0,
  stuck_throttle_min = 0.5,
  flipped_up_dot = 0.3,
  flipped_time_s = 2.0,
  cooldown_s = 15.0,
}

local active = false
local cfg = nil
local checkT = 0        -- аккумулятор опроса
local stuckT = 0
local flippedT = 0
local cooldownT = 0
local damage = 0        -- приходит из GE (setDamage)
local ignoreT = 0       -- сек «неуязвимости» после ремонта/телепорта (Фаза 9.5)
local dmgReqT = 0       -- Фаза 10.5: раз в 2 с просим урон у GE (без onUpdate)
local lastKind = '—'

local function toGE(level, msg)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if extensions and extensions.soulPilot_main and extensions.soulPilot_main.onVehicleLog then extensions.soulPilot_main.onVehicleLog("%s", "%s") end',
      level, tostring(msg):gsub('\\', '\\\\'):gsub('"', '\\"')))
  end)
end

local function notifyGE(kind, info)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if extensions and extensions.soulPilot_main and extensions.soulPilot_main.onVehiclePain then extensions.soulPilot_main.onVehiclePain("%s", "%s") end',
      tostring(kind):gsub('"', ''), tostring(info or ''):gsub('\\', '\\\\'):gsub('"', '\\"')))
  end)
end

local function clampNum(v, lo, hi, dflt)
  v = tonumber(v)
  if v == nil or v ~= v then return dflt end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function speedKph()
  local s = 0
  pcall(function() s = electrics.values.wheelspeed or 0 end)
  s = tonumber(s) or 0
  if s ~= s then return 0 end
  return math.max(0, s) * 3.6
end

local function throttleRaw()
  local v = 0
  pcall(function() v = input.state.throttle.val or 0 end)
  v = tonumber(v) or 0
  if v ~= v then return 0 end
  return v
end

-- Углы Эйлера (градусы). getDirectionVectorUp() в 0.39.4 врёт (up≈0.97 при
-- машине на крыше) — НЕ используем. Fallback: матрица трансформации (up = 3-я
-- колонка), только если углы подозрительно нулевые.
local function rollPitch()
  local roll, pitch = 0, 0
  pcall(function() roll = tonumber(obj:getRollAngle()) or 0 end)
  pcall(function() pitch = tonumber(obj:getPitchAngle()) or 0 end)
  roll = tonumber(roll) or 0
  pitch = tonumber(pitch) or 0
  if roll ~= roll then roll = 0 end
  if pitch ~= pitch then pitch = 0 end
  local flipped = math.abs(roll) > 90 or math.abs(pitch) > 90
  if not flipped and math.abs(roll) < 0.01 and math.abs(pitch) < 0.01 then
    local ok, m = pcall(function() return obj:getTransform() end)
    if ok and m then
      local ok2, up = pcall(function() return m:getColumn(2) end)
      if ok2 and up then
        local ok3, d = pcall(function() return up:dot(vec3(0, 0, 1)) end)
        if ok3 and d and d < 0.3 then flipped = true end
      end
    end
  end
  return roll, pitch, flipped
end

local function aiDriving()
  local ok, r = pcall(function() return ai and ai.isDriving and ai.isDriving() or false end)
  return ok and r == true
end

-- Прогрев идёт? (не мешаем заводу/свею)
local function warmupBusy()
  local st = nil
  pcall(function()
    if soulPilotWarmupCmd and soulPilotWarmupCmd.getState then
      st = soulPilotWarmupCmd.getState()
    end
  end)
  return st == 'starting_engine' or st == 'warming_up'
end

-- Поглаживание активно? (не трогаем машину во время pet)
local function petBusy()
  local r = false
  pcall(function()
    if soulPilotPetCmd and soulPilotPetCmd.isActive then
      r = soulPilotPetCmd.isActive() == true
    end
  end)
  return r
end

local function report(kind, info)
  if cooldownT > 0 then return end
  cooldownT = cfg.cooldown_s
  stuckT = 0
  flippedT = 0
  lastKind = kind
  aplPrint('aplPain: ' .. kind .. ' → ' .. info)
  toGE('INFO', 'pain ' .. kind .. ': ' .. info)
  notifyGE(kind, info)
end

function M.updateGFX(dt)
  if not active or cfg == nil then return end
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then return end

  -- Фаза 10.5: раз в 2 с ПРОСИМ урон у GE (не зависим от GE onUpdate)
  dmgReqT = dmgReqT + dt
  if dmgReqT >= 2 then
    dmgReqT = 0
    pcall(function()
      obj:queueGameEngineLua(
        'if extensions and extensions.soulPilot_main and extensions.soulPilot_main.onVehiclePainDamageRequest then extensions.soulPilot_main.onVehiclePainDamageRequest() end')
    end)
  end
  if cooldownT > 0 then
    cooldownT = math.max(0, cooldownT - dt)
  end
  local poll = 1 / math.max(cfg.check_hz, 0.1)
  checkT = checkT + dt
  if checkT < poll then return end
  local step = checkT
  checkT = 0

  -- Фаза 9.5: неуязвимость после телепорта/ремонта — детекторы молчат
  if ignoreT > 0 then
    ignoreT = math.max(0, ignoreT - dt)
    stuckT = 0
    flippedT = 0
    return
  end

  -- Не мешаем прогреву/поглаживанию — таймеры сбрасываем
  if warmupBusy() or petBusy() then
    stuckT = 0
    flippedT = 0
    return
  end

  local spd = speedKph()
  local thr = throttleRaw()
  local roll, pitch, isFlipped = rollPitch()
  local drv = aiDriving()

  -- FLIPPED: |roll| > 90 или |pitch| > 90 (углы Эйлера, градусы)
  if isFlipped then
    flippedT = flippedT + step
  else
    if flippedT > 0 then
      aplPrint(string.format('aplPain: FLIPPED сброс — roll=%.0f pitch=%.0f', roll, pitch))
    end
    flippedT = 0
  end
  if isFlipped and flippedT >= cfg.flipped_time_s and
      (math.abs(roll) > 90 or math.abs(pitch) > 90) then
    report('FLIPPED', string.format('roll=%.0f pitch=%.0f %.1fs', roll, pitch, flippedT))
    return
  end

  -- STUCK: газ есть (игрок ИЛИ AI), а скорости нет. aiDriving НЕ обязателен
  -- (24.10: игрок сам жмёт газ в пол, машина не едет — тоже STUCK).
  if thr >= cfg.stuck_throttle_min and spd <= cfg.stuck_speed_kph then
    stuckT = stuckT + step
  else
    stuckT = 0
  end
  if stuckT >= cfg.stuck_time_s then
    report('STUCK', string.format('speed=%.1f kph thr=%.2f %.1fs', spd, thr, stuckT))
    return
  end

  -- DAMAGE: только когда машина реально ВСТАЛА (мертвая). На ходу не чиним,
  -- даже если урон огромный (грунтовка/кочки дают миллионы).
  if damage >= cfg.damage_threshold and spd <= cfg.stuck_speed_kph then
    report('DAMAGE', string.format('damageSum=%.0f speed=%.1f', damage, spd))
  end
end

soulPilotPainCmd = {}

-- Legacy migration alias; new code must use soulPilotPainCmd.
autopilotLivePainCmd = soulPilotPainCmd

function soulPilotPainCmd.start(params)
  if active then return false end
  local t = type(params) == 'table' and params or {}
  local D = DEFAULTS
  cfg = {
    check_hz = clampNum(t.check_hz, 0.1, 10, D.check_hz),
    damage_threshold = clampNum(t.damage_threshold, 0, 1e9, D.damage_threshold),
    stuck_speed_kph = clampNum(t.stuck_speed_kph, 0, 100, D.stuck_speed_kph),
    stuck_time_s = clampNum(t.stuck_time_s, 1, 120, D.stuck_time_s),
    stuck_throttle_min = clampNum(t.stuck_throttle_min, 0.1, 1, D.stuck_throttle_min),
    flipped_up_dot = clampNum(t.flipped_up_dot, 0, 0.9, D.flipped_up_dot),
    flipped_time_s = clampNum(t.flipped_time_s, 0.5, 60, D.flipped_time_s),
    cooldown_s = clampNum(t.cooldown_s, 1, 600, D.cooldown_s),
  }
  active = true
  checkT, stuckT, flippedT, cooldownT = 0, 0, 0, 0
  damage = 0
  ignoreT = 0
  dmgReqT = 0
  lastKind = '—'
  aplPrint(string.format('aplPain: АВТО-ВОССТАНОВЛЕНИЕ ВКЛ (damage>=%.2f, stuck %.0f км/ч %.0f с, flip |roll|>90 или |pitch|>90)',
    cfg.damage_threshold, cfg.stuck_speed_kph, cfg.stuck_time_s))
  toGE('INFO', 'pain auto ON')
  return true
end

function soulPilotPainCmd.stop()
  if not active then return false end
  active = false
  cfg = nil
  aplPrint('aplPain: ВЫКЛ')
  toGE('INFO', 'pain auto OFF')
  return true
end

-- GE: после ремонта/телепорта — «неуязвимость» N секунд (детекторы молчат)
function soulPilotPainCmd.ignoreDamage(seconds)
  ignoreT = clampNum(seconds, 0, 30, 3.0)
  stuckT, flippedT = 0, 0
  aplPrint('aplPain: ignoreDamage=' .. string.format('%.1f', ignoreT) .. ' с')
  return true
end

-- GE присылает getSectionDamageSum() каждые 2 с (vehicle этого API не видит).
-- ВАЖНО: шкала — ОЧКИ (тысячи/миллионы), не 0..1. Клампим до 1e9.
function soulPilotPainCmd.setDamage(v, seq)
  local n = tonumber(v)
  if n == nil or n ~= n then n = 0 end
  damage = clampNum(n, 0, 1e9, 0)
  aplPrint('PAIN RECV: ' .. tostring(v) .. ' (seq ' .. tostring(seq or '?') .. ') → damage=' ..
    string.format('%.1f', damage) .. ' (порог ' ..
    string.format('%.1f', active and cfg and cfg.damage_threshold or -1) .. ')')
  return true
end

function soulPilotPainCmd.status()
  local roll, pitch = rollPitch()
  local lines = {
    '--- apl_pain status (vehicle) ---',
    'active=' .. tostring(active) .. ' last=' .. tostring(lastKind) ..
      ' cooldown=' .. string.format('%.1f', cooldownT) .. 'с',
    string.format('speed=%.1f км/ч thr=%.2f roll=%.0f pitch=%.0f aiDriving=%s damageSum=%s (порог %.3f)',
      speedKph(), throttleRaw(), roll, pitch, tostring(aiDriving()), tostring(damage),
      active and cfg and cfg.damage_threshold or 0),
    cfg and string.format('пороги: damage>=%.2f stuck<=%.0fкм/ч/%.0fс flip |roll|>90/|pitch|>90 %.1fс',
      cfg.damage_threshold, cfg.stuck_speed_kph, cfg.stuck_time_s,
      cfg.flipped_time_s) or nil,
    string.format('таймеры: stuck=%.1f flipped=%.1f ignore=%.1f', stuckT, flippedT, ignoreT),
  }
  for _, l in ipairs(lines) do if l then print('aplPain: ' .. l) end end
  return true
end

function M.onReset()
  stuckT, flippedT = 0, 0
  -- active сохраняем: после respawn авто-восстановление продолжает работать
end

function M.onVehicleDestroyed()
  active = false
  cfg = nil
end

return M
