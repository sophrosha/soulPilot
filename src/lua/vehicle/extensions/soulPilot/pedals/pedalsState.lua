-- soulPilot pedals state.
-- All mutable runtime state is created here so the other pedal modules do not
-- need hidden locals or globals.

local M = {}

local function newChannel()
  return { rate_limited = 0, ema = 0, output = 0 }
end

function M.create()
  return {
    cfg = nil,
    cfg_from_file = false,
    active = false,
    need_init = true,
    init_from_zero = true,
    overrides_written = false,
    clutch_written = false,
    predictive_on = false,
    start_time = 0,
    smooth_start_skipped = true,
    step_garbage_warned = {},
    out_garbage_warned = {},
    pipe = {
      throttle = newChannel(),
      brake = newChannel(),
    },
    last_out = { engaged = false, throttle = 0, brake = 0, clutch = 0 },
    last_raw = { throttle = 0, brake = 0, clutch = 0 },
    raw_hold_time = 0,
    last_raw_sample = 0,
    stuck_time = 0,
    stuck_warned = false,
    ai_was_driving = false,
    resume_time = 99,
    throttle_high_time = 0,
    throttle_high_warn_acc = 0,
    ramp_time = 0,
    last_gear = "",
    shift_hold_time = 0,
    shift_hold_value = 0,
    rate_scale = 1.0,
    rate_scale_time = 0,
    diag_hist = {},
    diag_n = 0,
    notify = nil,
  }
end

local function resetChannel(channel)
  channel.rate_limited = 0
  channel.ema = 0
  channel.output = 0
end

function M.reset(state)
  resetChannel(state.pipe.throttle)
  resetChannel(state.pipe.brake)

  state.last_out = { engaged = false, throttle = 0, brake = 0, clutch = 0 }
  state.last_raw = { throttle = 0, brake = 0, clutch = 0 }
  state.predictive_on = false
  state.start_time = 0
  state.raw_hold_time = 0
  state.last_raw_sample = 0
  state.stuck_time = 0
  state.stuck_warned = false
  state.ai_was_driving = false
  state.resume_time = 99
  state.throttle_high_time = 0
  state.throttle_high_warn_acc = 0
  state.ramp_time = 0
  state.rate_scale = 1.0
  state.rate_scale_time = 0
  state.last_gear = ""
  state.shift_hold_time = 0
  state.shift_hold_value = 0
  state.step_garbage_warned = {}
  state.out_garbage_warned = {}
  state.diag_hist = {}
  state.diag_n = 0
end

function M.resetChannel(state, name)
  resetChannel(state.pipe[name])
end

return M
