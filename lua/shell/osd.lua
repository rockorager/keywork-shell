local kw = require("keywork")
local dbus = require("keywork.dbus")
local log = require("keywork.log")
local loop = require("keywork.loop")
local process = require("keywork.process")
local xdg = require("keywork.xdg")

local M = {}

M.width = 208
M.height = 48
M.margin = 96

local TRACK_WIDTH = 144
local DISPLAY_MS = 1400

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function icon_for(kind, value, muted)
  if kind == "brightness" then
    return "display-brightness-symbolic"
  end
  local prefix = kind == "microphone" and "microphone-sensitivity" or "audio-volume"
  if muted or value <= 0 then
    return prefix .. "-muted"
  elseif value < 0.34 then
    return prefix .. "-low"
  elseif value < 0.67 then
    return prefix .. "-medium"
  end
  return prefix .. "-high"
end

local function level_bar(theme, value, muted)
  local fill_width = math.floor(TRACK_WIDTH * (muted and 0 or clamp(value, 0, 1)) + 0.5)
  local fill = kw.sized({ width = fill_width, height = 6 }, kw.container({
    background = theme.colors.accent,
    radius = theme.radius[6],
    min_width = fill_width,
    min_height = 6,
  }, kw.text("")))
  return kw.sized({ width = TRACK_WIDTH, height = 6 }, kw.container({
    background = theme.colors.fill_secondary,
    radius = theme.radius[6],
    min_width = TRACK_WIDTH,
    min_height = 6,
    horizontal_align = "start",
    vertical_align = "center",
  }, fill))
end

local Level = kw.stateful({
  build = function(self, context)
    local theme = context.theme
    local value = clamp(tonumber(self.props.value) or 0, 0, 1)
    local muted = self.props.muted == true

    return kw.theme({
      data = theme,
      child = kw.container({
        min_width = M.width,
        min_height = M.height,
        padding = { all = 4 },
      }, kw.container({
        background = theme.colors.surface_high,
        radius = theme.radius[6],
        min_width = M.width - 8,
        min_height = M.height - 8,
        padding = { x = theme.space[3] },
        vertical_align = "center",
      }, kw.row({
        align = "center",
        spacing = theme.space[3],
        children = {
          kw.icon({
            name = icon_for(self.props.kind, value, muted),
            size = 20,
            color = muted and theme.colors.text_tertiary or theme.colors.text,
          }),
          level_bar(theme, value, muted),
        },
      }))),
    })
  end,
})

M.Level = Level

local Controller = {}
Controller.__index = Controller

function Controller:changed()
  if self.on_change then
    self.on_change()
  end
end

function Controller:visible()
  return self.current
end

function Controller:show(kind, value, muted)
  self.generation = self.generation + 1
  local generation = self.generation
  self.current = {
    kind = kind,
    value = clamp(value, 0, 1),
    muted = muted == true,
    generation = generation,
  }
  self:changed()
  loop.spawn(function()
    loop.sleep(DISPLAY_MS)
    if self.current and self.current.generation == generation then
      self.current = nil
      self:changed()
    end
  end)
end

function Controller:enqueue(job)
  self.jobs[#self.jobs + 1] = job
  if self.running then
    return
  end
  self.running = true
  loop.spawn(function()
    while #self.jobs > 0 do
      table.remove(self.jobs, 1)()
    end
    self.running = false
  end)
end

local audio_targets = {
  volume = "@DEFAULT_AUDIO_SINK@",
  microphone = "@DEFAULT_AUDIO_SOURCE@",
}

local function run(argv)
  local result, err = process.capture(argv)
  if not result then
    log.warn("osd command failed", argv[1], err or "unknown")
    return nil
  end
  if not result.ok then
    log.warn("osd command failed", argv[1], result.stderr or "")
    return nil
  end
  return result
end

function Controller:adjust_audio(kind, action)
  local target = audio_targets[kind]
  if not target or (action ~= "up" and action ~= "down" and action ~= "mute") then
    return false
  end
  self:enqueue(function()
    local changed
    if action == "mute" then
      changed = run({ "wpctl", "set-mute", target, "toggle" })
    else
      if not run({ "wpctl", "set-mute", target, "0" }) then
        return
      end
      local step = action == "up" and "5%+" or "5%-"
      changed = run({ "wpctl", "set-volume", "-l", "1.0", target, step })
    end
    if not changed then
      return
    end
    local state = run({ "wpctl", "get-volume", target })
    if not state then
      return
    end
    local value = tonumber(state.stdout:match("Volume:%s*([%d%.]+)")) or 0
    self:show(kind, value, state.stdout:find("MUTED", 1, true) ~= nil)
  end)
  return true
end

local function read_number(path)
  local value = xdg.read_file(path)
  return value and tonumber(value:match("^%s*(%d+)")) or nil
end

function Controller:read_backlight(name)
  local root = "/sys/class/backlight/" .. name
  local value = read_number(root .. "/brightness")
  local maximum = read_number(root .. "/max_brightness")
  if not value or not maximum or maximum <= 0 then
    return nil
  end
  return {
    name = name,
    value = value,
    maximum = maximum,
  }
end

function Controller:backlight()
  local preferred = os.getenv("KEYWORK_BACKLIGHT_DEVICE")
  if preferred and preferred ~= "" then
    return self:read_backlight(preferred)
  end
  if self.backlight_name then
    local current = self:read_backlight(self.backlight_name)
    if current then
      return current
    end
    self.backlight_name = nil
  end
  local entries, err = xdg.read_dir("/sys/class/backlight")
  if not entries then
    log.warn("backlight discovery failed", err or "unknown")
    return nil
  end
  table.sort(entries, function(left, right)
    return left.name < right.name
  end)
  for _, entry in ipairs(entries) do
    local current = self:read_backlight(entry.name)
    if current then
      self.backlight_name = entry.name
      return current
    end
  end
  log.warn("brightness osd disabled: no backlight device")
  return nil
end

function Controller:system()
  if self.system_bus then
    return self.system_bus
  end
  local ok, bus = pcall(function()
    return dbus.system()
  end)
  if not ok or not bus then
    log.warn("brightness control failed: system dbus unavailable")
    return nil
  end
  self.system_bus = bus
  return bus
end

function Controller:adjust_brightness(action)
  if action ~= "up" and action ~= "down" then
    return false
  end
  self:enqueue(function()
    local current = self:backlight()
    if not current then
      return
    end
    local step = math.max(1, math.floor(current.maximum * 0.05 + 0.5))
    local target = clamp(current.value + (action == "up" and step or -step), 0, current.maximum)
    if target ~= current.value then
      local bus = self:system()
      if not bus then
        return
      end
      local reply, err = bus:call({
        destination = "org.freedesktop.login1",
        path = "/org/freedesktop/login1/session/auto",
        interface = "org.freedesktop.login1.Session",
        member = "SetBrightness",
        args = {
          dbus.string("backlight"),
          dbus.string(current.name),
          dbus.uint32(target),
        },
        timeout_ms = 1000,
      })
      if not reply then
        log.warn("brightness control failed", err or "unknown")
        return
      end
    end
    self:show("brightness", target / current.maximum, false)
  end)
  return true
end

function M.new(on_change)
  return setmetatable({
    on_change = on_change,
    jobs = {},
    running = false,
    generation = 0,
  }, Controller)
end

return M
