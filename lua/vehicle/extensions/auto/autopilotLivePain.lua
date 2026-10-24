-- AutopilotLive — Фаза 9.1: «Система Боли» (vehicle-слой)
-- Детекторы: STUCK (AI газует, но не едет), FLIPPED (лежит на боку/крыше),
-- DAMAGE (порог урона — значение приходит из GE: getSectionDamageSum доступен
-- только в GE-слое). Действия (телепорт/ремонт) выполняет GE (vanilla API).

local M = {}

local DEFAULTS = {
  check_hz = 1.0,
  damage_threshold = 2500.0,
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
local lastKind = '—'

local function toGE(level, msg)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if autopilotLive_main and autopilotLive_main.onVehicleLog then autopilotLive_main.onVehicleLog("%s", "%s") end',
      level, tostring(msg):gsub('\\', '\\\\'):gsub('"', '\\"')))
  end)
end

local function notifyGE(kind, info)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if autopilotLive_main and autopilotLive_main.onVehiclePain then autopilotLive_main.onVehiclePain("%s", "%s") end',
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

local function upDot()
  local ok, d = pcall(function()
    return obj:getDirectionVectorUp():dot(vec3(0, 0, 1))
  end)
  if not ok then return 1 end
  d = tonumber(d) or 1
  if d ~= d then return 1 end
  return d
end

local function aiDriving()
  local ok, r = pcall(function() return ai and ai.isDriving and ai.isDriving() or false end)
  return ok and r == true
end

-- Прогрев идёт? (не мешаем заводу/свею)
local function warmupBusy()
  local st = nil
  pcall(function()
    if autopilotLiveWarmupCmd and autopilotLiveWarmupCmd.getState then
      st = autopilotLiveWarmupCmd.getState()
    end
  end)
  return st == 'starting_engine' or st == 'warming_up'
end

-- Поглаживание активно? (не трогаем машину во время pet)
local function petBusy()
  local r = false
  pcall(function()
    if autopilotLivePetCmd and autopilotLivePetCmd.isActive then
      r = autopilotLivePetCmd.isActive() == true
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
  print('aplPain: ' .. kind .. ' → ' .. info)
  toGE('INFO', 'pain ' .. kind .. ': ' .. info)
  notifyGE(kind, info)
end

function M.updateGFX(dt)
  if not active or cfg == nil then return end
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then return end
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
  local up = upDot()
  local drv = aiDriving()

  -- FLIPPED: сначала проверяем порог, затем обновляем таймер. Если up >= порога
  -- (машина стоит ровно) — таймер СБРАСЫВАЕТСЯ (ложные срабатывания 24.10).
  local isFlipped = up < cfg.flipped_up_dot
  if isFlipped then
    flippedT = flippedT + step
  else
    if flippedT > 0 then
      print(string.format('aplPain: FLIPPED сброс — up=%.2f >= %.2f', up, cfg.flipped_up_dot))
    end
    flippedT = 0
  end
  if isFlipped and flippedT >= cfg.flipped_time_s and up < cfg.flipped_up_dot then
    report('FLIPPED', string.format('up=%.2f %.1fs', up, flippedT))
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

  -- DAMAGE: порог (значение из GE)
  if damage >= cfg.damage_threshold then
    report('DAMAGE', string.format('damageSum=%.3f', damage))
  end
end

autopilotLivePainCmd = {}

function autopilotLivePainCmd.start(params)
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
  lastKind = '—'
  print(string.format('aplPain: АВТО-ВОССТАНОВЛЕНИЕ ВКЛ (damage>=%.2f, stuck %.0f км/ч %.0f с, flip up<%.2f)',
    cfg.damage_threshold, cfg.stuck_speed_kph, cfg.stuck_time_s, cfg.flipped_up_dot))
  toGE('INFO', 'pain auto ON')
  return true
end

function autopilotLivePainCmd.stop()
  if not active then return false end
  active = false
  cfg = nil
  print('aplPain: ВЫКЛ')
  toGE('INFO', 'pain auto OFF')
  return true
end

-- GE: после ремонта/телепорта — «неуязвимость» N секунд (детекторы молчат)
function autopilotLivePainCmd.ignoreDamage(seconds)
  ignoreT = clampNum(seconds, 0, 30, 3.0)
  stuckT, flippedT = 0, 0
  print('aplPain: ignoreDamage=' .. string.format('%.1f', ignoreT) .. ' с')
  return true
end

-- GE присылает getSectionDamageSum() каждые 2 с (vehicle этого API не видит).
-- ВАЖНО: шкала — ОЧКИ (тысячи/миллионы), не 0..1. Клампим до 1e9.
function autopilotLivePainCmd.setDamage(v)
  local n = tonumber(v)
  if n == nil or n ~= n then n = 0 end
  damage = clampNum(n, 0, 1e9, 0)
  print(string.format('aplPain: RECV setDamage=%s (type %s) → damage=%.1f (порог %.1f)',
    tostring(v), type(v), damage, active and cfg and cfg.damage_threshold or -1))
  return true
end

function autopilotLivePainCmd.status()
  local lines = {
    '--- apl_pain status (vehicle) ---',
    'active=' .. tostring(active) .. ' last=' .. tostring(lastKind) ..
      ' cooldown=' .. string.format('%.1f', cooldownT) .. 'с',
    string.format('speed=%.1f км/ч thr=%.2f up=%.2f aiDriving=%s damageSum=%s (порог %.3f)',
      speedKph(), throttleRaw(), upDot(), tostring(aiDriving()), tostring(damage),
      active and cfg and cfg.damage_threshold or 0),
    cfg and string.format('пороги: damage>=%.2f stuck<=%.0fкм/ч/%.0fс flip up<%.2f/%.1fс',
      cfg.damage_threshold, cfg.stuck_speed_kph, cfg.stuck_time_s,
      cfg.flipped_up_dot, cfg.flipped_time_s) or nil,
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
