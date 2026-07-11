local M = {}

local function state_dir()
  local dir = os.getenv("XDG_STATE_HOME")
  if dir == nil or dir == "" then
    dir = (os.getenv("HOME") or "") .. "/.local/state"
  end
  return dir .. "/keywork-shell"
end

local function history_path()
  return state_dir() .. "/history"
end

-- Activation counts by entry id: { ["app:firefox.desktop"] = 12, ... }
function M.load()
  local counts = {}
  local file = io.open(history_path(), "r")
  if not file then
    return counts
  end
  for line in file:lines() do
    local count, id = line:match("^(%d+)%s+(.+)$")
    if count then
      -- Pre-provider rows were bare desktop ids; adopt them into the
      -- apps namespace.
      if not id:find(":", 1, true) then
        id = "app:" .. id
      end
      counts[id] = tonumber(count)
    end
  end
  file:close()
  return counts
end

function M.bump(counts, id)
  counts[id] = (counts[id] or 0) + 1
  os.execute(string.format("mkdir -p '%s'", state_dir()))
  local file = io.open(history_path(), "w")
  if not file then
    return
  end
  for entry_id, count in pairs(counts) do
    file:write(string.format("%d %s\n", count, entry_id))
  end
  file:close()
end

return M
