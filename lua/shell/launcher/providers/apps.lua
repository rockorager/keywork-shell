-- XDG desktop applications provider. Desktop-file actions ([Desktop
-- Action ...] groups — "New Private Window" and friends) become the
-- entry's secondary actions.

local loop = require("keywork.loop")
local log = require("keywork.log")
local xdg = require("keywork.xdg.applications")

local M = {}

local function list_desktop_files(dir)
  local files = {}
  local pipe = io.popen(string.format("find -L '%s' -type f -name '*.desktop' 2>/dev/null", dir))
  if not pipe then
    return files
  end
  for line in pipe:lines() do
    table.insert(files, line)
  end
  pipe:close()
  return files
end

local function exec_basename(exec)
  local first = exec:match("^%S+") or ""
  return first:match("([^/]+)$") or first
end

-- Weighted lowercase haystacks for the fuzzy matcher; empty fields are
-- dropped so the matcher never scans them.
local function search_fields(app)
  local weighted = {
    { text = app.name, weight = 1.0 },
    { text = table.concat(app.keywords, " "), weight = 0.8 },
    { text = app.generic_name, weight = 0.7 },
    { text = exec_basename(app.exec), weight = 0.6 },
    { text = app.comment, weight = 0.4 },
  }
  local fields = {}
  for _, field in ipairs(weighted) do
    local text = (field.text or ""):lower()
    if text ~= "" then
      table.insert(fields, { text = text, weight = field.weight })
    end
  end
  return fields
end

-- Serial keeps transient unit names unique when the same app is launched
-- twice in the same second; the timestamp keeps them unique across shell
-- restarts (old units stay around as long as the app runs).
local launch_serial = 0

-- Wraps an app's argv in a transient systemd user unit so the app lives
-- outside keywork-shell.service's cgroup — otherwise restarting the shell
-- kills everything it ever launched. ExitType=cgroup keeps the unit alive
-- for apps whose first process forks and exits (browsers, electron).
local function systemd_wrap(argv, app)
  launch_serial = launch_serial + 1
  local slug = (app.id or "app"):gsub("%.desktop$", ""):gsub("[^%w%-]", "-")
  local unit = ("app-keywork-%s-%d-%d"):format(slug, os.time(), launch_serial)
  local wrapped = {
    "systemd-run",
    "--user",
    "--collect",
    "--slice=app.slice",
    "--property=ExitType=cgroup",
    "--unit=" .. unit,
    "--description=" .. (app.name or slug),
    "--",
  }
  for _, arg in ipairs(argv) do
    table.insert(wrapped, arg)
  end
  return wrapped
end

local function launch(app, action_id, ctx)
  loop.spawn(function()
    local proc, err = xdg.launch(app, {
      action = action_id,
      terminal_argv = { os.getenv("TERMINAL") or "xterm", "-e" },
      wrap = systemd_wrap,
    })
    if not proc then
      log.warn("launch failed", app.id, err or "unknown")
    elseif proc ~= true then
      -- Wait for systemd-run to start the unit before closing the
      -- launcher window; dismissing immediately could cancel the spawn
      -- mid-flight. (true means D-Bus activation already handled it.)
      proc:wait()
    end
    ctx.dismiss()
  end)
end

local function entry_actions(app)
  local actions = {
    {
      title = "Open",
      run = function(ctx)
        launch(app, nil, ctx)
      end,
    },
  }
  for _, action in ipairs(app.actions or {}) do
    table.insert(actions, {
      title = action.name,
      run = function(ctx)
        launch(app, action.id, ctx)
      end,
    })
  end
  return actions
end

function M.load()
  local entries = {}
  local claimed = {}
  for _, dir in ipairs(xdg.data_dirs()) do
    local base = dir .. "/applications"
    for _, path in ipairs(list_desktop_files(base)) do
      local id = path:sub(#base + 2):gsub("/", "-")
      -- First data dir wins, and a NoDisplay override still claims the id.
      if not claimed[id] then
        claimed[id] = true
        local app = xdg.parse(path, { id = id })
        if app and app.exec and not app.no_display and not app.hidden then
          table.insert(entries, {
            id = "app:" .. id,
            title = app.name,
            subtitle = app.generic_name or app.comment,
            icon = app.icon,
            search = search_fields(app),
            actions = entry_actions(app),
          })
        end
      end
    end
  end
  return entries
end

return M
