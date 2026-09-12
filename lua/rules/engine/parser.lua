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
--- surrounding braces), evaluated via `load("return {" .. body .. "}")` — same
--- trust level as any `require()` of a local file, since these are the
--- reader's own rulesets. Fields need the usual Lua field separator (a comma
--- or a semicolon) between them, same as any Lua table literal.

local M = {}

---@class Rules.ParsedRule
---@field id string
---@field severity "critical"|"recommended"|"nice-to-have"
---@field check table|nil
---@field source_file string
---@field source_line integer

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

  local lines = vim.fn.readfile(file_path)
  local in_block = false
  local block_start = nil
  local block_lines = {}

  for i, line in ipairs(lines) do
    if not in_block then
      if line:match("^```rule%s*$") then
        in_block = true
        block_start = i
        block_lines = {}
      end
    else
      if line:match("^```%s*$") then
        in_block = false
        local src = table.concat(block_lines, "\n")
        local chunk, load_err = load("return {" .. src .. "}", "rule@" .. file_path .. ":" .. block_start)
        if not chunk then
          errors[#errors + 1] = ("%s:%d: %s"):format(file_path, block_start, load_err)
        else
          local rule_ok, rule = pcall(chunk)
          if not rule_ok then
            errors[#errors + 1] = ("%s:%d: %s"):format(file_path, block_start, tostring(rule))
          elseif type(rule) ~= "table" or type(rule.id) ~= "string" or rule.id == "" then
            errors[#errors + 1] = ("%s:%d: rule block has no string `id`"):format(file_path, block_start)
          elseif type(rule.severity) ~= "string" then
            errors[#errors + 1] = ("%s:%d: rule %s has no string `severity`"):format(file_path, block_start, rule.id)
          else
            rule.source_file = file_path
            rule.source_line = block_start
            rules[#rules + 1] = rule
          end
        end
      else
        block_lines[#block_lines + 1] = line
      end
    end
  end

  if in_block then
    errors[#errors + 1] = ("%s:%d: unterminated ```rule block"):format(file_path, block_start)
  end

  return rules, errors
end

return M
