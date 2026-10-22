---@module 'rules.engine.agent.validate'
---@brief Check a model's answer about a manual rule against the tree as it is now.
---@description
--- `validate(rule, text, root, opts)` turns the raw answer of an agent into a **proposal** for one rule. It
--- trusts nothing the model says about the code: every quoted line is looked up in the file, within a few
--- lines of the line the model named, and a finding that does not occur there is dropped.
---
--- The answer is JSON (a single fenced block is allowed, nothing else around it):
---
--- ```json
--- { "results": [
---   { "rule": "DEP-01", "verdict": "violation" | "compliant" | "unclear",
---     "checked": ["lua/a.lua", "lua/b.lua"],
---     "findings": [ { "file": "lua/a.lua", "line": 12, "quote": "require(\"x\")", "why": "..." } ],
---     "reason": "free text, for `unclear`" } ] }
--- ```
---
--- What comes out is never a verdict. `status` says what the model proposed, `proposed` is always true and
--- `verified` always false: an agent's answer is not a pass, it never changes `check_family_json`'s exit code,
--- and one actor must not both propose and verify. Anything that does not hold up becomes `unclear` -- never a
--- guess: an answer that is not JSON or not this schema (the raw text is attached), a rule the answer does not
--- mention, a `checked` entry that was not sent, a `violation` none of whose findings survived, a `compliant`
--- that names no file it looked at.
---
--- Pure like `plan`: no `vim.api`, no network. The files a request carried must be passed as `opts.sent`;
--- without that list `checked` and `file` cannot be judged and every answer is `unclear`.

local read_file = require("rules.engine.agent.read")

local M = {}

--- Lines on each side of the named line in which a quote must occur.
M.WINDOW = 3
--- A file bigger than this is not read; a finding in it is dropped.
M.MAX_FILE_BYTES = 2 * 1024 * 1024
--- A quote shorter than this proves nothing (`end`, `x` occur in any window).
M.MIN_QUOTE_BYTES = 4

---@class Rules.Agent.Finding
---@field file string  relative, "/"-separated; one of the files that were sent
---@field line integer
---@field quote string  as found in the file (trimmed)
---@field why? string

---@class Rules.Agent.Dropped
---@field finding any  what the model wrote
---@field reason string

---@class Rules.Agent.Result
---@field rule_id string
---@field status "violation"|"compliant"|"unclear"  what is proposed; never a pass
---@field proposed true
---@field verified false
---@field findings Rules.Agent.Finding[]  only the ones that hold; empty unless `violation`
---@field checked string[]  files the model says it looked at (all of them were sent)
---@field unchecked string[]  sent files the model does not say it looked at; a `compliant` that leaves some says
---   less than it seems to
---@field dropped Rules.Agent.Dropped[]  findings that did not hold up
---@field reason? string  why `unclear`, or the model's own words
---@field raw? string  the answer as received, attached when it could not be read

---@class Rules.Agent.ValidateOpts
---@field sent string[]  the relative paths the request carried (`Rules.Agent.Batch.files`)
---@field window? integer  lines on each side to look in (default `M.WINDOW`)

local VERDICTS = { violation = true, compliant = true, unclear = true }

---@param rule_id string
---@param reason string
---@param extra? { raw?: string, dropped?: Rules.Agent.Dropped[], checked?: string[] }
---@return Rules.Agent.Result
local function unclear(rule_id, reason, extra)
  return {
    rule_id = rule_id,
    status = "unclear",
    proposed = true,
    verified = false,
    findings = {},
    checked = extra and extra.checked or {},
    dropped = extra and extra.dropped or {},
    reason = reason,
    raw = extra and extra.raw,
  }
end

--- A path as the plan writes it: "/"-separated, no leading `./`.
---@param path string
---@return string
local function norm_path(path)
  local p = path:gsub("\\", "/")
  while p:sub(1, 2) == "./" do
    p = p:sub(3)
  end
  return p
end

---@param value any
---@return boolean
local function is_list(value)
  -- `vim.NIL` is a userdata in the editor and an (empty) table under the standalone shim: a JSON null is no list in either
  if type(value) ~= "table" or value == vim.NIL then
    return false
  end
  local n = 0
  for key in pairs(value) do
    if type(key) ~= "number" then
      return false
    end
    n = n + 1
  end
  return n == #value
end

--- The JSON text of an answer: the answer itself, or the inside of the one fenced block that is all of it.
---@param text string
---@return string
local function json_text(text)
  local inner = text:match("^%s*```[%w]*\r?\n(.-)\r?\n?```%s*$")
  return inner or text
end

--- Lines of a file, nil when it cannot be read.
---@param root string
---@param file string
---@return string[]|nil
local function read_lines(root, file)
  local content = read_file.file(root .. "/" .. file, M.MAX_FILE_BYTES)
  if not content then
    return nil
  end
  return vim.split((content:gsub("\r\n", "\n")), "\n", { plain = true })
end

