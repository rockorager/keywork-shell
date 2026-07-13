local kw = require("keywork")
local sb = require("keywork.storybook")
local audio = require("shell.audio")
local bar_colors = require("shell.bar.colors")
local bar_util = require("shell.bar.util")
local lock = require("shell.lock")
local network = require("shell.bar.network")
local sway = require("shell.bar.sway")
local notifications = require("shell.notifications")
local osd = require("shell.osd")

local function lock_story(id, name, options)
  options = options or {}
  return sb.story({
    id = id,
    group = "Lock screen",
    name = name,
    viewport = options.viewport or { width = 1280, height = 720 },
    color_scheme = options.color_scheme or "dark",
    render = function()
      return lock.View({
        key = id,
        username = options.username or "Tim Rock",
        status = options.status,
        time = "9:41",
        date = "Sunday, July 12",
        autofocus = false,
        on_submit = function(_) end,
      })
    end,
  })
end

local function menu_story(id, name, width, render)
  return sb.story({
    id = id,
    group = "Menus",
    name = name,
    viewport = { width = width, height = "content", scale = 2 },
    color_scheme = "dark",
    render = function(context)
      local theme = kw.theme_for(context)
      local palette = bar_colors.palette(theme)
      return kw.theme({
        data = palette.theme,
        child = render(palette),
      })
    end,
  })
end

local function audio_menu_story()
  return menu_story("menus/audio", "Audio devices", 420, function(palette)
    return audio.Menu({
      colors = palette,
      audio = {
        outputs = {
          {
            id = 1,
            name = "alsa_output.pci-0000_00_1f.3.analog-stereo",
            description = "Core Ultra 200V Series Processors HD Audio Speaker",
            nick = "Speaker",
            icon_name = "audio-card-analog",
            available = true,
            default = true,
            port_type = "speaker",
            bus = "pci",
          },
          {
            id = 2,
            name = "bluez_output.14_7A_E4_D0_1F_07.1",
            description = "Tim’s AirPods",
            icon_name = "audio-headphones",
            available = true,
            bus = "bluetooth",
          },
        },
        inputs = {
          {
            id = 3,
            name = "alsa_input.pci-0000_00_1f.3.analog-stereo",
            description = "Core Ultra 200V Series Processors HD Audio Microphone",
            nick = "Microphone",
            icon_name = "audio-card-analog",
            available = true,
            default = true,
            port_type = "mic",
            bus = "pci",
          },
        },
      },
    })
  end)
end

local function wifi_menu_story()
  return menu_story("menus/wifi", "Wi-Fi networks", 300, function(palette)
    return network.Menu({
      colors = palette,
      wifi = {
        networks = {
          { path = "/story/home", name = "Home", percent = 92, secured = true, known = true, connected = true },
          { path = "/story/cafe", name = "Coffee Shop", percent = 68 },
          { path = "/story/phone", name = "Phone Hotspot", percent = 44, secured = true },
          { path = "/story/neighbor", name = "Neighbor", percent = 18, secured = true, known = true },
        },
      },
    })
  end)
end

local function workspace_story()
  return sb.story({
    id = "bar/workspaces",
    group = "Bar",
    name = "Workspace switcher",
    viewport = { width = 220, height = 40, scale = 2 },
    color_scheme = "dark",
    render = function(context)
      local theme = kw.theme_for(context)
      local palette = bar_colors.palette(theme)
      return kw.theme({
        data = palette.theme,
        child = kw.sized({
          width = 220,
          height = 40,
          child = kw.container({
            background = palette.background,
            vertical_align = "center",
            padding = { x = theme.space[2], y = theme.space[1] },
            child = sway.Switcher({
              colors = palette,
              sway = {
                connected = true,
                workspaces = {
                  { name = "1" },
                  { name = "2", focused = true },
                  { name = "3" },
                  { name = "4", urgent = true },
                },
                switch = function(_) end,
              },
            }),
          }),
        }),
      })
    end,
  })
end

