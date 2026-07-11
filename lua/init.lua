local kw = require("keywork")

local bar = require("shell.bar")
local ipc = require("shell.ipc")
local launcher = require("shell.launcher")
local notifications = require("shell.notifications")

-- App-level state shared by the window set. Anything that decides which
-- windows exist lives here and flips via kw.app.invalidate(); widget
-- state (kw.stateful) is per-window runtime.
local shell = {
  launcher_open = false,
}

local function set_launcher_open(open)
  if shell.launcher_open == open then
    return
  end
  shell.launcher_open = open
  kw.app.invalidate()
end

-- Keybindings reach the running shell over the session bus:
--   bindsym $mod+Return exec keywork-shell launcher
local ipc_handle, ipc_err = ipc.serve({
  toggle_launcher = function()
    set_launcher_open(not shell.launcher_open)
  end,
})
if not ipc_handle and ipc_err == "name-taken" then
  io.stderr:write("keywork-shell: another instance already owns " .. ipc.name .. "\n")
  os.exit(1)
end

local notification_server = notifications.serve(function()
  kw.app.invalidate()
end)

return kw.app({
  app_id = "dev.rockorager.keywork.Shell",
  backend = "cpu",
  windows = function(ctx)
    local windows = {}
    for index, output in ipairs(ctx.outputs) do
      windows[#windows + 1] = kw.window({
        id = "bar:" .. output.name,
        output = output.name,
        width = 0, -- stretch to the anchored edges
        height = bar.height,
        layer_shell = {
          layer = "top",
          anchor = { "top", "left", "right" },
          exclusive_zone = bar.height,
        },
        child = bar.Bar({
          key = "bar",
          show_tray = index == 1,
        }),
      })
    end

    -- The launcher window's existence follows app state: declaring it
    -- creates the surface, dropping it destroys it. No anchors, so the
    -- compositor centers it on the output.
    if shell.launcher_open and ctx.outputs[1] then
      windows[#windows + 1] = kw.window({
        id = "launcher",
        output = ctx.outputs[1].name,
        width = launcher.width,
        height = launcher.height,
        layer_shell = {
          layer = "overlay",
          keyboard = "exclusive",
        },
        child = launcher.Launcher({
          key = "launcher",
          on_dismiss = function()
            set_launcher_open(false)
          end,
        }),
      })
    end

    -- Include geometry in each window id: layer-shell margins and dimensions
    -- cannot be updated live, so a card whose stack position or content height
    -- changes must be recreated with its new declaration.
    if notification_server and ctx.outputs[1] then
      local output = ctx.outputs[1]
      -- A zero-zone layer surface is already placed inside the bar's
      -- exclusive zone; this margin is only the visual gap below it.
      local top = notifications.gap
      local available = math.max(0, output.height - bar.height - top - notifications.margin)
      local used = 0
      for _, notification in ipairs(notification_server:visible()) do
        local height = notifications.height_for(notification)
        if used > 0 and used + height > available then
          break
        end
        windows[#windows + 1] = kw.window({
          id = "notification:" .. notification.id .. ":" .. used .. ":" .. height,
          output = output.name,
          width = notifications.width,
          height = height,
          layer_shell = {
            layer = "overlay",
            anchor = { "top", "right" },
            margin = {
              top = top + used,
              right = notifications.margin,
            },
          },
          child = notifications.Card({
            key = "notification-card",
            server = notification_server,
            notification = notification,
          }),
        })
        used = used + height + notifications.gap
      end
    end

    return windows
  end,
})
