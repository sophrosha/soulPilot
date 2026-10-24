-- soulPilot — Фаза 11.2: Spotify/Audio-Reactive (GE-слой)
-- Загружается из main.lua: extensions.load('soulPilot/music').
--
-- Ответственность:
--   * каждые 50 мс читать src_music/current.json, который пишет Python;
--   * считать данные устаревшими, если seq не менялся > stale_ms (300 мс);
--   * пересылать bass/beat/bpm/night в vehicle-слой
--     (soulPilotMusicCmd.set — глобальная таблица vehicle-расширения,
--      тот же проверенный канал, что wheel/pain/popup);
--   * команда apl_music("on"|"off"|"toggle"|"status").
--
-- UDP в BeamNG Lua нет — файл является единственным каналом. Запись
-- атомарная (temp + os.replace), поэтому чтение не увидит половину JSON.

local M = {}

local FILE = 'mods/unpacked/soulPilot/src_music/current.json'
local POLL_DT = 0.05        -- чтение файла, сек (20 Гц)
local STALE_S = 0.3         -- нет нового seq дольше -> bass/beat = 0
local NIGHT_DT = 1.0        -- пересчёт день/ночь, сек
local REARM_DT = 5.0        -- повторный start после respawn машины, сек

local enabled = false
local pollAcc = 0
local nightAcc = 0
local rearmAcc = 0
local night = false

local lastSeq = nil
local staleT = STALE_S + 1
local last = { bass = 0, beat = 0, bpm = 0 }
local lastRead = nil
local dbgAcc = 0

local function clamp01(v)
  v = tonumber(v)
  if v == nil or v ~= v then return 0 end
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

local function readState()
  local f = io.open(FILE, 'r')
  if not f then return nil end
  local content = f:read('*all')
  f:close()
  if content == nil or content == '' then return nil end
  local ok, doc = pcall(jsonDecode, content, FILE)
  if not ok or type(doc) ~= 'table' then return nil end
  return doc
end

local function playerVehicle()
  local ok, veh = pcall(function()
    return getPlayerVehicle and getPlayerVehicle(0)
  end)
  if ok and veh then return veh end
  return nil
end

-- Тихая отправка: при отсутствии машины НЕ логируем WARN 20 раз в секунду.
local function send(cmd)
  local veh = playerVehicle()
  if not veh or not veh.queueLuaCommand then return false end
  local ok = pcall(function() veh:queueLuaCommand(cmd) end)
  return ok
end

-- Ночь по тем же правилам, что popup/Ф6 (main.lua.isNightNow).
local function updateNight()
  local ok, v = pcall(function()
    if extensions and extensions.soulPilot_main
      and extensions.soulPilot_main.isNightNow then
      return extensions.soulPilot_main.isNightNow()
    end
    return false
  end)
  night = (ok and v == true)
end

local function sendState()
  local cmd = string.format(
    'soulPilotMusicCmd.set(%.4f, %d, %.1f, %s)',
    last.bass, last.beat, last.bpm, night and 'true' or 'false')
  return send(cmd)
end

