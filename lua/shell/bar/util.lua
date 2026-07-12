local kw = require("keywork")

local M = {}

local function trim(value)
  local trimmed = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return trimmed
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
    child = child,
    align = "center",
    on_tap = options.on_tap,
  })
end

M.trim = trim
M.label = label
M.status_pill = status_pill

return M
