local kw = require("keywork")
local dbus = require("keywork.dbus")
local log = require("keywork.log")
local loop = require("keywork.loop")
local util = require("shell.bar.util")

local trim = util.trim
local capture = util.capture
local label = util.label
local status_pill = util.status_pill
local dbus_entries_to_table = util.dbus_entries_to_table

local DBUS_PROPERTIES = "org.freedesktop.DBus.Properties"
local DBUS_OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager"

local IWD = "net.connman.iwd"
local IWD_STATION = "net.connman.iwd.Station"
local IWD_NETWORK = "net.connman.iwd.Network"
local IWD_AGENT = "net.connman.iwd.SignalLevelAgent"
local IWD_AGENT_PATH = "/dev/keywork/bar/SignalLevelAgent"
-- dBm thresholds aligned with the 80/60/40/20 percent icon buckets.
local IWD_SIGNAL_LEVELS = { -60, -70, -80, -90 }
local IWD_LEVEL_PERCENT = { 90, 70, 50, 30, 10 }

local function wifi_signal_icon(percent)
  if percent >= 80 then
    return "network-wireless-signal-excellent"
  elseif percent >= 60 then
    return "network-wireless-signal-good"
  elseif percent >= 40 then
    return "network-wireless-signal-ok"
  elseif percent >= 20 then
    return "network-wireless-signal-weak"
  end
  return "network-wireless-signal-none"
end

local function dbm_to_percent(dbm)
  return math.max(0, math.min(100, (dbm + 100) * 2))
end

local function pill_from_values(palette, operstate, essid, percent, on_tap)
  if not percent and operstate == "up" then
    percent = essid ~= "" and 70 or 50
  end
  percent = math.max(0, math.min(100, percent or 0))
  local name = "network-wireless-offline"
  local color = palette.error
  if operstate == "up" then
    color = palette.accent
    name = wifi_signal_icon(percent)
  end
  return status_pill(palette, "network", name, nil, color, { on_tap = on_tap })
end

