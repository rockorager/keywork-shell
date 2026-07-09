local kw = require("keywork")
local dbus = require("keywork.dbus")
local log = require("keywork.log")
local loop = require("keywork.loop")
local process = require("keywork.process")
local util = require("shell.bar.util")

local trim = util.trim
local seconds_until_next_minute = util.seconds_until_next_minute
local capture = util.capture
local label = util.label
local status_pill = util.status_pill
local dbus_entries_to_table = util.dbus_entries_to_table

local UPOWER = "org.freedesktop.UPower"
local UPOWER_DEVICE = "org.freedesktop.UPower.Device"
local DBUS_PROPERTIES = "org.freedesktop.DBus.Properties"

local IWD = "net.connman.iwd"
local IWD_STATION = "net.connman.iwd.Station"
local IWD_NETWORK = "net.connman.iwd.Network"
local IWD_AGENT = "net.connman.iwd.SignalLevelAgent"
local IWD_AGENT_PATH = "/dev/keywork/bar/SignalLevelAgent"
-- dBm thresholds aligned with the 80/60/40/20 percent icon buckets.
local IWD_SIGNAL_LEVELS = { -60, -70, -80, -90 }
local IWD_LEVEL_PERCENT = { 90, 70, 50, 30, 10 }

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

local function network_status_from_values(palette, operstate, essid, percent)
  if not percent and operstate == "up" then
    percent = essid ~= "" and 70 or 50
  end
  percent = math.max(0, math.min(100, percent or 0))
  local name = "network-wireless-offline"
  local color = palette.error
  if operstate == "up" then
    color = palette.accent
    if percent >= 80 then
      name = "network-wireless-signal-excellent"
    elseif percent >= 60 then
      name = "network-wireless-signal-good"
    elseif percent >= 40 then
      name = "network-wireless-signal-ok"
    elseif percent >= 20 then
      name = "network-wireless-signal-weak"
    else
      name = "network-wireless-signal-none"
    end
  end
  return status_pill(palette, "network", name, nil, color)
end

local function network_status_from_output(palette, output)
  local lines = {}
  for line in (output .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  return network_status_from_values(palette, trim(lines[1] or "down"), trim(lines[2] or ""), tonumber(lines[3]))
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
    return status_pill(palette, "battery", "battery-level-0", "", palette.muted, { icon_size = 14 })
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
    name = "battery-level-100-charged"
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
    icon_size = 14,
    label_font_size = 12,
  })
end

