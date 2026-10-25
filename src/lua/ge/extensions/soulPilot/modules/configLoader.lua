-- soulPilot GE config loader: default configs and user overrides.

local M = {}

M.USER_CONFIG_DIR = "settings/mod_settings/soulPilot/"
M.MOD_CONFIG_DIR = "mods/unpacked/soulPilot/src/config/"
M.RUNTIME_CONFIG_DIR = "mods/unpacked/soulPilot/config/"
M.GRAPH_DIR = "mods/unpacked/soulPilot/ai/road/"
M.GRAPH_CONF = M.MOD_CONFIG_DIR .. "graph.json"

M.MASTER_DEFAULTS = {
  enable_wheel = 1,
  smooth_ai_cars = 1,
  smooth_spectapilot = 1,
  enable_pedals = 1,
  enable_lights = 1,
  enable_popup = 1,
  enable_pain = 1,
  enable_music = 0,
  debug_mode = 0,
  ai_mode = "traffic",
  skip_warmup_if_warm = 1,
}

M.LIGHTS_DEFAULTS = {
  timing = { poll_hz = 1, hysteresis_min = 15 },
  modes = { day_state = 1, night_state = 1 },
  night_window = { start = "20:00", ["end"] = "07:00" },
}

M.PET_DEFAULTS = {
  duration_s = 6.0,
  throttle = { offset = 0.05, amp = 0.05, hz = 2.5 },
  steer_rate_scale = 0.5,
  sound = {
    sound_event = "",
    pitch = 0.7,
    interval_s = 0.5,
    breath_hz = 0.3,
    breath_depth = 0.25,
    volume = 2.0,
    no_pos = false,
  },
  cooldown = {
    speed_gate_kph = 5.0,
    spam_max = 4,
    spam_window_s = 30.0,
    cooldown_s = 20.0,
  },
}

M.POPUP_DEFAULTS = {
  models = { "bolide", "wigeon", "bx", "wendover", "barstow" },
  day_min_s = 120,
  day_max_s = 180,
  night_min_s = 180,
  night_max_s = 300,
  blink_min_s = 1.5,
  blink_max_s = 2.0,
  debug_force_blink_delay_s = 0,
  squint_min = 0.27,
  squint_max = 0.50,
  squint_duration_s = 6.0,
}

M.PAIN_DEFAULTS = {
  check_hz = 1,
  damage_threshold = 50000,
  damage_threshold_percent = 0.8,
  damage_threshold_by_model = { us_semi = 10000000 },
  damage_speed_kph = 1.0,
  damage_hold_s = 2.0,
  stuck_speed_kph = 5,
  stuck_time_s = 5,
  stuck_throttle_min = 0.5,
  flipped_up_dot = 0.3,
  flipped_time_s = 2,
  cooldown_s = 15,
  restore_ai = 1,
  warmup_after = 1,
  warmup_sway = 0,
}

local function copyTable(source)
  local copy = {}
  for key, value in pairs(source) do
    if type(value) == "table" then
      copy[key] = copyTable(value)
    else
      copy[key] = value
    end
  end
  return copy
end

local function clampNumber(value, minimum, maximum, fallback)
  value = tonumber(value)
  if value == nil or value ~= value then
    return fallback
  end
  if value < minimum then
    return minimum
  end
  if value > maximum then
    return maximum
  end
  return value
end

local function clampZeroOne(value, fallback)
  return clampNumber(value, 0, 1, fallback)
end

