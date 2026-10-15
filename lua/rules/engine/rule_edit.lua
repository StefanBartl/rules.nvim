---@module 'rules.engine.rule_edit'
---@brief Text edits of one rule file: what a writer changes, and nothing else.
---@description
--- A rule file is a frontmatter (`id`, `severity`, `family`), a heading, an optional ` ```rule ` block that holds
--- `check` and `agent`, and the prose. `apply` changes the named parts of such a text by editing LINES, so everything
--- it was not asked to change (other prose, line endings, the final newline, the identity lines) stays byte for byte.
--- The boundaries are the reader's own (`parser.text_range`, the block and heading the splitter found).
---
--- What can be patched: `severity` (frontmatter, and the block's own `severity` when it repeats it), `title` (the
--- heading), `text` (the prose), `check` and `agent` (the block; `vim.NIL` removes a key). A `check` or `agent` patch
--- writes the block again from its evaluated table, so a block with a Lua function or a comment is refused for it: it
--- stays a thing to edit by hand. A `severity` or `text` patch never writes the block again: the block's own
--- `severity` literal is changed in place, comments and functions stay.
---
--- The result is read back with the loader's own parser and compared with what was asked for; a text that would
--- not read as the patch says (a prose with a heading in it, an invalid `agent`) is refused, never written.
---
--- Not its job: files, locks, etags (`rules.ops`).

local parser = require("rules.engine.parser")
local sandbox = require("rules.util.sandbox")

local M = {}

M.SEVERITIES = { "critical", "recommended", "nice-to-have" }

-- ── a Lua value as the text of a block ──────────────────────────────────────────

local BACKSLASH = string.char(92)

---A double-quoted Lua string literal for `s`.
---@param s string
---@return string
local function quote(s)
  local out = s:gsub('[%c"\\]', function(c)
    if c == '"' then
      return BACKSLASH .. '"'
    elseif c == BACKSLASH then
      return BACKSLASH .. BACKSLASH
    elseif c == "\n" then
      return BACKSLASH .. "n"
    elseif c == "\r" then
      return BACKSLASH .. "r"
    elseif c == "\t" then
      return BACKSLASH .. "t"
    end
    return BACKSLASH .. ("%03d"):format(c:byte())
  end)
  return '"' .. out .. '"'
end

local KEY = "^[%a_][%w_]*$"
local RESERVED = {
  ["and"] = true,
  ["break"] = true,
  ["do"] = true,
  ["else"] = true,
  ["elseif"] = true,
  ["end"] = true,
  ["false"] = true,
  ["for"] = true,
  ["function"] = true,
  ["goto"] = true,
  ["if"] = true,
  ["in"] = true,
  ["local"] = true,
  ["nil"] = true,
  ["not"] = true,
  ["or"] = true,
  ["repeat"] = true,
  ["return"] = true,
  ["then"] = true,
  ["true"] = true,
  ["until"] = true,
  ["while"] = true,
}

---@param value any
---@return string|nil text
---@return string|nil err
function M.lua_value(value)
  local kind = type(value)
  if kind == "string" then
    return quote(value), nil
  elseif kind == "boolean" then
    return tostring(value), nil
  elseif kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return nil, "a number that is not finite"
    end
    if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
      return ("%d"):format(value), nil
    end
    return ("%.17g"):format(value), nil
  elseif kind == "table" then
    if next(value) == nil then
      return "{}", nil
    end
    local parts = {}
    if vim.islist(value) then
      for _, item in ipairs(value) do
        local text, err = M.lua_value(item)
        if not text then
          return nil, err
        end
        parts[#parts + 1] = text
      end
    else
      local keys = {}
      for key in pairs(value) do
        if type(key) ~= "string" then
          return nil, "a table with a key that is not a string"
        end
        keys[#keys + 1] = key
      end
      table.sort(keys)
      for _, key in ipairs(keys) do
        local text, err = M.lua_value(value[key])
        if not text then
          return nil, err
        end
        local name = (key:match(KEY) and not RESERVED[key]) and key or ("[" .. quote(key) .. "]")
        parts[#parts + 1] = name .. " = " .. text
      end
    end
    return "{ " .. table.concat(parts, ", ") .. " }", nil
  end
  return nil, ("a value of the type %s cannot be written"):format(kind)
end

---@param value any
---@return boolean
local function holds_function(value)
  if type(value) == "function" then
    return true
  elseif type(value) == "table" then
    for _, item in pairs(value) do
      if holds_function(item) then
        return true
      end
    end
  end
  return false
end

---The index after the long bracket that opens at `at`, nil when none opens there.
---@param source string
---@param at integer
---@return integer|nil
local function long_end(source, at)
  local eq = source:match("^%[(=*)%[", at)
  if not eq then
    return nil
  end
  local _, close = source:find("]" .. eq .. "]", at + #eq + 2, true)
  return (close or #source) + 1
end

---The index of the closing quote of the short string that opens at `at` (an unfinished one ends at its line).
---@param source string
---@param at integer
---@return integer
local function string_end(source, at)
  local quote_char = source:sub(at, at)
  local j = at + 1
  while j <= #source do
    local d = source:sub(j, j)
    if d == BACKSLASH then
      j = j + 2
    elseif d == quote_char or d == "\n" then
      break
    else
      j = j + 1
    end
  end
  return j
end

---Walks the source of a block the way Lua reads it, so a string or a long bracket is never taken for a comment. Tells
---whether the source holds a comment, and where the string literals of its top-level `severity = "..."` stand (the
---line of the source, the first and the last column of the literal, quotes included).
---@param source string
---@return boolean comment
---@return { line: integer, from: integer, to: integer }[] severities
local function scan(source)
  local comment, found = false, {}
  local depth, i, n = 0, 1, #source

  while i <= n do
    local c = source:sub(i, i)
    if c == "-" and source:sub(i + 1, i + 1) == "-" then
      comment = true
      i = long_end(source, i + 2) or ((source:find("\n", i, true) or n) + 1)
    elseif c == '"' or c == "'" then
      i = string_end(source, i) + 1
    elseif c == "[" and long_end(source, i) then
      i = long_end(source, i) --[[@as integer]]
    elseif c == "{" then
      depth, i = depth + 1, i + 1
    elseif c == "}" then
      depth, i = depth - 1, i + 1
    elseif c:match("[%a_]") then
      local name = source:match("^[%a_][%w_]*", i)
      local after = i + #name
      i = after
      if name == "severity" and depth == 0 and source:sub(after - #name - 1, after - #name - 1) ~= "." then
        local from = source:match([=[^%s*=%s*()["']]=], after)
        if from then
          local stop = string_end(source, from)
          local before = source:sub(1, from - 1)
          local _, breaks = before:gsub("\n", "")
          local line_start = before:match(".*\n()") or 1
          if source:sub(stop, stop) == source:sub(from, from) and not source:sub(from, stop):find("\n", 1, true) then
            found[#found + 1] = { line = breaks + 1, from = from - line_start + 1, to = stop - line_start + 1 }
          end
          i = stop + 1
        end
      end
    else
      i = i + 1
    end
  end
  return comment, found
end

---@class Rules.BlockField
---@field key string   the name of the field
---@field l1 integer   the first line of the source it stands on
---@field l2 integer   the last line

---The fields of a block's table constructor (`id = ...,`, `check = { ... },`), each with the lines it takes. `nil` when
---a field cannot be told by its name (a positional entry), when two fields share a line or when a separator stands in
---front of its field (comma-first style: a line that starts with `,`): a block like that is not edited line by line,
---the caller writes it again from its table.
---@param source string  the lines of the block between the fences
---@return Rules.BlockField[]|nil
local function top_fields(source)
  local fields = {}
  local depth, i, n, line = 0, 1, #source, 1
  local start, first_line, last_line = nil, 1, 1
  local fresh = true -- nothing but blanks yet on this line

  ---@return boolean ok
  local function finish()
    if not start then
      return true
    end
    local text = source:sub(start, i - 1)
    local key = text:match("^([%a_][%w_]*)%s*=[^=]") or text:match([=[^%[%s*["']([^"']*)["']%s*%]%s*=[^=]]=])
    start = nil
    if not key then
      return false
    end
    local previous = fields[#fields]
    if previous and first_line <= previous.l2 then
      return false
    end
    fields[#fields + 1] = { key = key, l1 = first_line, l2 = last_line }
    return true
  end

  while i <= n do
    local c = source:sub(i, i)
    local stop = i
    if c == "\n" then
      line = line + 1
      fresh = true
    elseif not c:match("%s") then
      if fresh and depth == 0 and (c == "," or c == ";") then
        return nil
      end
      fresh = false
      if not start and not (c == "," or c == ";") then
        start, first_line = i, line
      end
      if (c == "," or c == ";") and depth == 0 then
        if not finish() then
          return nil
        end
      elseif c == '"' or c == "'" then
        stop = string_end(source, i)
      elseif c == "[" and long_end(source, i) then
        stop = long_end(source, i) - 1
      elseif c == "{" or c == "(" or c == "[" then
        depth = depth + 1
      elseif c == "}" or c == ")" or c == "]" then
        depth = depth - 1
      end
      last_line = line
      if stop > i then
        local _, breaks = source:sub(i, stop):gsub("\n", "")
        line = line + breaks
        last_line = line
      end
    end
    i = stop + 1
  end
  i = n + 1
  if not finish() then
    return nil
  end
  return fields
end

---The lines of a block (without the fences) for a table: `id`, `severity`, `check`, `agent`, then the rest in byte
---order.
---@param tbl table
---@return string[]|nil lines
---@return string|nil err
local function block_lines(tbl)
  local first = { "id", "severity", "check", "agent" }
  local seen, keys = {}, {}
  for _, key in ipairs(first) do
    if tbl[key] ~= nil then
      keys[#keys + 1] = key
      seen[key] = true
    end
  end
  local rest = {}
  for key in pairs(tbl) do
    if type(key) ~= "string" then
      return nil, "the block has a key that is not a string"
    end
    if not seen[key] then
      rest[#rest + 1] = key
    end
  end
  table.sort(rest)
  vim.list_extend(keys, rest)
  local lines = {}
  for _, key in ipairs(keys) do
    local text, err = M.lua_value(tbl[key])
    if not text then
      return nil, ("%s: %s"):format(key, err)
    end
    local name = (key:match(KEY) and not RESERVED[key]) and key or ("[" .. quote(key) .. "]")
    lines[#lines + 1] = name .. " = " .. text .. ","
  end
  return lines, nil
end

-- ── lines ───────────────────────────────────────────────────────────────────────

---@param text string
---@return string[] lines
---@return string eol
---@return boolean final  the text ends with a line break
---@return boolean mixed  some lines end in CR LF and some in LF
local function split_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  local final = false
  if lines[#lines] == "" then
    lines[#lines] = nil
    final = true
  end
  -- without a final newline the last line has no line break of its own, so it has no CR to count
  local counted = final and #lines or #lines - 1
  local crlf = 0
  for i = 1, counted do
    if lines[i]:sub(-1) == "\r" then
      crlf = crlf + 1
    end
  end
  local mixed = crlf > 0 and crlf < counted
  local eol = (crlf > 0 and not mixed) and "\r\n" or "\n"
  if eol == "\r\n" then
    for i = 1, counted do
      lines[i] = lines[i]:sub(1, -2)
    end
  end
  return lines, eol, final, mixed
end

---@param lines string[]
---@param eol string
---@param final boolean
---@return string
local function join_lines(lines, eol, final)
  local text = table.concat(lines, eol)
  return final and (text .. eol) or text
end

---@param lines string[]
---@param from integer
---@param to integer
---@param new string[]
local function replace(lines, from, to, new)
  for _ = from, to do
    table.remove(lines, from)
  end
  for i, line in ipairs(new) do
    table.insert(lines, from + i - 1, line)
  end
end

-- ── the text of a rule ──────────────────────────────────────────────────────────

---A text as given by a client, with LF line endings: a CR LF pair would leave a CR at the end of every line in a file
---that ends its lines with LF (or in front of the CR of a file that ends them with CR LF), and the file would mix them.
---@param text string
---@return string
local function lf(text)
  return (text:gsub("\r\n", "\n"))
end

---Lines of a text for a rule file. A divider line (`---`, `***`, `___`) at the end of the text, right under a line of
---text, would make that line a heading (`---`) or glue to it: a blank line goes in front of it.
---@param text string
---@return string[]
local function text_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  local last = #lines
  while last > 0 and lines[last]:match("^%s*$") do
    last = last - 1
  end
  if last >= 2 and parser.is_framing(lines[last]) and not parser.is_framing(lines[last - 1]) then
    table.insert(lines, last, "")
  end
  return lines
end

-- ── the edit ────────────────────────────────────────────────────────────────────

---Where a field stands among the others when a new one is written: the order `block_lines` writes them in.
local RANK = { id = 1, severity = 2, check = 3, agent = 4 }

---Change the string literals of the block's own `severity` (a block repeats it) to `severity`, line by line.
---@param lines string[]
---@param s integer  the line of the opening fence
---@param e integer  the line of the closing fence
---@param severity string
---@return boolean found  false: the block has no such literal (nothing was changed)
local function set_block_severity(lines, s, e, severity)
  local _, found = scan(table.concat(lines, "\n", s + 1, e - 1))
  for k = #found, 1, -1 do
    local at, row = found[k], lines[s + found[k].line]
    local quote_char = row:sub(at.from, at.from)
    lines[s + at.line] = row:sub(1, at.from - 1) .. quote_char .. severity .. quote_char .. row:sub(at.to + 1)
  end
  return #found > 0
end

---Change the `check` and `agent` fields of a block line by line: a field the patch does not name stays as it is, byte
---for byte (the order of its keys, the way it is laid out), and so does the `severity` the block repeats. A field the
---patch names is written again on one line, in the place of the old one; a new one goes after the fields that
---belong before it. Not possible (`false`) for a block whose fields cannot be told apart by lines (two on one line, a
---positional entry): the caller writes the whole block again.
---@param lines string[]
---@param s integer  the line of the opening fence
---@param e integer  the line of the closing fence
---@param patch Rules.RulePatch
---@param repeats_severity boolean  the block has a `severity` of its own
---@return boolean done
local function edit_fields(lines, s, e, patch, repeats_severity)
  local fields = top_fields(table.concat(lines, "\n", s + 1, e - 1))
  if not fields or #fields == 0 then
    return false
  end
  local edits = {}
  local indent = lines[s + fields[1].l1]:match("^%s*")
  for _, key in ipairs({ "check", "agent" }) do
    local value = patch[key]
    if value ~= nil then
      local new = {}
      if value ~= vim.NIL then
        local text = M.lua_value(value)
        if not text then
          return false
        end
        new[1] = ("%s%s = %s,"):format(indent, key, text)
      end
      -- a key given twice: the last one is the one that counts in Lua, so that one is replaced; to remove the key every
      -- one of them would have to go, which is the caller's whole-block rewrite
      local field, count = nil, 0
      for _, f in ipairs(fields) do
        if f.key == key then
          field, count = f, count + 1
        end
      end
      if count > 1 and value == vim.NIL then
        return false
      end
      if field then
        edits[#edits + 1] = { l1 = s + field.l1, l2 = s + field.l2, new = new }
      elseif #new > 0 then
        -- after the last field that belongs before it, at the top when none does
        local anchor
        for _, f in ipairs(fields) do
          if (RANK[f.key] or 5) < RANK[key] then
            anchor = f
          end
        end
        local at = anchor and s + anchor.l2 + 1 or s + fields[1].l1
        if anchor and not lines[s + anchor.l2]:match("[,;]%s*$") then
          lines[s + anchor.l2] = lines[s + anchor.l2]:gsub("%s*$", "") .. ","
        end
        edits[#edits + 1] = { l1 = at, l2 = at - 1, new = new }
      end
    end
  end
  if patch.severity ~= nil and repeats_severity and not set_block_severity(lines, s, e, patch.severity) then
    return false
  end
  -- bottom to top, and of two edits of one place the later one first, so the fields come out in the order they were made
  for index, edit in ipairs(edits) do
    edit.index = index
  end
  table.sort(edits, function(a, b)
    if a.l1 ~= b.l1 then
      return a.l1 > b.l1
    end
    return a.index > b.index
  end)
  for _, edit in ipairs(edits) do
    replace(lines, edit.l1, edit.l2, edit.new)
  end
  return true
end

---@class Rules.RulePatch
---@field severity? string
---@field title? string
---@field text? string
---@field check? table|userdata   `vim.NIL` removes it
---@field agent? table|userdata

---Change a rule file text. Returns the new text, or `nil` and why not.
---@param path string  only for messages
---@param text string
---@param patch Rules.RulePatch
---@return string|nil new_text
---@return string|nil err
function M.apply(path, text, patch)
  local lines, eol, final, mixed = split_lines(text)
  if mixed then
    return nil, "the file mixes CR LF and LF line endings; fix that by hand first"
  end
  local rule_file, errs = parser.split_text(path, table.concat(lines, "\n") .. "\n")
  if not rule_file then
    return nil, errs[1] or "not a rule file"
  end
  local off = rule_file.offset
  local id = rule_file.id
  local edit_block = patch.check ~= nil or patch.agent ~= nil
  local given = patch.text ~= nil and lf(patch.text) or nil
  ---@type string|nil
  local want_title

  -- bottom to top, so the indices above an edit stay valid
  if patch.text ~= nil then
    local from, to = parser.text_range(rule_file)
    from, to = off + from, off + to
    local first, last
    for i = from, to do
      if lines[i] and not parser.is_framing(lines[i]) then
        first = first or i
        last = i
      end
    end
    local new = given == "" and {} or text_lines(given)
    if first then
      replace(lines, first, last, new)
      -- no text left: one blank line between what is above and what is below, as in a file made without text
      if #new == 0 and lines[first - 1] == "" and lines[first] == "" then
        table.remove(lines, first)
      end
    elseif #new > 0 then
      local insert = {}
      if from > 1 and lines[from - 1] and lines[from - 1]:match("%S") then
        insert[#insert + 1] = ""
      end
      vim.list_extend(insert, new)
      if lines[from] and lines[from]:match("%S") then
        insert[#insert + 1] = ""
      end
      replace(lines, from, from - 1, insert)
    end
  end

  if not edit_block and patch.severity ~= nil and rule_file.block then
    -- the block repeats the severity: change that one literal in place, the rest of the block stays as it is
    local block = rule_file.block
    if block.fence > 0 then
      return nil, "the rule block sits inside a longer fence; edit it by hand"
    end
    set_block_severity(lines, off + block.s, off + block.e, patch.severity)
  elseif edit_block then
    local block = rule_file.block
    local tbl = {}
    local s, e
    if block then
      if block.fence > 0 then
        return nil, "the rule block sits inside a longer fence; edit it by hand"
      end
      s, e = off + block.s, off + block.e
      local source = table.concat(lines, "\n", s + 1, e - 1)
      if scan(source) then
        return nil, "the rule block has a comment; edit it by hand"
      end
      local value, why = sandbox.eval_table(source, "rule@" .. path)
      if not value then
        return nil, ("the rule block does not evaluate: %s"):format(tostring(why))
      end
      tbl = value
      if holds_function(tbl) then
        return nil, "the rule block holds a Lua function; edit it by hand"
      end
    end
    local repeats_severity = tbl.severity ~= nil
    if patch.severity ~= nil and tbl.severity ~= nil then
      tbl.severity = patch.severity
    end
    if patch.check ~= nil then
      tbl.check = patch.check ~= vim.NIL and patch.check or nil
    end
    if patch.agent ~= nil then
      tbl.agent = patch.agent ~= vim.NIL and patch.agent or nil
    end
    if next(tbl) == nil then
      if block then
        -- the block says nothing now: take it out with one blank line, so no double blank is left behind
        local to = e
        if lines[e + 1] == "" then
          to = e + 1
        end
        replace(lines, s, to, {})
      end
    elseif not (block and edit_fields(lines, s, e, patch, repeats_severity)) then
      -- a new block, or one whose fields cannot be told apart by lines: written again from its table
      local rendered, why = block_lines(tbl)
      if not rendered then
        return nil, why
      end
      local fenced = { "```rule" }
      vim.list_extend(fenced, rendered)
      fenced[#fenced + 1] = "```"
      if block then
        replace(lines, s, e, fenced)
      else
        local at = rule_file.heading and (off + rule_file.heading) or off
        local insert = { "" }
        vim.list_extend(insert, fenced)
        if not rule_file.heading then
          insert[#insert + 1] = ""
        end
        replace(lines, at + 1, at, insert)
      end
    end
  end

  if patch.title ~= nil then
    local heading_text = patch.title
    if not heading_text:find(id, 1, true) then
      heading_text = ("`%s` — %s"):format(id, heading_text)
    end
    want_title = heading_text
    if rule_file.heading then
      local at = off + rule_file.heading
      local hashes = lines[at]:match("^(#+)%s")
      lines[at] = hashes .. " " .. heading_text
    else
      replace(lines, off + 1, off, { "#### " .. heading_text, "" })
    end
  end

  if patch.severity ~= nil then
    local done = false
    for i = 2, off do
      if lines[i]:match("^severity:") then
        lines[i] = "severity: " .. patch.severity
        done = true
        break
      end
    end
    if not done then
      return nil, "the frontmatter has no severity line"
    end
  end

  local new_text = join_lines(lines, eol, final)

  -- read it back the way the loader would, and compare with what was asked for
  local rule, rerrs = parser.parse_rule_text(path, (new_text:gsub("\r\n", "\n")))
  if not rule or #rerrs > 0 then
    return nil, ("the result would not read as a rule: %s"):format(tostring((rerrs or {})[1] or "unknown"))
  end
  if rule.id ~= id then
    return nil, "the result would have another id"
  end
  if patch.severity ~= nil and rule.severity ~= patch.severity then
    return nil, "the result would not have the severity asked for"
  end
  if given ~= nil then
    local want = parser.prose(vim.split(given, "\n", { plain = true }))
    if rule.text ~= want then
      return nil, "the text would not read back as written (a heading or a separator line in it ends the text of a rule)"
    end
  end
  if want_title ~= nil and rule.title ~= want_title then
    return nil, "the title would not read back as written"
  end
  if patch.check ~= nil then
    local want = patch.check ~= vim.NIL and patch.check or nil
    if not vim.deep_equal(rule.check, want) then
      return nil, "the check would not read back as written"
    end
  end
  if patch.agent ~= nil then
    local want = patch.agent ~= vim.NIL and patch.agent or nil
    if not vim.deep_equal(rule.agent, want) then
      return nil, "the agent hint would not read back as written (it is validated like a rule's own)"
    end
  end
  return new_text, nil
end

---The text of a new rule file: the frontmatter, the heading, the block, the text as given (never wrapped), and the
---divider `---` between blank lines at the end (added unless the text ends with one).
---@param spec { id: string, severity: string, title: string, text?: string, check?: table, agent?: table }
---@return string|nil text
---@return string|nil err
function M.render_new(spec)
  local family = spec.id:match("^(%a+)%-") or spec.id
  local out = {
    "---",
    "id: " .. spec.id,
    "severity: " .. spec.severity,
    "family: " .. family,
    "---",
    "",
  }
  local heading = spec.title
  if not heading:find(spec.id, 1, true) then
    heading = ("`%s` — %s"):format(spec.id, heading)
  end
  out[#out + 1] = "#### " .. heading
  out[#out + 1] = ""
  local tbl = { check = spec.check, agent = spec.agent }
  if next(tbl) ~= nil then
    local rendered, why = block_lines(tbl)
    if not rendered then
      return nil, why
    end
    out[#out + 1] = "```rule"
    vim.list_extend(out, rendered)
    out[#out + 1] = "```"
    out[#out + 1] = ""
  end
  local given = spec.text ~= nil and lf(spec.text) or nil
  if given and given ~= "" then
    vim.list_extend(out, text_lines(given))
  end
  -- The file ends as the rule files of the shipped rulesets do: the text, a blank line, the divider `---`, a blank
  -- line (the generator copies the lines of a rule file as they are, so this is what keeps two rules in a document
  -- apart). A text that ends with the divider already is not given a second one, and a blank line or two at its end
  -- change nothing: the callers do not have to know the convention.
  while out[#out] ~= nil and out[#out]:match("^%s*$") do
    out[#out] = nil
  end
  if not (given and given ~= "" and out[#out]:match("^%s*%-%-%-%s*$")) then
    out[#out + 1] = ""
    out[#out + 1] = "---"
  end
  out[#out + 1] = ""
  local text = table.concat(out, "\n") .. "\n"
  local rule, errs = parser.parse_rule_text(spec.id .. ".md", text)
  if not rule or #errs > 0 then
    return nil, ("the rule would not read back: %s"):format(tostring((errs or {})[1] or "unknown"))
  end
  if given and rule.text ~= parser.prose(vim.split(given, "\n", { plain = true })) then
    return nil, "the text would not read back as written (a heading or a separator line in it ends the text)"
  end
  if spec.check ~= nil and not vim.deep_equal(rule.check, spec.check) then
    return nil, "the check would not read back as written"
  end
  if spec.agent ~= nil and not vim.deep_equal(rule.agent, spec.agent) then
    return nil, "the agent hint would not read back as written"
  end
  return text, nil
end

return M
