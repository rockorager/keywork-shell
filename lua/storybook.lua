local kw = require("keywork")
local sb = require("keywork.storybook")
local audio = require("shell.audio")
local bar_colors = require("shell.bar.colors")
local network = require("shell.bar.network")
local notifications = require("shell.notifications")
local osd = require("shell.osd")

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
            description = "Built-in Audio Analog Stereo",
            icon_name = "audio-card",
            available = true,
            default = true,
          },
          {
            id = 2,
            name = "alsa_output.pci-0000_01_00.1.hdmi-stereo",
            description = "HDMI / DisplayPort",
            icon_name = "video-display",
            available = true,
          },
        },
        inputs = {
          {
            id = 3,
            name = "alsa_input.pci-0000_00_1f.3.analog-stereo",
            description = "Built-in Audio Microphone",
            icon_name = "audio-input-microphone",
            available = true,
            default = true,
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
    audio_menu_story(),
    wifi_menu_story(),
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
