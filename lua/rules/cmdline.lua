---@module 'rules.cmdline'
---@brief Words of a `:Rules` write verb to values and `rules-ops/1` fields -- pure, no UI, no I/O.
---@description
--- The command line (`:Rules set DEP-06 severity=critical title=A new title`) and the Markdown form both end in
--- the same fields of an operation of `rules-ops/1`. What is shared lives here, so the two cannot read a place or a
--- patch in two ways:
---
---  - `split_assignments`: `key=value` words, a value may hold spaces (a word that is no known `key=` goes on with the
---    value before it)
---  - `patch`: the assignments of `:Rules set` as the `patch` of a `set` operation
---  - `place`, `place_text`: a place (`--to=<layout>#<section>`, `--after=<ID>`, `--before=<ID>`) as the fields of
---    an operation
---
--- Not its job: checking a value against the rules of a rule (that is the door's, `rules.ops`: its answer is what
--- the user sees), writing, windows.

local M = {}

---The keys `:Rules set` takes: the fields of a rule that a `set` operation can change.
M.SET_KEYS = { "severity", "title", "text", "check", "agent" }

---The keys `:Rules new` takes after the title.
M.NEW_KEYS = { "severity", "text", "ruleset" }

---@param tokens string[]
---@param known string[]  the accepted keys
---@param strict? boolean  true: a word that starts no known `key=` before the first one is an error
---@return string[]|nil lead  the words before the first known key (the title of `:Rules new`)
---@return table<string, string>|nil values  key -> text (trimmed, may be empty)
---@return string|nil err
function M.split_assignments(tokens, known, strict)
  local is_known = {}
  for _, key in ipairs(known) do
    is_known[key] = true
  end
  local lead = {}
  ---@type { key: string, words: string[] }[]
  local items = {}
  for _, token in ipairs(tokens) do
    local key, value = token:match("^([%a_][%w_]*)=(.*)$")
    if key and is_known[key] then
      items[#items + 1] = { key = key, words = { value } }
    elseif #items > 0 then
      local words = items[#items].words
      words[#words + 1] = token
    elseif strict and key then
      return nil, nil, ("unknown field '%s' (known: %s)"):format(key, table.concat(known, ", "))
    elseif strict then
      return nil, nil, ("expected key=value, got '%s'"):format(token)
    else
      lead[#lead + 1] = token
    end
  end
  local values = {}
  for _, item in ipairs(items) do
    if values[item.key] ~= nil then
      return nil, nil, ("'%s' given twice"):format(item.key)
    end
    values[item.key] = vim.trim(table.concat(item.words, " "))
  end
  return lead, values, nil
end

---The `patch` of a `set` operation from the assignments of `:Rules set`. `check` and `agent` are data: a JSON
---object sets them, nothing after the `=` removes them (`null` in the patch). The other keys are texts, as typed.
---@param values table<string, string>
---@return table|nil patch
---@return string|nil err
function M.patch(values)
  local patch, count = {}, 0
  for key, text in pairs(values) do
    count = count + 1
    if key == "check" or key == "agent" then
      if text == "" then
        patch[key] = vim.NIL
      else
        local ok, decoded = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
        if not ok or type(decoded) ~= "table" or vim.islist(decoded) then
          return nil, ("%s= takes a JSON object (or nothing, to remove it)"):format(key)
        end
        patch[key] = decoded
      end
    else
      patch[key] = text
    end
  end
  if count == 0 then
    return nil, "nothing to set (expected key=value ...)"
  end
  return patch, nil
end

---`<layout>#<section>` (the `output` path of a layout and a heading text) or `<layout>` alone (the top of it) as the
---fields of a place.
---@param text string
---@return table|nil place
---@return string|nil err
function M.to(text)
  local file, section = text:match("^([^#]*)#(.*)$")
  if not file then
    if text == "" then
      return nil, "the place is empty (expected <file>#<section>)"
    end
    return { layout = text, top = true }, nil
  end
  if file == "" then
    return nil, "the place has no file before '#' (expected <file>#<section>)"
  end
  if section == "" then
    return nil, "the place has no section after '#' (expected <file>#<section>)"
  end
  return { layout = file, section = section }, nil
end

---The place of a command line: from `--to=`, `--after=` or `--before=` (one of them), `--first` with a section.
---@param flags { to?: string, after?: string, before?: string, first?: boolean }
---@return table|nil place  `{}` when none was given
---@return string|nil err
function M.place(flags)
  local given = (flags.to and 1 or 0) + (flags.after and 1 or 0) + (flags.before and 1 or 0)
  if given > 1 then
    return nil, "give one place: --to, --after or --before"
  end
  if given == 0 then
    if flags.first then
      return nil, "--first goes with --to=<file>#<section>"
    end
    return {}, nil
  end
  if flags.to then
    local place, err = M.to(flags.to)
    if not place then
      return nil, err
    end
    if flags.first then
      if place.top then
        return nil, "--first needs a section: --to=<file>#<section>"
      end
      place.first = true
    end
    return place, nil
  end
  if flags.first then
    return nil, "--first goes with --to=<file>#<section>"
  end
  return { after = flags.after, before = flags.before }, nil
end

---The place a line of the form says: empty (none), `after <ID>`, `before <ID>`, or what `--to=` takes.
---@param text string
---@return table|nil place  `{}` when the line is empty
---@return string|nil err
function M.place_text(text)
  local trimmed = vim.trim(text)
  if trimmed == "" then
    return {}, nil
  end
  local word, id = trimmed:match("^(%a+)%s+(%S+)$")
  if word == "after" or word == "before" then
    return { [word] = id }, nil
  end
  -- anything else is a layout (its path may hold a space); the door says when there is none of that name
  return M.to(trimmed)
end

return M
