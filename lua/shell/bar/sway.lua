local kw = require("keywork")
local json = require("keywork.json")
local loop = require("keywork.loop")
local bit = require("bit")
local util = require("shell.bar.util")

local label = util.label

local IPC_COMMAND = 0
local IPC_GET_WORKSPACES = 1
local IPC_SUBSCRIBE = 2

local function le32(value)
  return string.char(
    bit.band(value, 0xff),
    bit.band(bit.rshift(value, 8), 0xff),
    bit.band(bit.rshift(value, 16), 0xff),
    bit.band(bit.rshift(value, 24), 0xff)
  )
end

local function read_le32(value, offset)
  local b1, b2, b3, b4 = value:byte(offset, offset + 3)
  if not b4 then
    return nil
  end
  return b1 + bit.lshift(b2, 8) + bit.lshift(b3, 16) + bit.lshift(b4, 24)
end

local function sway_send(client, message_type, payload)
  payload = payload or ""
  local ok = client.socket:write("i3-ipc" .. le32(#payload) .. le32(message_type) .. payload)
  if not ok then
    client.connected = false
  end
  return ok
end

local function parse_workspaces(payload)
  local workspaces = {}
  local decoded = json.decode(payload)
  for _, object in ipairs(decoded or {}) do
    if object.name then
      table.insert(workspaces, {
        name = object.name,
        focused = object.focused == true,
        urgent = object.urgent == true,
      })
    end
  end
  return workspaces
end

local function handle_sway_frame(client, message_type, payload)
  if message_type == IPC_GET_WORKSPACES then
    client.workspaces = parse_workspaces(payload)
    return true
  end

  if bit.band(message_type, 0x80000000) ~= 0 then
    sway_send(client, IPC_GET_WORKSPACES, "")
  end
  return false
end

local function drain_sway(client)
  local changed = false
  while #client.buffer >= 14 do
    if client.buffer:sub(1, 6) ~= "i3-ipc" then
      client.connected = false
      return changed
    end
    local length = read_le32(client.buffer, 7)
    local message_type = read_le32(client.buffer, 11)
    if not length or not message_type or #client.buffer < 14 + length then
      break
    end
    local payload = client.buffer:sub(15, 14 + length)
    client.buffer = client.buffer:sub(15 + length)
    changed = handle_sway_frame(client, message_type, payload) or changed
  end
  return changed
end

local function connect_sway(on_change)
  local path = os.getenv("SWAYSOCK")
  if not path or path == "" then
    return nil
  end

  local socket = loop.connect(path)
  if not socket then
    return nil
  end

  local client = {
    socket = socket,
    buffer = "",
    workspaces = {},
    connected = true,
  }

  loop.spawn(function()
    for chunk in socket:chunks() do
      client.buffer = client.buffer .. chunk
      if drain_sway(client) then
        on_change()
      end
    end
    client.connected = false
    on_change()
  end)
  sway_send(client, IPC_GET_WORKSPACES, "")
  sway_send(client, IPC_SUBSCRIBE, '["workspace"]')
  return client
end

local function workspaces(palette, sway)
  local items = {}
  for _, workspace in ipairs(sway.workspaces or {}) do
    local name = workspace.name
    local selected = workspace.urgent or workspace.focused
    table.insert(items, kw.chip({
      id = "workspace-" .. name,
      theme = palette.chip_theme,
      label = name,
      selected = selected,
      align = "center",
      padding = { x = palette.space[3] },
      on_tap_down = function()
        if sway.connected then
          sway_send(sway, IPC_COMMAND, "workspace " .. json.encode(name))
        end
      end,
    }))
  end

  if #items == 0 then
    table.insert(items, label(sway.connected and "loading sway" or "no sway", palette, palette.muted))
  end
  return kw.row({ spacing = palette.space[1], children = items })
end

local SwayWorkspaces = kw.stateful({
  init = function(self)
    self.sway = connect_sway(function()
      self:set_state()
    end) or { buffer = "", workspaces = {}, connected = false }
  end,

  dispose = function(self)
    if self.sway.socket then
      self.sway.socket:close()
    end
  end,

  build = function(self)
    return workspaces(self.props.colors, self.sway)
  end,
})

return {
  Workspaces = SwayWorkspaces,
}
