-- AutopilotLive — Фаза 12.2: GE-мост для Vue-настроек.
-- Загружается из main.lua: extensions.load('autopilotLive/uiConfig').
--
-- UI вызывает:
--   extensions.autopilotLive_uiConfig.getConfig()    -> таблица settings/state
--   extensions.autopilotLive_uiConfig.setConfig({files={music={...}, wheel={...}}})
--   extensions.autopilotLive_uiConfig.setModule("master"|"lights"|"music"|"parking", true|false)
--
-- setConfig сохраняет только известные файлы из ai/config; значения
-- проверяются на finite/тип. Комментарии в JSON сохраняются при слиянии.

local M = {}

local CONFIG_DIR = 'mods/unpacked/AutopilotLive/ai/config/'

local FILES = {
  master  = CONFIG_DIR .. 'master.json',
  wheel   = CONFIG_DIR .. 'wheel.json',
  music   = CONFIG_DIR .. 'music.json',
  lights  = CONFIG_DIR .. 'lights.json',
  popup   = CONFIG_DIR .. 'popup.json',
  pet     = CONFIG_DIR .. 'pet.json',
  pain    = CONFIG_DIR .. 'pain.json',
  pedals  = CONFIG_DIR .. 'pedals.json',
  warmup  = CONFIG_DIR .. 'warmup.json',
  parking = CONFIG_DIR .. 'parking.json',
}

local moduleState = {
  lights = false,
  music = false,
  parking = false,
  wheel = false,
  popup = false,
}

local function readJson(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*all')
  f:close()
  if not content or content == '' then return nil end
  local ok, decoded = pcall(jsonDecode, content, path)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
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

-- Убираем функции/NaN/inf; обычные JSON-типы оставляем.
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

local function writeJson(path, data)
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

-- === Публичные методы ===
function M.getConfig()
  local out = {
    version = 1,
    values = {},
    files = {},
    state = {
      master = masterState(),
      lights = moduleState.lights,
      music = moduleState.music,
      parking = moduleState.parking,
      wheel = moduleState.wheel,
      popup = moduleState.popup,
    },
  }
  for key, path in pairs(FILES) do
    out.values[key] = readJson(path) or {}
    out.files[key] = path
  end
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
    local current = readJson(FILES[file]) or {}
    local sanitized = sanitize(values)
    if type(sanitized) ~= 'table' then
      table.insert(errors, file .. ': invalid values')
    else
      local merged = deepCopy(current)
      deepMerge(merged, sanitized)
      local ok, err = writeJson(FILES[file], merged)
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

  local ok, result, err
  if name == 'master' then
    ok, result = callGlobal('apl_autopilot', on and 'on' or 'off')
  elseif name == 'lights' then
    ok, result = callGlobal('apl_lights', on and 'auto' or 'off')
    if ok then moduleState.lights = (result == true) end
  elseif name == 'music' then
    ok, result = callGlobal('apl_music', on and 'on' or 'off')
    if ok then moduleState.music = (result == true) end
  elseif name == 'parking' then
    ok, result = callGlobal('apl_park', on and 'auto' or 'cancel')
    if ok then moduleState.parking = (result == true) end
  elseif name == 'wheel' then
    ok, result = callGlobal('apl_wheel', on and 'on' or 'off')
    if ok then moduleState.wheel = (result == true) end
  elseif name == 'popup' then
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

  return {
    ok = success,
    result = result,
    error = errorMessage,
    state = {
      master = masterState(),
      lights = moduleState.lights,
      music = moduleState.music,
      parking = moduleState.parking,
      wheel = moduleState.wheel,
      popup = moduleState.popup,
    },
  }
end

function M.getState()
  return {
    master = masterState(),
    lights = moduleState.lights,
    music = moduleState.music,
    parking = moduleState.parking,
    wheel = moduleState.wheel,
    popup = moduleState.popup,
  }
end

function M.onExtensionLoaded()
  print('aplUiConfig: GE-модуль загружен (Vue settings bridge)')
end

return M
