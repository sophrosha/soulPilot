-- AutopilotLive — Фаза 12.3: GE-мост для Vue-настроек.
-- Настройки живут в userPath: settings/autopilotLive/*.json.
-- Файл из мода (ai/config) используется только как дефолт/fallback.
-- Запись ВСЕГДА в settings/autopilotLive — мод можно упаковать в zip.
--
-- UI вызывает:
--   extensions.autopilotLive_uiConfig.getConfig()
--   extensions.autopilotLive_uiConfig.setConfig({files={music={...}, wheel={...}}})
--   extensions.autopilotLive_uiConfig.setModule("master"|"lights"|"music"|"parking", true|false)
--   extensions.autopilotLive_uiConfig.setDebug(true|false)

local M = {}

local MOD_CONFIG_DIR = 'mods/unpacked/AutopilotLive/ai/config/'
local USER_CONFIG_DIR = 'settings/autopilotLive/'

local FILES = {
  master  = 'master.json',
  wheel   = 'wheel.json',
  music   = 'music.json',
  lights  = 'lights.json',
  popup   = 'popup.json',
  pet     = 'pet.json',
  pain    = 'pain.json',
  pedals  = 'pedals.json',
  warmup  = 'warmup.json',
  parking = 'parking.json',
  debug   = 'debug.json',
}

local moduleState = {
  lights = false,
  music = false,
  parking = false,
  wheel = false,
  popup = false,
  debug = false,
}

local function ensureUserDir()
  pcall(function()
    if FS and FS.directoryCreate then
      FS:directoryCreate(USER_CONFIG_DIR, true)
    end
  end)
end

local function readFile(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*all')
  f:close()
  if not content or content == '' then return nil end
  local ok, decoded = pcall(jsonDecode, content, path)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
end

-- Пользовательский файл важнее; если его нет — дефолт из мода.
local function readJson(name)
  if not FILES[name] then return nil end
  local user = readFile(USER_CONFIG_DIR .. FILES[name])
  if user then return user end
  return readFile(MOD_CONFIG_DIR .. FILES[name])
end

local function deepCopy(v)
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deepCopy(x) end
  return out
end

local function isFiniteNumber(v)
  if type(v) ~= 'number' then return false end
  if v ~= v then return false end
  if v == math.huge or v == -math.huge then return false end
  return true
end

local function sanitize(v)
  local tv = type(v)
  if tv == 'number' then
    return isFiniteNumber(v) and v or nil
  elseif tv == 'string' or tv == 'boolean' then
    return v
  elseif tv == 'table' then
    local out = {}
    for k, x in pairs(v) do
      local sx = sanitize(x)
      if sx ~= nil then out[k] = sx end
    end
    return out
  end
  return nil
end

local function deepMerge(dst, src)
  for k, v in pairs(src or {}) do
    if type(v) == 'table' and type(dst[k]) == 'table' then
      deepMerge(dst[k], v)
    else
      dst[k] = deepCopy(v)
    end
  end
  return dst
end

local function writeJson(name, data)
  if not FILES[name] then return false, 'unknown config: ' .. tostring(name) end
  ensureUserDir()
  local path = USER_CONFIG_DIR .. FILES[name]
  if type(jsonWriteFile) == 'function' then
    local ok, err = pcall(jsonWriteFile, path, data, true)
    if ok then return true end
    return false, err
  end
  local f, err = io.open(path, 'w')
  if not f then return false, err end
  local okEnc, encoded = pcall(jsonEncode, data)
  if not okEnc or not encoded then
    f:close()
    return false, 'jsonEncode failed'
  end
  f:write(encoded)
  f:close()
  return true
end

local function callGlobal(name, arg)
  local fn = _G[name]
  if type(fn) ~= 'function' then
    return false, 'global ' .. tostring(name) .. ' отсутствует'
  end
  local ok, result = pcall(fn, arg)
  if not ok then return false, tostring(result) end
  return true, result
end

local function masterState()
  local ok, value = pcall(function()
    return apl_autopilotState and apl_autopilotState() or 'off'
  end)
  return ok and tostring(value or 'off') or 'off'
end

-- Сохраняем выбор UI как дефолт мастера: masterFinish читает этот файл.
local function setMasterDefault(key, on)
  if not key then return end
  local data = readJson('master') or {}
  data[key] = on and 1 or 0
  writeJson('master', data)
end

local function stateTable()
  return {
    master = masterState(),
    lights = moduleState.lights,
    music = moduleState.music,
    parking = moduleState.parking,
    wheel = moduleState.wheel,
    popup = moduleState.popup,
    debug = moduleState.debug,
  }
end

-- === Публичные методы ===
function M.getConfig()
  ensureUserDir()
  local out = {
    version = 1,
    values = {},
    state = stateTable(),
  }
  for key in pairs(FILES) do
    out.values[key] = readJson(key) or {}
  end
  moduleState.debug = (tonumber(out.values.debug.enabled) or 0) ~= 0
  out.state.debug = moduleState.debug
  return out
end

function M.setConfig(payload)
  if type(payload) == 'string' then
    local ok, decoded = pcall(jsonDecode, payload)
    if not ok or type(decoded) ~= 'table' then
      return { ok = false, error = 'setConfig: bad JSON' }
    end
    payload = decoded
  end
  if type(payload) ~= 'table' then
    return { ok = false, error = 'setConfig: payload is not table' }
  end

  local incoming = {}
  if type(payload.files) == 'table' then
    for file, values in pairs(payload.files) do
      if FILES[file] and type(values) == 'table' then incoming[file] = values end
    end
  elseif type(payload.file) == 'string' and type(payload.values) == 'table' then
    if FILES[payload.file] then incoming[payload.file] = payload.values end
  else
    for file, values in pairs(payload) do
      if FILES[file] and type(values) == 'table' then incoming[file] = values end
    end
  end

  local written, errors, requiresRespawn = {}, {}, false
  for file, values in pairs(incoming) do
    local current = readJson(file) or {}
    local sanitized = sanitize(values)
    if type(sanitized) ~= 'table' then
      table.insert(errors, file .. ': invalid values')
    else
      local merged = deepCopy(current)
      deepMerge(merged, sanitized)
      local ok, err = writeJson(file, merged)
      if ok then
        table.insert(written, file)
        if file == 'wheel' then requiresRespawn = true end
      else
        table.insert(errors, file .. ': ' .. tostring(err))
      end
    end
  end

  if #written == 0 then
    return { ok = false, error = table.concat(errors, '; '), written = written }
  end
  return {
    ok = true,
    written = written,
    errors = #errors > 0 and errors or nil,
    requiresRespawn = requiresRespawn,
  }
end

function M.setModule(name, on)
  name = tostring(name or ''):lower()
  on = (on == true or on == 1 or on == 'true')

  local ok, result
  if name == 'master' then
    ok, result = callGlobal('apl_autopilot', on and 'on' or 'off')
  elseif name == 'lights' then
    setMasterDefault('enable_lights', on)
    ok, result = callGlobal('apl_lights', on and 'auto' or 'off')
    if ok then moduleState.lights = (result == true) end
  elseif name == 'music' then
    -- Критично: «музыка выключена» = дефолт мастера, а не только текущая команда.
    setMasterDefault('enable_music', on)
    ok, result = callGlobal('apl_music', on and 'on' or 'off')
    if ok then moduleState.music = (result == true) end
  elseif name == 'parking' then
    ok, result = callGlobal('apl_park', on and 'auto' or 'cancel')
    if ok then moduleState.parking = (result == true) end
  elseif name == 'wheel' then
    setMasterDefault('enable_wheel', on)
    ok, result = callGlobal('apl_wheel', on and 'on' or 'off')
    if ok then moduleState.wheel = (result == true) end
  elseif name == 'popup' then
    setMasterDefault('enable_popup', on)
    ok, result = callGlobal('apl_popup', on and 'auto' or 'off')
    if ok then moduleState.popup = (result == true) end
  else
    return { ok = false, error = 'unknown module: ' .. name }
  end

  local success = ok and (result ~= false)
  local errorMessage = nil
  if not ok then
    errorMessage = tostring(result)
  elseif result == false then
    errorMessage = 'module rejected the command'
  end

  return { ok = success, result = result, error = errorMessage, state = stateTable() }
end

function M.setDebug(on)
  local enabled = (on == true or on == 1 or on == 'true')
  local data = readJson('debug') or { enabled = 0 }
  data.enabled = enabled and 1 or 0
  local ok, err = writeJson('debug', data)
  if not ok then
    return { ok = false, error = tostring(err) }
  end
  moduleState.debug = enabled
  pcall(function()
    if apl_debug_set then apl_debug_set(enabled) end
  end)
  return { ok = true, enabled = enabled }
end

function M.getState()
  return stateTable()
end

function M.onExtensionLoaded()
  ensureUserDir()
  print('aplUiConfig: userPath=' .. USER_CONFIG_DIR .. ', mod defaults=' .. MOD_CONFIG_DIR)
end

return M
