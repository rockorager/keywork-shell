local M = {}

-- Palette derived from the resolved theme so the bar adapts to the
-- system color scheme, matching the keywork-launcher card look. The
-- theme's space/radius scales ride along so widgets built outside
-- build() (async update hooks) can reach the design tokens too.
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

    space = theme.space,
    radius = theme.radius,
    font_size = theme.font_size,
  }

  -- Bar chip design in one ambient theme: kw.chip reads it without every
  -- call site having to receive and pass a separate component theme.
  -- min_height 28 keeps icon-only and labeled chips the same height in
  -- the bar row; it's a dimension, not a scale step.
  local bar_theme = {}
  for key, value in pairs(theme) do bar_theme[key] = value end
  bar_theme.components = {}
  for key, value in pairs(theme.components or {}) do bar_theme.components[key] = value end
  bar_theme.components.chip = {
    padding_x = theme.space[2],
    padding_y = 0,
    radius = theme.radius[4],
    min_height = 28,
    foreground = result.muted,
    hover_background = result.hover,
    selected_background = result.active,
    selected_foreground = result.on_active,
    selected_hover_background = result.active_hover,
  }
  result.theme = bar_theme

  return result
end

M.palette = palette

return M
