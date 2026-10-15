---@module 'rules.engine.loader'
---@brief Load rules from every configured ruleset path and merge them.
---@description
--- Refuses a duplicate ID across rulesets — an ID is unique across every
--- ruleset a user has loaded, not just within one file, matching
--- `Checklists/README.md`'s own rule: "IDs werden nie wiederverwendet."
--- A retired rule (`<ruleset>/_retired/<FAMILY>/<ID>.md`) is never loaded, but its
--- id stays taken: a live rule with the id of a retired one is a duplicate too.
---
--- A file under `_rules/` (the folder of the rule files) that yields no rule is
--- an error, not a file to skip: an empty one, one without a frontmatter, one
--- with merge-conflict markers. Anywhere else a `.md` file that holds no rule is
--- an ordinary document (a README, notes) and is no business of the loader.

local parser = require("rules.engine.parser")
local fswalk = require("rules.engine.fswalk")
local safe_error = require("lib.lua.error")
-- SEC-34: `vim.fn.expand()` would also apply shell/`<cfile>`-style specials
-- this is a static config string, not buffer/user text, but the ruleset
-- path is the plugin's own documented `~/path/to/your/checklists` example
-- (README.md, docs/BINDINGS.md), so it has to actually expand `~`/env vars.
local expand_path = require("lib.nvim.cross.fs.expand_path")

local M = {}

--- The folder of the rule files of a ruleset (`<FAMILY>/<ID>.md` inside it).
M.RULES_DIR = "_rules"
--- The folder of the retired rules of a ruleset.
M.RETIRED_DIR = "_retired"

--- Whether a file name is the one of a note about a folder (`README.md`, any case): it is no rule file wherever it lies.
---@param name string
---@return boolean
local function is_readme(name)
  return name:lower() == "readme.md"
end