local function status_pills_story()
  return sb.story({
    id = "bar/status-pills",
    group = "Bar",
    name = "Status pills",
    viewport = { width = 180, height = 40, scale = 2 },
    color_scheme = "dark",
    render = function(context)
      local theme = kw.theme_for(context)
      local palette = bar_colors.palette(theme)
      return kw.theme({
        data = palette.theme,
        child = kw.sized({
          width = 180,
          height = 40,
          child = kw.container({
            background = palette.background,
            vertical_align = "center",
            padding = { x = theme.space[2], y = theme.space[1] },
            child = kw.row({
              spacing = theme.space[2],
              align = "center",
              children = {
                bar_util.status_pill("volume", "audio-volume-high", nil, palette.accent),
                bar_util.status_pill("network", "network-wireless-signal-good", nil, palette.accent),
                bar_util.status_pill("battery", "battery-level-80", "82%", palette.success),
              },
            }),
          }),
        }),
      })
    end,
  })
end

local function osd_story(id, name, model)
  return sb.story({
    id = id,
    group = "OSD",
    name = name,
    viewport = { width = osd.width, height = osd.height, scale = 2 },
    color_scheme = "dark",
    render = function()
      return osd.Level(model)
    end,
  })
end

local notification_server = {}

function notification_server:dismiss(_) end
function notification_server:invoke(_, _, _) end

local next_notification_id = 1
local function notification_story(id, name, notification)
  notification.id = next_notification_id
  notification.body = notification.body or ""
  notification.actions = notification.actions or {}
  notification.urgency = notification.urgency or 1
  next_notification_id = next_notification_id + 1
  return sb.story({
    id = id,
    group = "Notifications",
    name = name,
    viewport = {
      width = notifications.width,
      height = "content",
      scale = 2,
    },
    color_scheme = "dark",
    render = function()
      return notifications.Card({
        key = "notification",
        server = notification_server,
        notification = notification,
      })
    end,
  })
end

return sb.book({
  title = "keywork-shell",
  stories = {
    lock_story("lock/dark", "Dark"),
    lock_story("lock/light", "Light", { color_scheme = "light" }),
    lock_story("lock/authentication-failed", "Authentication failed", {
      status = "Authentication failed",
    }),
    lock_story("lock/empty-password", "Empty password", {
      status = "Enter your password",
    }),
    lock_story("lock/avatar-fallback", "Avatar fallback", {
      username = "Alex Morgan",
    }),
    lock_story("lock/compact-output", "Compact output", {
      viewport = { width = 640, height = 480 },
    }),
    audio_menu_story(),
    wifi_menu_story(),
    workspace_story(),
    status_pills_story(),
    osd_story("osd/volume", "Volume", {
      key = "volume",
      kind = "volume",
      value = 0.72,
    }),
    osd_story("osd/volume-low", "Volume low", {
      key = "volume-low",
      kind = "volume",
      value = 0.12,
    }),
    osd_story("osd/volume-muted", "Volume muted", {
      key = "volume-muted",
      kind = "volume",
      value = 0.72,
      muted = true,
    }),
    osd_story("osd/microphone-muted", "Microphone muted", {
      key = "microphone-muted",
      kind = "microphone",
      value = 0.88,
      muted = true,
    }),
    osd_story("osd/brightness", "Brightness", {
      key = "brightness",
      kind = "brightness",
      value = 0.75,
    }),
    notification_story("notifications/messages", "Messages", {
      app_name = "Messages",
      icon = "mail-message-new-symbolic",
      summary = "Sam",
      body = "Are we still on for dinner tonight?",
      actions = {
        { key = "default", label = "Open" },
      },
    }),
    notification_story("notifications/calendar-actions", "Calendar with actions", {
      app_name = "Calendar",
      icon = "x-office-calendar-symbolic",
      summary = "Design review",
      body = "Starts in 10 minutes",
      actions = {
        { key = "default", label = "Open" },
        { key = "snooze", label = "Snooze" },
        { key = "join", label = "Join" },
      },
    }),
    notification_story("notifications/slack", "Slack message", {
      app_name = "Slack",
      icon = "chat-message-new-symbolic",
      summary = "Alex Chen in #shell",
      body = "The deployment is green. I left a few notes on the notification changes for tomorrow.",
      actions = {
        { key = "default", label = "Open" },
      },
    }),
    notification_story("notifications/summary-only", "Summary only", {
      app_name = "Screenshot",
      icon = "camera-photo-symbolic",
      summary = "Screenshot saved",
    }),
    notification_story("notifications/critical", "Critical", {
      app_name = "System",
      icon = "dialog-warning-symbolic",
      summary = "Battery critically low",
      body = "Connect a charger now.",
      urgency = 2,
    }),
  },
})