---@param quote string
---@return string
local function trim(quote)
  return (quote:gsub("\r\n", "\n"):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Check one finding against the tree.
---@param finding any
---@param sent_set table<string, true>
---@param root string
---@param window integer
---@param cache table<string, string[]|false>
---@return Rules.Agent.Finding|nil kept
---@return string|nil reason  why it was dropped
local function check_finding(finding, sent_set, root, window, cache)
  if type(finding) ~= "table" then
    return nil, "a finding is not an object"
  end
  if type(finding.file) ~= "string" or type(finding.quote) ~= "string" then
    return nil, "a finding needs a string `file` and a string `quote`"
  end
  local line = finding.line
  if type(line) ~= "number" or line % 1 ~= 0 or line < 1 then
    return nil, "`line` must be a whole number of 1 or more"
  end
  local file = norm_path(finding.file)
  if not sent_set[file] then
    return nil, ("`%s` was not sent"):format(file)
  end
  local quote = trim(finding.quote)
  if quote == "" then
    return nil, "`quote` is empty"
  end
  if #quote < M.MIN_QUOTE_BYTES then
    return nil, ("`quote` is shorter than %d bytes"):format(M.MIN_QUOTE_BYTES)
  end
  if cache[file] == nil then
    cache[file] = read_lines(root, file) or false
  end
  local lines = cache[file]
  if not lines then
    return nil, ("`%s` cannot be read"):format(file)
  end
  local first = math.max(1, line - window)
  local last = math.min(#lines, line + window)
  if first > last then
    return nil, ("line %d is past the end of `%s`"):format(line, file)
  end
  local around = table.concat(lines, "\n", first, last)
  if not around:find(quote, 1, true) then
    return nil, ("the quote does not occur within %d lines of %s:%d"):format(window, file, line)
  end
  return { file = file, line = line, quote = quote, why = type(finding.why) == "string" and finding.why or nil }, nil
end

---@param rule Rules.ParsedRule|{ id: string }
---@param text string
---@param root string
---@param opts Rules.Agent.ValidateOpts
---@return Rules.Agent.Result
local function judge(rule, text, root, opts)
  local id = rule.id
  if type(text) ~= "string" then
    return unclear(id, "the answer is not text")
  end
  if not (opts and is_list(opts.sent)) then
    return unclear(id, "no list of sent files to check the answer against", { raw = text })
  end
  local ok, decoded = pcall(vim.json.decode, json_text(text))
  if not ok or type(decoded) ~= "table" then
    return unclear(id, "the answer is not JSON", { raw = text })
  end
  if not is_list(decoded.results) then
    return unclear(id, "the answer has no `results` list", { raw = text })
  end

  local entry, count = nil, 0
  for _, candidate in ipairs(decoded.results) do
    if type(candidate) == "table" and candidate.rule == id then
      entry = candidate
      count = count + 1
    end
  end
  if count == 0 then
    return unclear(id, "the answer does not mention this rule")
  end
  if count > 1 then
    return unclear(id, "the answer names this rule more than once", { raw = text })
  end

  local verdict = entry.verdict
  if type(verdict) ~= "string" or not VERDICTS[verdict] then
    return unclear(id, "`verdict` must be violation, compliant or unclear", { raw = text })
  end
  local findings_raw = entry.findings == nil and {} or entry.findings
  local checked_raw = entry.checked == nil and {} or entry.checked
  if not is_list(checked_raw) or not is_list(findings_raw) then
    return unclear(id, "`checked` and `findings` must be lists", { raw = text })
  end

  local sent_set = {}
  for _, path in ipairs(opts.sent) do
    sent_set[norm_path(path)] = true
  end
  local checked = {}
  for _, path in ipairs(checked_raw) do
    if type(path) ~= "string" or not sent_set[norm_path(path)] then
      return unclear(id, ("`checked` names a file that was not sent: %s"):format(tostring(path)), { raw = text })
    end
    checked[#checked + 1] = norm_path(path)
  end

  local model_reason = type(entry.reason) == "string" and entry.reason or nil

  if verdict == "unclear" then
    local result = unclear(id, model_reason or "the model could not tell", { checked = checked })
    return result
  end

  if verdict == "compliant" then
    if #findings_raw > 0 then
      return unclear(id, "the answer says compliant and lists findings", { raw = text, checked = checked })
    end
    if #checked == 0 then
      return unclear(id, "compliant, but no file is named as looked at")
    end
    return {
      rule_id = id,
      status = "compliant",
      proposed = true,
      verified = false,
      findings = {},
      checked = checked,
      dropped = {},
      reason = model_reason,
    }
  end

  -- violation: believe only what the tree confirms
  local window = opts.window or M.WINDOW
  local cache = {}
  local kept, dropped = {}, {}
  for _, finding in ipairs(findings_raw) do
    local good, why = check_finding(finding, sent_set, root, window, cache)
    if good then
      kept[#kept + 1] = good
    else
      dropped[#dropped + 1] = { finding = finding, reason = why }
    end
  end
  if #kept == 0 then
    return unclear(id, "a violation was proposed but no finding holds up against the tree", {
      checked = checked,
      dropped = dropped,
    })
  end
  return {
    rule_id = id,
    status = "violation",
    proposed = true,
    verified = false,
    findings = kept,
    checked = checked,
    dropped = dropped,
    reason = model_reason,
  }
end

--- An `unclear` proposal for a rule, for a host that has no answer to check (the request failed, nothing was sent).
---@param rule_id string
---@param reason string
---@return Rules.Agent.Result
function M.unclear(rule_id, reason)
  local result = unclear(rule_id, reason)
  result.unchecked = {}
  return result
end

--- The sent files that `checked` does not name.
---@param sent any
---@param checked string[]
---@return string[]
local function unchecked_of(sent, checked)
  if not is_list(sent) then
    return {}
  end
  local seen = {}
  for _, path in ipairs(checked) do
    seen[path] = true
  end
  local out = {}
  for _, path in ipairs(sent) do
    local normalized = norm_path(path)
    if not seen[normalized] then
      out[#out + 1] = normalized
    end
  end
  return out
end

--- Turn the answer of an agent into a proposal for `rule`.
---@param rule Rules.ParsedRule|{ id: string }
---@param text string  the answer as received
---@param root string  the tree the files were sent from
---@param opts Rules.Agent.ValidateOpts
---@return Rules.Agent.Result
function M.validate(rule, text, root, opts)
  local result = judge(rule, text, root, opts)
  result.unchecked = unchecked_of(opts and opts.sent, result.checked)
  return result
end

return M
