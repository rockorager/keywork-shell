local kw = require("keywork")

local bar = require("shell.bar")
local ipc = require("shell.ipc")
local launcher = require("shell.launcher")

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

    return windows
  end,
})
