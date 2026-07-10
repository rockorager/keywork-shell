local kw = require("keywork")
local dbus = require("keywork.dbus")
local log = require("keywork.log")
local loop = require("keywork.loop")
local process = require("keywork.process")
local service = require("keywork.service")
local stream = require("keywork.stream")
local network = require("shell.bar.network")
local util = require("shell.bar.util")

local seconds_until_next_minute = util.seconds_until_next_minute
local label = util.label
local status_pill = util.status_pill

local UPOWER = "org.freedesktop.UPower"
local UPOWER_DEVICE = "org.freedesktop.UPower.Device"
local DISPLAY_DEVICE = "/org/freedesktop/UPower/devices/DisplayDevice"

local TIME_FORMAT = "%a %b %d  %I:%M %p"

local function volume_status(palette, audio)
  if not audio then
    return status_pill(palette, "volume", "audio-volume-muted", nil, palette.muted)
  end
  local percent = audio.percent
  local muted = audio.muted
  local name = "audio-volume-high"
  local color = palette.accent
  if muted or percent <= 0 then
    name = "audio-volume-muted"
    color = palette.muted
  elseif percent < 34 then
    name = "audio-volume-low"
  elseif percent < 67 then
    name = "audio-volume-medium"
  end
  return status_pill(palette, "volume", name, nil, color)
end

local function upower_state_name(state)
  if state == 1 then
    return "Charging"
  elseif state == 2 then
    return "Discharging"
  elseif state == 4 then
    return "Full"
  elseif state == 5 then
    return "Pending charge"
  elseif state == 6 then
    return "Pending discharge"
  end
  return "Unknown"
end

local function battery_status_from_values(palette, percentage, state)
  if not percentage then
    return status_pill(palette, "battery", "battery-level-0", "", palette.muted)
  end
  local capacity = math.max(0, math.min(100, math.floor(percentage + 0.5)))
  local status = upower_state_name(state)
  local level = math.floor(capacity / 10) * 10
  if capacity > 0 and level == 0 then
    level = 10
  end
  if capacity >= 95 then
    level = 100
  end

  local name = "battery-level-" .. tostring(level)
  if status == "Charging" then
    if level == 100 then
      name = "battery-full-charging"
    else
      name = name .. "-charging"
    end
  elseif status == "Full" then
    name = "battery-level-100-plugged-in"
  end

  local color = palette.success
  if status ~= "Charging" and status ~= "Full" then
    if capacity <= 15 then
      color = palette.danger
    elseif capacity <= 30 then
      color = palette.warning
    end
  end
  return status_pill(palette, "battery", name, tostring(capacity) .. "%", color, {
    label_font_size = palette.font_size[1],
  })
end

local clock_service = service.define("shell.bar.clock", function(self)
  self:publish(os.date(TIME_FORMAT))
  local timer = loop.timer({ delay = seconds_until_next_minute(), interval = 60.0 })
  for _ in timer:ticks() do
    self:publish(os.date(TIME_FORMAT))
  end
end)

local audio_service = service.define("shell.bar.audio", function(self)
  local refreshing = false
  local dirty = false

  local function refresh()
    if refreshing then
      dirty = true
      return
    end
    refreshing = true
    loop.spawn(function()
      local result = process.capture({ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" })
      refreshing = false
      if result and result.ok then
        local raw = tonumber(result.stdout:match("Volume:%s*([%d%.]+)")) or 0
        self:publish({
          percent = math.floor(raw * 100 + 0.5),
          muted = result.stdout:find("MUTED", 1, true) ~= nil,
        })
      end
      if dirty then
        dirty = false
        refresh()
      end
    end)
  end

  refresh()

  local proc = process.spawn({
    argv = { "pactl", "subscribe" },
    stdout = "pipe",
    stderr = "pipe",
  })
  if not proc then
    log.warn("volume subscribe unavailable")
    return
  end

  for line in stream.lines(proc:stdout()) do
    if line:find("sink", 1, true) or line:find("server", 1, true) then
      refresh()
    end
  end
  local result = proc:wait()
  if not (result and result.ok) then
    log.warn("volume subscribe exited")
  end
end)

local battery_service = service.define("shell.bar.battery", function(self)
  local ok, bus = pcall(function()
    return dbus.system()
  end)
  if not ok or not bus then
    log.warn("battery dbus unavailable")
    return
  end

  -- The observer resyncs on UPower restarts and reports unavailable while
  -- the daemon is down, so no manual GetAll/signal plumbing is needed.
  local obs = bus:observe({
    destination = UPOWER,
    path = DISPLAY_DEVICE,
    interface = UPOWER_DEVICE,
    timeout_ms = 1000,
  })
  for event in obs:changes() do
    if event.available then
      self:publish({
        percentage = event.props.Percentage,
        state = event.props.State,
      })
    else
      self:publish({})
    end
  end
end)

local StatusItems = kw.stateful({
  init = function(self)
    self.audio = audio_service:use(self.scope, function(audio)
      self.audio = audio
      self:set_state()
    end)
    self.battery = battery_service:use(self.scope, function(battery)
      self.battery = battery
      self:set_state()
    end)
    self.time = clock_service:use(self.scope, function(time)
      self.time = time
      self:set_state()
    end) or os.date(TIME_FORMAT)
  end,

  build = function(self, context)
    local palette = self.props.colors
    local battery = self.battery or {}
    return kw.row({
      spacing = palette.space[2],
      align = "center",
      children = {
        volume_status(palette, self.audio),
        network.Network({ key = "network", colors = palette }),
        battery_status_from_values(palette, battery.percentage, battery.state),
        label(self.time, palette),
      },
    })
  end,
})

return {
  Items = StatusItems,
}
