local kw = require("keywork")
local loop = require("keywork.loop")
local log = require("keywork.log")
local xdg = require("keywork.xdg.applications")

local apps = require("shell.launcher.apps")
local match = require("shell.launcher.match")
local history = require("shell.launcher.history")

local M = {}

local visible_rows = 8
local row_height = 44
local max_results = 64

M.width = 640
M.height = 470

local function rank(entries, counts, query)
  local needle = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
  local scored = {}
  for _, entry in ipairs(entries) do
    local score = match.score(needle, entry)
    if score then
      -- Frecency: dominates the empty-query ordering, nudges searches.
      local boost = math.min(counts[entry.id] or 0, 20)
      score = score + boost * (needle == "" and 10 or 2)
      table.insert(scored, { entry = entry, score = score })
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.entry.search.name < b.entry.search.name
  end)
  local results = {}
  for index = 1, math.min(#scored, max_results) do
    results[index] = scored[index].entry
  end
  return results
end

local function entry_icon(entry, size)
  local name = entry.icon or ""
  if name == "" then
    name = "application-x-executable"
  end
  if name:sub(1, 1) == "/" then
    if name:match("%.svg$") then
      return kw.svg_icon({ path = name, size = size })
    end
    name = name:match("([^/]+)%.%w+$") or "application-x-executable"
  end
  name = name:gsub("%.png$", ""):gsub("%.svg$", ""):gsub("%.xpm$", "")
  return kw.icon({ name = name, size = size })
end

local function dismiss(self)
  if self.props.on_dismiss then
    self.props.on_dismiss()
  end
end

-- Serial keeps transient unit names unique when the same app is launched
-- twice in the same second; the timestamp keeps them unique across shell
-- restarts (old units stay around as long as the app runs).
local launch_serial = 0

-- Wraps an app's argv in a transient systemd user unit so the app lives
-- outside keywork-shell.service's cgroup — otherwise restarting the shell
-- kills everything it ever launched. ExitType=cgroup keeps the unit alive
-- for apps whose first process forks and exits (browsers, electron).
local function systemd_wrap(argv, entry)
  launch_serial = launch_serial + 1
  local slug = (entry.id or "app"):gsub("%.desktop$", ""):gsub("[^%w%-]", "-")
  local unit = ("app-keywork-%s-%d-%d"):format(slug, os.time(), launch_serial)
  local wrapped = {
    "systemd-run",
    "--user",
    "--collect",
    "--slice=app.slice",
    "--property=ExitType=cgroup",
    "--unit=" .. unit,
    "--description=" .. (entry.name or slug),
    "--",
  }
  for _, arg in ipairs(argv) do
    table.insert(wrapped, arg)
  end
  return wrapped
end

local function launch(self, entry)
  if not entry then
    return
  end
  history.bump(self.counts, entry.id)
  loop.spawn(function()
    local proc, err = xdg.launch(entry, {
      terminal_argv = { os.getenv("TERMINAL") or "xterm", "-e" },
      wrap = systemd_wrap,
    })
    if not proc then
      log.warn("launch failed", entry.id, err or "unknown")
    elseif proc ~= true then
      -- Wait for systemd-run to start the unit before closing the
      -- launcher window; dismissing immediately could cancel the spawn
      -- mid-flight. (true means D-Bus activation already handled it.)
      proc:wait()
    end
    dismiss(self)
  end)
end

local function set_query(self, text)
  self.query = text
  self.results = rank(self.entries, self.counts, text)
  self.selected = 1
  self.top = 1
  self:set_state()
end

local function move_selection(self, delta)
  local count = #self.results
  if count == 0 then
    return
  end
  self.selected = math.max(1, math.min(count, self.selected + delta))
  if self.selected < self.top then
    self.top = self.selected
  elseif self.selected > self.top + visible_rows - 1 then
    self.top = self.selected - visible_rows + 1
  end
  self:set_state()
end

local function search_field(self, theme)
  return kw.container({ padding = { x = theme.space[4], y = theme.space[2] } },
    kw.row({
      spacing = theme.space[2],
      align = "center",
      children = {
        kw.icon({ name = "system-search", size = 18, color = theme.colors.text_tertiary }),
        kw.expanded(kw.text_input({
          id = "query",
          placeholder = "Search apps…",
          autofocus = true,
          on_change = function(text)
            set_query(self, text)
          end,
        })),
      },
    })
  )
end

local function divider(theme)
  return kw.container({ background = theme.colors.border, min_height = 1 },
    kw.sized({ height = 1 }, kw.text("")))
end

local function result_row(self, index, entry, theme)
  local selected = index == self.selected
  local subtitle = entry.generic_name or entry.comment or ""
  return kw.gesture({
    id = "result-" .. entry.id,
    hover_background = not selected and theme.colors.fill_secondary or nil,
    on_tap = function()
      launch(self, entry)
    end,
    child = kw.container({
      background = selected and theme.colors.fill or nil,
      radius = theme.radius[4],
      min_height = row_height,
      vertical_align = "center",
      padding = { x = theme.space[3] },
    }, kw.row({
      spacing = theme.space[3],
      align = "center",
      children = {
        entry_icon(entry, 24),
        kw.text(entry.name),
        kw.spacer(),
        kw.label(subtitle, { color = theme.colors.text_tertiary }),
      },
    })),
  })
end

local function result_list(self, theme)
  local rows = {}
  local last = math.min(#self.results, self.top + visible_rows - 1)
  for index = self.top, last do
    table.insert(rows, result_row(self, index, self.results[index], theme))
  end
  if #rows == 0 then
    table.insert(rows, kw.container({ min_height = row_height, align = "center" },
      kw.label("No matches", { color = theme.colors.text_tertiary })))
  end
  return kw.column({ align = "stretch", children = rows })
end

local function footer(self, theme)
  local hint_color = theme.colors.text_tertiary
  -- One step below the label role (font_size[2]).
  local hint_size = theme.font_size[1]
  local function hint(keys, text)
    return kw.row({
      spacing = theme.space[1],
      align = "center",
      children = {
        kw.label(keys, { color = theme.colors.text_secondary, size = hint_size }),
        kw.label(text, { color = hint_color, size = hint_size }),
      },
    })
  end
  local count = #self.results
  return kw.container({ padding = { x = theme.space[4], y = theme.space[2] } },
    kw.row({
      spacing = theme.space[4],
      align = "center",
      children = {
        kw.label(count == 1 and "1 result" or count .. " results", { color = hint_color, size = hint_size }),
        kw.spacer(),
        hint("↑↓", "select"),
        hint("↵", "open"),
        hint("esc", "close"),
      },
    })
  )
end

-- Launcher view hosted inside the shell's launcher window. The window's
-- existence is app state; props.on_dismiss asks the shell to drop it.
local Launcher = kw.stateful({
  init = function(self)
    self.entries = apps.load()
    self.counts = history.load()
    self.query = ""
    self.selected = 1
    self.top = 1
    self.results = rank(self.entries, self.counts, "")
  end,

  build = function(self, context)
    local theme = kw.resolve_theme(kw.theme_data({
      components = {
        input = {
          -- The search field is chromeless: the surrounding container
          -- provides the visual frame, so the input keeps only its
          -- vertical rhythm (space-2).
          background = 0x00000000,
          border = 0x00000000,
          focused_border = 0x00000000,
          padding_x = 0,
          padding_y = 8,
        },
      },
    }), context)

    local content = kw.column({
      align = "stretch",
      children = {
        search_field(self, theme),
        divider(theme),
        -- 6px inset from keywork-launcher's design; the space scale
        -- (4, 8, 12, ...) has no matching step.
        kw.container({ padding = { x = 6, y = 6 } }, result_list(self, theme)),
        kw.spacer(),
        divider(theme),
        footer(self, theme),
      },
    })

    return kw.theme({
      data = theme,
      child = kw.actions({
        bindings = {
          launch = function()
            launch(self, self.results[self.selected])
          end,
          next = function()
            move_selection(self, 1)
          end,
          previous = function()
            move_selection(self, -1)
          end,
          dismiss = function()
            dismiss(self)
          end,
        },
        child = kw.shortcuts({
          bindings = {
            enter = "launch",
            down = "next",
            up = "previous",
            escape = "dismiss",
          },
          child = kw.box({
            background = theme.colors.surface,
            border = theme.colors.border,
            border_width = 1,
            radius = theme.radius[5],
          }, content),
        }),
      }),
    })
  end,
})

M.Launcher = Launcher

return M