local StatusItems = kw.stateful({
  init = function(self)
    local palette = self.props.colors
    self.volume = status_pill(palette, "volume", "audio-volume-muted", nil, palette.muted)
    self.network = status_pill(palette, "network", "network-wireless-offline", nil, palette.error)
    self.battery = status_pill(palette, "battery", "battery-level-0", "", palette.muted, { icon_size = 14 })
    self:update_time()
    self:update_volume()
    self:update_network()
    self:watch_volume()
    self:watch_network()
    self:watch_battery()
    self:update_battery()
    self.timer = loop.timer({ delay = seconds_until_next_minute(), interval = 60.0 })
    local timer = self.timer
    loop.spawn(function()
      for _ in timer:ticks() do
        self:set_state(function(state)
          state:update_time()
          -- Signal strength has no change signal; refresh with the clock.
          state:update_network()
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
    if self.network_proc then
      self.network_proc:cancel()
    end
    if self.network_sub then
      self.network_sub:cancel()
    end
    if self.network_iwd_sub then
      self.network_iwd_sub:cancel()
    end
    if self.iwd_agent then
      self.iwd_agent:unexport()
    end
    if self.network_bus then
      self.network_bus:close()
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

  -- iwd exposes everything on the system bus (iwctl is only a CLI over
  -- it), so prefer that over shelling out when a station exists.
  discover_iwd = function(self)
    if not self.network_bus or self.iwd_station then
      return
    end
    loop.spawn(function()
      local object_manager = self.network_bus:proxy(IWD, "/", "org.freedesktop.DBus.ObjectManager", { timeout_ms = 2000 })
      local managed_objects = object_manager:GetManagedObjects()
      if not managed_objects then
        return -- no iwd on this system; the shell fallback stays
      end
      for _, entry in ipairs(managed_objects or {}) do
        local interfaces = dbus_entries_to_table(entry[2])
        if interfaces[IWD_STATION] then
          self.iwd_station = entry[1]
          break
        end
      end
      if self.iwd_station then
        self:register_iwd_agent_now()
        self:update_network_iwd_now()
      end
    end)
  end,

  register_iwd_agent_now = function(self)
    if self.iwd_agent then
      return
    end
    local ok, agent = pcall(function()
      return self.network_bus:export(IWD_AGENT_PATH, {
        [IWD_AGENT] = {
          methods = {
            Changed = {
              in_signature = "oy",
              call = function(_, _device, level)
                self:set_state(function(state)
                  state.iwd_percent = IWD_LEVEL_PERCENT[(tonumber(level) or 4) + 1] or 10
                  state:update_network()
                end)
              end,
            },
            Release = {
              in_signature = "",
              call = function() end,
            },
          },
        },
      })
    end)
    if not ok then
      log.warn("iwd signal agent export failed")
      return
    end
    self.iwd_agent = agent
    local reply, err = self.network_bus:call({
      destination = IWD,
      path = self.iwd_station,
      interface = IWD_STATION,
      member = "RegisterSignalLevelAgent",
      args = {
        dbus.object_path(IWD_AGENT_PATH),
        dbus.array("n", IWD_SIGNAL_LEVELS),
      },
      timeout_ms = 2000,
    })
    if not reply then
      log.warn("iwd RegisterSignalLevelAgent failed", err or "unknown")
    end
  end,

  register_iwd_agent = function(self)
    loop.spawn(function()
      self:register_iwd_agent_now()
    end)
  end,

  update_network_iwd_now = function(self)
    local bus = self.network_bus
    if not bus or not self.iwd_station then
      return
    end
    local reply = bus:call({
      destination = IWD,
      path = self.iwd_station,
      interface = DBUS_PROPERTIES,
      member = "GetAll",
      args = { IWD_STATION },
      timeout_ms = 1000,
    })
    if not reply then
      -- Station gone (iwd restarted?); fall back to the shell path.
      self.iwd_station = nil
      self:set_state(function(state)
        state:update_network()
      end)
      return
    end
    local props = dbus_entries_to_table((reply.args or {})[1])
    local connected_path = props.ConnectedNetwork
    if props.State ~= "connected" or not connected_path then
      self:set_state(function(state)
        state.network = network_status_from_values(state.props.colors, "down", "", 0)
      end)
      return
    end
    local network_reply = bus:call({
      destination = IWD,
      path = connected_path,
      interface = DBUS_PROPERTIES,
      member = "GetAll",
      args = { IWD_NETWORK },
      timeout_ms = 1000,
    })
    local essid = ""
    if network_reply then
      essid = dbus_entries_to_table((network_reply.args or {})[1]).Name or ""
    end
    local function apply()
      self:set_state(function(state)
        state.network = network_status_from_values(state.props.colors, "up", essid, state.iwd_percent)
      end)
    end
    if self.iwd_percent then
      apply()
      return
    end
    -- No agent report yet: read the real RSSI instead of guessing,
    -- so the pill never flashes an optimistic level at startup.
    local ordered_reply = bus:call({
      destination = IWD,
      path = self.iwd_station,
      interface = IWD_STATION,
      member = "GetOrderedNetworks",
      timeout_ms = 2000,
    })
    if ordered_reply then
      for _, entry in ipairs((ordered_reply.args or {})[1] or {}) do
        if entry[1] == connected_path then
          -- Signal strength arrives in units of 0.01 dBm.
          local dbm = (tonumber(entry[2]) or -10000) / 100
          self.iwd_percent = math.max(0, math.min(100, (dbm + 100) * 2))
          break
        end
      end
    end
    apply()
  end,

  update_network_iwd = function(self)
    loop.spawn(function()
      self:update_network_iwd_now()
    end)
  end,

  update_network = function(self)
    if self.iwd_station and self.network_bus then
      self:update_network_iwd()
      return
    end
    if not self.network_proc then
      self.network_proc = capture({ "sh", "-c", [==[
iface=$(ls /sys/class/net 2>/dev/null | grep -E '^wl|^wlan' | head -n1)
if [ -z "$iface" ]; then
  printf 'down\n\n0\n'
  exit 0
fi
operstate=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || printf 'down')
essid=''
dbm=''
if command -v iw >/dev/null 2>&1; then
  link=$(iw dev "$iface" link 2>/dev/null)
  essid=$(printf '%s\n' "$link" | sed -n 's/^[[:space:]]*SSID: //p' | head -n1)
  dbm=$(printf '%s\n' "$link" | sed -n 's/^[[:space:]]*signal: \(-\{0,1\}[0-9]\{1,\}\) dBm.*/\1/p' | head -n1)
elif command -v iwctl >/dev/null 2>&1; then
  show=$(iwctl station "$iface" show 2>/dev/null)
  essid=$(printf '%s\n' "$show" | sed -n 's/^[[:space:]]*Connected network[[:space:]]*//p' | head -n1 | sed 's/[[:space:]]*$//')
  dbm=$(printf '%s\n' "$show" | sed -n 's/^[[:space:]]*RSSI[[:space:]]*\(-\{0,1\}[0-9]\{1,\}\) dBm.*/\1/p' | head -n1)
elif command -v iwgetid >/dev/null 2>&1; then
  essid=$(iwgetid -r 2>/dev/null || true)
fi
if [ -n "$dbm" ]; then
  quality=$(( (dbm + 100) * 2 ))
  [ "$quality" -gt 100 ] && quality=100
  [ "$quality" -lt 0 ] && quality=0
else
  quality=$(awk -v iface="$iface:" '$1 == iface { printf "%d", ($3 * 100 / 70 + 0.5) }' /proc/net/wireless 2>/dev/null)
fi
printf '%s\n%s\n%s\n' "$operstate" "$essid" "$quality"
]==] }, function(result)
        self.network_proc = nil
        if result.ok then
          self:set_state(function(state)
            state.network = network_status_from_output(state.props.colors, result.stdout)
          end)
        end
      end)
    end
  end,

  watch_network = function(self)
    if self.network_bus or self.network_sub then
      return
    end
    local ok, bus = pcall(function()
      return dbus.system()
    end)
    if not ok or not bus then
      return
    end
    self.network_bus = bus
    self.network_sub = bus:subscribe({
      path_namespace = "/org/freedesktop/NetworkManager",
    })
    local sub = self.network_sub
    loop.spawn(function()
      for signal in sub:events() do
        if signal.member == "PropertiesChanged"
          or signal.member == "StateChanged"
          or signal.member == "DeviceAdded"
          or signal.member == "DeviceRemoved" then
          self:set_state(function(state)
            state:update_network()
          end)
        end
      end
    end)
    -- iwd systems: Station state and connected-network changes.
    local iwd_ok, iwd_sub = pcall(function()
      return bus:subscribe({
        path_namespace = "/net/connman/iwd",
      })
    end)
    if iwd_ok and iwd_sub then
      self.network_iwd_sub = iwd_sub
      local sub = self.network_iwd_sub
      loop.spawn(function()
        for signal in sub:events() do
          if signal.member == "PropertiesChanged" then
            self:set_state(function(state)
              state:update_network()
            end)
          end
        end
      end)
    end
    self:discover_iwd()
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
        state:apply_battery_properties(path, dbus_entries_to_table((reply.args or {})[1]))
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
      self:apply_battery_properties(signal.path or "", dbus_entries_to_table(signal.args[2]))
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
      self:update_network()
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
        self.network,
        self.battery,
        label(self.time, palette),
      },
    })
  end,
})

return {
  Items = StatusItems,
}
