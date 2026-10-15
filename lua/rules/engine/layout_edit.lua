---@module 'rules.engine.layout_edit'
---@brief Where a rule stands in a layout: find, take out and put in the `{{rule ID}}` line, nothing else.
---@description
--- A layout is the order of a generated document (`docs/RULESET-FORMAT.md`). A rule appears in it as a whole line
--- `{{rule ID}}`; the rest (headings, introductions) is the author's text and is never touched. Line endings and the
--- final newline are kept.
---
--- A place is `{ after = ID }`, `{ before = ID }` (a rule that already stands in the layout) or
--- `{ section = "heading text", first? = true, nth? = n }` (the end of that section, or its start): a section is a
--- heading up to the next heading of the same or a higher level; `nth` picks the n-th heading of that text when several
--- have it (default the first). The start is before the first rule token of the section's own text (the lines before its
--- first subheading); a section with no token of its own has an introduction (the text between its heading and its next
--- heading), which is not a rule, so there the start is behind the introduction, with a blank line before the token and
--- one after it, and so is the end of a section with no token at all. `{ top = true }` is the start of the layout: before
--- the first rule that stands above every heading, else right under the frontmatter.
---
--- `gap = { above = n, below = m }` on any place says how many blank lines stood above and below the token when it was
--- taken out: the token goes back with exactly those (what `retire` and `move` answer to restore a layout byte for byte).
---
--- What is a heading or a token: a line is a heading (`#` to `######`, a space, a text) or a token (the whole line
--- `{{rule ID}}`, whitespace behind it ignored) only OUTSIDE the frontmatter, a fenced code block (backticks or tildes,
--- three or more, closed by the same character and at least as many, up to three spaces of indentation; one never
--- closed runs to the end) and an HTML comment (`<!--` to `-->`, also over several lines). The generator
--- (`rules.engine.catalog`) is more naive: it fills EVERY whole-line token, also one in a fence or a comment. So a token
--- in a fence is no token for the editor but a rule for the generator; `place` therefore refuses an id that stands
--- hidden like that (the generator would place it twice).
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

---The fence a line opens: its character and length, or nil. Up to three spaces of indentation, three or more `` ` ``
---or `~`; the info string of a backtick fence has no backtick (else it is inline code).
---@param line string
---@return string|nil char
---@return integer|nil len
local function fence_open(line)
  local indent, run, rest = line:match("^( *)(`+)(.*)$")
  if indent and #indent <= 3 and #run >= 3 and not rest:find("`", 1, true) then
    return "`", #run
  end
  indent, run = line:match("^( *)(~+)")
  if indent and #indent <= 3 and #run >= 3 then
    return "~", #run
  end
  return nil, nil
end

---Whether a line closes the fence `char` of `len`: the same character, at least as many, nothing but blanks behind.
---@param line string
---@param char string
---@param len integer
---@return boolean
local function fence_close(line, char, len)
  local indent, run
  if char == "`" then
    indent, run = line:match("^( *)(`+)[ \t]*$")
  else
    indent, run = line:match("^( *)(~+)[ \t]*$")
  end
  return indent ~= nil and #indent <= 3 and #run >= len
end

---What the editor sees of the lines of a layout: the headings and the tokens, outside the frontmatter, fences and
---comments. THE one classifier: every finder, every slot and every removal reads this.
---@class Rules.LayoutIndex
---@field heading table<integer, { [1]: integer, [2]: string }>  line -> `{ level, text }`
---@field token table<integer, string>  line -> rule id
---@field hidden table<integer, string>  line -> rule id, of a token the editor does not see (fence, comment)

---@param lines string[]
---@return Rules.LayoutIndex
local function index(lines)
  local out = { heading = {}, token = {}, hidden = {} }
  local first = 1
  if (lines[1] or ""):gsub("%s+$", "") == "---" then
    for i = 2, #lines do
      if (lines[i]:gsub("%s+$", "")) == "---" then
        first = i + 1
        break
      end
    end
  end
  local char, len
  local comment = false
  for i = 1, #lines do
    local line = lines[i]
    local id = token_id(line)
    local seen = true
    if i < first then
      seen = false
    elseif char then
      seen = false
      if fence_close(line, char, len) then
        char, len = nil, nil
      end
    elseif comment then
      seen = false
      if line:find("-->", 1, true) then
        comment = false
      end
    else
      local c, n = fence_open(line)
      if c then
        char, len, seen = c, n, false
      elseif line:match("^ ? ? ?<!%-%-") then
        -- an HTML block: the whole line is the comment; it goes on when the line does not end it
        seen = false
        comment = not line:find("-->", line:find("<!--", 1, true) + 2, true)
      else
        -- a comment that starts later in a line (behind text, not inside a code span) hides the lines behind it
        local plain = line:gsub("(`+).-%1", "")
        local at = plain:find("<!--", 1, true)
        if at and not plain:find("-->", at + 2, true) then
          comment = true
        end
      end
    end
    if seen then
      local level, text = heading(line)
      if level then
        out.heading[i] = { level, text }
      elseif id then
        out.token[i] = id
      end
    elseif id and i >= first then
      out.hidden[i] = id
    end
  end
  return out
