---@module 'rules.engine.layout_edit'
---@brief Where a rule stands in a layout: find, take out and put in the `{{rule ID}}` line, nothing else.
---@description
--- A layout is the order of a generated document (`docs/RULESET-FORMAT.md`). A rule appears in it as a whole line
--- `{{rule ID}}`; the rest (headings, introductions) is the author's text and is never touched. Line endings and the
--- final newline are kept.
---
--- A place is `{ after = ID }`, `{ before = ID }` (a rule that already stands in the layout) or
--- `{ section = "heading text", first? = true }` (the end of that section, or its start): a section is a heading
--- up to the next heading of the same or a higher level. The start is before the first rule token of the section;
--- a section with no token yet has an introduction (the text between its heading and its next heading), which is not
--- a rule, so there both the start and the end are behind the introduction, with a blank line before the token and one
--- after it. A `#` line in a fenced block is no heading. `{ top = true }` is the start of the layout: before the
--- first rule that stands above every heading, else right under the frontmatter.
---
--- Not its job: finding the layouts of a ruleset (`rules.ops`), writing files, regenerating the documents.

local M = {}

---@param line string
---@return string|nil id
local function token_id(line)
  local bare = line:gsub("%s+$", "")
  return bare:match("^{{rule%s+([^%s}]+)%s*}}$")
end

---@param line string
---@return integer|nil level
---@return string|nil text
local function heading(line)
  local hashes, rest = line:match("^(#+)%s+(.-)%s*$")
  if hashes and #hashes <= 6 then
    return #hashes, rest
  end
  return nil, nil
end

