---@meta

---@alias shell.wayland.EventState 'idled' | 'resumed'

---@class shell.wayland.Event
---@field id    number
---@field state shell.wayland.EventState

---@class shell.wayland.Client
local Client = {}

---@return integer?
function Client:fd() end

---@param timeout_ms integer
---@return number? id
---@return string? error
function Client:watch(timeout_ms) end

---@return shell.wayland.Event[]? events
---@return string? error
function Client:dispatch() end

function Client:close() end

local M = {}

---@return shell.wayland.Client? client
---@return string? error
function M.connect() end

return M