end

---Line index of the token of `id` the editor sees.
---@param lines string[]
---@param idx Rules.LayoutIndex
---@param id string
---@return integer|nil
local function find(lines, idx, id)
  for i = 1, #lines do
    if idx.token[i] == id then
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
  local lines = split(text)
  return find(lines, index(lines), id) ~= nil
end

---Where the token of `id` stands: the heading of its section and the id of the token above it in the same section.
---@param text string
---@param id string
---@return { section: string|nil, prev: string|nil }|nil
function M.locate(text, id)
  local lines = split(text)
  local idx = index(lines)
  local at = find(lines, idx, id)
  if not at then
    return nil
  end
  local section, prev
  for i = at - 1, 1, -1 do
    local mark = idx.heading[i]
    if mark then
      section = mark[2]
      break
    end
    prev = prev or idx.token[i]
  end
  return { section = section, prev = prev }
end

---Take the token at line `at` out. A blank line left doubled by it is taken too, and so is the blank line a token at the
---very end of the layout stood behind (the one `place` puts in front of a token it writes at the end).
---@param lines string[]
---@param at integer
local function take_out(lines, at)
  table.remove(lines, at)
  if lines[at] == "" and lines[at - 1] == "" then
    table.remove(lines, at)
  elseif at > #lines and lines[at - 1] == "" then
    table.remove(lines, at - 1)
  end
end

---Take the token of `id` out.
---@param text string
---@param id string
---@return string|nil new_text
---@return string|nil err
function M.remove(text, id)
  local lines, eol, final = split(text)
  local at = find(lines, index(lines), id)
  if not at then
    return nil, ("the layout has no {{rule %s}}"):format(id)
  end
  take_out(lines, at)
  return join(lines, eol, final), nil
end

