---@module 'rules.ui.candidates'
---@brief What `<Tab>` offers for the arguments of `:Rules`: families, ids, places -- read live, never an error.
---@description
--- Read from the scan of the rulesets (`rules.contract.view`, which is kept while no `.md` file changes, so a `<Tab>`
--- does not parse the rulesets again and does not notify about a load error on every key). Completion fails soft:
--- no ruleset, a scan that fails, a ruleset that is a single file: no candidates, never an error in the middle of
--- typing.
---
--- The places are the layouts of the folders in `rulesets` (`rules.ops.layouts`): `<output>#<heading>`, a blank in a
--- heading written as `\ ` the way the command line wants it. Reading the layouts is a walk over the folder, so the
--- answer is kept for a couple of seconds.
---
--- Not its job: what a candidate means (the argument types in `rules.bindings.usrcmds`).

local M = {}

---How long the places are kept.
M.TTL_SECONDS = 2

---@type { at: integer, key: string, places: table<string, string[]> }|nil
local places_cache

---@return Rules.Contract.View|nil
local function view()
  local ok, result = pcall(function()
    local contract = require("rules.contract")
    return (contract.view(contract.editor_opts()))
  end)
  return ok and result or nil
end

---Distinct values of `field` over the loaded rules (or over the retired ones), sorted.
---@param field "id"|"family"
---@param retired? boolean  the retired rules of the scan, not the loaded ones
---@return string[]
local function column(field, retired)
  local scan = view()
  if not scan then
    return {}
  end
  local seen, out = {}, {}
  for _, rule in ipairs(retired and (scan.retired or {}) or scan.rules) do
    local value = rule[field]
    if value and not seen[value] then
      seen[value] = true
      out[#out + 1] = value
    end
  end
  table.sort(out)
  return out
end

---The families of the loaded rules.
---@return string[]
function M.families()
  return column("family")
end

---Whether a rule of the family exists in any ruleset, loaded or retired (a retired rule keeps its number, so its
---family is not a new one). When the rulesets cannot be read the answer is `true`: nobody is asked about a family on
---the strength of a scan that failed.
---@param family string
---@return boolean
function M.family_known(family)
  local scan = view()
  if not scan then
    return true
  end
  for _, list in ipairs({ scan.rules, scan.retired or {} }) do
    for _, rule in ipairs(list) do
      if rule.family == family then
        return true
      end
    end
  end
  return false
end

---The ids of the loaded rules.
---@return string[]
function M.ids()
  return column("id")
end

---The ids of the retired rules that no loaded rule has again: the ones `:Rules reinstate` can bring back. (An id that is
---loaded AND retired - a file in `_retired/` of a rule that was made again - is no candidate: the door refuses it.)
---@return string[]
function M.retired_ids()
  local loaded = {}
  for _, id in ipairs(column("id")) do
    loaded[id] = true
  end
  return vim.tbl_filter(function(id)
    return not loaded[id]
  end, column("id", true))
end

---The names the rulesets go by in a document.
---@return string[]
function M.ruleset_names()
  local scan = view()
  if not scan then
    return {}
  end
  local out = {}
  for _, path in ipairs(scan.paths) do
    out[#out + 1] = scan.names[path]
  end
  return out
end

---The heading texts of a layout, in the order they stand (the frontmatter and fenced code are left out).
---@param text string
---@return string[]
local function headings(text)
  local out = {}
  local in_front, in_fence = false, false
  for i, line in ipairs(vim.split((text:gsub("\r", "")), "\n", { plain = true })) do
    if i == 1 and line == "---" then
      in_front = true
    elseif in_front then
      in_front = line ~= "---"
    elseif line:match("^```") or line:match("^~~~") then
      in_fence = not in_fence
    elseif not in_fence then
      local heading = line:match("^#+%s+(.-)%s*$")
      if heading and heading ~= "" then
        out[#out + 1] = heading
      end
    end
  end
  return out
end
M.headings = headings

---Every layout of every ruleset folder: `output` path -> its headings.
---@return table<string, string[]> layouts
local function layouts()
  local scan = view()
  if not scan then
    return {}
  end
  local key = table.concat(scan.paths, "\n")
  local now = (vim.uv.now() or 0)
  if places_cache and places_cache.key == key and now - places_cache.at < M.TTL_SECONDS * 1000 then
    return places_cache.places
  end
  local out = {}
  local ops = require("rules.ops")
  for _, path in ipairs(scan.paths) do
    for _, layout in ipairs(ops.layouts(path)) do
      out[layout.output] = headings(layout.text)
    end
  end
  places_cache = { at = now, key = key, places = out }
  return out
end

---The `output` paths of the layouts.
---@return string[]
function M.layout_outputs()
  local out = vim.tbl_keys(layouts())
  table.sort(out)
  return out
end

---A blank in a place is written `\ ` on the command line.
---@param text string
---@return string
local function escape(text)
  return (text:gsub(" ", "\\ "))
end

---A text as ONE word of the command line (a blank, a tab or a backslash in it marked), for a name the user did not type.
---@param text string
---@return string
local function as_word(text)
  return require("rules.cmdline").escape(text)
end

---The places that start with `lead`: the layouts' `output` paths until a `#` is typed, then the headings of that
---layout.
---@param lead string
---@return string[]
function M.places(lead)
  local all = layouts()
  local out = {}
  local typed = lead:match("^([^#]*)#")
  if typed then
    -- the layout is found by its name, the way it is written on the line (a blank as `\ `) is not that name
    local file = require("rules.cmdline").unescape(typed)
    for _, heading in ipairs(all[file] or {}) do
      local candidate = as_word(file) .. "#" .. escape(heading)
      if candidate:sub(1, #lead) == lead then
        out[#out + 1] = candidate
      end
    end
    return out
  end
  for _, output in ipairs(M.layout_outputs()) do
    local candidate = as_word(output)
    if candidate:sub(1, #lead) == lead then
      out[#out + 1] = candidate
    end
  end
  return out
end

---The heading texts of every layout (each once, in the order they are found) that start with `lead`, a blank written
---`\ ` as the command line wants it: what `--section=` offers. Which layout the heading belongs to is not known at
---that point of the line (`--layout=` may come after it), so all of them are offered.
---@param lead string
---@return string[]
function M.sections(lead)
  local all = layouts()
  local outputs = vim.tbl_keys(all)
  table.sort(outputs)
  local seen, out = {}, {}
  for _, output in ipairs(outputs) do
    for _, heading in ipairs(all[output]) do
      local candidate = escape(heading)
      if not seen[candidate] and candidate:sub(1, #lead) == lead then
        seen[candidate] = true
        out[#out + 1] = candidate
      end
    end
  end
  return out
end

---The `output` paths of the layouts that start with `lead`: what `--layout=` offers, a blank written `\ ` as the command
---line wants it (the lead is compared the way it was typed, so `my\ d` finds `my docs/x.md`).
---@param lead string
---@return string[]
function M.layouts(lead)
  local out = {}
  for _, output in ipairs(M.layout_outputs()) do
    local candidate = as_word(output)
    if candidate:sub(1, #lead) == lead then
      out[#out + 1] = candidate
    end
  end
  return out
end

---The project folder a command line names with `--project=` (the last one), as typed.
---@param cmd_line string|nil
---@return string|nil
local function project_word(cmd_line)
  local cmdline = require("rules.cmdline")
  local given
  for _, word in ipairs(cmdline.words(cmd_line or "")) do
    local value = cmdline.unescape(word.text):match("^%-%-project=(.*)$")
    if value ~= nil then
      given = value
    end
  end
  return given
end

---The ids that have a waiver in the project: the ones `:Rules renew` and `:Rules unwaive` work on. The project is the one
---the command line names (`--project=`), else the one the command would take (`rules.ui.project`). Read from the file on
---every call (it is small and may have been written a moment ago); a project the door would refuse and a file that cannot
---be used are no candidates, never an error.
---@param cmd_line? string  the command line as typed so far
---@return string[]
function M.waived_ids(cmd_line)
  local ok, out = pcall(function()
    local project = require("rules.ui.project")
    local dir = project.dir(project.request(project_word(cmd_line)))
    if not dir then
      return {}
    end
    local entries = require("rules.engine.waivers").load_entries(dir)
    local ids = vim.tbl_keys(entries)
    table.sort(ids)
    return ids
  end)
  return ok and out or {}
end

---The folders `--project=` offers: the sub-folders of the lead (a blank written `\ ` the way the command line wants it).
---@param lead string
---@return string[]
function M.project_dirs(lead)
  local plain = require("rules.cmdline").unescape(lead)
  -- a backtick is a command substitution to the wildcard expansion of the editor: a folder called like one must not run
  if plain:find("`", 1, true) then
    return {}
  end
  local ok, list = pcall(vim.fn.getcompletion, plain, "dir")
  if not ok then
    return {}
  end
  return vim.tbl_map(function(dir)
    -- the editor ends a folder with the separator of the system; on Windows that is a backslash, and a backslash before
    -- the blank that follows (` --dry`) is an escaped blank: the next word would be part of the folder. `/` is a
    -- separator there too.
    if vim.fn.has("win32") == 1 then
      dir = dir:gsub("\\", "/")
    end
    return as_word(dir)
  end, list)
end

---Forget what was kept (the specs, after they wrote a layout).
function M.reset()
  places_cache = nil
end

return M