function M.configPath(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end

  local user_path = M.USER_CONFIG_DIR .. name
  local file = io.open(user_path, "r")
  if file then
    file:close()
    return user_path
  end

  -- Development keeps configs under src/config; a deployed/release mod keeps
  -- them at the mod root. Prefer src when both exist, so tests and dev runs
  -- keep the same paths.
  local source_path = M.MOD_CONFIG_DIR .. name
  file = io.open(source_path, "r")
  if file then
    file:close()
    return source_path
  end

  local runtime_path = M.RUNTIME_CONFIG_DIR .. name
  file = io.open(runtime_path, "r")
  if file then
    file:close()
    return runtime_path
  end
  return source_path
end

function M.readJsonFile(path)
  if type(path) == "string" then
    local name = path:match("([^/]+)$")
    if name then
      local user_path = M.USER_CONFIG_DIR .. name
      local user_file = io.open(user_path, "r")
      if user_file then
        user_file:close()
        path = user_path
      end
    end
  end

  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local content = file:read("*all")
  file:close()

  local ok, decoded = pcall(jsonDecode, content, path)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

function M.parseTime(value)
  if type(value) == "number" then
    if value == value and value >= 0 and value < 24 then
      return value
    end
    return nil
  end
  if type(value) ~= "string" then
    return nil
  end

  local hour, minute = value:match("^(%d%d?):(%d%d)$")
  if hour then
    hour, minute = tonumber(hour), tonumber(minute)
    if hour >= 0 and hour < 24 and minute >= 0 and minute <= 59 then
      return hour + minute / 60
    end
    return nil
  end

  local number = tonumber(value)
  if number and number == number and number >= 0 and number < 24 then
    return number
  end
  return nil
end

function M.normalizeHour(value)
  value = value % 24
  if value < 0 then
    value = value + 24
  end
  return value
end

function M.inNightWindow(hour, start_hour, end_hour)
  if start_hour == nil or end_hour == nil or start_hour == end_hour then
    return false
  end
  if start_hour < end_hour then
    return hour >= start_hour and hour < end_hour
  end
  return hour >= start_hour or hour < end_hour
end

function M.loadGraphConfig()
  local defaults = {
    friction_mu = 0.75,
    turn_angle_threshold_deg = 20,
    speed_round_kph = 5,
  }
  local decoded = M.readJsonFile(M.GRAPH_CONF)
  if not decoded then
    return defaults
  end
  return {
    friction_mu = tonumber(decoded.friction_mu) or defaults.friction_mu,
    turn_angle_threshold_deg = tonumber(decoded.turn_angle_threshold_deg)
      or defaults.turn_angle_threshold_deg,
    speed_round_kph = tonumber(decoded.speed_round_kph) or defaults.speed_round_kph,
  }
end

function M.loadMasterConfig()
  local defaults = M.MASTER_DEFAULTS
  local config = copyTable(defaults)
  local decoded = M.readJsonFile(M.configPath("master.json"))
  if not decoded then
    return config
  end

  local function flag(name, fallback)
    local value = tonumber(decoded[name])
    if value == nil or value ~= value then
      return fallback
    end
    return value ~= 0 and 1 or 0
  end

  config.enable_wheel = flag("enable_wheel", defaults.enable_wheel)
  config.smooth_ai_cars = flag("smooth_ai_cars", defaults.smooth_ai_cars)
  config.smooth_spectapilot = flag("smooth_spectapilot", defaults.smooth_spectapilot)
  config.enable_pedals = flag("enable_pedals", defaults.enable_pedals)
  config.enable_lights = flag("enable_lights", defaults.enable_lights)
  config.enable_popup = flag("enable_popup", defaults.enable_popup)
  config.enable_pain = flag("enable_pain", defaults.enable_pain)
  config.enable_music = flag("enable_music", defaults.enable_music)
  config.debug_mode = flag("debug_mode", defaults.debug_mode)
  config.skip_warmup_if_warm = flag("skip_warmup_if_warm", defaults.skip_warmup_if_warm)

  if type(decoded.ai_mode) == "string" then
    local mode = decoded.ai_mode:lower()
    if mode == "" or mode == "traffic" or mode == "span" then
      config.ai_mode = mode
    end
  end
  return config
end

function M.loadLightsConfig()
  local defaults = M.LIGHTS_DEFAULTS
  local config = {
    timing = copyTable(defaults.timing),
    modes = copyTable(defaults.modes),
    night_window = copyTable(defaults.night_window),
    maps = {},
    from_file = false,
  }

  local decoded = M.readJsonFile(M.configPath("lights.json"))
  if decoded then
    config.from_file = true
    local function value(group, key, minimum, maximum, fallback)
      local raw = type(decoded[group]) == "table" and tonumber(decoded[group][key]) or nil
      return clampNumber(raw, minimum, maximum, fallback)
    end
    config.timing.poll_hz = value("timing", "poll_hz", 0.1, 10, defaults.timing.poll_hz)
    config.timing.hysteresis_min = value("timing", "hysteresis_min", 0, 120, defaults.timing.hysteresis_min)
    config.modes.day_state = value("modes", "day_state", 0, 2, defaults.modes.day_state)
    config.modes.night_state = value("modes", "night_state", 1, 2, defaults.modes.night_state)
    if type(decoded.night_window) == "table" then
      if M.parseTime(decoded.night_window.start) then
        config.night_window.start = tostring(decoded.night_window.start)
      end
      if M.parseTime(decoded.night_window["end"]) then
        config.night_window["end"] = tostring(decoded.night_window["end"])
      end
    end
  end

  local decoded_map = M.readJsonFile(M.configPath("lights_by_map.json"))
  if decoded_map and type(decoded_map.maps) == "table" then
    for map_id, entry in pairs(decoded_map.maps) do
      if type(map_id) == "string" and type(entry) == "table"
        and type(entry.night_window) == "table"
        and M.parseTime(entry.night_window.start)
        and M.parseTime(entry.night_window["end"]) then
        config.maps[map_id:lower()] = {
          start = tostring(entry.night_window.start),
          ["end"] = tostring(entry.night_window["end"]),
        }
      end
    end
  end
  return config
end

function M.loadPetConfig()
  local defaults = M.PET_DEFAULTS
  local config = {
    duration_s = defaults.duration_s,
    offset = defaults.throttle.offset,
    amp = defaults.throttle.amp,
    hz = defaults.throttle.hz,
    steer_rate_scale = defaults.steer_rate_scale,
    sound_event = defaults.sound.sound_event,
    pitch = defaults.sound.pitch,
    sound_interval = defaults.sound.interval_s,
    breath_hz = defaults.sound.breath_hz,
    breath_depth = defaults.sound.breath_depth,
    sound_volume = defaults.sound.volume,
    sound_no_pos = defaults.sound.no_pos,
    speed_gate_kph = defaults.cooldown.speed_gate_kph,
    spam_max = defaults.cooldown.spam_max,
    spam_window_s = defaults.cooldown.spam_window_s,
    cooldown_s = defaults.cooldown.cooldown_s,
    from_file = false,
  }

  local decoded = M.readJsonFile(M.configPath("pet.json"))
  if decoded then
    config.from_file = true
    local function group_number(group, key, minimum, maximum, fallback)
      local raw = type(decoded[group]) == "table" and tonumber(decoded[group][key]) or nil
      return clampNumber(raw, minimum, maximum, fallback)
    end
    local function top_number(key, minimum, maximum, fallback)
      return clampNumber(decoded[key], minimum, maximum, fallback)
    end
    config.duration_s = top_number("duration_s", 1, 60, defaults.duration_s)
    config.offset = group_number("throttle", "offset", 0, 0.3, defaults.throttle.offset)
    config.amp = group_number("throttle", "amp", 0, 0.3, defaults.throttle.amp)
    config.hz = group_number("throttle", "hz", 0.05, 10, defaults.throttle.hz)
    config.steer_rate_scale = top_number("steer_rate_scale", 0.1, 1, defaults.steer_rate_scale)
    config.pitch = group_number("sound", "pitch", 0.2, 3, defaults.sound.pitch)
    config.sound_interval = group_number("sound", "interval_s", 0.05, 10, defaults.sound.interval_s)
    config.breath_hz = group_number("sound", "breath_hz", 0, 5, defaults.sound.breath_hz)
    config.breath_depth = group_number("sound", "breath_depth", 0, 1, defaults.sound.breath_depth)
    config.sound_volume = group_number("sound", "volume", 0, 3, defaults.sound.volume)
    if type(decoded.sound) == "table" then
      if type(decoded.sound.no_pos) == "boolean" then
        config.sound_no_pos = decoded.sound.no_pos
      end
      if type(decoded.sound.sound_event) == "string" then
        config.sound_event = decoded.sound.sound_event
      end
    end
    config.speed_gate_kph = group_number("cooldown", "speed_gate_kph", 0, 120, defaults.cooldown.speed_gate_kph)
    config.spam_max = group_number("cooldown", "spam_max", 1, 50, defaults.cooldown.spam_max)
    config.spam_window_s = group_number("cooldown", "spam_window_s", 1, 600, defaults.cooldown.spam_window_s)
    config.cooldown_s = group_number("cooldown", "cooldown_s", 0, 600, defaults.cooldown.cooldown_s)
  end

  if config.sound_event == "" or config.sound_interval <= 0 then
    config.sound_interval = 0
  end
  return config
end

function M.loadPopupConfig()
  local defaults = M.POPUP_DEFAULTS
  local config = {
    models = copyTable(defaults.models),
    day_min_s = defaults.day_min_s,
    day_max_s = defaults.day_max_s,
    night_min_s = defaults.night_min_s,
    night_max_s = defaults.night_max_s,
    blink_min_s = defaults.blink_min_s,
    blink_max_s = defaults.blink_max_s,
    debug_force_blink_delay_s = defaults.debug_force_blink_delay_s,
    squint_min = defaults.squint_min,
    squint_max = defaults.squint_max,
    squint_duration_s = defaults.squint_duration_s,
    from_file = false,
  }

  local decoded = M.readJsonFile(M.configPath("popup.json"))
  if decoded then
    config.from_file = true
    local function number(key, minimum, maximum, fallback)
      return clampNumber(decoded[key], minimum, maximum, fallback)
    end
    if type(decoded.models) == "table" and decoded.models[1] ~= nil then
      local models = {}
      for _, value in ipairs(decoded.models) do
        if type(value) == "string" and value ~= "" then
          models[#models + 1] = value:lower()
        end
      end
      if #models > 0 then
        config.models = models
      end
    end
    config.day_min_s = number("day_min_s", 5, 3600, config.day_min_s)
    config.day_max_s = number("day_max_s", 5, 3600, config.day_max_s)
    config.night_min_s = number("night_min_s", 5, 3600, config.night_min_s)
    config.night_max_s = number("night_max_s", 5, 3600, config.night_max_s)
    config.blink_min_s = number("blink_min_s", 0.2, 10, config.blink_min_s)
    config.blink_max_s = number("blink_max_s", 0.2, 10, config.blink_max_s)
    config.debug_force_blink_delay_s = number("debug_force_blink_delay_s", 0, 600, config.debug_force_blink_delay_s)
    config.squint_min = number("squint_min", 0, 1, config.squint_min)
    config.squint_max = number("squint_max", 0, 1, config.squint_max)
    config.squint_duration_s = number("squint_duration_s", 0.5, 60, config.squint_duration_s)
    if config.squint_max < config.squint_min then
      config.squint_max = config.squint_min
    end
  end

  -- debug_force_blink_delay_s is a diagnostics-only override. Never let a
  -- stale/user value turn normal blinking into a 5-second loop.
  local master = M.loadMasterConfig()
  if not master or tonumber(master.debug_mode) ~= 1 then
    config.debug_force_blink_delay_s = 0
  end

  if config.day_max_s < config.day_min_s then
    config.day_max_s = config.day_min_s
  end
  if config.night_max_s < config.night_min_s then
    config.night_max_s = config.night_min_s
  end
  if config.blink_max_s < config.blink_min_s then
    config.blink_max_s = config.blink_min_s
  end
  return config
end

function M.loadPainConfig()
  local defaults = M.PAIN_DEFAULTS
  local config = copyTable(defaults)
  local decoded = M.readJsonFile(M.configPath("pain.json"))
  if not decoded then
    return config
  end

  local function number(key, minimum, maximum, fallback)
    return clampNumber(decoded[key], minimum, maximum, fallback)
  end
  config.check_hz = number("check_hz", 0.1, 10, defaults.check_hz)
  config.damage_threshold = number("damage_threshold", 0, 1e9, defaults.damage_threshold)
  config.damage_threshold_percent = number("damage_threshold_percent", 0, 1, defaults.damage_threshold_percent)
  config.damage_speed_kph = number("damage_speed_kph", 0, 20, defaults.damage_speed_kph)
  config.damage_hold_s = number("damage_hold_s", 0, 30, defaults.damage_hold_s)
  config.damage_threshold_by_model = copyTable(defaults.damage_threshold_by_model)
  if type(decoded.damage_threshold_by_model) == "table" then
    for model, value in pairs(decoded.damage_threshold_by_model) do
      local numeric = tonumber(value)
      if type(model) == "string" and numeric and numeric > 0 then
        config.damage_threshold_by_model[model:lower()] = numeric
      end
    end
  end
  config.stuck_speed_kph = number("stuck_speed_kph", 0, 200, defaults.stuck_speed_kph)
  config.stuck_time_s = number("stuck_time_s", 1, 120, defaults.stuck_time_s)
  config.stuck_throttle_min = number("stuck_throttle_min", 0.1, 1, defaults.stuck_throttle_min)
  config.flipped_up_dot = number("flipped_up_dot", 0, 0.9, defaults.flipped_up_dot)
  config.flipped_time_s = number("flipped_time_s", 0.5, 60, defaults.flipped_time_s)
  config.cooldown_s = number("cooldown_s", 1, 600, defaults.cooldown_s)
  config.restore_ai = number("restore_ai", 0, 1, defaults.restore_ai)
  config.warmup_after = number("warmup_after", 0, 1, defaults.warmup_after)
  config.warmup_sway = number("warmup_sway", 0, 1, defaults.warmup_sway)
  return config
end

return M
