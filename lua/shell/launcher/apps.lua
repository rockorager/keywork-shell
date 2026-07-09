local M = {}

local function trim(value)
  local trimmed = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return trimmed
end

local function data_dirs()
  local home = os.getenv("HOME") or ""
  local dirs = {}
  local seen = {}
  local function add(dir)
    dir = trim(dir)
    if dir ~= "" and not seen[dir] then
      seen[dir] = true
      table.insert(dirs, dir)
    end
  end

  local data_home = os.getenv("XDG_DATA_HOME")
  if data_home == nil or data_home == "" then
    data_home = home .. "/.local/share"
  end
  add(data_home)

  local data_paths = os.getenv("XDG_DATA_DIRS")
  if data_paths == nil or data_paths == "" then
    data_paths = "/usr/local/share:/usr/share"
  end
  for dir in data_paths:gmatch("[^:]+") do
    add(dir)
  end
  return dirs
end

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

local function parse_desktop_file(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local fields = {}
  local in_entry = false
  for line in file:lines() do
    local section = line:match("^%[(.-)%]%s*$")
    if section then
      in_entry = section == "Desktop Entry"
    elseif in_entry then
      -- Bare keys only; localized keys like Name[de] are skipped.
      local key, value = line:match("^([%w%-]+)%s*=%s*(.-)%s*$")
      if key then
        fields[key] = value
      end
    end
  end
  file:close()
  return fields
end

-- Strip XDG Exec field codes (%f, %U, ...); %% unescapes to %.
local function clean_exec(exec)
  local cleaned = exec:gsub("%%[fFuUdDnNickvm]", "")
  cleaned = cleaned:gsub("%%%%", "%%")
  return trim(cleaned)
end

local function exec_basename(exec)
  local first = exec:match("^%S+") or ""
  return first:match("([^/]+)$") or first
end

local function entry_from_fields(id, fields)
  if (fields.Type or "Application") ~= "Application" then
    return nil
  end
  if fields.NoDisplay == "true" or fields.Hidden == "true" then
    return nil
  end
  if not fields.Name or not fields.Exec or fields.Exec == "" then
    return nil
  end

  local exec = clean_exec(fields.Exec)
  local entry = {
    id = id,
    name = fields.Name,
    generic = fields.GenericName,
    comment = fields.Comment,
    icon = fields.Icon,
    exec = exec,
    terminal = fields.Terminal == "true",
  }
  entry.search = {
    name = entry.name:lower(),
    generic = (entry.generic or ""):lower(),
    comment = (entry.comment or ""):lower(),
    keywords = (fields.Keywords or ""):lower():gsub(";", " "),
    exec = exec_basename(exec):lower(),
  }
  return entry
end

function M.load()
  local entries = {}
  local claimed = {}
  for _, dir in ipairs(data_dirs()) do
    local base = dir .. "/applications"
    for _, path in ipairs(list_desktop_files(base)) do
      local id = path:sub(#base + 2):gsub("/", "-")
      -- First data dir wins, and a NoDisplay override still claims the id.
      if not claimed[id] then
        claimed[id] = true
        local fields = parse_desktop_file(path)
        if fields then
          local entry = entry_from_fields(id, fields)
          if entry then
            table.insert(entries, entry)
          end
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
