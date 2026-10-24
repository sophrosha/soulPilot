-- soulPilot — Фаза 6: автофары день/ночь (vehicle-слой)
-- Подключается штатно (lua/vehicle/extensions/auto — автозагрузка расширений).
--
-- Ответственность vehicle-слоя (Фаза 6):
--   * применять целевой state фар (0=выкл, 1=ближний, 2=дальний) через штатный
--     electrics.setLightsState — БЕЗ input.event, БЕЗ toggle-цикла;
--   * guard «без дёрганья»: setLightsState вызываем ТОЛЬКО если текущее
--     electrics.values.lights_state ≠ целевого (схема techCore.handleSetLights,
--     tech/techCore.lua:481-483 — api_research_phase6.md §1.2);
--   * в auto-режиме детектировать ручное вмешательство игрока (клавиша L,
--     радиал-меню, клик в салоне, flash-highbeam): lights_state ≠ lastApplied
--     значит «изменили не мы» → auto выключается, фары остаются как поставил
--     игрок («не дерёмся») → событие в GE (§7.4 исследования).
--
-- Время/карта/guard pop-up живут ТОЛЬКО в GE (main.lua): vehicle получает
-- готовый числовой target (как в warmup — логики времени здесь нет).
-- wheel/pedals/КПП/CSV — не трогаются.

local M = {}

-- === Состояние ===
-- mode: 'off' | 'manual' | 'auto'
local mode = 'off'
local target = 0          -- целевой state для auto (0/1/2, приходит из GE)
local lastApplied = nil   -- что МЫ применили в auto (nil = ещё не применяли:
                          -- первое применение/после respawn — без interrupt)
local suppress = false    -- Фаза 8: popup моргает — авто-логика молчит (не
                          -- считает мигок ручным вмешательством, не применяет
                          -- target)

-- === Лог событий в GE (паттерн soulPilotWarmup.lua:77-83) ===
local function toGE(level, msg)
  pcall(function()
    obj:queueGameEngineLua(string.format(
      'if extensions and extensions.soulPilot_main and extensions.soulPilot_main.onVehicleLog then extensions.soulPilot_main.onVehicleLog("%s", "%s") end',
      level, tostring(msg):gsub('\\', '\\\\'):gsub('"', '\\"')))
  end)
end

-- === Чтение/установка состояния фар ===
local function curState()
  local s = 0
  pcall(function() s = electrics.values.lights_state or 0 end)
  s = tonumber(s) or 0
  if s ~= s then return 0 end
  return s
end

local function clampState(v)
  v = tonumber(v) or 0
  if v ~= v then return 0 end
  v = math.floor(v + 0.5)
  if v < 0 then return 0 end
  if v > 2 then return 2 end
  return v
end

-- Применение с guard (паттерн techCore): щелчок переключателя — ТОЛЬКО при
-- реальном расхождении. При совпадении — тишина («вкл ярко / выкл», без циклов).
local function applyState(v)
  if curState() ~= v then
    electrics.setLightsState(v)
  end
end

-- vehicle → GE: авто-режим отключён игроком вручную (хендлер main.lua)
local function notifyManualOverride()
  pcall(function()
    obj:queueGameEngineLua(
      'if extensions and extensions.soulPilot_main and extensions.soulPilot_main.onVehicleLightsAutoOff then extensions.soulPilot_main.onVehicleLightsAutoOff() end')
  end)
end

-- === Публичные команды (GE шлёт через queueLuaCommand) ===
soulPilotLightsCmd = {}

-- Включение auto: GE уже вычислил первый target по времени/карте.
function soulPilotLightsCmd.autoOn(initialTarget)
  target = clampState(initialTarget)
  mode = 'auto'
  lastApplied = nil -- применяем на ближайшем кадре: старт без ложного interrupt
  toGE('INFO', 'lights: auto ON (target=' .. tostring(target) .. ')')
  return true
end

-- Смена target (день↔ночь) — только пока auto жив: после interrupt-отключения
-- опоздавшая команда GE игнорируется.
function soulPilotLightsCmd.setTarget(t)
  if mode ~= 'auto' then return false end
  target = clampState(t)
  return true
end

-- Ручной режим: far=2 / near=1 / off=0. Явная команда игрока — НЕ считается
-- «вмешательством» (interrupt), auto при этом снимается.
function soulPilotLightsCmd.setManual(v)
  mode = 'manual'
  lastApplied = nil
  target = clampState(v)
  applyState(target)
  toGE('INFO', 'lights: manual state=' .. tostring(target))
  return true
end

-- Фаза 8 (popup): временная приостановка авто-логики — на время мигка
-- popup-модуля (setLightsState(1)→(0)) interrupt НЕ срабатывает и target не
-- применяется; после снятия suppress auto продолжается как прежде.
function soulPilotLightsCmd.setSuppress(v)
  suppress = v == true
  return true
end

-- Фаза 8 (popup): активен ли авто-режим — popup отличает переходы Ф6-auto
-- (ночь/день) от ручного вмешательства игрока.
function soulPilotLightsCmd.isAuto()
  return mode == 'auto'
end

-- Фаза 8 (popup): текущий целевой state Ф6 (0/1/2) — popup не моргает, если
-- target ≠ 1 (не бьётся за свет), и не навязывает 1.
function soulPilotLightsCmd.getTarget()
  return target
end

function soulPilotLightsCmd.status()
  local applied = lastApplied ~= nil and tostring(lastApplied) or 'нет'
  local lines = {
    '--- apl_lights status (vehicle) ---',
    'mode=' .. mode .. ' target=' .. tostring(target) ..
      ' lastApplied=' .. applied,
    'lights_state=' .. tostring(curState()) ..
      ' (0=выкл, 1=ближний, 2=дальний)',
    mode == 'auto'
      and 'в auto: следующее применение — при расхождении с lastApplied; ручное вмешательство отключит auto'
      or 'auto не активен',
  }
  for _, l in ipairs(lines) do print('aplLights: ' .. l) end
  toGE('INFO', 'lights status: mode=' .. mode .. ' target=' .. tostring(target) ..
    ' lights_state=' .. tostring(curState()))
  return true
end

-- === Кадр ===
function M.updateGFX(dt)
  if dt == nil or dt ~= dt or dt <= 0 or dt > 1 then return end -- NaN/перерывы
  if mode ~= 'auto' then return end
  if suppress then return end -- Фаза 8: popup моргает — молчим (см. setSuppress)

  local cur = curState()

  -- Детект ручного вмешательства (§7.4): state изменили НЕ мы — авто-отключение
  if lastApplied ~= nil and cur ~= lastApplied then
    mode = 'off'
    notifyManualOverride()
    return
  end

  -- Первое применение (lastApplied=nil) или смена target от GE
  if lastApplied == nil or cur ~= target then
    applyState(target)
    lastApplied = target
  end
end

-- === Жизненный цикл ===
function M.onReset()
  -- Respawn: electrics сброшены — в auto пере-применяем target на ближайшем
  -- кадре (lastApplied=nil гасит ложный interrupt на свежих нулях).
  -- suppress сбрасываем страховочно (popup на respawn снимает свой сам).
  suppress = false
  if mode == 'auto' then lastApplied = nil end
end

function M.onVehicleDestroyed()
  mode = 'off'
  target = 0
  lastApplied = nil
  suppress = false
end

return M
