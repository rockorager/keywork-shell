local kw = require("keywork")
local json = require("keywork.json")
local loop = require("keywork.loop")
local service = require("keywork.service")
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

-- The published snapshot carries the switch command as a closure over the
-- service's client, so widgets can act without owning the socket.
local function snapshot(client)
  return {
    workspaces = client.workspaces,
    connected = client.connected,
    switch = function(name)
      if client.connected then
        sway_send(client, IPC_COMMAND, "workspace " .. json.encode(name))
      end
    end,
  }
end

local sway_service = service.define("shell.bar.sway", function(self)
  local path = os.getenv("SWAYSOCK")
  local socket = path and path ~= "" and loop.connect(path) or nil
  if not socket then
    self:publish({ workspaces = {}, connected = false })
    return
  end

  local client = {
    socket = socket,
    buffer = "",
    workspaces = {},
    connected = true,
  }

  sway_send(client, IPC_GET_WORKSPACES, "")
  sway_send(client, IPC_SUBSCRIBE, '["workspace"]')
  self:publish(snapshot(client))

  for chunk in socket:chunks() do
    client.buffer = client.buffer .. chunk
    if drain_sway(client) then
      self:publish(snapshot(client))
    end
  end
  client.connected = false
  self:publish(snapshot(client))
end)

local function WorkspaceSwitcher(props)
  local palette = props.colors
  local sway = props.sway
  local items = {}
  for _, workspace in ipairs(sway.workspaces or {}) do
    local name = workspace.name
    local selected = workspace.urgent or workspace.focused
    table.insert(items, kw.chip({
      id = "workspace-" .. name,
      label = name,
      selected = selected,
      align = "center",
      on_tap_down = function()
        if sway.switch then
          sway.switch(name)
        end
      end,
    }))
  end

  if #items == 0 then
    table.insert(items, label(sway.connected and "loading sway" or "no sway", palette.muted))
  end
  return kw.row({ spacing = palette.space[1], children = items })
end

local SwayWorkspaces = kw.stateful({
  init = function(self)
    self.sway = sway_service:use(self.scope, function(snap)
      self.sway = snap
      self:set_state()
    end) or { workspaces = {}, connected = true }
  end,

  build = function(self)
    return WorkspaceSwitcher({ colors = self.props.colors, sway = self.sway })
  end,
})

return {
  Switcher = WorkspaceSwitcher,
  Workspaces = SwayWorkspaces,
}