function M.onUpdate(dtReal)
  if not enabled then return end
  if dtReal == nil or dtReal ~= dtReal or dtReal <= 0 or dtReal > 1 then return end

  pollAcc = pollAcc + dtReal
  nightAcc = nightAcc + dtReal
  rearmAcc = rearmAcc + dtReal

  if nightAcc >= NIGHT_DT then
    nightAcc = 0
    updateNight()
  end

  -- После respawn vehicle-модуль создаётся заново (active=false) —
  -- периодически повторяем start, чтобы фича не отваливалась.
  if rearmAcc >= REARM_DT then
    rearmAcc = 0
    send('soulPilotMusicCmd.start()')
  end

  if pollAcc < POLL_DT then return end
  pollAcc = 0

  local doc = readState()
  if doc ~= nil then
    local seq = tonumber(doc.seq)
    if seq ~= nil and lastSeq ~= nil and seq == lastSeq then
      staleT = staleT + POLL_DT
    else
      lastSeq = seq
      staleT = 0
    end
    if seq == nil then staleT = 0 end -- старый формат без seq — доверяем

    if staleT <= STALE_S then
      lastRead = doc
      last.bass = clamp01(doc.bass)
      last.beat = (tonumber(doc.beat) or 0) >= 0.5 and 1 or 0
      local bpm = tonumber(doc.bpm)
      last.bpm = (bpm ~= nil and bpm == bpm) and bpm or 0
      if doc.paused == true then
        last.bass = 0
        last.beat = 0
      end
    end
  else
    staleT = staleT + POLL_DT
  end

  if staleT > STALE_S then
    last.bass = 0
    last.beat = 0
    last.bpm = 0
  end

  sendState()

  dbgAcc = dbgAcc + POLL_DT
  if dbgAcc >= 10 then
    dbgAcc = 0
    print(string.format(
      'apl_music: bass=%.2f beat=%d bpm=%.0f seq=%s stale=%.2fs night=%s',
      last.bass, last.beat, last.bpm, tostring(lastSeq), staleT, tostring(night)))
  end
end

-- === Команда apl_music("on"|"off"|"toggle"|"status") ===
function apl_music(mode)
  mode = tostring(mode or ''):lower()

  if mode == 'on' then
    if enabled then
      print('apl_music: уже включено (apl_music("off") чтобы выключить)')
      return true
    end
    enabled = true
    pollAcc = 0
    nightAcc = 0
    rearmAcc = 0
    staleT = STALE_S + 1
    lastSeq = nil
    lastRead = nil
    last = { bass = 0, beat = 0, bpm = 0 }
    updateNight()
    local sent = send('soulPilotMusicCmd.start()')
    print('apl_music: ON — читаю ' .. FILE .. ' каждые ' ..
      string.format('%.0f', POLL_DT * 1000) .. ' мс; vehicle start=' .. tostring(sent))
    if readState() == nil then
      print('apl_music: файла пока нет/не читается — запустите src_music/app.py')
    end
    return true
  end

  if mode == 'off' then
    if not enabled then
      print('apl_music: уже выключено')
      return true
    end
    enabled = false
    last = { bass = 0, beat = 0, bpm = 0 }
    staleT = STALE_S + 1
    local sent = send('soulPilotMusicCmd.stop()')
    print('apl_music: OFF (vehicle stop=' .. tostring(sent) .. ')')
    return true
  end

  if mode == 'toggle' then
    return apl_music(enabled and 'off' or 'on')
  end

  if mode == 'status' then
    local doc = readState()
    print('--- apl_music status ---')
    print('enabled=' .. tostring(enabled) .. ', файл=' .. FILE)
    print('file_ok=' .. tostring(doc ~= nil) ..
      ', last_seq=' .. tostring(lastSeq) ..
      ', stale=' .. string.format('%.2f', staleT) .. ' с, night=' .. tostring(night))
    print(string.format('bass=%.2f beat=%d bpm=%.0f%s',
      last.bass, last.beat, last.bpm,
      (staleT > STALE_S) and ' (ДАННЫЕ УСТАРЕЛИ)' or ''))
    if doc == nil then
      print('подсказка: запустите src_music/app.py и нажмите Start')
    end
    send('soulPilotMusicCmd.status()')
    return true
  end

  print('Использование: apl_music("on"|"off"|"toggle"|"status")')
  return false
end

-- === Жизненный цикл ===
function M.onExtensionLoaded()
  print('apl_music: GE-модуль загружен (Spotify/Audio-Reactive)')
end

function M.onClientPostStartMission()
  -- vehicle-слой перезагрузился; enabled сохраняем, start повторится в onUpdate.
  rearmAcc = REARM_DT
  staleT = STALE_S + 1
  lastSeq = nil
end

function M.onExtensionUnloaded()
  if enabled then
    send('soulPilotMusicCmd.stop()')
  end
  enabled = false
end

return M
