local kw = require("keywork")
local loop = require("keywork.loop")
local process = require("keywork.process")

local M = {}

local function trim(value)
  local trimmed = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return trimmed
end

local function seconds_until_next_minute()
  local now = os.date("*t")
  return 60 - now.sec
end

local function capture(argv, callback)
  local proc = process.spawn({
    argv = argv,
    stdout = "pipe",
    stderr = "pipe",
  })
  if not proc then
    return nil
  end
  loop.spawn(function()
    local stdout = {}
    for chunk in proc:stdout() do
      table.insert(stdout, chunk)
    end
    local stderr = {}
    for chunk in proc:stderr() do
      table.insert(stderr, chunk)
    end
    local result = proc:wait()
    if result then
      result.stdout = table.concat(stdout)
      result.stderr = table.concat(stderr)
      callback(result)
    end
  end)
  return proc
end

local function label(value, palette, color)
  return kw.label(value, { color = color or palette.foreground })
end

local function status_pill(palette, id, icon_name, text, color, options)
  options = options or {}
  local child = kw.icon_theme({
    color = color,
    size = options.icon_size or 16,
    child = kw.default_text_style({
      color = color,
      child = kw.icon_label(icon_name, text, {
        size = options.icon_size or 16,
        font_size = options.label_font_size,
      }),
    }),
  })
  return kw.chip({
    id = id,
    theme = palette.chip_theme,
    child = child,
    align = "center",
    on_tap = function()
      print("clicked " .. id)
    end,
  })
end

local function dbus_entries_to_table(entries)
  local result = {}
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" and entry[1] ~= nil then
      result[entry[1]] = entry[2]
    end
  end
  return result
end

M.trim = trim
M.seconds_until_next_minute = seconds_until_next_minute
M.capture = capture
M.label = label
M.status_pill = status_pill
M.dbus_entries_to_table = dbus_entries_to_table

return M
