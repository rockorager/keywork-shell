local M = {}

local function is_boundary(text, index)
  if index <= 1 then
    return true
  end
  local prev = text:sub(index - 1, index - 1)
  return prev == " " or prev == "-" or prev == "_" or prev == "." or prev == "/"
end

-- Score needle against haystack (both lowercase). Higher is better;
-- nil means no match. Substring hits beat subsequence hits, earlier
-- and word-boundary hits beat later mid-word ones.
function M.fuzzy(needle, hay)
  if needle == "" then
    return 0
  end
  if hay == "" then
    return nil
  end

  local start = hay:find(needle, 1, true)
  if start then
    local score = 100 - (start - 1) * 2 - (#hay - #needle) * 0.2
    if start == 1 then
      score = score + 40
    elseif is_boundary(hay, start) then
      score = score + 20
    end
    return score
  end

  local score = 0
  local last = 0
  for i = 1, #needle do
    local found = hay:find(needle:sub(i, i), last + 1, true)
    if not found then
      return nil
    end
    if found == last + 1 and last > 0 then
      score = score + 4
    elseif is_boundary(hay, found) then
      score = score + 6
    else
      score = score + 1
    end
    last = found
  end
  return score - #hay * 0.2
end

local field_weights = {
  { field = "name", weight = 1.0 },
  { field = "keywords", weight = 0.8 },
  { field = "generic", weight = 0.7 },
  { field = "exec", weight = 0.6 },
  { field = "comment", weight = 0.4 },
}

-- Best weighted score across an entry's searchable fields, or nil.
function M.score(query, entry)
  if query == "" then
    return 0
  end
  local best = nil
  for _, spec in ipairs(field_weights) do
    local score = M.fuzzy(query, entry.search[spec.field])
    if score then
      score = score * spec.weight
      if best == nil or score > best then
        best = score
      end
    end
  end
  return best
end

return M
