-- AutopilotLive — Фаза 12.3: GE-мост для Vue-настроек.
-- Настройки живут в userPath: settings/autopilotLive/*.json.
-- Файл из мода (ai/config) используется только как дефолт/fallback.
-- Запись ВСЕГДА в settings/autopilotLive — мод можно упаковать в zip.
--
-- UI вызывает:
--   extensions.autopilotLive_uiConfig.getConfig()
--   extensions.autopilotLive_uiConfig.setConfig({files={music={...}, wheel={...}}})
--   extensions.autopilotLive_uiConfig.setModule("master"|"lights"|"music", true|false)
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
  debug   = 'debug.json',
  ui      = 'ui.json',
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

local function masterState()
  local ok, value = pcall(function()
    return apl_autopilotState and apl_autopilotState() or 'off'
  end)
  return ok and tostring(value or 'off') or 'off'
end

-- Сохраняем выбор UI как дефолт мастера: masterFinish читает этот файл.
local function setMasterDefault(key, on)
  if not key then return false end
  local data = readJson('master') or {}
  data[key] = on and 1 or 0
  local ok = writeJson('master', data)
  return ok == true
end

local function getGameLanguage()
  local ok, value = pcall(function()
    if core_locales and core_locales.getLanguage then return core_locales.getLanguage() end
    return 'en-US'
  end)
  return ok and tostring(value or 'en-US') or 'en-US'
end

local function normalizeLanguage(value)
  local v = tostring(value or ''):lower():gsub('-', '_')
  if v:find('uk', 1, true) or v:find('ua', 1, true) then return 'uk' end
  if v:find('be', 1, true) or v:find('by', 1, true) then return 'by' end
  if v:find('ru', 1, true) then return 'ru' end
  return 'en'
end

local function uiLanguage()
  local ui = readJson('ui') or {}
  if type(ui.language) == 'string' and ui.language ~= '' then
    return normalizeLanguage(ui.language)
  end
  return normalizeLanguage(getGameLanguage())
end

local function stateTable()
  local master = readJson('master') or {}
  local function flag(name)
    return (tonumber(master[name]) or 0) ~= 0
  end
  local debug = readJson('debug') or {}
  return {
    master = flag('enable_master'),
    masterLive = masterState(),
    language = uiLanguage(),
    lights = flag('enable_lights'),
    music = flag('enable_music'),
    wheel = flag('enable_wheel'),
    popup = flag('enable_popup'),
    debug = (tonumber(debug.enabled) or 0) ~= 0,
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

-- UI — это только настройки. Никаких вызовов apl_music/apl_lights/
-- apl_park и т.п.: физический старт делает apl_autopilot("on").
local MODULE_FLAGS = {
  master = 'enable_master',
  lights = 'enable_lights',
  music = 'enable_music',
  wheel = 'enable_wheel',
  popup = 'enable_popup',
}

function M.setModule(name, on)
  name = tostring(name or ''):lower()
  local key = MODULE_FLAGS[name]
  if not key then return false end
  on = (on == true or on == 1 or on == 'true')
  return setMasterDefault(key, on)
end

function M.setDebug(on)
  local enabled = (on == true or on == 1 or on == 'true')
  local data = readJson('debug') or { enabled = 0 }
  data.enabled = enabled and 1 or 0
  local ok, err = writeJson('debug', data)
  if not ok then
    return { ok = false, error = tostring(err) }
  end
  pcall(function()
    if apl_debug_set then apl_debug_set(enabled) end
  end)
  return { ok = true, enabled = enabled }
end

function M.setLanguage(lang)
  local normalized = normalizeLanguage(lang)
  local ui = readJson('ui') or {}
  ui.language = normalized
  local ok, err = writeJson('ui', ui)
  if not ok then
    return { ok = false, error = tostring(err) }
  end
  return { ok = true, language = normalized, state = stateTable() }
end

function M.getState()
  return stateTable()
end

function M.onExtensionLoaded()
  ensureUserDir()
  print('aplUiConfig: userPath=' .. USER_CONFIG_DIR .. ', mod defaults=' .. MOD_CONFIG_DIR)
end

return M
