-- soulPilot wheel configuration.
-- The JSON file is the source of truth; these defaults are only a fallback.

local M = {}

M.FALLBACK_CONFIG = "mods/unpacked/soulPilot/config/wheel.json"

M.DEFAULTS = {
  rate_limit = { steer_rise = 6.0, steer_fall = 8.0 },
  ema_tau = { steer = 0.08 },
  lerp_tau = { steer = 0.05 },
}

M.PRESETS = {
  comfort = { rise = 4.0, fall = 6.0, ema = 0.15, lerp = 0.12 },
  sport = { rise = 6.0, fall = 7.0, ema = 0.04, lerp = 0.05 },
}

local function copyDefaults()
  local copy = {}
  for group, values in pairs(M.DEFAULTS) do
    copy[group] = {}
    for key, value in pairs(values) do
      copy[group][key] = value
    end
  end
  return copy
end

local function ensurePositive(config, group, key, fallback)
  local value = config[group][key]
  if value == nil or value ~= value or value <= 0 then
    config[group][key] = fallback
  end
end

local function validate(config)
  local defaults = M.DEFAULTS
  ensurePositive(config, "rate_limit", "steer_rise", defaults.rate_limit.steer_rise)
  ensurePositive(config, "rate_limit", "steer_fall", defaults.rate_limit.steer_fall)
  ensurePositive(config, "ema_tau", "steer", defaults.ema_tau.steer)
  ensurePositive(config, "lerp_tau", "steer", defaults.lerp_tau.steer)
end

local function mergeKnownValues(config, decoded)
  for group, defaults in pairs(M.DEFAULTS) do
    local decoded_group = type(decoded[group]) == "table" and decoded[group] or nil
    if decoded_group then
      for key in pairs(defaults) do
        local value = tonumber(decoded_group[key])
        if value ~= nil then
          config[group][key] = value
        end
      end
    end
  end
end

local function applyMode(config, decoded, notify)
  local mode = type(decoded.mode) == "string" and decoded.mode:lower() or "comfort"
  local preset = M.PRESETS[mode]

  if preset then
    config.rate_limit.steer_rise = preset.rise
    config.rate_limit.steer_fall = preset.fall
    config.ema_tau.steer = preset.ema
    config.lerp_tau.steer = preset.lerp
    config.mode = mode
    return
  end

  config.mode = "custom"
  if mode ~= "custom" and notify then
    notify("WARN", 'wheel: unknown mode="' .. tostring(mode) .. '", using values from wheel.json')
  end
end

function M.load(path, notify)
  local config = copyDefaults()
  local file = io.open(path, "r")
  if not file then
    if notify then
      notify("WARN", "wheel: config not found (" .. tostring(path) .. "), using code defaults")
    end
    config.mode = "custom"
    return config, false
  end

  local content = file:read("*all")
  file:close()

  local ok, decoded = pcall(jsonDecode, content, path)
  if not ok or type(decoded) ~= "table" then
    if notify then
      notify("WARN", "wheel: config parse failed, using code defaults")
    end
    config.mode = "custom"
    return config, false
  end

  mergeKnownValues(config, decoded)
  applyMode(config, decoded, notify)
  validate(config)
  return config, true
end

return M
