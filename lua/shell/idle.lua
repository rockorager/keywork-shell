local log = require("keywork.log")
local loop = require("keywork.loop")
local process = require("keywork.process")
local wayland = require("shell.wayland")

local M = {}

local DIM_AFTER_MS = 60 * 1000
local LOCK_AFTER_MS = 5 * 60 * 1000
local POWER_OFF_AFTER_MS = 10 * 60 * 1000

local DIM_COMMAND = [[
current=$(brightnessctl get)
max=$(brightnessctl max)
threshold=$((max * 30 / 100))
target=$current
if [ "$current" -gt "$threshold" ]; then target=$threshold; fi
brightnessctl -s set "$target"
brightnessctl --device="tpacpi::kbd_backlight" set 0
]]

local RESTORE_COMMAND = [[
brightnessctl -r
brightnessctl --device="tpacpi::kbd_backlight" set 100%
]]

local function run(argv, description)
    loop.spawn(function()
        local result, err = process.capture(argv)
        if not result then
            log.warn(description .. " failed", err or "unknown")
        elseif not result.ok then
            log.warn(description .. " failed", result.stderr or "unknown")
        end
    end)
end

local Controller = {}
Controller.__index = Controller

function Controller:handle(event)
    local action = self.actions[event.id]
    if not action then
        return
    end

    if action == "dim" then
        if event.state == "idled" then
            self.dimmed = true
            run({ "sh", "-c", DIM_COMMAND }, "idle dim")
        elseif self.dimmed then
            self.dimmed = false
            run({ "sh", "-c", RESTORE_COMMAND }, "idle brightness restore")
        end
    elseif action == "lock" and event.state == "idled" then
        self.lock()
    elseif action == "power" then
        if event.state == "idled" then
            self.outputs_off = true
            run({ "swaymsg", "output * power off" }, "idle output power off")
        elseif self.outputs_off then
            self.outputs_off = false
            run({ "swaymsg", "output * power on" }, "idle output power on")
        end
    end
end

function Controller:stop()
    if self.stopped then
        return
    end
    self.stopped = true
    self.fd_watch:cancel()
    self.client:close()
end

function M.start(options)
    assert(options and type(options.lock) == "function", "idle.start requires a lock handler")

    local client, connect_err = wayland.connect()
    if not client then
        log.warn("idle manager disabled", connect_err or "Wayland unavailable")
        return nil
    end

    local dim_id, dim_err = client:watch(DIM_AFTER_MS)
    local lock_id, lock_err = client:watch(LOCK_AFTER_MS)
    local power_id, power_err = client:watch(POWER_OFF_AFTER_MS)
    if not dim_id or not lock_id or not power_id then
        client:close()
        log.warn("idle manager disabled", dim_err or lock_err or power_err or "could not create idle notification")
        return nil
    end

    local controller = setmetatable({
        client = client,
        lock = options.lock,
        actions = {
            [dim_id] = "dim",
            [lock_id] = "lock",
            [power_id] = "power",
        },
        dimmed = false,
        outputs_off = false,
        stopped = false,
    }, Controller)

    controller.fd_watch = loop.fd(client:fd(), { read = true })
    loop.spawn(function()
        for event in controller.fd_watch:events() do
            if event.err or event.hup then
                log.warn("idle manager disconnected from Wayland")
                controller:stop()
                return
            end
            if event.read then
                local events, dispatch_err = client:dispatch()
                if not events then
                    log.warn("idle manager dispatch failed", dispatch_err or "unknown")
                    controller:stop()
                    return
                end
                for _, idle_event in ipairs(events) do
                    controller:handle(idle_event)
                end
            end
        end
    end)

    log.info("idle manager enabled")
    return controller
end

return M