local function pill_from_output(palette, output, on_tap)
  local lines = {}
  for line in (output .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end
  return pill_from_values(palette, trim(lines[1] or "down"), trim(lines[2] or ""), tonumber(lines[3]), on_tap)
end

local Network = kw.stateful({
  init = function(self)
    local palette = self.props.colors
    self.colors = palette
    self.wifi_tap = function()
      self:toggle_wifi_menu()
    end
    self.pill = pill_from_values(palette, "down", "", 0, self.wifi_tap)
    self:update_network()
    self:watch_network()
    -- Signal strength has no change signal; refresh once a minute.
    self.timer = loop.timer({ delay = 60.0, interval = 60.0 })
    local timer = self.timer
    loop.spawn(function()
      for _ in timer:ticks() do
        self:set_state(function(state)
          state:update_network()
        end)
      end
    end)
  end,

  dispose = function(self)
    if self.timer then
      self.timer:cancel()
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
    if self.network_iwd_objects_sub then
      self.network_iwd_objects_sub:cancel()
    end
    if self.iwd_agent then
      self.iwd_agent:unexport()
    end
    if self.network_bus then
      self.network_bus:close()
    end
  end,

  -- iwd exposes everything on the system bus (iwctl is only a CLI over
  -- it), so prefer that over shelling out when a station exists.
  discover_iwd = function(self)
    if not self.network_bus or self.iwd_station then
      return
    end
    loop.spawn(function()
      local object_manager = self.network_bus:proxy(IWD, "/", DBUS_OBJECT_MANAGER, { timeout_ms = 2000 })
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
        state.pill = pill_from_values(state.props.colors, "down", "", 0, state.wifi_tap)
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
        state.pill = pill_from_values(state.props.colors, "up", essid, state.iwd_percent, state.wifi_tap)
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
          self.iwd_percent = dbm_to_percent(dbm)
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

  toggle_wifi_menu = function(self)
    self:set_state(function(state)
      state.wifi_menu_open = not state.wifi_menu_open
      if state.wifi_menu_open then
        state.wifi_status = nil
        state:refresh_wifi_list()
        state:scan_wifi()
      end
    end)
  end,

  scan_wifi = function(self)
    if not self.network_bus or not self.iwd_station or self.wifi_scan_inflight then
      return
    end
    -- Show Scanning… immediately. A concurrent list fetch may still see
    -- Station.Scanning=false before Scan starts; wifi_scan_inflight keeps
    -- the indicator on until the Scan call returns, after which the
    -- station property (and its PropertiesChanged) own the flag.
    self.wifi_scan_inflight = true
    self:set_state(function(state)
      state.wifi_scanning = true
    end)
    loop.spawn(function()
      -- Errors here are usually "already scanning"; the results land via
      -- the Scanning PropertiesChanged signal either way.
      self.network_bus:call({
        destination = IWD,
        path = self.iwd_station,
        interface = IWD_STATION,
        member = "Scan",
        timeout_ms = 2000,
      })
      self.wifi_scan_inflight = false
      -- Re-read so the header and list match post-Scan station state
      -- (Scanning true now, or already false with a fuller list).
      self:refresh_wifi_list()
    end)
  end,

  -- Coalesces concurrent refresh requests. A fetch does N D-Bus GetAll
  -- calls and can still be in flight when Scanning flips or InterfacesAdded
  -- fires; dropping those would leave the menu stuck on a partial list
  -- until the next open.
  refresh_wifi_list = function(self)
    if self.wifi_fetching then
      self.wifi_refresh_pending = true
      return
    end
    self.wifi_fetching = true
    loop.spawn(function()
      while true do
        self.wifi_refresh_pending = false
        self:refresh_wifi_list_now()
        if not self.wifi_refresh_pending then
          break
        end
      end
      self.wifi_fetching = false
    end)
  end,

  refresh_wifi_list_now = function(self)
    local bus = self.network_bus
    if not bus or not self.iwd_station then
      self:set_state(function(state)
        state.wifi_status = "iwd unavailable"
      end)
      return
    end
    local station_reply = bus:call({
      destination = IWD,
      path = self.iwd_station,
      interface = DBUS_PROPERTIES,
      member = "GetAll",
      args = { IWD_STATION },
      timeout_ms = 1000,
    })
    local scanning = station_reply
      and dbus_entries_to_table((station_reply.args or {})[1]).Scanning == true
    local ordered_reply = bus:call({
      destination = IWD,
      path = self.iwd_station,
      interface = IWD_STATION,
      member = "GetOrderedNetworks",
      timeout_ms = 3000,
    })
    local networks = {}
    for i, entry in ipairs(ordered_reply and (ordered_reply.args or {})[1] or {}) do
      if i > 12 then
        break
      end
      local path = entry[1]
      local props_reply = bus:call({
        destination = IWD,
        path = path,
        interface = DBUS_PROPERTIES,
        member = "GetAll",
        args = { IWD_NETWORK },
        timeout_ms = 1000,
      })
      if props_reply then
        local props = dbus_entries_to_table((props_reply.args or {})[1])
        table.insert(networks, {
          path = path,
          name = props.Name or "?",
          secured = props.Type ~= nil and props.Type ~= "open",
          known = props.KnownNetwork ~= nil,
          connected = props.Connected == true,
          percent = dbm_to_percent((tonumber(entry[2]) or -10000) / 100),
        })
      end
    end
    self:set_state(function(state)
      state.wifi_networks = networks
      -- Keep Scanning… while our Scan call is still in flight even if this
      -- snapshot was taken before iwd flipped Station.Scanning.
      state.wifi_scanning = scanning or self.wifi_scan_inflight
    end)
  end,

  connect_wifi = function(self, entry)
    loop.spawn(function()
      self:set_state(function(state)
        state.wifi_status = entry.connected and "Disconnecting…" or ("Connecting to " .. entry.name .. "…")
      end)
      local reply, err
      if entry.connected then
        reply, err = self.network_bus:call({
          destination = IWD,
          path = self.iwd_station,
          interface = IWD_STATION,
          member = "Disconnect",
          timeout_ms = 10000,
        })
      else
        -- Known and open networks connect directly; secured unknown
        -- ones need an auth agent we don't provide yet (POC).
        reply, err = self.network_bus:call({
          destination = IWD,
          path = entry.path,
          interface = IWD_NETWORK,
          member = "Connect",
          timeout_ms = 30000,
        })
      end
      self:set_state(function(state)
        state.wifi_status = reply and nil or ("Failed: " .. (err or "unknown"))
      end)
      self.iwd_percent = nil
      self:update_network_iwd()
      self:refresh_wifi_list()
    end)
  end,

  build_wifi_menu = function(self)
    local palette = self.props.colors
    local rows = {}

    local header_children = { label("Wi-Fi", palette, palette.muted), kw.spacer() }
    if self.wifi_status then
      table.insert(header_children, label(self.wifi_status, palette, palette.subtle))
    elseif self.wifi_scanning then
      table.insert(header_children, label("Scanning…", palette, palette.subtle))
    end
    table.insert(rows, kw.padding({
      x = palette.space[3],
      y = palette.space[2],
      child = kw.row({ align = "center", children = header_children }),
    }))

    for _, entry in ipairs(self.wifi_networks or {}) do
      local color = entry.connected and palette.foreground or palette.muted
      local children = {
        kw.icon({ name = wifi_signal_icon(entry.percent), size = 16, color = color }),
        kw.expanded(label(entry.name, palette, color)),
      }
      if entry.secured and not entry.known then
        table.insert(children, kw.icon({ name = "network-wireless-encrypted", size = 14, color = palette.subtle }))
      end
      if entry.connected then
        table.insert(children, kw.icon({ name = "object-select", size = 16, color = palette.foreground }))
      end
      -- The gesture child must be a container (box): hover_background
      -- restyles the box directly, and its radius rounds the highlight.
      table.insert(rows, kw.gesture({
        id = "wifi-" .. entry.path,
        hover_background = palette.hover,
        on_tap = function()
          self:connect_wifi(entry)
        end,
        child = kw.container({
          radius = palette.radius[4],
          padding = { x = palette.space[3], y = palette.space[2] },
        }, kw.row({
          spacing = palette.space[2],
          align = "center",
          children = children,
        })),
      }))
    end

    if not self.wifi_networks or #self.wifi_networks == 0 then
      table.insert(rows, kw.padding({
        x = palette.space[3],
        y = palette.space[2],
        child = label(self.wifi_networks and "No networks found" or "Loading…", palette, palette.subtle),
      }))
    end

    return kw.container({
      background = palette.background,
      border = palette.border,
      border_width = 1,
      radius = palette.radius[4],
      padding = palette.space[1],
      child = kw.column({ children = rows }),
    })
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
            state.pill = pill_from_output(state.props.colors, result.stdout, state.wifi_tap)
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
    -- iwd systems: Station state, scanning, and connected-network changes.
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
              if state.wifi_menu_open then
                state:refresh_wifi_list()
              end
            end)
          end
        end
      end)
    end
    -- iwd's ObjectManager lives at /, outside the namespace above. Network
    -- objects appear and disappear there while GetOrderedNetworks grows.
    local objects_ok, objects_sub = pcall(function()
      return bus:subscribe({
        path = "/",
        interface = DBUS_OBJECT_MANAGER,
      })
    end)
    if objects_ok and objects_sub then
      self.network_iwd_objects_sub = objects_sub
      local sub = self.network_iwd_objects_sub
      loop.spawn(function()
        for signal in sub:events() do
          local object_path = (signal.args or {})[1]
          if (signal.member == "InterfacesAdded" or signal.member == "InterfacesRemoved")
            and type(object_path) == "string"
            and object_path:sub(1, #"/net/connman/iwd/") == "/net/connman/iwd/" then
            self:set_state(function(state)
              if state.wifi_menu_open then
                state:refresh_wifi_list()
              end
            end)
          end
        end
      end)
    end
    self:discover_iwd()
  end,

  update = function(self)
    if self.colors ~= self.props.colors then
      self.colors = self.props.colors
      self:update_network()
    end
  end,

  build = function(self, context)
    local palette = self.props.colors
    return kw.anchored({
      id = "network",
      popup = self.wifi_menu_open and kw.popup({
        edge = "bottom",
        alignment = "end",
        gap = palette.space[1],
        width = 300,
        content = function()
          return self:build_wifi_menu()
        end,
        on_close = function()
          self:set_state(function(state)
            state.wifi_menu_open = false
          end)
        end,
      }) or nil,
      child = self.pill,
    })
  end,
})

return {
  Network = Network,
}
