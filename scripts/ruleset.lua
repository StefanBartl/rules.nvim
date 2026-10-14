-- scripts/ruleset.lua -- the headless tools for a ruleset in the one-file-per-rule form.
--
--   nvim --headless -u NONE -i NONE -n -l scripts/ruleset.lua catalog [--check] <ruleset-folder>
--   nvim --headless -u NONE -i NONE -n -l scripts/ruleset.lua migrate [--write] [--rules-dir=D] [--layouts-dir=D] <folder>
--
-- catalog   builds the reading documents from the layouts; with --check it writes nothing and exits 1
--           when a document is out of date (for CI, like `tasks index --check`).
-- migrate   turns the documents with ```rule blocks into one file per rule plus layouts. Without --write it
--           only converts in memory and says what it would do and whether the result reads back byte for
--           byte (apart from the table of contents, which is counted). With --write it writes the files and
--           proves on disk that the documents the generator makes are the ones written. Run it on a clean
--           git tree: the old documents are replaced by the generated ones.
--
-- Exit code: 0 done / up to date, 1 a document is stale or a problem was found, 2 wrong usage or no lib.nvim.
-- lib.nvim is found through $LIB_NVIM_DIR, $LIB_NVIM_PATH, $REPOS_DIR/lib.nvim, .deps/lib.nvim, a sibling
-- checkout, then lazy.nvim's data folder.

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(script)))
vim.opt.rtp:prepend(plugin_root)

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
vim.opt.rtp:append(lib)

local function usage()
  io.stderr:write(
    "usage: ruleset.lua catalog [--check] <folder> | migrate [--write] [--rules-dir=D] [--layouts-dir=D] <folder>\n"
  )
  os.exit(2)
end

local command = arg[1]
local flags, positional = {}, {}
for i = 2, #arg do
  local key, value = arg[i]:match("^%-%-([%w%-]+)=?(.*)$")
  if key then
    flags[key] = value ~= "" and value or true
  else
    positional[#positional + 1] = arg[i]
  end
end
if (command ~= "catalog" and command ~= "migrate") or #positional ~= 1 then
  usage()
end
local root = positional[1]

if command == "catalog" then
  local catalog = require("rules.engine.catalog")
  local results, load_errors = catalog.build(root, { check = flags.check == true })
  local code = 0
  for _, result in ipairs(results) do
    io.stdout:write(("%-9s %s\n"):format(result.status, result.output))
    if result.status == "stale" or result.status == "error" then
      code = 1
    end
    for _, problem in ipairs(result.problems) do
      io.stdout:write("  problem: " .. problem .. "\n")
      code = 1
    end
    for _, id in ipairs(result.unused or {}) do
      io.stdout:write("  note: rule " .. id .. " is in no layout\n")
    end
  end
  for _, err in ipairs(load_errors) do
    io.stdout:write("  load error: " .. err .. "\n")
    code = 1
  end
  if #results == 0 then
    io.stdout:write("no layouts found under " .. root .. "\n")
  end
  os.exit(code)
end

local migrate = require("rules.engine.migrate")
local report = migrate.run(root, {
  write = flags.write == true,
  rules_dir = type(flags["rules-dir"]) == "string" and flags["rules-dir"] or nil,
  layouts_dir = type(flags["layouts-dir"]) == "string" and flags["layouts-dir"] or nil,
})
local rules = 0
for _, c in ipairs(report.conversions) do
  rules = rules + #c.rule_files
  io.stdout:write(
    ("%-40s rules=%3d  table of contents: %s%s\n"):format(
      c.output,
      #c.rule_files,
      c.toc,
      c.toc == "differs" and (" (%d lines change)"):format(c.toc_lines_changed) or ""
    )
  )
end
io.stdout:write(
  ("%d document(s), %d rule(s)%s\n"):format(
    #report.conversions,
    rules,
    flags.write == true and (", %d file(s) written"):format(#report.written) or " (nothing written: add --write)"
  )
)
for _, problem in ipairs(report.problems) do
  io.stdout:write("problem: " .. problem .. "\n")
end
os.exit(#report.problems > 0 and 1 or 0)
