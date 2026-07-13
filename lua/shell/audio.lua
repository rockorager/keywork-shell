local kw = require("keywork")
local keywork_audio = require("keywork.audio")
local log = require("keywork.log")
local service = require("keywork.service")
local util = require("shell.bar.util")

local status_pill = util.status_pill

local M = {}

local active_monitor = nil

local audio_service = service.define("shell.audio", function(self)
  local monitor, err = keywork_audio.monitor()
  if not monitor then
    log.warn("PipeWire audio unavailable", err or "unknown")
    self:publish({ outputs = {}, inputs = {} })
    return
  end
  active_monitor = monitor
  self.scope:on_cancel(function()
    if active_monitor == monitor then active_monitor = nil end
    monitor:close()
  end)

  local function publish()
    self:publish({
      output = monitor:default_sink(),
      input = monitor:default_source(),
      outputs = monitor:sinks(),
      inputs = monitor:sources(),
    })
  end

  publish()
  for _ in monitor:events() do publish() end
end)

function M.use(scope, on_change)
  return audio_service:use(scope, on_change)
end

local device_kind = {
  volume = "sink",
  microphone = "source",
}

function M.adjust(kind, action, count)
  local monitor = active_monitor
  local target_kind = device_kind[kind]
  if not monitor then return nil, "PipeWire audio unavailable" end
  if not target_kind then return nil, "invalid audio kind" end
  local device = monitor:default(target_kind)
  if not device then return nil, "default audio device unavailable" end

  count = math.max(1, math.floor(tonumber(count) or 1))
  local ok, err
  if action == "mute" then
    if count % 2 == 1 then ok, err = monitor:toggle_muted(device.id) end
  elseif action == "up" or action == "down" then
    if device.muted then
      ok, err = monitor:set_muted(device.id, false)
      if not ok then return nil, err end
    end
    local direction = action == "up" and 1 or -1
    ok, err = monitor:adjust_volume(device.id, direction * count * 0.05, 1.0)
  else
    return nil, "invalid audio action"
  end
  if ok == nil and err then return nil, err end
  return monitor:default(target_kind)
end

function M.set_default(device)
  local monitor = active_monitor
  if not monitor then return nil, "PipeWire audio unavailable" end
  return monitor:set_default(device.kind, device.name)
end

local function menu_label(value, color)
  return kw.label(value, {
    color = color,
    max_lines = 1,
  })
end

local function volume_icon(kind, device)
  local prefix = kind == "microphone" and "microphone-sensitivity" or "audio-volume"
  local volume = device and device.volume or 0
  if not device or device.muted or volume <= 0 then
    return prefix .. "-muted"
  elseif volume < 0.34 then
    return prefix .. "-low"
  elseif volume < 0.67 then
    return prefix .. "-medium"
  end
  return prefix .. "-high"
end

local function volume_status(palette, device, on_tap)
  local color = palette.accent
  if not device or device.muted or (device.volume or 0) <= 0 then
    color = palette.muted
  end
  return status_pill("volume", volume_icon("volume", device), nil, color, {
    on_tap = on_tap,
  })
end

local function device_icon(kind, device)
  local generic = kind == "sink" and "audio-volume-high" or "audio-input-microphone"
  local name = device.icon_name
  if not name or name == "" or name:match("^audio%-card") or name == "audio-speakers" then
    return generic
  end
  if name == "audio-headphones-bluetooth" then
    return "audio-headphones"
  end
  return name
end

local function device_label(kind, device)
  local internal = device.bus == "pci" or device.bus == "platform"
  local nick = device.nick
  if internal then
    if kind == "sink" and device.port_type == "speaker" then
      return "Built-in Speakers"
    elseif kind == "source" and device.port_type == "mic" then
      return "Built-in Microphone"
    end
  end
  if nick and nick ~= "" then
    return nick
  end
  return device.description or device.name
end

local function device_rows(palette, kind, devices, on_select)
  local rows = {}
  for _, device in ipairs(devices) do
    if device.available ~= false then
      local color = not device.default and palette.muted or nil
      rows[#rows + 1] = kw.menu_item({
        id = "audio-" .. kind .. "-" .. tostring(device.id),
        on_tap = function() on_select(device) end,
        child = kw.row({
          spacing = palette.space[2],
          align = "center",
          children = {
            kw.icon({
              name = device_icon(kind, device),
              color = palette.muted,
            }),
            kw.expanded(menu_label(device_label(kind, device), color)),
            device.default and kw.icon({
              name = "object-select",
            }) or kw.sized({ width = 16 }, kw.text("")),
          },
        }),
      })
    end
  end
  if #rows == 0 then
    rows[1] = kw.padding({
      x = palette.space[3],
      y = palette.space[2],
      child = menu_label("No available devices", palette.subtle),
    })
  end
  return rows
end

local function audio_menu(palette, audio, on_select)
  audio = audio or { outputs = {}, inputs = {} }
  on_select = on_select or function(_) end
  local rows = { kw.menu_label({ text = "Output" }) }
  for _, row in ipairs(device_rows(palette, "sink", audio.outputs or {}, on_select)) do
    rows[#rows + 1] = row
  end
  rows[#rows + 1] = kw.menu_label({ text = "Input" })
  for _, row in ipairs(device_rows(palette, "source", audio.inputs or {}, on_select)) do
    rows[#rows + 1] = row
  end
  return kw.menu({
    child = kw.column({ children = rows }),
  })
end

local AudioMenu = kw.stateful({
  build = function(self)
    return audio_menu(self.props.colors, self.props.audio, self.props.on_select)
  end,
})

local Audio = kw.stateful({
  init = function(self)
    self.audio_tap = function()
      self:set_state(function(state)
        state.menu_open = not state.menu_open
      end)
    end
    self.audio = M.use(self.scope, function(snapshot)
      self.audio = snapshot
      self:set_state()
    end)
  end,

  select_device = function(self, device)
    local ok, err = M.set_default(device)
    if not ok then log.warn("audio default selection failed", err or "unknown") end
  end,

  build = function(self)
    local palette = self.props.colors
    local audio = self.audio or {}
    return kw.anchored({
      id = "audio",
      popup = self.menu_open and kw.popup({
        edge = "bottom",
        alignment = "end",
        gap = palette.space[1],
        width = 420,
        content = function()
          return audio_menu(palette, self.audio, function(device)
            self:select_device(device)
          end)
        end,
        on_close = function()
          self:set_state(function(state) state.menu_open = false end)
        end,
      }) or nil,
      child = volume_status(palette, audio.output, self.audio_tap),
    })
  end,
})

M.Audio = Audio
M.Menu = AudioMenu

return M
