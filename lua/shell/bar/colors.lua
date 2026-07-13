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
  }

  -- Keep the Radix chip metrics from the ambient theme and only make the
  -- bar's status chips neutral instead of accent-colored.
  local bar_theme = {}
  for key, value in pairs(theme) do bar_theme[key] = value end
  bar_theme.components = {}
  for key, value in pairs(theme.components or {}) do bar_theme.components[key] = value end
  local chip = {}
  for key, value in pairs(theme.components.chip or {}) do chip[key] = value end
  chip.background = nil
  chip.foreground = result.muted
  chip.hover_background = result.hover
  chip.pressed_background = result.hover
  chip.selected_background = result.active
  chip.selected_foreground = result.on_active
  chip.selected_hover_background = result.active_hover
  chip.selected_pressed_background = result.active_hover
  bar_theme.components.chip = chip
  result.theme = bar_theme

  return result
end

M.palette = palette

return M
