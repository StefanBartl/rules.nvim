---@module 'rules.engine.loader'
---@brief Load rules from every configured ruleset path and merge them.
---@description
--- Refuses a duplicate ID across rulesets — an ID is unique across every
--- ruleset a user has loaded, not just within one file, matching
--- `Checklists/README.md`'s own rule: "IDs werden nie wiederverwendet."

local parser = require("rules.engine.parser")
local fswalk = require("rules.engine.fswalk")
-- SEC-34: `vim.fn.expand()` would also apply shell/`<cfile>`-style specials
-- this is a static config string, not buffer/user text, but the ruleset
-- path is the plugin's own documented `~/path/to/your/checklists` example
-- (README.md, docs/BINDINGS.md), so it has to actually expand `~`/env vars.
local expand_path = require("lib.nvim.cross.fs.expand_path")

local M = {}

--- Every `.md` file reachable from `path` — itself if it already is one.
---@param path string
---@return string[] md_files
---@return string|nil error  set when `path` resolves to neither a directory
---   nor a readable `.md` file -- distinct from a directory that genuinely
---   has zero `.md` files in it, which is not an error (ERR-11)
local function md_files_under(path)
  local expanded = expand_path(path)

  if vim.fn.isdirectory(expanded) == 1 then
    -- `fswalk.files` (a literal `uv.fs_scandir` walk), not `vim.fn.globpath`:
    -- glob-family functions interpret `~`/`[`/`?`/`*`/`{}` in their PATH
    -- argument too, not just the pattern -- a ruleset path containing any of
    -- those (a Windows 8.3 short-name segment under a long-username `%TEMP%`
    -- is the classic real-world case) would silently glob-match nothing,
    -- despite `isdirectory` above confirming the directory genuinely exists.
    -- `fswalk` never interprets `path`, only lists what is actually there.
    local files = {}
    for _, file in ipairs(fswalk.files(expanded)) do
      if file:match("%.md$") then
        files[#files + 1] = file
      end
    end
    return files, nil
  elseif expanded:match("%.md$") then
    if vim.fn.filereadable(expanded) == 1 then
      return { expanded }, nil
    end
    return {}, ("ruleset path %q: not a readable file"):format(path)
  end

  return {}, ("ruleset path %q: not a directory or a readable .md file"):format(path)
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

  for _, path in ipairs(ruleset_paths or {}) do
    local files, path_err = md_files_under(path)
    if path_err then
      errors[#errors + 1] = path_err
    end
    for _, file in ipairs(files) do
      -- `:p` makes it absolute; `vim.fs.normalize` forces "/"-separators --
      -- needed on Windows, where `globpath` and a hand-built path can name
      -- the same file with different slash directions and compare unequal.
      local canonical = vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
      if not seen_files[canonical] then
        seen_files[canonical] = true
        local file_rules, file_errors = parser.extract_rules(file)
        vim.list_extend(errors, file_errors)
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
  end

  return rules, errors
end

return M
