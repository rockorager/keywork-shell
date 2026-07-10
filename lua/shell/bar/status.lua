local kw = require("keywork")
local dbus = require("keywork.dbus")
local log = require("keywork.log")
local loop = require("keywork.loop")
local process = require("keywork.process")
local service = require("keywork.service")
local network = require("shell.bar.network")
local util = require("shell.bar.util")

local seconds_until_next_minute = util.seconds_until_next_minute
local capture = util.capture
local label = util.label
local status_pill = util.status_pill

local UPOWER = "org.freedesktop.UPower"
local UPOWER_DEVICE = "org.freedesktop.UPower.Device"
local DBUS_PROPERTIES = "org.freedesktop.DBus.Properties"
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
    capture({ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }, function(result)
      refreshing = false
      if result.ok then
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

  local buffer = ""
  for chunk in proc:stdout() do
    buffer = buffer .. chunk
    while true do
      local newline = buffer:find("\n", 1, true)
      if not newline then
        break
      end
      local line = buffer:sub(1, newline - 1)
      buffer = buffer:sub(newline + 1)
      if line:find("sink", 1, true) or line:find("server", 1, true) then
        refresh()
      end
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

  local sub_ok, sub = pcall(function()
    return bus:subscribe({
      path_namespace = "/org/freedesktop/UPower",
    })
  end)
  if not sub_ok or not sub then
    log.warn("battery dbus subscribe failed")
    return
  end

  local percentage, state

  local function apply(path, props)
    if path ~= DISPLAY_DEVICE then
      return
    end
    if props.Percentage ~= nil then
      percentage = props.Percentage
    end
    if props.State ~= nil then
      state = props.State
    end
    self:publish({ percentage = percentage, state = state })
  end

  local function read_display_device()
    local reply, err = bus:call({
      destination = UPOWER,
      path = DISPLAY_DEVICE,
      interface = DBUS_PROPERTIES,
      member = "GetAll",
      args = { UPOWER_DEVICE },
      timeout_ms = 1000,
    })
    if not reply then
      log.warn("battery dbus properties failed", err or DISPLAY_DEVICE)
      return
    end
    apply(DISPLAY_DEVICE, (reply.args or {})[1] or {})
  end

  read_display_device()

  for signal in sub:events() do
    if signal.member == "PropertiesChanged" and (signal.args or {})[1] == UPOWER_DEVICE then
      apply(signal.path or "", signal.args[2] or {})
    elseif signal.member == "DeviceAdded" or signal.member == "DeviceRemoved" or signal.member == "Changed" then
      read_display_device()
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
