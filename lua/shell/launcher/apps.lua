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

-- Precomputed lowercase fields for the fuzzy matcher.
local function search_index(entry)
  return {
    name = entry.name:lower(),
    generic = (entry.generic_name or ""):lower(),
    comment = (entry.comment or ""):lower(),
    keywords = table.concat(entry.keywords, " "):lower(),
    exec = exec_basename(entry.exec):lower(),
  }
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
        local entry = xdg.parse(path, { id = id })
        if entry and entry.exec and not entry.no_display and not entry.hidden then
          entry.search = search_index(entry)
          table.insert(entries, entry)
        end
      end
    end
  end
  table.sort(entries, function(a, b)
    return a.search.name < b.search.name
  end)
  return entries
end

return M
