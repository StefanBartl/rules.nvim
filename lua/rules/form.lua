---@module 'rules.form'
---@brief The Markdown form behind `:Rules new` -- text in, one `new` operation out; no UI, no file, no write.
---@description
--- The form is a Markdown buffer: text lines for the free fields, a `- [ ]` / `- [x]` bullet list for the severity
--- and a `## text` section for the prose of the rule. This module builds the template, parses what the user left in
--- the buffer, checks it up front (what is required and well formed) and flips one bullet while keeping the list at
--- one tick. It touches no buffer, window or file, so `TESTS/form_spec.lua` drives it with plain strings;
--- `rules.ui.form` is the thin UI on top.
---
--- Layout:
---
---     # New rule
---     <!-- hints -->
---     Family: DEP
---     Title: One line that names the rule
---     Place: after DEP-03
---
---     ## severity (one)
---     - [ ] critical
---     - [x] recommended
---     - [ ] nice-to-have
---
---     ## text
---     The prose of the rule, as long as it needs.
---
--- Lines starting with `!` at the top (the report of an earlier submit) and `<!--` hints are not form content;
--- everything below `## text` is the prose, as typed.
---
--- The form finds out what is missing (family, title, severity) before anything is asked of the engine. What else is
--- wrong with a request (a text that would end the rule early, a layout that is not there, an id that is taken) is
--- told by the door (`rules.ops`, its `dry_run` first): the form does not repeat the rules of a rule.
---
--- Not its job: windows and keys (`rules.ui.form`), the write (`rules.write`).

local cmdline = require("rules.cmdline")

local M = {}

---The severities, in the order the contract names them: the door's own list (`rules.ops` checks a request against
---it), which is light to load -- the grammar of `:Rules` reads it when the command is made.
---@return string[]
function M.severities()
  return vim.deepcopy(require("rules.engine.rule_edit").SEVERITIES)
end

---The one-line hint under the title of a fresh form.
M.DEFAULT_HINT = "<!-- <Space>/<CR> tick, <C-s> check and create, q cancel, g? help -->"

local SEVERITY_HEADING = "## severity (one)"
local TEXT_HEADING = "## text"

---@param line string
---@return string
local function rtrim(line)
  return line:match("^(.*%S)") or ""
end

---@class Rules.FormOpts
---@field family? string
---@field title? string
---@field ruleset? string
---@field rulesets? string[]  the names of the rulesets (the `Ruleset:` line is shown when there are several)
---@field place? string
---@field severity? string   ticked in a fresh form
---@field text? string
---@field families? string[]  listed in a hint
---@field layouts? string[]   the layouts' output paths, listed in a hint
---@field hint? string

