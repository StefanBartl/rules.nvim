---@module 'rules.engine.layout_edit'
---@brief Where a rule stands in a layout: find, take out and put in the `{{rule ID}}` line, nothing else.
---@description
--- A layout is the order of a generated document (`docs/RULESET-FORMAT.md`). A rule appears in it as a whole line
--- `{{rule ID}}`; the rest (headings, introductions) is the author's text and is never touched. Line endings and the
--- final newline are kept.
---
--- A place is `{ after = ID }`, `{ before = ID }` (a rule that already stands in the layout) or
--- `{ section = "heading text", first? = true }` (the end of that section, or its start): a section is a heading
--- up to the next heading of the same or a higher level. `{ top = true }` is the start of the layout: before the
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
  local section, prev
  for i = at - 1, 1, -1 do
    local level, name = heading(lines[i])
    if level then
      section = name
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

---The line before which a token goes in the section named `name`, or `nil` when there is no such section.
---@param lines string[]
---@param name string
---@param first boolean
---@return integer|nil
local function section_slot(lines, name, first)
  local start, level
  for i, line in ipairs(lines) do
    local l, text = heading(line)
    if l and text == name then
      start, level = i, l
      break
    end
  end
  if not start then
    return nil
  end
  local stop = #lines + 1
  for i = start + 1, #lines do
    local l = heading(lines[i])
    if l and l <= level then
      stop = i
      break
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
      return first_token
    end
  elseif last_token then
    return last_token + 1
  end
  -- no token in the section: right under the heading, after the blank lines that follow it
  local slot = start + 1
  while slot < stop and lines[slot] == "" do
    slot = slot + 1
  end
  return slot
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
  for i = start, #lines do
    if heading(lines[i]) then
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
  local slot
  if where.after or where.before then
    local anchor = where.after or where.before
    local at = find(lines, anchor)
    if not at then
      return nil, ("the layout has no {{rule %s}} to put it next to"):format(anchor)
    end
    slot = where.after and (at + 1) or at
  elseif where.section then
    slot = section_slot(lines, where.section, where.first == true)
    if not slot then
      return nil, ("the layout has no section %q"):format(where.section)
    end
  elseif where.top then
    slot = top_slot(lines)
  else
    return nil, "a place needs after, before, section or top"
  end
  table.insert(lines, slot, "{{rule " .. id .. "}}")
  return join(lines, eol, final), nil
end

return M
