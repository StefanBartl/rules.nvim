-- scripts/roundtrip.lua -- does the writer keep a ruleset byte for byte? (read only, writes nothing)
--
--   nvim --headless -u NONE -i NONE -n -l scripts/roundtrip.lua <ruleset-folder> [<ruleset-folder> ...]
--
-- For every rule file (the one-file-per-rule form) of the folders:
--   * a patch that says what is there (`severity`, `text`) gives the same bytes back;
--   * changing the severity, the title and the text and changing it back gives the same bytes back;
--   * the changed text reads back as written.
-- A folder that does not load without errors fails as well (`load error:` lines count as `failed`): an empty rule
-- file, one with merge-conflict markers or none of the frontmatter, a live and a retired rule with one id. Without
-- that such a file would be passed over as "no rule file".
-- This is the property `rules-ops/1` `set` is built on (`rules.engine.rule_edit`); run it on a real ruleset
-- before trusting a write on it. Exit code: 0 all held, 1 a property failed, 2 wrong usage or no lib.nvim.
-- lib.nvim is found through $LIB_NVIM_DIR, $LIB_NVIM_PATH, $REPOS_DIR/lib.nvim, .deps/lib.nvim, a sibling
-- checkout, then lazy.nvim's data folder.

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(script)))
vim.opt.rtp:prepend(vim.fn.escape(plugin_root, ","))

---@param dir string|nil
---@return boolean
local function has_lib(dir)
  return dir ~= nil and dir ~= "" and vim.fn.isdirectory(dir .. "/lua/lib/nvim") == 1
end

---@return string|nil
local function find_lib()
  local repos = vim.env.REPOS_DIR
  local candidates = {
    LIB_NVIM_DIR = vim.env.LIB_NVIM_DIR,
    LIB_NVIM_PATH = vim.env.LIB_NVIM_PATH,
    REPOS_DIR = (repos and repos ~= "") and (repos .. "/lib.nvim") or nil,
    deps = plugin_root .. "/.deps/lib.nvim",
    sibling = vim.fs.dirname(plugin_root) .. "/lib.nvim",
    lazy = vim.fn.stdpath("data") .. "/lazy/lib.nvim",
  }
  for _, key in ipairs({ "LIB_NVIM_DIR", "LIB_NVIM_PATH", "REPOS_DIR", "deps", "sibling", "lazy" }) do
    if has_lib(candidates[key]) then
      return candidates[key]
    end
  end
  return nil
end

local lib = find_lib()
if not lib then
  io.stderr:write("error: lib.nvim not found (set LIB_NVIM_DIR, or REPOS_DIR with a lib.nvim checkout)\n")
  os.exit(2)
end
vim.opt.rtp:append(vim.fn.escape(lib, ","))

local dirs = {}
for i = 1, #_G.arg do
  dirs[#dirs + 1] = _G.arg[i]
end
if #dirs == 0 then
  io.stderr:write("usage: roundtrip.lua <ruleset-folder> [<ruleset-folder> ...]\n")
  os.exit(2)
end

local loader = require("rules.engine.loader")
local parser = require("rules.engine.parser")
local rule_edit = require("rules.engine.rule_edit")
local fswalk = require("rules.engine.fswalk")

---@param path string
---@return string
local function read(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local files, refused, failed = 0, {}, {}

for _, dir in ipairs(dirs) do
  -- a file the loader cannot read as a rule (an empty one, one with merge-conflict markers, one with no frontmatter under
  -- `_rules/`) would otherwise be passed over below as "no rule file": the folder has to load without errors, each
  -- on its own (a duplicate id across two folders is for `ruleset.lua check`)
  local _, load_errors = loader.load({ dir })
  for _, err in ipairs(load_errors) do
    failed[#failed + 1] = "load error: " .. err
  end
  for _, file in ipairs(fswalk.files(dir)) do
    local name = file:match("[^/]+$")
    if file:match("%.md$") and not file:find("/_retired/", 1, true) then
      local text = read(file)
      local normal = (text:gsub("\r\n", "\n"))
      if parser.classify(vim.split(normal, "\n", { plain = true })) == "rule" then
        files = files + 1
        local rule = parser.parse_rule_text(file, normal)
        if rule then
          ---@param label string
          ---@param ok boolean
          local function check(label, ok)
            if not ok then
              failed[#failed + 1] = ("%s: %s"):format(name, label)
            end
          end
          ---@param label string
          ---@param patch table
          ---@param undo table
          ---@param reads fun(read_back: table): boolean
          local function round(label, patch, undo, reads)
            local changed, why = rule_edit.apply(file, text, patch)
            if not changed then
              refused[#refused + 1] = ("%s %s: %s"):format(name, label, tostring(why))
              return
            end
            local back = rule_edit.apply(file, changed, undo)
            check(label .. " and back", back == text)
            local again = parser.parse_rule_text(file, (changed:gsub("\r\n", "\n")))
            check(label .. " reads back", again ~= nil and reads(again))
          end

          local same = rule_edit.apply(file, text, { severity = rule.severity, text = rule.text })
          check("a patch of what is there", same == text)

          local other = rule.severity == "critical" and "recommended" or "critical"
          round("severity", { severity = other }, { severity = rule.severity }, function(r)
            return r.severity == other
          end)
          local retitled = ("`%s` — retitled"):format(rule.id)
          round("title", { title = retitled }, { title = rule.title or "" }, function(r)
            return r.title == retitled
          end)
          local longer = rule.text .. "\n\nAn added paragraph."
          round("text", { text = longer }, { text = rule.text }, function(r)
            return r.text == longer
          end)
        end
      end
    end
  end
end

print(("rule files: %d, refused: %d, failed: %d"):format(files, #refused, #failed))
for i = 1, math.min(10, #refused) do
  print("  refused: " .. refused[i])
end
for i = 1, math.min(10, #failed) do
  print("  FAILED: " .. failed[i])
end
os.exit(#failed == 0 and 0 or 1)
