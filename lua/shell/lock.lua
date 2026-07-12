local kw = require("keywork")
local clock = require("shell.clock")

local M = {}

local function avatar(theme, path)
  if path then
    return kw.sized({
      width = 96,
      height = 96,
      child = kw.image({ path = path, fit = "cover" }),
    })
  end

  return kw.icon({ name = "avatar-default", size = 96, color = theme.colors.text_secondary })
end

M.View = kw.stateful({
  init = function(self)
    if self.props.time and self.props.date then
      return
    end
    self.timestamp = clock.use(self.scope, function(timestamp)
      self.timestamp = timestamp
      self:set_state()
    end) or os.time()
  end,

  build = function(self, context)
    local theme = context.theme
    local status = self.props.status
    local message = status or "Enter your password to unlock"
    local message_color = status and theme.colors.danger or theme.colors.text_secondary
    local timestamp = self.timestamp or os.time()
    local time = self.props.time or clock.format_time(timestamp)
    local date = self.props.date or clock.format_date(timestamp)

    local card = kw.sized({
      width = 360,
      child = kw.container({
        background = theme.colors.surface,
        border = theme.colors.border,
        border_width = 1,
        radius = theme.radius[5],
        padding = theme.space[5],
        child = kw.column({
          align = "stretch",
          spacing = theme.space[3],
          children = {
            kw.center(avatar(theme, self.props.avatar_path)),
            kw.center(kw.text(self.props.username or "User", {
              color = theme.colors.text,
              role = "title",
            })),
            kw.text_input({
              id = "password",
              placeholder = "Password",
              autofocus = self.props.autofocus ~= false,
              obscured = true,
              clear_on_submit = true,
              on_submit = self.props.on_submit,
            }),
            kw.center(kw.text(message, {
              color = message_color,
              role = "label",
            })),
          },
        }),
      }),
    })

    return kw.theme({
      data = theme,
      child = kw.box({ background = theme.colors.background }, kw.center(kw.column({
        align = "center",
        spacing = theme.space[5],
        children = {
          kw.column({
            align = "center",
            spacing = theme.space[1],
            children = {
              kw.text(date, {
                color = theme.colors.text_secondary,
                font_size = 18,
                role = "label",
              }),
              kw.text(time, {
                color = theme.colors.text,
                font_size = 64,
                line_height = 72,
              }),
            },
          }),
          card,
        },
      }))),
    })
  end,
})

return M
