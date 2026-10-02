---@module 'rules.engine.parser'
---@brief Extract fenced ```rule blocks from a Markdown file into rule tables.
---@description
--- The parser looks for exactly one marker: a fenced code block tagged
--- ` ```rule `. Everything else in the file — headings, prose, other fenced
--- blocks, old table-based rule text — is invisible to it on purpose. That is
--- what keeps a format migration incremental: a file half in the legacy table
--- format and half in the new fenced-block format parses correctly, picking up
--- only the entries that have actually been converted.
---
--- A block's content is a Lua table-constructor *body* (fields, not the
--- surrounding braces). Fields need the usual Lua field separator (a comma
--- or a semicolon) between them, same as any Lua table literal. It is
--- evaluated in an **empty environment** (`rules.util.sandbox`): a ruleset is
--- code, and a body that calls anything fails as a malformed block. A
--- `check.fn` survives as a closure and only gets its environment back when
--- the host trusts predicates -- see `checks/lua_predicate.lua`.
---
--- Around the block the parser keeps three things the block cannot say about
--- itself. `text` is the prose under it, up to the next heading or rule block.
--- `title` is the heading the rule sits under when that heading names the rule
--- (`#### `DEP-01` — ...`, which is how every real ruleset is written), and
--- `section` is the heading above that -- what a catalog groups by. Headings
--- inside other fenced blocks (a shell comment in a ```bash example) are not
--- headings. These three belong to the parser: a block that sets a field of
--- the same name has it overwritten, like `source_file`.

local safe_error = require("lib.lua.error")
local sandbox = require("rules.util.sandbox")

local M = {}

---@class Rules.AgentSpec
---@field question string|nil  replaces the generic "does the code comply with the rule text"
---@field include string[]|nil  globs saying where an agent should look
---@field max_files integer|nil

---@class Rules.ParsedRule
---@field id string
---@field severity "critical"|"recommended"|"nice-to-have"
---@field check table|nil
---@field agent Rules.AgentSpec|nil  validated; an invalid one is dropped and reported
---@field title string|nil  the heading that names this rule
---@field section string|nil  the heading above it
---@field text string  the prose under the block, "" when there is none
---@field source_file string
---@field source_line integer

---@type table<string, true>
local VALID_SEVERITIES = { critical = true, recommended = true, ["nice-to-have"] = true }

---@type table<string, true>
local AGENT_KEYS = { question = true, include = true, max_files = true }

--- A string with no content once whitespace is gone.
---@param s any
---@return boolean
local function is_blank(s)
  return type(s) ~= "string" or s:match("^%s*$") ~= nil
end

--- Check a block's optional `agent` field. A bad one is dropped, not fatal: the
--- rule's mechanical check does not depend on it, so losing the whole rule
--- over a typo in an optional hint would remove it from a gate.
---@param agent any
---@return Rules.AgentSpec|nil clean  only the known, valid keys
---@return string|nil problem  why it was dropped
local function validate_agent(agent)
  if type(agent) ~= "table" or vim.islist(agent) and #agent > 0 then
    return nil, "must be a table"
  end

  for key in pairs(agent) do
    if not AGENT_KEYS[key] then
      return nil, ("unknown key %s (want question, include, max_files)"):format(tostring(key))
    end
  end

  if agent.question ~= nil and is_blank(agent.question) then
    return nil, "`question` must be a non-empty string"
  end

  if agent.include ~= nil then
    local ok = type(agent.include) == "table" and vim.islist(agent.include) and #agent.include > 0
    if ok then
      for _, glob in ipairs(agent.include) do
        if is_blank(glob) then
          ok = false
          break
        end
      end
    end
    if not ok then
      return nil, "`include` must be a non-empty list of non-empty strings"
    end
  end

  local max_files = agent.max_files
  if max_files ~= nil and (type(max_files) ~= "number" or max_files < 1 or max_files ~= math.floor(max_files)) then
    return nil, "`max_files` must be a positive integer"
  end

  return { question = agent.question, include = agent.include, max_files = max_files }, nil
end

--- Join prose lines into one string, without the blank lines and the Markdown
--- thematic breaks (`---`) that merely frame it.
---@param lines string[]
---@return string
local function prose(lines)
  local first, last = 1, #lines
  local function is_framing(line)
    local bare = line:gsub("%s", "")
    return bare == "" or bare:match("^%-%-%-+$") ~= nil or bare:match("^%*%*%*+$") ~= nil or bare:match("^___+$") ~= nil
  end
  while first <= last and is_framing(lines[first]) do
    first = first + 1
  end
  while last >= first and is_framing(lines[last]) do
    last = last - 1
  end
  return table.concat(lines, "\n", first, last)
end

--- The outline position of a rule: its own title and the section above it.
---@param stack {level: integer, text: string}[]  open headings, shallowest first
---@param id string
---@return string|nil title
---@return string|nil section
local function place(stack, id)
  local top = stack[#stack]
  if top and top.text:find(id, 1, true) then
    local parent = stack[#stack - 1]
    return top.text, parent and parent.text or nil
  end
  return nil, top and top.text or nil
end

--- Extract the fenced ```rule blocks from one Markdown file.
---@param file_path string
---@return Rules.ParsedRule[] rules
---@return string[] errors  one entry per block that failed to parse
function M.extract_rules(file_path)
  local rules = {}
  local errors = {}

  if vim.fn.filereadable(file_path) == 0 then
    errors[#errors + 1] = ("%s: not readable"):format(file_path)
    return rules, errors
  end

  -- ERR-01: `filereadable` above only checks openability at that instant --
  -- a TOCTOU window (the file removed/renamed/locked before this read) means
  -- `readfile` can still throw (`E484`) rather than return an error value.
  local read_ok, lines = safe_error.safe_call(vim.fn.readfile, file_path)
  if not read_ok then
    errors[#errors + 1] = ("%s: could not read (%s)"):format(file_path, lines.message)
    return rules, errors
  end
  local in_block = false
  local block_start = nil
  local block_lines = {}

  -- Outline and prose tracking. `fence` is the backtick count of any *other*
  -- open fenced block (0 = none), so a `# comment` inside a shell example is
  -- not mistaken for a heading. A fence closes only on at least as many
  -- backticks, which is what lets a ````markdown block show a ```rule one.
  -- `outer_fence` holds the surrounding fence while a rule block inside it is
  -- read (block detection itself does not care about fences, as it never did).
  local fence = 0
  local outer_fence = 0
  local stack = {}
  ---@type Rules.ParsedRule|nil
  local current = nil
  local text_lines = {}

  local function finish_text()
    if current then
      current.text = prose(text_lines)
    end
    current = nil
    text_lines = {}
  end

  for i, line in ipairs(lines) do
    if not in_block then
      if line:match("^```rule%s*$") then
        finish_text()
        in_block = true
        outer_fence, fence = fence, 0
        block_start = i
        block_lines = {}
      elseif fence > 0 then
        local ticks = line:match("^(`+)%s*$")
        if ticks and #ticks >= fence then
          fence = 0
        end
        text_lines[#text_lines + 1] = line
      elseif line:match("^```") then
        fence = #line:match("^(`+)")
        text_lines[#text_lines + 1] = line
      else
        local hashes, title = line:match("^(#+)%s+(.-)%s*$")
        if hashes and #hashes <= 6 then
          finish_text()
          while #stack > 0 and stack[#stack].level >= #hashes do
            stack[#stack] = nil
          end
          stack[#stack + 1] = { level = #hashes, text = title }
        else
          text_lines[#text_lines + 1] = line
        end
      end
    else
      if line:match("^```%s*$") then
        in_block = false
        fence, outer_fence = outer_fence, 0
        local src = table.concat(block_lines, "\n")
        local rule, eval_err = sandbox.eval_table(src, "rule@" .. file_path .. ":" .. block_start)
        if not rule then
          errors[#errors + 1] = ("%s:%d: %s"):format(file_path, block_start, eval_err)
        elseif type(rule.id) ~= "string" or rule.id == "" then
          errors[#errors + 1] = ("%s:%d: rule block has no string `id`"):format(file_path, block_start)
        elseif type(rule.severity) ~= "string" then
          errors[#errors + 1] = ("%s:%d: rule %s has no string `severity`"):format(file_path, block_start, rule.id)
        elseif not VALID_SEVERITIES[rule.severity] then
          errors[#errors + 1] = ("%s:%d: rule %s has invalid `severity` %q (want critical/recommended/nice-to-have)"):format(
            file_path,
            block_start,
            rule.id,
            rule.severity
          )
        else
          if rule.agent ~= nil then
            local clean, problem = validate_agent(rule.agent)
            if not clean then
              errors[#errors + 1] = ("%s:%d: rule %s: invalid `agent` field (%s) -- ignored"):format(
                file_path,
                block_start,
                rule.id,
                problem
              )
            end
            rule.agent = clean
          end
          rule.title, rule.section = place(stack, rule.id)
          rule.text = ""
          rule.source_file = file_path
          rule.source_line = block_start
          rules[#rules + 1] = rule
          current = rule
        end
      else
        block_lines[#block_lines + 1] = line
      end
    end
  end

  if in_block then
    errors[#errors + 1] = ("%s:%d: unterminated ```rule block"):format(file_path, block_start)
  end
  finish_text()

  return rules, errors
end

return M
