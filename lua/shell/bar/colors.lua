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
  }

  -- Bar chip design in one place: kw.chip reads metrics and colors from
  -- theme.components.chip, so call sites only say what differs.
  -- min_height 28 keeps icon-only and labeled chips the same height in
  -- the bar row; it's a dimension, not a scale step.
  result.chip_theme = {
    components = {
      chip = {
        padding_x = theme.space[2],
        padding_y = 0,
        radius = theme.radius[4],
        min_height = 28,
        foreground = result.muted,
        hover_background = result.hover,
        selected_background = result.active,
        selected_foreground = result.on_active,
        selected_hover_background = result.active_hover,
      },
    },
  }

  return result
end

M.palette = palette

return M
