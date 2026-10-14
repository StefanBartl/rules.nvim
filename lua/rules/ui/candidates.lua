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
    return (require("rules.contract").view(nil))
  end)
  return ok and result or nil
end

---Distinct values of `field` over the rules, sorted.
---@param field "id"|"family"
---@return string[]
local function column(field)
  local scan = view()
  if not scan then
    return {}
  end
  local seen, out = {}, {}
  for _, rule in ipairs(scan.rules) do
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

---The ids of the loaded rules.
---@return string[]
function M.ids()
  return column("id")
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

---The places that start with `lead`: the layouts' `output` paths until a `#` is typed, then the headings of that
---layout.
---@param lead string
---@return string[]
function M.places(lead)
  local all = layouts()
  local out = {}
  local file = lead:match("^([^#]*)#")
  if file then
    for _, heading in ipairs(all[file] or {}) do
      local candidate = file .. "#" .. escape(heading)
      if candidate:sub(1, #lead) == lead then
        out[#out + 1] = candidate
      end
    end
    return out
  end
  for _, output in ipairs(M.layout_outputs()) do
    if output:sub(1, #lead) == lead then
      out[#out + 1] = output
    end
  end
  return out
end

---Forget what was kept (the specs, after they wrote a layout).
function M.reset()
  places_cache = nil
end

return M
