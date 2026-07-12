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

local function menu_label(value, palette, color)
  return kw.label(value, {
    color = color or palette.foreground,
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
  return status_pill(palette, "volume", volume_icon("volume", device), nil, color, {
    on_tap = on_tap,
  })
end

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

  section_row = function(self, title)
    local palette = self.props.colors
    return kw.padding({
      x = palette.space[3],
      y = palette.space[2],
      child = menu_label(title, palette, palette.muted),
    })
  end,

  device_rows = function(self, kind, devices)
    local palette = self.props.colors
    local rows = {}
    local generic_icon = kind == "sink" and "audio-speakers" or "audio-input-microphone"
    for _, device in ipairs(devices) do
      if device.available ~= false then
        local color = device.default and palette.foreground or palette.muted
        rows[#rows + 1] = kw.gesture({
          id = "audio-" .. kind .. "-" .. tostring(device.id),
          hover_background = palette.hover,
          on_tap = function() self:select_device(device) end,
          child = kw.container({
            radius = palette.radius[4],
            padding = { x = palette.space[3], y = palette.space[2] },
          }, kw.row({
            spacing = palette.space[2],
            align = "center",
            children = {
              kw.icon({ name = device.icon_name or generic_icon, size = 16, color = color }),
              kw.expanded(menu_label(device.description or device.name, palette, color)),
              device.default and kw.icon({
                name = "object-select",
                size = 16,
                color = palette.foreground,
              }) or kw.sized({ width = 16 }, kw.text("")),
            },
          })),
        })
      end
    end
    if #rows == 0 then
      rows[1] = kw.padding({
        x = palette.space[3],
        y = palette.space[2],
        child = menu_label("No available devices", palette, palette.subtle),
      })
    end
    return rows
  end,

  build_menu = function(self)
    local palette = self.props.colors
    local audio = self.audio or { outputs = {}, inputs = {} }
    local rows = { self:section_row("Output") }
    for _, row in ipairs(self:device_rows("sink", audio.outputs or {})) do
      rows[#rows + 1] = row
    end
    rows[#rows + 1] = self:section_row("Input")
    for _, row in ipairs(self:device_rows("source", audio.inputs or {})) do
      rows[#rows + 1] = row
    end
    local item_height = 44
    local list_height = math.min(#rows * item_height, item_height * 9)
    return kw.container({
      background = palette.background,
      border = palette.border,
      border_width = 1,
      radius = palette.radius[4],
      padding = palette.space[1],
      child = kw.sized({
        height = list_height,
        child = kw.list({
          id = "audio-menu-list",
          count = #rows,
          item_height = item_height,
          build_item = function(index) return rows[index] end,
        }),
      }),
    })
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
        content = function() return self:build_menu() end,
        on_close = function()
          self:set_state(function(state) state.menu_open = false end)
        end,
      }) or nil,
      child = volume_status(palette, audio.output, self.audio_tap),
    })
  end,
})

M.Audio = Audio

return M