---@param text string
---@return string[] lines
---@return string eol
---@return boolean final
local function split(text)
  local eol = text:find("\r\n", 1, true) and "\r\n" or "\n"
  local lines = vim.split(text, "\n", { plain = true })
  local final = false
  if lines[#lines] == "" then
    lines[#lines] = nil
    final = true
  end
  if eol == "\r\n" then
    for i, line in ipairs(lines) do
      lines[i] = line:gsub("\r$", "")
    end
  end
  return lines, eol, final
end

---@param lines string[]
---@param eol string
---@param final boolean
---@return string
local function join(lines, eol, final)
  local text = table.concat(lines, eol)
  return final and (text .. eol) or text
end

---The headings of a layout: line index -> `{ level, text }`. A `#` line inside a fenced block (a code example in an
---introduction) is no heading.
---@param lines string[]
---@return table<integer, { [1]: integer, [2]: string }>
local function headings_of(lines)
  local out = {}
  local fence = 0
  for i, line in ipairs(lines) do
    local ticks = line:match("^(`+)")
    if fence > 0 then
      if ticks and #ticks >= fence and line:match("^`+%s*$") then
        fence = 0
      end
    elseif ticks and #ticks >= 3 then
      fence = #ticks
    else
      local level, text = heading(line)
      if level then
        out[i] = { level, text }
      end
    end
  end
  return out
end

---Line index of the token of `id`, outside a fenced block.
---@param lines string[]
---@param id string
---@return integer|nil
local function find(lines, id)
  local fence = 0
  for i, line in ipairs(lines) do
    local ticks = line:match("^(`+)")
    if fence > 0 then
      if ticks and #ticks >= fence and line:match("^`+%s*$") then
        fence = 0
      end
    elseif ticks and #ticks >= 3 then
      fence = #ticks
    elseif token_id(line) == id then
      return i
    end
  end
  return nil
end

---Whether the layout text has a token for this rule.
---@param text string
---@param id string
---@return boolean
function M.has(text, id)
  return find((split(text)), id) ~= nil
end

---Where the token of `id` stands: the heading of its section and the id of the token above it in the same section.
---@param text string
---@param id string
---@return { section: string|nil, prev: string|nil }|nil
function M.locate(text, id)
  local lines = split(text)
  local at = find(lines, id)
  if not at then
    return nil
  end
  local marks = headings_of(lines)
  local section, prev
  for i = at - 1, 1, -1 do
    local mark = marks[i]
    if mark then
      section = mark[2]
      break
    end
    prev = prev or token_id(lines[i])
  end
  return { section = section, prev = prev }
end

---Take the token of `id` out. A blank line left doubled by it is taken too.
---@param text string
---@param id string
---@return string|nil new_text
---@return string|nil err
function M.remove(text, id)
  local lines, eol, final = split(text)
  local at = find(lines, id)
  if not at then
    return nil, ("the layout has no {{rule %s}}"):format(id)
  end
  table.remove(lines, at)
  if lines[at] == "" and lines[at - 1] == "" then
    table.remove(lines, at)
  end
  return join(lines, eol, final), nil
end

---Where a token goes in the section named `name`.
---
---With tokens in the section: after the last one, or before the first one (`first`). Without any: after the
---introduction of the section (the text between its heading and the next heading of any level, which is not a rule),
---for `first` as well, with one blank line before the token and one after it.
---@param lines string[]
---@param name string
---@param first boolean
---@return integer|nil slot  the token goes before this line
---@return boolean|nil blank_before  a blank line goes in front of the token
---@return boolean|nil blank_after  a blank line goes behind it
local function section_slot(lines, name, first)
  local marks = headings_of(lines)
  local start, level
  for i = 1, #lines do
    local mark = marks[i]
    if mark and mark[2] == name then
      start, level = i, mark[1]
      break
    end
  end
  if not start then
    return nil
  end
  local stop = #lines + 1
  -- the first heading of any level below the section's own: where its introduction ends
  local intro_end
  for i = start + 1, #lines do
    local mark = marks[i]
    if mark then
      intro_end = intro_end or i
      if mark[1] <= level then
        stop = i
        break
      end
    end
  end
  local first_token, last_token
  for i = start + 1, stop - 1 do
    if token_id(lines[i]) then
      first_token = first_token or i
      last_token = i
    end
  end
  if first then
    if first_token then
      return first_token, false, false
    end
  elseif last_token then
    return last_token + 1, false, false
  end
  -- no token in the section: behind the introduction. The blank lines that end it stay behind the token, so the
  -- token has one blank line in front of it and keeps the blank line(s) that were in front of the next heading.
  -- (`first` is the same place: the introduction is not a rule, so the start of the rules is behind it.)
  if not intro_end then
    -- the last section of the layout: the token goes at its very end, the blank lines there are the end of the file
    return #lines + 1, lines[#lines] ~= "", false
  end
  local slot = intro_end
  while slot - 1 > start and lines[slot - 1] == "" do
    slot = slot - 1
  end
  -- a blank line behind it unless one is there already
  return slot, true, lines[slot] ~= ""
end

---The line before which a token goes at the top of the layout: before the first token that stands above every heading,
---else right under the frontmatter.
---@param lines string[]
---@return integer
local function top_slot(lines)
  local start = 1
  if (lines[1] or ""):gsub("%s+$", "") == "---" then
    for i = 2, #lines do
      if (lines[i]:gsub("%s+$", "")) == "---" then
        start = i + 1
        break
      end
    end
  end
  local marks = headings_of(lines)
  for i = start, #lines do
    if marks[i] then
      break
    elseif token_id(lines[i]) then
      return i
    end
  end
  return start
end

---Put the token of `id` at a place.
---@param text string
---@param id string
---@param where { after?: string, before?: string, section?: string, first?: boolean, top?: boolean }
---@return string|nil new_text
---@return string|nil err
function M.place(text, id, where)
  local lines, eol, final = split(text)
  if find(lines, id) then
    return nil, ("the layout has {{rule %s}} already"):format(id)
  end
  local slot, blank_before, blank_after
  if where.after or where.before then
    local anchor = where.after or where.before
    local at = find(lines, anchor)
    if not at then
      return nil, ("the layout has no {{rule %s}} to put it next to"):format(anchor)
    end
    slot = where.after and (at + 1) or at
  elseif where.section then
    slot, blank_before, blank_after = section_slot(lines, where.section, where.first == true)
    if not slot then
      return nil, ("the layout has no section %q"):format(where.section)
    end
  elseif where.top then
    slot = top_slot(lines)
  else
    return nil, "a place needs after, before, section or top"
  end
  local put = { "{{rule " .. id .. "}}" }
  if blank_before then
    table.insert(put, 1, "")
  end
  if blank_after then
    put[#put + 1] = ""
  end
  for n, line in ipairs(put) do
    table.insert(lines, slot + n - 1, line)
  end
  return join(lines, eol, final), nil
end

return M
