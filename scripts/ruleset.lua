-- scripts/ruleset.lua -- the headless tools for a ruleset in the one-file-per-rule form.
--
--   nvim --headless -u NONE -i NONE -n -l scripts/ruleset.lua catalog [--check] [OPTIONS] [<ruleset-folder>]
--   nvim --headless -u NONE -i NONE -n -l scripts/ruleset.lua check [CHECKS] [OPTIONS] [<ruleset-folder>]
--   nvim --headless -u NONE -i NONE -n -l scripts/ruleset.lua migrate [--write] [--rules-dir=D] [--layouts-dir=D] [OPTIONS] <dir>
--
-- OPTIONS  --vault=D --project=D --trust=D (repeatable)
-- CHECKS   (check only) --waivers [--today=YYYY-MM-DD]   --gaps | --strict-gaps
--
-- The folder may be `@vault/<name>`, a ruleset of the rules-vault (`--vault=D`, else `$RULES_VAULT`, else `vault` in the
-- `.rules.json` of `--project=D` / `$RULES_PROJECT`). `catalog` without a folder builds every ruleset the settings
-- name: the project file, else the vault's own list, else every folder under `<vault>/rulesets/` (`rules.settings`). A
-- configured ruleset that is not a folder (a folder renamed, a path that is a file) is a problem, never dropped
-- silently. A folder named here wins over a stale `$RULES_VAULT`: the vault is only needed for `@vault/<name>` and for the
-- rulesets that nobody names. `--trust=D` (repeatable, also `$RULES_TRUST`) trusts the rulesets under D: no command here
-- runs a check, the flag is the same as for `scripts/rules.lua`.
--
-- catalog   builds the reading documents from the layouts; with --check it writes nothing and exits 1
--           when a document is out of date (for CI, like `tasks index --check`).
-- check     loads every ruleset together (the snapshot document of `rules-export/1`) and exits 1 on any `load_errors`:
--           a duplicate rule id (also across two rulesets, and between a live and a retired rule), an invalid severity,
--           a rule file that does not read, a file under `_rules/` that yields no rule (empty, merge-conflict
--           markers, no frontmatter), a retired file that does not read, a configured ruleset that is no folder.
--           With `--vault=D` and no folder it checks every ruleset the vault offers (its own list, else every folder
--           under rulesets/) and warns about the folders under rulesets/ that the vault file leaves out.
--           Writes nothing; this is the "loads without errors" step of the CI of a rules-vault
--           (templates/rules-vault-ci.yml).
--           With `--waivers` it also reads the `.rules-waivers.json` of the project (`--project=D` or $RULES_PROJECT is
--           required) and exits 1 when that file cannot be used or a waiver in it has EXPIRED (its `expires` day is
--           before today; docs/BINDINGS.md "Waivers"). A waiver for an id no ruleset has is a note, not a failure.
--           `--today=YYYY-MM-DD` judges the expiry as of that day (a reproducible run); default: today's date.
--           With `--gaps` it also lists, as notes, the numbers a family skips between its smallest and largest id
--           (DEP-01 and DEP-03 with no DEP-02; a retired rule keeps its number, so it leaves no gap). It is a hint
--           and exits 0: gaps appear legitimately (a rule deleted instead of retired, a ruleset that numbers in
--           blocks on purpose), so nothing is said without the flag. `--strict-gaps` lists them too and exits 1
--           when there is one, for a vault that numbers without holes. It judges the folders being checked together:
--           name a folder to leave the others out.
-- migrate   turns the documents with ```rule blocks into one file per rule plus layouts. Without --write it
--           only converts in memory and says what it would do and whether the result reads back byte for
--           byte (apart from the table of contents, which is counted). With --write it writes the files and
--           proves on disk that the documents the generator makes are the ones written; if a write or that
--           proof fails, everything the run wrote is taken back. Run it on a clean git tree: the old
--           documents are replaced by the generated ones.
--
-- Exit code: 0 done / up to date, 1 a document is stale or a problem was found, 2 wrong usage (an unknown flag,
-- a flag with a value it does not take, a missing value) or no lib.nvim.
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
    "usage: ruleset.lua catalog [--check] [--vault=D] [--project=D] [--trust=D] [<folder>] | "
      .. "check [--waivers [--today=YYYY-MM-DD]] [--gaps|--strict-gaps] [--vault=D] [--project=D] [--trust=D] [<folder>] | "
      .. "migrate [--write] [--rules-dir=D] [--layouts-dir=D] [--vault=D] [--project=D] [--trust=D] <folder>\n"
  )
  os.exit(2)
end

--- The flags each command knows: "bool" takes no value, "value" needs one, "multi" needs one and may be given again.
--- Anything else is wrong usage: a typo such as `--chek` must not run the command without the flag (that would write
--- the documents `--check` is there to check).
local FLAGS = {
  catalog = { check = "bool", vault = "value", project = "value", trust = "multi" },
  check = {
    vault = "value",
    project = "value",
    trust = "multi",
    waivers = "bool",
    today = "value",
    gaps = "bool",
    ["strict-gaps"] = "bool",
  },
  migrate = {
    write = "bool",
    ["rules-dir"] = "value",
    ["layouts-dir"] = "value",
    vault = "value",
    project = "value",
    trust = "multi",
  },
}

local command = arg[1]
local known = FLAGS[command]
if not known then
  usage()
end
local flags, positional = {}, {}
for i = 2, #arg do
  local a = arg[i]
  if a:sub(1, 2) == "--" then
    local key, value = a:match("^%-%-([^=]+)=(.*)$")
    if not key then
      key = a:match("^%-%-([^=]+)$")
    end
    local kind = key and known[key]
    local takes_value = kind == "value" or kind == "multi"
    if not kind or (kind == "bool" and value ~= nil) or (takes_value and (value == nil or value == "")) then
      usage()
    end
    if kind == "multi" then
      flags[key] = flags[key] or {}
      table.insert(flags[key], value)
    else
      flags[key] = value or true
    end
  else
    positional[#positional + 1] = a
  end
end
if #positional > 1 or (#positional == 0 and command ~= "catalog" and command ~= "check") then
  usage()
end
-- `--waivers` judges the `.rules-waivers.json` of a project, so it needs one; `--today` only means something with it
local waivers_project = flags.project or vim.env.RULES_PROJECT
if flags.waivers and (not waivers_project or waivers_project == "") then
  io.stderr:write("error: --waivers checks the waivers of a project: give --project=D (or set $RULES_PROJECT)\n")
  os.exit(2)
end
if flags.today and not flags.waivers then
  usage()
end

-- the folders to work on: the one given (`@vault/<name>` through the vault), or for `catalog` and `check` every
-- ruleset the settings name
local settings = require("rules.settings")
local settings_opts = { vault = flags.vault, project = flags.project or vim.env.RULES_PROJECT, trust = flags.trust }
local expand_path = require("lib.nvim.cross.fs.expand_path")
local roots = {}
-- findings about the configured rulesets themselves (a folder that is not there): the run goes on, then fails
local missing = {}
-- notes that do not fail the run
local notes = {}

if #positional == 1 then
  local path, err = settings.resolve_entry(positional[1], settings_opts)
  if not path then
    io.stderr:write("error: " .. err .. "\n")
    os.exit(2)
  end
  roots[1] = path
else
  -- with `--vault=D` the vault is the subject of `check` (the CI of a vault): what the vault offers, whatever else
  -- names rulesets
  local res = settings.resolve(vim.tbl_extend("force", settings_opts, { need_vault = flags.vault ~= nil }))
  settings.notify(res)
  local err = settings.error_text(res, false)
  if err then
    io.stderr:write("error: " .. err .. "\n")
    os.exit(2)
  end
  local offered = {}
  if command == "check" and flags.vault and res.vault and res.vault.exists then
    for _, folder in ipairs(res.vault.loaded or res.vault.rulesets) do
      offered[#offered + 1] = { path = folder, name = vim.fs.basename(folder), origin = "vault" }
    end
    -- the vault file narrows the list: the folders it leaves out are not checked here, though the CI of a vault globs them
    local listed = {}
    for _, folder in ipairs(res.vault.loaded or {}) do
      listed[#listed + 1] = vim.fs.normalize(folder)
    end
    for _, folder in ipairs(res.vault.rulesets) do
      if not vim.tbl_contains(listed, vim.fs.normalize(folder)) then
        notes[#notes + 1] = ("warning: %s/%s is not listed in the .rules.json of the vault: it is not checked here"):format(
          settings.VAULT_SUBDIR,
          vim.fs.basename(folder)
        )
      end
    end
  else
    for _, entry in ipairs(res.entries) do
      offered[#offered + 1] = entry
    end
  end
  for _, entry in ipairs(offered) do
    if vim.fn.isdirectory(expand_path(entry.path)) == 1 then
      roots[#roots + 1] = entry.path
    else
      missing[#missing + 1] = settings.not_a_folder_text(entry)
    end
  end
  if #roots == 0 and #missing == 0 then
    io.stderr:write("error: no ruleset folder is configured: name one, or " .. settings.NO_VAULT_HINT .. "\n")
    os.exit(2)
  end
end
local root = roots[1]

---Print what the configured rulesets turned up, and the code the run exits with because of it.
---@return integer code
local function say_findings()
  for _, line in ipairs(notes) do
    io.stdout:write(line .. "\n")
  end
  for _, line in ipairs(missing) do
    io.stdout:write("  problem: " .. line .. "\n")
  end
  return #missing > 0 and 1 or 0
end

if command == "check" then
  if #roots == 0 then
    say_findings()
    io.stdout:write("FAILED: no configured ruleset is a folder\n")
    os.exit(1)
  end
  -- all rulesets together, through the snapshot document: a duplicate id across two rulesets is only seen this way.
  -- `vault` goes along: an explicit vault wins over $RULES_VAULT, and a stale $RULES_VAULT breaks nothing here
  local text, failure = require("rules.api").call("snapshot", nil, { rulesets = roots, vault = flags.vault, trust = flags.trust })
  local ok, doc = pcall(vim.json.decode, text)
  if failure ~= nil or not ok or type(doc) ~= "table" or doc.kind ~= "rules.snapshot" then
    io.stdout:write("FAILED: the rulesets could not be read: " .. tostring(text):sub(1, 400) .. "\n")
    os.exit(1)
  end
  for _, err in ipairs(doc.load_errors or {}) do
    io.stdout:write("  load error: " .. err .. "\n")
  end
  local counts = doc.counts or {}
  io.stdout:write(
    ("%d rule(s) in %d file(s), %d family(ies), %d ruleset(s)\n"):format(
      counts.rules or 0,
      counts.files or 0,
      counts.families or 0,
      #roots
    )
  )
  local code = say_findings()
  if #(doc.load_errors or {}) > 0 then
    io.stdout:write(("FAILED: %d load error(s)\n"):format(#doc.load_errors))
    os.exit(1)
  end
  if code ~= 0 then
    io.stdout:write("FAILED: a configured ruleset is not a folder\n")
    os.exit(code)
  end
  if flags.gaps or flags["strict-gaps"] then
    -- a hint about the numbering, apart from the load errors: asked for, never part of the snapshot document
    local gaps_mod = require("rules.engine.gaps")
    local found, gaps_err = require("rules.contract").gaps({ rulesets = roots, vault = flags.vault, trust = flags.trust })
    if not found then
      io.stdout:write("FAILED: the numbering could not be read: " .. tostring(gaps_err and gaps_err.message or gaps_err) .. "\n")
      os.exit(1)
    end
    local strict = flags["strict-gaps"] == true
    for _, gap in ipairs(found) do
      io.stdout:write(("  %s: %s\n"):format(strict and "gap" or "note", gaps_mod.text(gap)))
    end
    io.stdout:write(("%d number(s) not taken in %d family(ies)\n"):format(gaps_mod.total(found), #found))
    if strict and #found > 0 then
      io.stdout:write(("FAILED: %d family(ies) skip numbers (--strict-gaps)\n"):format(#found))
      os.exit(1)
    end
  end
  if flags.waivers then
    -- the waivers of the project (`rules.waivers`): a file that cannot be used or a waiver that ran out fails the run
    local wtext, wfailure = require("rules.api").call("waivers", nil, {
      rulesets = roots,
      vault = flags.vault,
      trust = flags.trust,
      project = waivers_project,
      today = type(flags.today) == "string" and flags.today or nil,
    })
    local wok, wdoc = pcall(vim.json.decode, wtext)
    if wfailure ~= nil or not wok or type(wdoc) ~= "table" or wdoc.kind ~= "rules.waivers" then
      local message = wok and type(wdoc) == "table" and wdoc.message or tostring(wtext):sub(1, 400)
      io.stdout:write("FAILED: the waivers could not be read: " .. tostring(message) .. "\n")
      os.exit(1)
    end
    local expired = 0
    for _, item in ipairs(wdoc.items) do
      if item.expired then
        expired = expired + 1
        io.stdout:write(("  expired waiver: %s ran out on %s (%s)\n"):format(item.id, item.expires, item.reason))
      elseif not item.known then
        io.stdout:write(("  note: the waiver for %s matches no loaded rule\n"):format(item.id))
      end
    end
    io.stdout:write(("%d waiver(s) as of %s, %d expired\n"):format(wdoc.counts.total, wdoc.today, expired))
    if expired > 0 then
      io.stdout:write(("FAILED: %d expired waiver(s): renew or remove them\n"):format(expired))
      os.exit(1)
    end
  end
  io.stdout:write("ok: every ruleset loads without errors\n")
  os.exit(0)
end

if command == "catalog" then
  local catalog = require("rules.engine.catalog")
  local code = say_findings()
  for _, folder in ipairs(roots) do
    local results, load_errors = catalog.build(folder, { check = flags.check == true })
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
      io.stdout:write("no layouts found under " .. folder .. "\n")
    end
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
  if #c.problems > 0 then
    io.stdout:write(("%-40s refused (see the problems below)\n"):format(c.output))
  else
    io.stdout:write(
      ("%-40s rules=%3d  table of contents: %s%s\n"):format(
        c.output,
        #c.rule_files,
        c.toc,
        c.toc == "differs" and (" (%d lines change)"):format(c.toc_lines_changed) or ""
      )
    )
  end
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
if report.rolled_back then
  io.stdout:write("everything this run wrote was taken back; fix the cause and run it again\n")
end
os.exit(#report.problems > 0 and 1 or 0)