---Where a token goes in the n-th section named `name`.
---
---With tokens of the section's own text (before its first subheading): after the last token of the whole section, or
---before the first own token (`first`). Without any (`first`), or without any token in the section: behind the
---introduction of the section (the text between its heading and the next heading of any level, which is not a rule),
---with one blank line before the token and one after it.
---@param lines string[]
---@param idx Rules.LayoutIndex
---@param name string
---@param nth integer
---@param first boolean
---@return integer|nil slot  the token goes before this line
---@return boolean|nil blank_before  a blank line goes in front of the token
---@return boolean|nil blank_after  a blank line goes behind it
local function section_slot(lines, idx, name, nth, first)
  local start, level
  local count = 0
  for i = 1, #lines do
    local mark = idx.heading[i]
    if mark and mark[2] == name then
      count = count + 1
      if count == nth then
        start, level = i, mark[1]
        break
      end
    end
  end
  if not start then
    return nil
  end
  local stop = #lines + 1
  -- the first heading of any level below the section's own: where its introduction ends
  local intro_end
  for i = start + 1, #lines do
    local mark = idx.heading[i]
    if mark then
      intro_end = intro_end or i
      if mark[1] <= level then
        stop = i
        break
      end
    end
  end
  local own_first, last_token
  for i = start + 1, stop - 1 do
    if idx.token[i] then
      if i < (intro_end or stop) then
        own_first = own_first or i
      end
      last_token = i
    end
  end
  if first then
    if own_first then
      return own_first, false, false
    end
  elseif last_token then
    return last_token + 1, false, false
  end
  -- no token to go in front of or behind: behind the introduction. The blank lines that end it stay behind the token,
  -- so the token has one blank line in front of it and keeps the blank line(s) that were in front of the next heading
  -- (or at the end of the layout, for its last section).
  local slot = intro_end or (#lines + 1)
  while slot - 1 > start and lines[slot - 1] == "" do
    slot = slot - 1
  end
  -- a blank line behind it unless one is there already, or there is nothing behind it
  return slot, true, slot <= #lines and lines[slot] ~= ""
end

---The line before which a token goes at the top of the layout: before the first token that stands above every heading,
---else right under the frontmatter.
---@param lines string[]
---@param idx Rules.LayoutIndex
---@return integer
local function top_slot(lines, idx)
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
    if idx.heading[i] then
      break
    elseif idx.token[i] then
      return i
    end
  end
  return start
end

---@class Rules.LayoutPlace
---@field after string|nil
---@field before string|nil
---@field section string|nil
---@field first boolean|nil
---@field nth integer|nil  the n-th section of that heading text (default 1)
---@field top boolean|nil
---@field gap { above?: integer, below?: integer }|nil  the blank lines around the token, exactly

---Put the token of `id` at a place.
---@param text string
---@param id string
---@param where Rules.LayoutPlace
---@return string|nil new_text
---@return string|nil err
function M.place(text, id, where)
  local lines, eol, final = split(text)
  local idx = index(lines)
  if find(lines, idx, id) then
    return nil, ("the layout has {{rule %s}} already"):format(id)
  end
  for _, hidden in pairs(idx.hidden) do
    if hidden == id then
      local why = "the layout has {{rule %s}} in a code block or a comment: the generator fills it too, so a second one"
        .. " would be placed twice"
      return nil, why:format(id)
    end
  end
  local slot, blank_before, blank_after
  if where.after or where.before then
    local anchor = where.after or where.before
    local at = find(lines, idx, anchor)
    if not at then
      return nil, ("the layout has no {{rule %s}} to put it next to"):format(anchor)
    end
    slot = where.after and (at + 1) or at
  elseif where.section then
    slot, blank_before, blank_after = section_slot(lines, idx, where.section, where.nth or 1, where.first == true)
    if not slot then
      return nil, ("the layout has no section %q"):format(where.section)
    end
  elseif where.top then
    slot = top_slot(lines, idx)
  else
    return nil, "a place needs after, before, section or top"
  end
  local put = { "{{rule " .. id .. "}}" }
  if where.gap then
    -- the blank lines around the slot are the ones the token stood between: they all go, and the recorded ones come
    local from, to = slot, slot
    while from > 1 and lines[from - 1] == "" do
      from = from - 1
    end
    while lines[to] == "" do
      to = to + 1
    end
    for _ = from, to - 1 do
      table.remove(lines, from)
    end
    slot = from
    for _ = 1, where.gap.above or 0 do
      table.insert(put, 1, "")
    end
    for _ = 1, where.gap.below or 0 do
      put[#put + 1] = ""
    end
  else
    if blank_before then
      table.insert(put, 1, "")
    end
    if blank_after then
      put[#put + 1] = ""
    end
  end
  for n, line in ipairs(put) do
    table.insert(lines, slot + n - 1, line)
  end
  return join(lines, eol, final), nil
end

---Where the token of `id` stands now, as a place that puts it back: `{ after }`, `{ section, first, nth? }`,
---`{ before }` or `{ top }`, with `gap` when the token stood between blank lines that `place` would not write on its own.
---The place is the first of these that gives back the layout byte for byte once the token is out; where none does
---(the author put text between the token and the rule above it, say) it is the first one, with the `gap`. The place is
---always inside the section the token stands in. Nil when the layout does not hold the token.
---@param text string
---@param id string
---@return table|nil place
function M.where(text, id)
  local lines = split(text)
  local idx = index(lines)
  local at = find(lines, idx, id)
  if not at then
    return nil
  end
  local head, prev, nxt
  for i = at - 1, 1, -1 do
    if idx.heading[i] then
      head = i
      break
    end
    prev = prev or idx.token[i]
  end
  for i = at + 1, #lines do
    if idx.heading[i] then
      break
    end
    if idx.token[i] then
      nxt = idx.token[i]
      break
    end
  end
  local nth
  if head then
    nth = 0
    for i = 1, head do
      local mark = idx.heading[i]
      if mark and mark[2] == idx.heading[head][2] then
        nth = nth + 1
      end
    end
  end
  local function section(first)
    return { section = idx.heading[head][2], first = first or nil, nth = nth > 1 and nth or nil }
  end
  -- in the order of the preference: behind the rule above it, the start of its section (or of the layout), in front of
  -- the rule below it, the end of its section
  local cands = {}
  if prev then
    cands[#cands + 1] = { after = prev }
  end
  cands[#cands + 1] = head and section(true) or { top = true }
  if nxt then
    cands[#cands + 1] = { before = nxt }
  end
  if head then
    cands[#cands + 1] = section(false)
  end
  -- the blank lines directly around the token
  local above, below = 0, 0
  while lines[at - above - 1] == "" do
    above = above + 1
  end
  while lines[at + below + 1] == "" do
    below = below + 1
  end
  local gap = above <= 100 and below <= 100 and { above = above, below = below } or nil
  local rest = M.remove(text, id)
  for _, cand in ipairs(cands) do
    if M.place(rest, id, cand) == text then
      return cand
    end
    if gap then
      local with = vim.tbl_extend("force", cand, { gap = gap })
      if M.place(rest, id, with) == text then
        return with
      end
    end
  end
  return gap and vim.tbl_extend("force", cands[1], { gap = gap }) or cands[1]
end

return M
