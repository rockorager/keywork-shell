local M = {}

-- Palette derived from the resolved theme so the bar adapts to the
-- system color scheme, matching the keywork-launcher card look. The
-- theme's space scale rides along so widgets built outside build()
-- (async update hooks) can reach the design tokens too.
local function palette(theme)
  local scheme = theme.colors
  local result = {
    background = scheme.surface,
    border = scheme.border,
    foreground = scheme.text,
    muted = scheme.text_secondary,
    subtle = scheme.text_tertiary,
    hover = scheme.fill_secondary,
    active = scheme.fill,
    active_hover = scheme.fill,
    on_active = scheme.text,
    error = scheme.danger,
    on_error = scheme.on_danger,
    success = scheme.success,
    warning = scheme.warning,
    danger = scheme.danger,
    accent = scheme.text,
    selection = scheme.accent,

    space = theme.space,
  }

  -- The bar uses Radix Badge size-3 metrics for primary status controls,
  -- while keeping their colors neutral instead of accent-colored.
  local bar_theme = {}
  for key, value in pairs(theme) do bar_theme[key] = value end
  bar_theme.components = {}
  for key, value in pairs(theme.components or {}) do bar_theme.components[key] = value end
  local chip = {}
  for key, value in pairs(theme.components.chip or {}) do chip[key] = value end
  chip.padding_x = theme.space[2] * 1.25
  chip.padding_y = theme.space[1]
  chip.radius = theme.radius[2]
  chip.min_height = theme.line_height[2] + 2 * theme.space[1]
  chip.font_size = theme.font_size[2]
  chip.line_height = theme.line_height[2]
  chip.icon_size = theme.space[4]
  chip.gap = theme.space[2]
  chip.background = nil
  chip.foreground = result.muted
  chip.hover_background = result.hover
  chip.pressed_background = result.hover
  chip.selected_background = result.active
  chip.selected_foreground = result.on_active
  chip.selected_hover_background = result.active_hover
  chip.selected_pressed_background = result.active_hover
  chip.focused_border = nil
  bar_theme.components.chip = chip
  result.theme = bar_theme

  return result
end

M.palette = palette

return M