---Fresh form text.
---@param opts? Rules.FormOpts
---@return string[] lines
function M.template(opts)
  opts = opts or {}
  local lines = { "# New rule", opts.hint or M.DEFAULT_HINT }
  if opts.families and #opts.families > 0 then
    lines[#lines + 1] = "<!-- families: " .. table.concat(opts.families, ", ") .. " -->"
  end
  lines[#lines + 1] = "Family: " .. (opts.family or "")
  lines[#lines + 1] = "Title: " .. (opts.title or "")
  if opts.rulesets and #opts.rulesets > 1 then
    lines[#lines + 1] = "<!-- rulesets: " .. table.concat(opts.rulesets, ", ") .. " -->"
    lines[#lines + 1] = "Ruleset: " .. (opts.ruleset or "")
  end
  if opts.layouts and #opts.layouts > 0 then
    lines[#lines + 1] = "<!-- place: after <ID>, before <ID>, <file>#<section> or <file>; files: "
      .. table.concat(opts.layouts, ", ")
      .. " -->"
  end
  lines[#lines + 1] = "Place: " .. (opts.place or "")
  lines[#lines + 1] = ""
  lines[#lines + 1] = SEVERITY_HEADING
  for _, severity in ipairs(M.severities()) do
    lines[#lines + 1] = ("- [%s] %s"):format(opts.severity == severity and "x" or " ", severity)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = TEXT_HEADING
  if opts.text and opts.text ~= "" then
    for _, line in ipairs(vim.split(opts.text, "\n", { plain = true })) do
      lines[#lines + 1] = line
    end
  end
  return lines
end

---@class Rules.FormParsed
---@field family string
---@field title string
---@field ruleset string
---@field place string
---@field ticks string[]    the ticked severities, in form order
---@field unknown string[]  ticked choices that are no severity
---@field text string       the prose below `## text`, without blank lines at either end

---Read the form text.
---@param lines string[]
---@return Rules.FormParsed
function M.parse(lines)
  ---@type Rules.FormParsed
  local out = { family = "", title = "", ruleset = "", place = "", ticks = {}, unknown = {}, text = "" }
  local severities = M.severities()
  local in_severity, in_text = false, false
  local prose = {}
  for _, raw in ipairs(lines) do
    if in_text then
      prose[#prose + 1] = raw
    else
      local line = rtrim(raw)
      -- a report ("!") or a hint ("<!--") is not form content
      local noise = line:sub(1, 1) == "!" or line:sub(1, 4) == "<!--"
      if not noise and line:match("^##%s+text%s*$") then
        in_text, in_severity = true, false
      elseif not noise and line:match("^##%s+severity") then
        in_severity = true
      elseif not noise and line:match("^##") then
        in_severity = false
      elseif not noise then
        local key, value = line:match("^(%a+):%s*(.*)$")
        key = key and key:lower()
        if key == "family" or key == "title" or key == "ruleset" or key == "place" then
          out[key] = value
          in_severity = false
        else
          local mark, text = line:match("^%s*[-*]%s+%[(.)%]%s+(.*)$")
          if in_severity and mark and (mark == "x" or mark == "X") then
            if vim.tbl_contains(severities, text) then
              out.ticks[#out.ticks + 1] = text
            else
              out.unknown[#out.unknown + 1] = text
            end
          end
        end
      end
    end
  end
  local first, last = 1, #prose
  while first <= last and prose[first]:match("^%s*$") do
    first = first + 1
  end
  while last >= first and prose[last]:match("^%s*$") do
    last = last - 1
  end
  if first <= last then
    out.text = table.concat(vim.list_slice(prose, first, last), "\n")
  end
  return out
end

---Check a parsed form. What it needs is a family, a title and one severity; the place has to be readable. A request
---that passes is one `new` operation for the door.
---@param parsed Rules.FormParsed
---@return table|nil op  `{ op = "new", family, title, severity, text?, ruleset?, <place> }`
---@return string[] errors
function M.validate(parsed)
  local ops = require("rules.ops")
  local errors = {}

  local family = vim.trim(parsed.family)
  if family == "" then
    errors[#errors + 1] = "Family is required (letters, e.g. DEP)"
  elseif not family:match("^%a+$") or #family > ops.FAMILY_MAX then
    errors[#errors + 1] = ("Family must be letters only, at most %d (e.g. DEP)"):format(ops.FAMILY_MAX)
  end

  local title = vim.trim(parsed.title)
  if title == "" then
    errors[#errors + 1] = "Title is required"
  elseif vim.fn.strchars(title) > ops.MAX_TITLE then
    errors[#errors + 1] = ("Title is longer than %d characters"):format(ops.MAX_TITLE)
  end

  for _, text in ipairs(parsed.unknown) do
    errors[#errors + 1] = "unknown severity: " .. text
  end
  if #parsed.ticks == 0 and #parsed.unknown == 0 then
    errors[#errors + 1] = "severity: tick one (" .. table.concat(M.severities(), ", ") .. ")"
  elseif #parsed.ticks > 1 then
    errors[#errors + 1] = ("severity: pick one, %d are ticked (%s)"):format(#parsed.ticks, table.concat(parsed.ticks, ", "))
  end

  local place, perr = cmdline.place_text(parsed.place)
  if not place then
    errors[#errors + 1] = "Place: " .. tostring(perr)
  end

  if #errors > 0 then
    return nil, errors
  end
  ---@type table
  local op = { op = "new", family = family, title = title, severity = parsed.ticks[1] }
  if parsed.text ~= "" then
    op.text = parsed.text
  end
  local ruleset = vim.trim(parsed.ruleset)
  if ruleset ~= "" then
    op.ruleset = ruleset
  end
  return vim.tbl_extend("force", op, place or {}), errors
end

---Flip the severity bullet on line `lnum`: ticking one clears the others, ticking the ticked one clears it.
---@param lines string[]
---@param lnum integer  1-based
---@return string[]|nil new_lines  `nil` when the line is not a bullet of the severity list
function M.toggle(lines, lnum)
  local line = lines[lnum]
  if not line then
    return nil
  end
  local indent, mark, text = line:match("^(%s*[-*]%s+)%[(.)%](.*)$")
  if not indent then
    return nil
  end
  -- the list is the run of bullets under the severity heading
  local first
  for i = lnum - 1, 1, -1 do
    if lines[i]:match("^##%s+severity") then
      first = i + 1
      break
    elseif not lines[i]:match("^%s*[-*]%s+%[.%]") then
      return nil
    end
  end
  if not first then
    return nil
  end
  local out = vim.deepcopy(lines)
  local was_ticked = mark == "x" or mark == "X"
  if not was_ticked then
    local i = first
    while out[i] and out[i]:match("^%s*[-*]%s+%[.%]") do
      out[i] = out[i]:gsub("^(%s*[-*]%s+)%[.%]", "%1[ ]")
      i = i + 1
    end
  end
  out[lnum] = indent .. "[" .. (was_ticked and " " or "x") .. "]" .. text
  return out
end

---Lines for the report put at the top of the form.
---@param errors string[]
---@return string[]
function M.error_lines(errors)
  local out = { "! The form was not submitted:" }
  for _, e in ipairs(errors) do
    out[#out + 1] = "! - " .. e
  end
  return out
end

---Drop an earlier report from the top of the form text. Only the lines at the very top: a line of the prose that
---starts with `!` stays.
---@param lines string[]
---@return string[]
function M.strip_errors(lines)
  local first = 1
  while lines[first] and lines[first]:sub(1, 1) == "!" do
    first = first + 1
  end
  return vim.list_slice(lines, first, #lines)
end

return M
