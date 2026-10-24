-- soulPilot pedals configuration.
-- Defaults are duplicated here only as a safe fallback when the JSON file is
-- missing or unreadable. The JSON file remains the source of truth.

local M = {}

M.FALLBACK_CONFIG = "mods/unpacked/soulPilot/config/pedals.json"

M.DEFAULTS = {
  rate_limit = {
    throttle_rise = 0.8,
    throttle_fall = 1.5,
    brake_rise = 1.7,
    brake_fall = 2.5,
  },
  shift = { hold_s = 0.4 },
  ema_tau = { throttle = 0.10, brake = 0.08 },
  lerp_tau = { throttle = 0.15, brake = 0.12 },
  arbitration = { brake_start = 0.1, brake_full = 0.5 },
  neutral = { speed_max_mps = 0.5, throttle_min = 0.05, brake = 0.3 },
  smooth_start = { time_s = 3.0, speed_mps = 5.0, throttle_cap = 0.45 },
  predictive = {
    brake_threshold = 0.8,
    lead = 0.12,
    release_hyst = 0.5,
    min_speed_mps = 1.5,
  },
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

local function ensureNonNegative(config, group, key, fallback)
  local value = config[group][key]
  if value == nil or value ~= value or value < 0 then
    config[group][key] = fallback
  end
end

local function ensureUnit(config, group, key, fallback)
  local value = config[group][key]
  if value == nil or value ~= value or value < 0 or value > 1 then
    config[group][key] = fallback
  end
end

local function validate(config)
  local defaults = M.DEFAULTS

  ensurePositive(config, "rate_limit", "throttle_rise", defaults.rate_limit.throttle_rise)
  ensurePositive(config, "rate_limit", "throttle_fall", defaults.rate_limit.throttle_fall)
  ensurePositive(config, "rate_limit", "brake_rise", defaults.rate_limit.brake_rise)
  ensurePositive(config, "rate_limit", "brake_fall", defaults.rate_limit.brake_fall)

  ensurePositive(config, "ema_tau", "throttle", defaults.ema_tau.throttle)
  ensurePositive(config, "ema_tau", "brake", defaults.ema_tau.brake)
  ensurePositive(config, "lerp_tau", "throttle", defaults.lerp_tau.throttle)
  ensurePositive(config, "lerp_tau", "brake", defaults.lerp_tau.brake)

  ensureUnit(config, "arbitration", "brake_start", defaults.arbitration.brake_start)
  ensureUnit(config, "arbitration", "brake_full", defaults.arbitration.brake_full)
  if config.arbitration.brake_full <= config.arbitration.brake_start then
    config.arbitration.brake_start = defaults.arbitration.brake_start
    config.arbitration.brake_full = defaults.arbitration.brake_full
  end

  ensureNonNegative(config, "neutral", "speed_max_mps", defaults.neutral.speed_max_mps)
  ensureUnit(config, "neutral", "throttle_min", defaults.neutral.throttle_min)
  ensureUnit(config, "neutral", "brake", defaults.neutral.brake)

  ensureNonNegative(config, "smooth_start", "time_s", defaults.smooth_start.time_s)
  ensureNonNegative(config, "smooth_start", "speed_mps", defaults.smooth_start.speed_mps)
  ensureUnit(config, "smooth_start", "throttle_cap", defaults.smooth_start.throttle_cap)

  ensureNonNegative(config, "shift", "hold_s", defaults.shift.hold_s)

  ensureUnit(config, "predictive", "brake_threshold", defaults.predictive.brake_threshold)
  ensureUnit(config, "predictive", "lead", defaults.predictive.lead)
  ensureUnit(config, "predictive", "release_hyst", defaults.predictive.release_hyst)
  ensureNonNegative(config, "predictive", "min_speed_mps", defaults.predictive.min_speed_mps)
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

function M.load(path, notify)
  local config = copyDefaults()
  local file = io.open(path, "r")
  if not file then
    if notify then
      notify("WARN", "pedals: config not found (" .. tostring(path) .. "), using code defaults")
    end
    return config, false
  end

  local content = file:read("*all")
  file:close()

  local ok, decoded = pcall(jsonDecode, content, path)
  if not ok or type(decoded) ~= "table" then
    if notify then
      notify("WARN", "pedals: config parse failed, using code defaults")
    end
    return config, false
  end

  mergeKnownValues(config, decoded)
  validate(config)
  return config, true
end

return M
