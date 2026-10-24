-- soulPilot wheel state.

local M = {}

function M.create()
  return {
    cfg = nil,
    cfg_from_file = false,
    active = false,
    active_config_path = nil,
    rate_scale = 1.0,
    need_init = true,
    seed_zero = false,
    init_grace = 0,
    spawn_guard = false,
    pipe = { rate_limited = 0, ema = 0, output = 0 },
    last_out = { engaged = false, steer = 0 },
    last_raw = 0,
    rate_raw = 0,
    rate_out = 0,
    prev_rate_raw = nil,
    prev_rate_out = nil,
    notify = nil,
  }
end

function M.resetRateStats(state)
  state.rate_raw = 0
  state.rate_out = 0
  state.prev_rate_raw = nil
  state.prev_rate_out = nil
end

function M.reset(state)
  state.pipe.rate_limited = 0
  state.pipe.ema = 0
  state.pipe.output = 0
  state.last_out = { engaged = false, steer = 0 }
  state.last_raw = 0
  M.resetRateStats(state)
end

return M
