local kw = require("keywork")

local colors = require("shell.bar.colors")
local status = require("shell.bar.status")
local sway = require("shell.bar.sway")
local tray = require("shell.bar.tray")

local M = {}

M.height = 40

-- Memoized per scheme: a stable palette identity keeps child update()
-- hooks from refreshing on every rebuild.
local palette_cache = {}
local function palette_for(theme)
  local cached = palette_cache[theme.color_scheme]
  if not cached then
    cached = colors.palette(theme)
    palette_cache[theme.color_scheme] = cached
  end
  return cached
end

local function launcher_button(self, palette)
  local open = self.props.launcher_open
  return kw.chip({
    id = "launcher-toggle",
    theme = palette.chip_theme,
    child = kw.icon({
      name = "view-app-grid-symbolic",
      size = 16,
      color = open and palette.on_active or palette.muted,
    }),
    align = "center",
    padding = { x = palette.space[3] },
    selected = open,
    on_tap = function()
      if self.props.on_toggle_launcher then
        self.props.on_toggle_launcher()
      end
    end,
  })
end

-- One bar per output. props: launcher_open, on_toggle_launcher, and
-- show_tray (SNI hosts register on D-Bus, so only one bar carries it).
local Bar = kw.stateful({
  build = function(self, context)
    local theme = context.theme
    local palette = palette_for(theme)

    local children = {
      launcher_button(self, palette),
      sway.Workspaces({ key = "sway-workspaces", colors = palette }),
      kw.spacer(),
    }
    if self.props.show_tray then
      children[#children + 1] = tray.Items({ key = "tray", colors = palette })
    end
    children[#children + 1] = status.Items({ key = "status", colors = palette })

    return kw.theme({
      data = theme,
      child = kw.column({
        align = "stretch",
        children = {
          kw.expanded(kw.container({
            background = palette.background,
            vertical_align = "center",
            padding = { x = theme.space[2], y = theme.space[1] },
          },
            kw.row({
              spacing = theme.space[3],
              align = "center",
              children = children,
            })
          )),
          -- Hairline against the windows below, like the launcher dividers.
          kw.container({ background = palette.border, min_height = 1 }, kw.sized({ height = 1 }, kw.text(""))),
        },
      }),
    })
  end,
})

M.Bar = Bar

return M