--- Which kind of place a file lies in: `"retired"` (a folder `_retired` on its way; a README there is `"skip"`, read
--- by nobody), `"rules"` (a folder `_rules` on its way, not a README) or `"other"`. `rel` is the path inside the
--- ruleset, "/"-separated.
---@param rel string
---@return "retired"|"rules"|"other"|"skip"
local function place_of(rel)
  local segments = vim.split(rel, "/", { plain = true })
  local name = segments[#segments]
  local in_rules = false
  for i = 1, #segments - 1 do
    if segments[i] == M.RETIRED_DIR then
      return is_readme(name) and "skip" or "retired"
    elseif segments[i] == M.RULES_DIR then
      in_rules = true
    end
  end
  return (in_rules and not is_readme(name)) and "rules" or "other"
end

---@class Rules.RulesetScan
---@field live string[]  the `.md` files that are read for rules
---@field strict table<string, true>  of those, the files in a `_rules` folder: each has to yield a rule
---@field retired string[]  the `.md` files of the `_retired` folders: never read for rules, but their ids are taken

--- Every `.md` file reachable from `path` — itself if it already is one.
---@param path string
---@return Rules.RulesetScan scan
---@return string|nil error  set when `path` resolves to neither a directory
---   nor a readable `.md` file -- distinct from a directory that genuinely
---   has zero `.md` files in it, which is not an error (ERR-11)
local function scan(path)
  local expanded = expand_path(path)
  local out = { live = {}, strict = {}, retired = {} }

  if vim.fn.isdirectory(expanded) == 1 then
    -- `fswalk.files` (a literal `uv.fs_scandir` walk), not `vim.fn.globpath`:
    -- glob-family functions interpret `~`/`[`/`?`/`*`/`{}` in their PATH
    -- argument too, not just the pattern -- a ruleset path containing any of
    -- those (a Windows 8.3 short-name segment under a long-username `%TEMP%`
    -- is the classic real-world case) would silently glob-match nothing,
    -- despite `isdirectory` above confirming the directory genuinely exists.
    -- `fswalk` never interprets `path`, only lists what is actually there.
    local base = (expanded:gsub("\\", "/")):gsub("/+$", "")
    for _, file in ipairs(fswalk.files(expanded)) do
      if file:match("%.md$") then
        -- by the path inside the ruleset: a folder named `_retired` above the ruleset is none of this
        local place = place_of(file:sub(1, #base) == base and file:sub(#base + 2) or file)
        if place == "retired" then
          -- `_retired/` holds the rules `rules-ops/1` retired: kept for their ids, never loaded
          out.retired[#out.retired + 1] = file
        elseif place ~= "skip" then
          out.live[#out.live + 1] = file
          if place == "rules" then
            out.strict[file] = true
          end
        end
      end
    end
    return out, nil
  elseif expanded:match("%.md$") then
    if vim.fn.filereadable(expanded) == 1 then
      out.live[1] = expanded
      return out, nil
    end
    return out, ("ruleset path %q: not a readable file"):format(path)
  end

  return out, ("ruleset path %q: not a directory or a readable .md file"):format(path)
end

--- The line of the first merge-conflict marker (`<<<<<<<`, `=======`, `>>>>>>>` at the start of a line) outside a
--- fenced code block, which may show such lines as an example. nil when there is none.
---@param lines string[]
---@return integer|nil line
---@return string|nil marker
local function conflict_marker(lines)
  local fence = 0
  for i, line in ipairs(lines) do
    if fence > 0 then
      local ticks = line:match("^(`+)%s*$")
      if ticks and #ticks >= fence then
        fence = 0
      end
    elseif line:match("^```") then
      fence = #line:match("^(`+)")
    elseif line:match("^<<<<<<<") then
      return i, "<<<<<<<"
    elseif line:match("^>>>>>>>") then
      return i, ">>>>>>>"
    elseif line:match("^=======%s*$") then
      return i, "======="
    end
  end
  return nil, nil
end

---@param lines string[]
---@return boolean
local function blank_file(lines)
  for _, line in ipairs(lines) do
    if line:find("%S") then
      return false
    end
  end
  return true
end

---@param file string
---@return string[]|nil lines
---@return string|nil error  `<file>: could not read (...)`
local function read_lines(file)
  local ok, lines = safe_error.safe_call(vim.fn.readfile, file)
  if not ok then
    return nil, ("%s: could not read (%s)"):format(file, lines.message)
  end
  return lines, nil
end

--- What is wrong with a file of a `_rules` folder that is not already told by the parser: a merge-conflict marker, or
--- no rule in it at all. The kinds the loader skips by design (a generated document, a layout) hold no rule and are
--- no fault.
---@param file string
---@param yielded boolean  the parser found a rule in it
---@param told boolean  the parser told a problem of this file already
---@return string[] problems
local function audit_rule_file(file, yielded, told)
  local lines, err = read_lines(file)
  if not lines then
    return told and {} or { err }
  end
  local at, marker = conflict_marker(lines)
  if at then
    return { ("%s:%d: merge-conflict marker `%s`: resolve the conflict"):format(file, at, marker) }
  end
  if yielded or told then
    return {}
  end
  local kind = parser.classify(lines)
  if kind == "generated" or kind == "layout" then
    return {}
  end
  local need = "a file under " .. M.RULES_DIR .. "/ is a rule file: it needs a frontmatter with `id` and `severity`"
  if blank_file(lines) then
    return { ("%s: the file is empty (%s)"):format(file, need) }
  end
  return { ("%s: no rule in this file (%s, or a ```rule block)"):format(file, need) }
end

---@class Rules.RetiredFile
---@field id string  the id the file name says (`_retired/DEP/DEP-05.md` is `DEP-05`)
---@field file string
---@field meta_id string|nil  the `id` of its frontmatter when that is another one: both are taken
---@field problems string[]  why it is no readable retired rule

--- What a retired file is: the original rule file with the facts of its retirement added to the frontmatter. Its id
--- is the one in the file name, and the one in the frontmatter too when the two differ (which is a fault).
---@param file string
---@return Rules.RetiredFile
local function read_retired(file)
  local entry = { id = file:match("([^/]+)%.md$") or file, file = file, problems = {} }
  local lines, err = read_lines(file)
  if not lines then
    entry.problems[1] = err
    return entry
  end
  local at, marker = conflict_marker(lines)
  if at then
    entry.problems[#entry.problems + 1] = ("%s:%d: merge-conflict marker `%s`: resolve the conflict"):format(file, at, marker)
  end
  local kind, parsed = parser.classify(lines)
  local meta_id = kind == "rule" and parsed and parsed.meta.id or nil
  if type(meta_id) ~= "string" or meta_id == "" then
    if #entry.problems == 0 then
      entry.problems[1] = ("%s: a retired rule needs a frontmatter with its `id`"):format(file)
    end
  elseif parsed and parsed.unterminated then
    entry.problems[#entry.problems + 1] = ("%s:1: frontmatter is not closed by a second `---` line"):format(file)
  elseif meta_id ~= entry.id then
    entry.meta_id = meta_id
    -- cut and made printable: the id comes from a file nobody has looked at
    local shown = meta_id:sub(1, 100):gsub("%c", "?")
    entry.problems[#entry.problems + 1] = ("%s: the file is named for %s but its frontmatter says `id: %s`"):format(
      file,
      entry.id,
      #meta_id > 100 and shown .. "..." or shown
    )
  end
  return entry
end

--- The retired rules of a ruleset folder, in the order of the files. A ruleset that is a file has none.
---@param path string
---@return Rules.RetiredFile[]
function M.retired(path)
  local files = scan(path).retired
  table.sort(files)
  local out = {}
  for _, file in ipairs(files) do
    out[#out + 1] = read_retired(file)
  end
  return out
end

--- Load and merge every ruleset path into one flat rule list.
---@param ruleset_paths string[]
---@return Rules.ParsedRule[] rules
---@return string[] errors  parse errors and ID collisions, in encounter order
function M.load(ruleset_paths)
  local by_id = {}
  local rules = {}
  local errors = {}
  -- Two `ruleset_paths` entries can reach the same file (a directory and a
  -- file inside it, or the same directory listed twice) -- dedupe on the
  -- canonical absolute path so that isn't reported as a real duplicate id.
  local seen_files = {}
  local retired_files = {}

  --- `:p` makes it absolute; `vim.fs.normalize` forces "/"-separators --
  --- needed on Windows, where `globpath` and a hand-built path can name
  --- the same file with different slash directions and compare unequal.
  ---@param file string
  ---@return string
  local function canonical_of(file)
    return vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
  end

  local retired_paths = {}
  for _, path in ipairs(ruleset_paths or {}) do
    local found, path_err = scan(path)
    if path_err then
      errors[#errors + 1] = path_err
    end
    for _, file in ipairs(found.live) do
      local canonical = canonical_of(file)
      if not seen_files[canonical] then
        seen_files[canonical] = true
        local file_rules, file_errors = parser.extract_rules(file)
        vim.list_extend(errors, file_errors)
        if found.strict[file] then
          vim.list_extend(errors, audit_rule_file(file, #file_rules > 0, #file_errors > 0))
        end
        for _, rule in ipairs(file_rules) do
          local existing = by_id[rule.id]
          if existing then
            errors[#errors + 1] = ("duplicate rule id %s: %s:%d and %s:%d"):format(
              rule.id,
              existing.source_file,
              existing.source_line,
              rule.source_file,
              rule.source_line
            )
          else
            by_id[rule.id] = rule
            rules[#rules + 1] = rule
          end
        end
      end
    end
    for _, file in ipairs(found.retired) do
      local canonical = canonical_of(file)
      if not retired_paths[canonical] then
        retired_paths[canonical] = true
        retired_files[#retired_files + 1] = file
      end
    end
  end

  -- the retired rules never run, but their ids are taken: a live rule with one of them is a duplicate, whichever
  -- ruleset holds it (two machines: one retired AAA-05, the other made it again, and git merged without a conflict)
  table.sort(retired_files)
  local retired_by_id = {}
  for _, file in ipairs(retired_files) do
    local entry = read_retired(file)
    vim.list_extend(errors, entry.problems)
    for _, id in ipairs({ entry.id, entry.meta_id }) do
      local live = by_id[id]
      local other = retired_by_id[id]
      if live then
        errors[#errors + 1] = ("duplicate rule id %s: %s:%d and %s (retired)"):format(
          id,
          live.source_file,
          live.source_line,
          entry.file
        )
      elseif other and other ~= entry.file then
        errors[#errors + 1] = ("duplicate rule id %s: %s (retired) and %s (retired)"):format(id, other, entry.file)
      end
      retired_by_id[id] = retired_by_id[id] or entry.file
    end
  end

  return rules, errors
end

return M
