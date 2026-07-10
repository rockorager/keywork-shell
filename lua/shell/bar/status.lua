local kw = require("keywork")
local dbus = require("keywork.dbus")
local log = require("keywork.log")
local loop = require("keywork.loop")
local process = require("keywork.process")
local network = require("shell.bar.network")
local util = require("shell.bar.util")

local seconds_until_next_minute = util.seconds_until_next_minute
local capture = util.capture
local label = util.label
local status_pill = util.status_pill

local UPOWER = "org.freedesktop.UPower"
local UPOWER_DEVICE = "org.freedesktop.UPower.Device"
local DBUS_PROPERTIES = "org.freedesktop.DBus.Properties"

local function volume_status_from_output(palette, output)
  local raw = tonumber(output:match("Volume:%s*([%d%.]+)")) or 0
  local percent = math.floor(raw * 100 + 0.5)
  local muted = output:find("MUTED", 1, true) ~= nil
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

local function battery_status_from_values(palette, percentage, state, line_power_online)
  if not percentage then
    return status_pill(palette, "battery", "battery-level-0", "", palette.muted)
  end
  local capacity = math.max(0, math.min(100, math.floor(percentage + 0.5)))
  local status = upower_state_name(state)
  if line_power_online and status ~= "Full" then
    status = "Charging"
  end
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

local StatusItems = kw.stateful({
  init = function(self)
    local palette = self.props.colors
    self.volume = status_pill(palette, "volume", "audio-volume-muted", nil, palette.muted)
    self.battery = status_pill(palette, "battery", "battery-level-0", "", palette.muted)
    self:update_time()
    self:update_volume()
    self:watch_volume()
    self:watch_battery()
    self:update_battery()
    self.timer = loop.timer({ delay = seconds_until_next_minute(), interval = 60.0 })
    local timer = self.timer
    loop.spawn(function()
      for _ in timer:ticks() do
        self:set_state(function(state)
          state:update_time()
        end)
      end
    end)
  end,

  dispose = function(self)
    if self.timer then
      self.timer:cancel()
    end
    if self.volume_proc then
      self.volume_proc:cancel()
    end
    if self.volume_sub then
      self.volume_sub:cancel()
    end
    if self.battery_sub then
      self.battery_sub:cancel()
    end
    if self.battery_bus then
      self.battery_bus:close()
    end
  end,

  update_time = function(self)
    self.time = os.date("%a %b %d  %I:%M %p")
  end,

  update_volume = function(self)
    local palette = self.props.colors
    self.colors = palette

    if not self.volume_proc then
      self.volume_proc = capture({ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }, function(result)
        self.volume_proc = nil
        if result.ok then
          self:set_state(function(state)
            state.volume = volume_status_from_output(state.props.colors, result.stdout)
          end)
        end
        if self.volume_dirty then
          self.volume_dirty = false
          self:update_volume()
        end
      end)
    end

  end,

  watch_volume = function(self)
    if self.volume_sub then
      return
    end

    self.volume_sub = process.spawn({
      argv = { "pactl", "subscribe" },
      stdout = "pipe",
      stderr = "pipe",
    })
    if not self.volume_sub then
      return
    end
    local proc = self.volume_sub
    loop.spawn(function()
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
            self:set_state(function(state)
              if state.volume_proc then
                state.volume_dirty = true
              else
                state:update_volume()
              end
            end)
          end
        end
      end
      local result = proc:wait()
      self.volume_sub = nil
      if not (result and result.ok) then
        log.warn("volume subscribe exited")
      end
    end)
  end,

  read_upower_properties = function(self, path)
    loop.spawn(function()
      local reply, err = self.battery_bus:call({
        destination = UPOWER,
        path = path,
        interface = DBUS_PROPERTIES,
        member = "GetAll",
        args = { UPOWER_DEVICE },
        timeout_ms = 1000,
      })
      if not reply then
        log.warn("battery dbus properties failed", err or path)
        return
      end
      self:set_state(function(state)
        state:apply_battery_properties(path, (reply.args or {})[1] or {})
        state:update_battery_widget()
      end)
    end)
  end,

  apply_battery_properties = function(self, path, props)
    local is_battery = path == "/org/freedesktop/UPower/devices/DisplayDevice"
      or tostring(path):find("/battery_", 1, true) ~= nil
      or props.Type == 2
    local is_line_power = props.Type == 1 or props.Online ~= nil

    if is_line_power and props.Online ~= nil then
      self.line_power_online = props.Online
    end
    if is_battery then
      if props.Percentage ~= nil then
        self.battery_percentage = props.Percentage
      end
      if props.State ~= nil then
        self.battery_state = props.State
      end
    end
  end,

  update_battery_widget = function(self)
    self.battery = battery_status_from_values(
      self.props.colors,
      self.battery_percentage,
      self.battery_state,
      self.line_power_online
    )
  end,

  update_battery = function(self)
    if not self.battery_bus then
      return
    end
    self:read_upower_properties("/org/freedesktop/UPower/devices/DisplayDevice")
    loop.spawn(function()
      local reply, err = self.battery_bus:call({
        destination = UPOWER,
        path = "/org/freedesktop/UPower",
        interface = UPOWER,
        member = "EnumerateDevices",
        timeout_ms = 1000,
      })
      if not reply then
        log.warn("battery dbus enumerate failed", err or "unknown")
        return
      end
      for _, path in ipairs((reply.args or {})[1] or {}) do
        self:read_upower_properties(path)
      end
    end)
  end,

  apply_battery_signal = function(self, signal)
    if signal.member == "PropertiesChanged" and (signal.args or {})[1] == UPOWER_DEVICE then
      self:apply_battery_properties(signal.path or "", signal.args[2] or {})
      self:update_battery_widget()
    elseif signal.member == "DeviceAdded" or signal.member == "DeviceRemoved" or signal.member == "Changed" then
      self:update_battery()
    end
  end,

  watch_battery = function(self)
    if self.battery_bus or self.battery_sub then
      return
    end
    local ok, bus = pcall(function()
      return dbus.system()
    end)
    if ok and bus then
      self.battery_bus = bus
      local sub_ok, sub = pcall(function()
        return bus:subscribe({
          path_namespace = "/org/freedesktop/UPower",
        })
      end)
      if sub_ok and sub then
        self.battery_sub = sub
        loop.spawn(function()
          for signal in sub:events() do
            if signal.member == "PropertiesChanged" or signal.member == "DeviceAdded" or signal.member == "DeviceRemoved" or signal.member == "Changed" then
              self:set_state(function(state)
                state:apply_battery_signal(signal)
              end)
            end
          end
        end)
      else
        log.warn("battery dbus subscribe failed")
        self.battery_bus:close()
        self.battery_bus = nil
      end
    else
      log.warn("battery dbus unavailable")
    end
  end,

  update = function(self)
    if self.colors ~= self.props.colors then
      self:update_volume()
      self:update_battery_widget()
    end
  end,

  build = function(self, context)
    local palette = self.props.colors
    return kw.row({
      spacing = palette.space[2],
      align = "center",
      children = {
        self.volume,
        network.Network({ key = "network", colors = palette }),
        self.battery,
        label(self.time, palette),
      },
    })
  end,
})

return {
  Items = StatusItems,
}
