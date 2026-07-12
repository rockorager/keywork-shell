local kw = require("keywork")

local background = require("background")
local bar = require("shell.bar")
local idle = require("shell.idle")
local ipc = require("shell.ipc")
local launcher = require("shell.launcher")
local notifications = require("shell.notifications")
local osd = require("shell.osd")
local session = require("shell.session")

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

local osd_controller = osd.new(function()
  kw.app.invalidate()
end)

local session_controller = session.start()
local idle_controller = idle.start({
  lock = function()
    session_controller:lock()
  end,
})

-- Keybindings reach the running shell over the session bus:
--   bindsym $mod+Return exec keywork-shell launcher
local ipc_handle, ipc_err = ipc.serve({
  toggle_launcher = function()
    set_launcher_open(not shell.launcher_open)
  end,
  lock = function()
    session_controller:lock()
  end,
  adjust_audio = function(kind, action)
    return osd_controller:adjust_audio(kind, action)
  end,
  adjust_brightness = function(action)
    return osd_controller:adjust_brightness(action)
  end,
  configure_background = function(payload)
    local ok, err = background.configure(payload)
    if not ok then return false, err end
    kw.app.invalidate()
    return true
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
  stop = function()
    if idle_controller then
      idle_controller:stop()
    end
    session_controller:stop()
  end,
  windows = function(ctx)
    local windows = {}
    background.append_windows(windows, ctx.outputs)
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

    local level = osd_controller:visible()
    if level and ctx.outputs[1] then
      windows[#windows + 1] = kw.window({
        id = "osd",
        output = ctx.outputs[1].name,
        width = osd.width,
        height = osd.height,
        layer_shell = {
          layer = "overlay",
          anchor = { "bottom" },
          margin = { bottom = osd.margin },
        },
        child = osd.Level({
          key = "osd-level",
          kind = level.kind,
          value = level.value,
          muted = level.muted,
        }),
      })
    end

    if notification_server and ctx.outputs[1]
        and #notification_server:visible() > 0 then
      local output = ctx.outputs[1]
      -- A zero-zone layer surface is already placed inside the bar's
      -- exclusive zone; this margin is only the visual gap below it.
      windows[#windows + 1] = kw.window({
        id = "notifications",
        output = output.name,
        width = notifications.width,
        height = "content",
        layer_shell = {
          layer = "overlay",
          anchor = { "top", "right" },
          margin = {
            top = notifications.gap,
            right = notifications.margin,
          },
        },
        child = notifications.Stack({
          key = "notification-stack",
          server = notification_server,
        }),
      })
    end

    return windows
  end,
})
