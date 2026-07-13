local kw = require("keywork")

local M = {}

local function trim(value)
  local trimmed = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return trimmed
end

local function label(value, color)
  return kw.label(value, { color = color })
end

local function status_pill(id, icon_name, text, color, options)
  options = options or {}
  return kw.chip({
    id = id,
    icon = icon_name,
    label = text,
    color = color,
    on_tap = options.on_tap,
  })
end

M.trim = trim
M.label = label
M.status_pill = status_pill

return M
