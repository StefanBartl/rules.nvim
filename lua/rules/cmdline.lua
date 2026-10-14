---@module 'rules.cmdline'
---@brief Words of a `:Rules` write verb to values and `rules-ops/1` fields -- pure, no UI, no I/O.
---@description
--- The command line (`:Rules set DEP-06 severity=critical title=A new title`) and the Markdown form both end in
--- the same fields of an operation of `rules-ops/1`. What is shared lives here, so the two cannot read a place or a
--- patch in two ways:
---
---  - `words`, `join`: the words of the argument string as typed (no backslash dropped, no run of blanks made one),
---    and words put together again with the blanks between them
---  - `split_assignments`: `key=value` words, a value may hold spaces (a word that is no known `key=` goes on with the
---    value before it)
---  - `bind`: the same with the one positional argument (the family, the id) found first, wherever it stands: a `key=`
---    word before it takes one word
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

---A word of the command line: the text as typed, and the blanks typed before it. A value that goes over several words
---is put together again from these, so a run of blanks or a backslash in it comes out as typed.
---@class Rules.Word
---@field text string  as typed: a backslash before a blank or a backslash is still there
---@field sep string   the blanks before the word

---The words of the argument string of a user command (`opts.args`), cut where Neovim cuts `<f-args>`: blanks separate
---words, a backslash before a blank or before a backslash keeps it in the word. Unlike `fargs` the words are not
---changed: no backslash is dropped, no run of blanks is made one.
---@param args string
---@return Rules.Word[]
function M.words(args)
  local out, i, n = {}, 1, #args
  while i <= n do
    local start = i
    while i <= n and args:sub(i, i):match("[ \t]") do
      i = i + 1
    end
    if i > n then
      break
    end
    local sep = args:sub(start, i - 1)
    local from = i
    while i <= n do
      local ch = args:sub(i, i)
      if ch == "\\" and i < n and args:sub(i + 1, i + 1):match("[\\ \t]") then
        i = i + 2
      elseif ch:match("[ \t]") then
        break
      else
        i = i + 1
      end
    end
    out[#out + 1] = { text = args:sub(from, i - 1), sep = sep }
  end
  return out
end

---What Neovim makes of a word of `opts.args` when it fills `fargs`: `\ ` is a blank, `\\` one backslash.
---@param text string
---@return string
function M.unescape(text)
  return (text:gsub("\\([\\ \t])", "%1"))
end

---@param token string|Rules.Word
---@return string
local function text_of(token)
  return type(token) == "table" and token.text or token
end

---@param token string|Rules.Word
---@return string
local function sep_of(token)
  return type(token) == "table" and token.sep or " "
end

---Words as one text, the blanks between them as typed (those before the first word are dropped).
---@param words (string|Rules.Word)[]
---@return string
function M.join(words)
  local out = {}
  for i, token in ipairs(words) do
    out[#out + 1] = (i > 1 and sep_of(token) or "") .. text_of(token)
  end
  return table.concat(out)
end

---@param known string[]
---@return table<string, true>
local function set_of(known)
  local out = {}
  for _, key in ipairs(known) do
    out[key] = true
  end
  return out
end

---The words that follow each other from a `key=` word: a word that is no known `key=` goes on with the value of the
---key before it.
---@param tokens (string|Rules.Word)[]
---@param known string[]
---@param strict boolean|nil
---@param items { key: string, text: string }[]  the assignments so far; added to
---@param lead (string|Rules.Word)[]  the words before the first key; added to (not in strict mode)
---@return string|nil err
local function collect(tokens, known, strict, items, lead)
  local is_known = set_of(known)
  local current
  for _, token in ipairs(tokens) do
    local text = text_of(token)
    local key, value = text:match("^([%a_][%w_]*)=(.*)$")
    if key and is_known[key] then
      current = { key = key, text = value }
      items[#items + 1] = current
    elseif current then
      current.text = current.text .. sep_of(token) .. text
    elseif strict and key then
      return ("unknown field '%s' (known: %s)"):format(key, table.concat(known, ", "))
    elseif strict then
      return ("expected key=value, got '%s'"):format(text)
    else
      lead[#lead + 1] = token
    end
  end
  return nil
end

---@param items { key: string, text: string }[]
---@return table<string, string>|nil values
---@return string|nil err
local function values_of(items)
  local values = {}
  for _, item in ipairs(items) do
    if values[item.key] ~= nil then
      return nil, ("'%s' given twice"):format(item.key)
    end
    values[item.key] = vim.trim(item.text)
  end
  return values, nil
end

---@param tokens (string|Rules.Word)[]
---@param known string[]  the accepted keys
---@param strict? boolean  true: a word that starts no known `key=` before the first one is an error
---@return string[]|nil lead  the words before the first known key (the title of `:Rules new`)
---@return table<string, string>|nil values  key -> text (trimmed, may be empty)
---@return string|nil err
function M.split_assignments(tokens, known, strict)
  local items, lead = {}, {}
  local err = collect(tokens, known, strict, items, lead)
  if err then
    return nil, nil, err
  end
  local values, verr = values_of(items)
  if not values then
    return nil, nil, verr
  end
  return vim.tbl_map(text_of, lead), values, nil
end

---Bind the words of a command line to the one positional argument (the family of `new`, the id of `set`), the
---assignments and the words left over, the way the grammar of the composer binds them: the positional argument is the
---first word that is not a known `key=` word, wherever it stands. A `key=` word before it takes that one word as its
---value; the words after it are read as `split_assignments` reads them (the lead is the title of `:Rules new`).
---@param words (string|Rules.Word)[]  the words that are no flag
---@param known string[]  the accepted keys
---@param strict? boolean  true: a word after the positional argument that starts no known `key=` is an error
---@return { positional: string|nil, lead: (string|Rules.Word)[], values: table<string, string> }|nil bound
---@return string|nil err
function M.bind(words, known, strict)
  local is_known = set_of(known)
  local at
  for i, token in ipairs(words) do
    local key = text_of(token):match("^([%a_][%w_]*)=")
    if not (key and is_known[key]) then
      at = i
      break
    end
  end
  local items, lead = {}, {}
  for i = 1, (at or #words + 1) - 1 do
    local key, value = text_of(words[i]):match("^([%a_][%w_]*)=(.*)$")
    items[#items + 1] = { key = key, text = value }
  end
  local after = at and vim.list_slice(words, at + 1, #words) or {}
  local err = collect(after, known, strict, items, lead)
  if err then
    return nil, err
  end
  local values, verr = values_of(items)
  if not values then
    return nil, verr
  end
  return { positional = at and text_of(words[at]) or nil, lead = lead, values = values }, nil
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
