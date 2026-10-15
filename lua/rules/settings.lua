---@module 'rules.settings'
---@brief What a run actually uses: `rulesets`, `gates` and `agent` from every place that can name them, ranked in one spot.
---@description
--- The places, highest first (`RANK`, the one definition of the order -- nothing else ranks):
---
---   call      the options of a headless entry point (`rules.api`, `scripts/rules.lua`, `$RULES_RULESETS`, `$RULES_GATES`)
---   setup     `setup({ ... })`
---   project   `<project>/.rules.json`, the root being checked
---   vault     `<vault>/.rules.json`; without a `rulesets` there, every folder under `<vault>/rulesets/`
---   default   `rules.config.DEFAULTS`
---
--- `rulesets` is taken whole from the highest place that names it. `gates` and `agent` are merged by name
--- (`rules.config.merge`). `lua_predicates` comes from `setup()` only.
---
--- The vault is found, in this order, from `vault` of the call, `setup({ vault })`, `$RULES_VAULT`, then `vault` in the
--- project file. Nothing else: a path is never guessed. Without a vault nothing is wrong -- it is optional -- and
--- `@vault/<name>` in `rulesets` is an error that says so. A vault that is named but not usable (no folder, a
--- `.rules.json` that cannot be read) is a problem only where the result depends on the vault: a call that names its
--- rulesets itself does not break over a stale `$RULES_VAULT` (`opts.need_vault` asks for the vault anyway).
---
--- A file that is there but cannot be used (not JSON, wrong shape, a vault that is no folder) is a PROBLEM: the caller must
--- stop and say it, a broken file never becomes "no settings". Things that are odd but harmless (an unknown key, an
--- absolute path in a file that lives in a repository) are WARNINGS. Both are lists of notes; `format` writes one as
--- text, with the file's path for the user (health, notifications) or without any path of this machine (`portable`: the
--- documents of `rules-export/1`).
---
--- TRUST. A `lua_predicate` check is code, and a ruleset can be somebody else's: a `.rules.json` in a repository that
--- is cloned from elsewhere may name rulesets (`rulesets`) and a vault (`vault`). Every ruleset of a result is therefore
--- tracked with where it came from (`entries`: `call`, `setup`, `project`, `vault`) and whether it is trusted:
---
---   trusted      what the user named himself: the rulesets of a call (the command line of a headless tool),
---                of `setup({ rulesets })`, and the rulesets of a vault named by a call, `setup({ vault })` or
---                `$RULES_VAULT`; and whatever lies under a path of `trust` (`setup({ trust })`, `--trust`, `$RULES_TRUST`)
---   not trusted  every ruleset a project `.rules.json` names (a relative path, `..`, an absolute path, `@vault/<name>`
---                alike), and the rulesets of a vault that a project `.rules.json` names
---
--- `trust_check` answers for a rule file by its real path (a link out of a trusted folder is not trusted).
--- The engine runs a `lua_predicate` only for a trusted file; the other check types do not care.
---
--- Not its job: loading the rules (`rules.engine.loader`), the public vault API (`rules.vault`).

local schema = require("rules.config.schema")
local file_mod = require("rules.config.file")
local merge = require("rules.config.merge")
local DEFAULTS = require("rules.config.DEFAULTS")

local M = {}

---Highest first. The only place that says which place wins.
---@type string[]
M.RANK = { "call", "setup", "project", "vault", "default" }

---The start of a `rulesets` entry that names a ruleset of the vault.
M.VAULT_PREFIX = "@vault/"

---The folder of the vault that holds the rulesets.
M.VAULT_SUBDIR = "rulesets"

---The environment variable that names the vault.
M.ENV_VAULT = "RULES_VAULT"

---The environment variable that lists the folders to trust (the same as `trust`; `;` or `:` separated).
M.ENV_TRUST = "RULES_TRUST"

---What a `lua_predicate` of a ruleset that is not trusted reports: not a pass, not a silent skip. No path of this machine.
M.UNTRUSTED = "not run: ruleset is not trusted (grant it: setup({ trust = { <folder> } }), --trust, or $" .. M.ENV_TRUST .. ")"

---How to get a vault, for a message that says there is none.
M.NO_VAULT_HINT = "setup({ vault = ... }), $" .. M.ENV_VAULT .. ", or vault in the project .rules.json"

---Where a vault came from, as the user would name it.
---@type table<string, string>
M.VAULT_WHERE = {
  call = "the vault option",
  setup = "setup({ vault = ... })",
  env = "$" .. M.ENV_VAULT,
  project = "vault in the project .rules.json",
}

---@class Rules.Settings.Note
---@field who string       what it is about, no path: "project .rules.json", "setup()", "$RULES_VAULT"
---@field text string      no path of this machine
---@field file string|nil  the file it is about (shown to the user, never in a document)
---@field detail string|nil  the rest, with paths of this machine (shown to the user only)
---@field vault boolean|nil   it is about the vault (its folder, its file, its list): `rules.vault` tells it

---@class Rules.Settings.Opts
---@field rulesets? string[]
---@field gates? table<string, string[]>
---@field agent? table
---@field vault? string
---@field project? string
---@field trust? string[]
---@field need_vault? boolean

---@class Rules.Settings.Entry
---@field path string      as in `rulesets`
---@field name string      the entry as it was written (`@vault/lua`), the folder name for a discovered one: no path
---@field origin "call"|"setup"|"project"|"vault"  the place that named it
---@field trusted boolean  whether its `lua_predicate` checks may run
---@field why string|nil   when it is not trusted: who named it

---@class Rules.Settings.Vault
---@field root string       the folder, absolute, `/`-separated
---@field source "call"|"setup"|"env"|"project"
---@field exists boolean    whether it is a folder
---@field rulesets string[] every folder under `<root>/rulesets/`, sorted (empty when it does not exist)
---@field loaded string[]|nil  the rulesets the vault itself offers: the `rulesets` of its own `.rules.json`, else `rulesets`
---   (none when that file cannot be used)
---@field file_problem boolean  its own `.rules.json` cannot be used

---@class Rules.Settings
---@field rulesets string[]
---@field gates table<string, string[]>
---@field agent Rules.AgentOpts
---@field lua_predicates boolean
---@field entries Rules.Settings.Entry[]  `rulesets`, one per path, with where it came from and whether it is trusted
---@field trust string[]       the folders the user trusts (`trust`, `--trust`, $RULES_TRUST), absolute
---@field vault_needed boolean whether this result depends on the vault (see the module header)
---@field vault Rules.Settings.Vault|nil
---@field project Rules.Config.File|nil     the project file, when a project was given
---@field vault_file Rules.Config.File|nil  the file of the vault, when there is a vault
---@field origin { rulesets: string, gates: table<string, string>, agent: table<string, string> }
---@field problems Rules.Settings.Note[]    non-empty: stop and say it
---@field warnings Rules.Settings.Note[]

-- ── notes ────────────────────────────────────────────────────────────────────────────

---@param list Rules.Settings.Note[]
---@param who string
---@param text string
---@param file string|nil
---@param detail string|nil
---@param about_vault boolean|nil
local function note(list, who, text, file, detail, about_vault)
  list[#list + 1] = { who = who, text = text, file = file, detail = detail, vault = about_vault or nil }
end

---@param n Rules.Settings.Note
---@param portable boolean|nil  true: no path of this machine in the text
---@return string
function M.format(n, portable)
  if portable then
    return ("%s: %s"):format(n.who, n.text)
  end
  return ("%s: %s%s"):format(n.file or n.who, n.text, n.detail or "")
end

---@param list Rules.Settings.Note[]
---@param portable boolean|nil
---@param only_vault boolean
---@return string|nil
local function text_of(list, portable, only_vault)
  local lines = {}
  for _, n in ipairs(list) do
    if n.vault or not only_vault then
      lines[#lines + 1] = M.format(n, portable)
    end
  end
  return #lines > 0 and table.concat(lines, "\n") or nil
end

---All problems as one text, `nil` when there are none.
---@param res Rules.Settings
---@param portable boolean|nil
---@return string|nil
function M.error_text(res, portable)
  return text_of(res.problems, portable, false)
end

---The problems that are about the vault (its folder, its `.rules.json`, its list) as one text, `nil` when there are none.
---@param res Rules.Settings
---@param portable boolean|nil
---@return string|nil
function M.vault_error_text(res, portable)
  return text_of(res.problems, portable, true)
end

---@type table<string, true>
local warned = {}

---Whether the "nothing is configured" hint was shown: once per session, not on every command.
local hinted = false

---Forget which warnings and hints were shown (a new `setup()`, and specs).
function M.reset()
  warned = {}
  hinted = false
end

---Whether this is the first time the "nothing is configured" hint is due (it then counts as shown).
---@return boolean
function M.first_hint()
  if hinted then
    return false
  end
  hinted = true
  return true
end

---Show the warnings of a result, each once per session however often the settings are resolved. Not the problems:
---the caller reports those (and stops).
---@param res Rules.Settings
function M.notify(res)
  for _, n in ipairs(res.warnings) do
    local text = M.format(n, false)
    if not warned[text] then
      warned[text] = true
      require("rules.util.notify").warn(text)
    end
  end
end

-- ── paths ────────────────────────────────────────────────────────────────────────────

---Whether a path names a place of ONE machine: absolute, `~`, or an environment variable.
---@param path string
---@return boolean
local function machine_path(path)
  return path:match("^[/\\]") ~= nil
    or path:match("^%a:[/\\]") ~= nil
    or path:match("^%a:$") ~= nil
    or path:match("^~") ~= nil
    or path:match("^[$%%]") ~= nil
end

---@param path string
---@return string
local function trim_slash(path)
  if #path > 1 and not path:match("^%a:/$") then
    path = path:gsub("/+$", "")
  end
  return path
end

---An absolute, `/`-separated path. A relative one starts at `base` (the folder of the file that holds it), or at the
---working directory without one.
---@param path string
---@param base string|nil
---@return string
local function absolute(path, base)
  -- required here, not at the top: loading `lib.nvim.fs.roots` exports environment variables, which `setup()` must not
  local expanded = require("lib.nvim.cross.fs.expand_path")(path)
  if base and not machine_path(path) then
    expanded = base .. "/" .. expanded
  end
  return trim_slash(vim.fs.normalize(vim.fn.fnamemodify(expanded, ":p")))
end

---@param path string
---@return boolean
local function is_dir(path)
  local stat = (vim.uv or vim.loop).fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

---Paths that differ only in case are one folder on Windows and (by default) on macOS.
local CASE_BLIND = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1

---A path as a key to compare by: the real path (a link, a Windows short name, `/var` against `/private/var`), one
---spelling of the separators, no trailing slash, one case where the file system folds it.
---@param path string
---@return string
local function path_key(path)
  local key = trim_slash(require("lib.nvim.fs.normkey")(path))
  if CASE_BLIND then
    key = key:find("[\128-\255]") and vim.fn.tolower(key) or key:lower()
  end
  return key
end

---Whether the key `inner` is `outer` or lies under it.
---@param inner string
---@param outer string
---@return boolean
local function key_within(inner, outer)
  if inner == outer then
    return true
  end
  local prefix = outer:sub(-1) == "/" and outer or (outer .. "/")
  return inner:sub(1, #prefix) == prefix
end

---Every folder under `<vault>/rulesets/`, sorted by name (hidden ones, `.git` and the like, are not rulesets).
---@param root string
---@return string[] folders
---@return boolean has_dir  whether `<root>/rulesets` exists
local function discover(root)
  local uv = vim.uv or vim.loop
  local dir = root .. "/" .. M.VAULT_SUBDIR
  local handle = uv.fs_scandir(dir)
  if not handle then
    return {}, false
  end
  local names = {}
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:sub(1, 1) ~= "." then
      if kind == "link" or kind == nil then
        local stat = uv.fs_stat(dir .. "/" .. name)
        kind = stat and stat.type or nil
      end
      if kind == "directory" then
        names[#names + 1] = name
      end
    end
  end
  table.sort(names)
  local out = {}
  for _, name in ipairs(names) do
    out[#out + 1] = dir .. "/" .. name
  end
  return out, true
end

---The folders `discover` finds, for a caller that must see the same rulesets (`rules.vault_scaffold` asks what a new
---ruleset would join).
---@type fun(root: string): string[], boolean
M.discover_rulesets = discover

---The name after `@vault/`, when it is one that cannot leave `<vault>/rulesets/`.
---@param name string
---@return boolean
local function valid_vault_name(name)
  if name == "" or name:find("[\\:%z]") then
    return false
  end
  for _, segment in ipairs(vim.split(name, "/", { plain = true })) do
    if segment == "" or segment == "." or segment == ".." then
      return false
    end
  end
  return true
end

-- ── the layers ───────────────────────────────────────────────────────────────────────

---@class Rules.Settings.Layer
---@field name string                 one of `RANK`
---@field values table                rulesets?, gates?, agent?, lua_predicates?
---@field base string|nil             the folder relative paths start at (the folder of a file layer)
---@field who string                  for messages
---@field file string|nil
---@field is_file boolean             lives in a file (a path of this machine in it is a warning)

---@param res Rules.Settings
---@param read Rules.Config.File
---@param who string
---@param about_vault boolean|nil
local function file_notes(res, read, who, about_vault)
  for _, problem in ipairs(read.problems) do
    local text = problem.key == "" and problem.message or ("%s %s"):format(problem.key, problem.message)
    note(res.problems, who, text, read.path, nil, about_vault)
  end
  if #read.unknown > 0 then
    local names = {}
    for _, entry in ipairs(read.unknown) do
      names[#names + 1] = schema.unknown_text(entry)
    end
    note(res.warnings, who, "unknown key(s) ignored: " .. table.concat(names, ", "), read.path, nil, about_vault)
  end
end

---Find the vault: the first place that names one. Does not look inside it.
---@param call table
---@param setup table
---@param project Rules.Config.File|nil
---@return string|nil raw
---@return string|nil source
---@return string|nil base  where a relative path starts
local function vault_candidate(call, setup, project)
  if call.vault then
    return call.vault, "call", nil
  end
  if setup.vault then
    return setup.vault, "setup", nil
  end
  local env = vim.env[M.ENV_VAULT]
  if env and env ~= "" then
    return env, "env", nil
  end
  if project and project.config.vault then
    return project.config.vault, "project", project.dir
  end
  return nil, nil, nil
end

---The `rulesets` of one layer as paths: `@vault/<name>` becomes `<vault>/rulesets/<name>`, a relative entry of a file
---starts at the folder of that file, an entry of `setup()` or a call is left as it is (the loader expands it).
---Which entry is meant, for a message that must carry no path: `@vault/<name>` and a relative entry as written, a path
---of this machine by its last segment.
---@param entry string
---@return string
local function entry_name(entry)
  if machine_path(entry) then
    local last = vim.fs.basename((entry:gsub("[/\\]+$", "")))
    return last ~= "" and last or entry
  end
  return entry
end

---@param res Rules.Settings
---@param layer Rules.Settings.Layer
---@param entries string[]
---@return string[] paths
---@return string[] names  the entries as written, no path of this machine: one per path
local function expand_entries(res, layer, entries)
  local out, names = {}, {}
  local vault_ready = res.vault ~= nil and res.vault.exists
  ---@param path string
  ---@param entry string
  local function add(path, entry)
    out[#out + 1] = path
    names[#names + 1] = entry_name(entry)
  end
  for _, entry in ipairs(entries) do
    if entry == "@vault" or entry:sub(1, #M.VAULT_PREFIX) == M.VAULT_PREFIX then
      res.vault_needed = true
      local name = entry:sub(#M.VAULT_PREFIX + 1)
      if entry == "@vault" or not valid_vault_name(name) then
        local text = ('rulesets entry %q: write "@vault/<name>", a folder name under the vault\'s %s/'):format(
          entry,
          M.VAULT_SUBDIR
        )
        note(res.problems, layer.who, text, layer.file, nil, layer.name == "vault")
      elseif res.vault ~= nil and not vault_ready then
        -- the vault is named but is no folder: that is the problem, said once, by the vault itself
        res.vault_needed = true
      elseif not vault_ready then
        local text = ("rulesets entry %q needs a vault, and none is found: %s"):format(entry, M.NO_VAULT_HINT)
        note(res.problems, layer.who, text, layer.file)
      else
        add(res.vault.root .. "/" .. M.VAULT_SUBDIR .. "/" .. name, entry)
      end
    elseif layer.is_file then
      local own = machine_path(entry)
      local path = own and entry or (layer.base .. "/" .. entry)
      if own then
        local text = 'a rulesets entry is a path of this machine; use a path relative to the file, or "@vault/<name>"'
        if layer.name == "project" then
          text = text .. " (outside the project its lua_predicate checks do not run, see trust)"
        end
        note(res.warnings, layer.who, text, layer.file, (': "%s"'):format(entry), layer.name == "vault")
      elseif layer.name == "project" and not key_within(path_key(absolute(path)), path_key(layer.base)) then
        local text = "a rulesets entry leaves the project folder; it is used, but its lua_predicate checks do not run,"
          .. " see trust"
        note(res.warnings, layer.who, text, layer.file, (': "%s"'):format(entry))
      end
      add(path, entry)
    else
      add(entry, entry)
    end
  end
  return out, names
end

---The folders the user trusts: `trust` of a call and of `setup()`, and `$RULES_TRUST`; absolute.
---@param call table
---@param setup table
---@return string[]
local function trust_paths(call, setup)
  local raw = {}
  vim.list_extend(raw, call.trust or {})
  vim.list_extend(raw, setup.trust or {})
  local env = vim.env[M.ENV_TRUST]
  if env and env ~= "" then
    vim.list_extend(raw, require("rules.env").split_paths(env))
  end
  local out = {}
  for _, path in ipairs(raw) do
    out[#out + 1] = absolute(path)
  end
  return out
end

---Where a ruleset was named, as the user would say it (no path of this machine).
---@type table<string, string>
M.ORIGIN_WHERE = {
  call = "named on the command line",
  setup = "setup({ rulesets })",
  project = "the project .rules.json",
  vault = "the .rules.json of the vault",
}

---What is wrong with a configured ruleset that is not a folder (a folder that was renamed, a path that is a file): the entry
---and where it was named, no path of this machine.
---@param entry Rules.Settings.Entry
---@return string
function M.not_a_folder_text(entry)
  return ("ruleset %s (%s) is not a folder"):format(entry.name, M.ORIGIN_WHERE[entry.origin] or entry.origin)
end

---Whether a ruleset is trusted, and if not, who named it.
---@param res Rules.Settings
---@param origin "call"|"setup"|"project"|"vault"
---@param path string
---@return boolean trusted
---@return string|nil why
local function judge(res, origin, path)
  if origin == "call" or origin == "setup" then
    return true, nil
  end
  if origin == "vault" and res.vault and res.vault.source ~= "project" then
    return true, nil
  end
  local key = path_key(absolute(path))
  for _, trusted in ipairs(res.trust) do
    if key_within(key, path_key(trusted)) then
      return true, nil
    end
  end
  if origin == "vault" then
    return false, "in a vault that the project .rules.json names"
  end
  return false, "named by the project .rules.json"
end

---Record where each ruleset of `paths` came from and whether it is trusted.
---@param res Rules.Settings
---@param origin "call"|"setup"|"project"|"vault"
---@param paths string[]
---@param names string[]
local function add_entries(res, origin, paths, names)
  for i, path in ipairs(paths) do
    local trusted, why = judge(res, origin, path)
    res.entries[#res.entries + 1] = { path = path, name = names[i], origin = origin, trusted = trusted, why = why }
  end
end

---Whether a rule file may run its `lua_predicate` checks: it lies (by real path) under a trusted ruleset of `res`.
---The answer for one file is kept, a run asks once per rule.
---@param res Rules.Settings
---@return fun(file: string): boolean
function M.trust_check(res)
  local roots = {}
  for _, entry in ipairs(res.entries or {}) do
    if entry.trusted then
      roots[#roots + 1] = path_key(absolute(entry.path))
    end
  end
  ---@type table<string, boolean>
  local memo = {}
  return function(file)
    if type(file) ~= "string" or file == "" then
      return false
    end
    local known = memo[file]
    if known ~= nil then
      return known
    end
    local key = path_key(file)
    local answer = false
    for _, root in ipairs(roots) do
      if key_within(key, root) then
        answer = true
        break
      end
    end
    memo[file] = answer
    return answer
  end
end

---Resolve the settings.
---@param opts? Rules.Settings.Opts
---  `project`: the root being checked; its `.rules.json` is read. Everything else is the `call` layer. `need_vault`: the
---  caller works on the vault itself (`:RulesVault`, health), so a vault that cannot be used is a problem even when
---  the rulesets are named elsewhere.
---@return Rules.Settings
function M.resolve(opts)
  opts = opts or {}
  local config = require("rules.config")
  ---@type Rules.Settings
  local res = {
    rulesets = {},
    entries = {},
    trust = {},
    gates = {},
    agent = vim.deepcopy(DEFAULTS.agent),
    lua_predicates = config.get().lua_predicates,
    vault = nil,
    vault_needed = opts.need_vault == true,
    project = nil,
    vault_file = nil,
    origin = { rulesets = "default", gates = {}, agent = {} },
    problems = {},
    warnings = {},
  }

  -- the call layer is the options table of a headless entry point; its shapes are checked like a file's
  local call_checked = schema.check({
    rulesets = opts.rulesets,
    gates = opts.gates,
    agent = opts.agent,
    vault = opts.vault,
    trust = opts.trust,
  }, "call")
  for _, problem in ipairs(call_checked.problems) do
    note(res.problems, "options", ("%s %s"):format(problem.key, problem.message))
  end
  local call = call_checked.clean
  local setup = config.explicit()
  res.trust = trust_paths(call, setup)

  if opts.project and opts.project ~= "" then
    res.project = file_mod.read(absolute(opts.project), "project")
    file_notes(res, res.project, "project " .. file_mod.NAME)
  end
  -- a refused file contributes nothing (and is reported as a problem)
  local project_cfg = res.project and #res.project.problems == 0 and res.project or nil

  -- what is wrong with the vault itself is kept apart: it is a problem only where the result depends on the vault
  ---@type { problems: Rules.Settings.Note[], warnings: Rules.Settings.Note[], vault: Rules.Settings.Vault|nil }
  local vault_notes = { problems = {}, warnings = {}, vault = nil }
  local raw, source, base = vault_candidate(call, setup, project_cfg)
  if raw and source then
    local root = absolute(raw, base)
    if source == "project" then
      note(
        res.warnings,
        "project " .. file_mod.NAME,
        "vault: a project file names the vault; it is used, but the rulesets of a vault that a project file names"
          .. " are not trusted (their lua_predicate checks do not run); name it in setup({ vault = ... }) or $"
          .. M.ENV_VAULT
          .. " to trust it",
        res.project and res.project.path
      )
      if machine_path(raw) then
        note(
          res.warnings,
          "project " .. file_mod.NAME,
          "vault is a path of this machine; a file in a repository should not carry one"
            .. " (set $RULES_VAULT or setup({ vault = ... }), or write a path relative to the file)",
          res.project and res.project.path,
          (': "%s"'):format(raw)
        )
      end
    end
    local exists = is_dir(root)
    local folders, has_dir = {}, false
    if exists then
      folders, has_dir = discover(root)
    else
      note(vault_notes.problems, M.VAULT_WHERE[source], "the vault is not a folder", nil, ": " .. root, true)
    end
    res.vault = { root = root, source = source, exists = exists, rulesets = folders, file_problem = false }
    vault_notes.vault = res.vault
    if exists and not has_dir then
      note(
        vault_notes.warnings,
        M.VAULT_WHERE[source],
        ("the vault has no %s/ folder: no rulesets are found in it"):format(M.VAULT_SUBDIR),
        nil,
        ": " .. root,
        true
      )
    end
    if exists then
      res.vault_file = file_mod.read(root, "vault")
      file_notes(vault_notes, res.vault_file, "vault " .. file_mod.NAME, true)
      res.vault.file_problem = #res.vault_file.problems > 0
    end
  end
  local vault_cfg = res.vault_file and #res.vault_file.problems == 0 and res.vault_file or nil

  ---@type Rules.Settings.Layer[]
  local layers = {
    { name = "call", values = call, who = "options", is_file = false },
    { name = "setup", values = setup, who = "setup()", is_file = false },
    {
      name = "project",
      values = project_cfg and project_cfg.config or {},
      base = project_cfg and project_cfg.dir,
      who = "project " .. file_mod.NAME,
      file = project_cfg and project_cfg.path,
      is_file = true,
    },
    {
      name = "vault",
      values = vault_cfg and vault_cfg.config or {},
      base = vault_cfg and vault_cfg.dir,
      who = "vault " .. file_mod.NAME,
      file = vault_cfg and vault_cfg.path,
      is_file = true,
    },
    { name = "default", values = DEFAULTS, who = "defaults", is_file = false },
  }
  assert(#layers == #M.RANK, "RANK and the layers must list the same places")

  -- what the vault itself offers: the list of its own file when it has one, else every folder under rulesets/; nothing
  -- when that file cannot be used (a broken list never turns into "every folder")
  local vault_ready = res.vault ~= nil and res.vault.exists
  local loaded_names = {}
  if vault_ready and res.vault then
    local listed = layers[4].values.rulesets
    if res.vault.file_problem then
      res.vault.loaded = {}
    elseif listed then
      res.vault.loaded, loaded_names = expand_entries(vault_notes, layers[4], listed)
    else
      res.vault.loaded = vim.deepcopy(res.vault.rulesets)
      for _, folder in ipairs(res.vault.loaded) do
        loaded_names[#loaded_names + 1] = vim.fs.basename(folder)
      end
    end
  end

  -- rulesets: the highest layer that names them; a vault without a list of its own offers every folder under rulesets/
  for _, layer in ipairs(layers) do
    local entries = layer.values.rulesets
    if layer.name == "vault" and res.vault then
      -- nobody above named the rulesets, so they come from the vault
      res.vault_needed = true
      if vault_ready then
        res.origin.rulesets = layer.values.rulesets and "vault"
          or (
            "vault ("
            .. (res.vault.file_problem and "its file cannot be used" or "every folder under " .. M.VAULT_SUBDIR .. "/")
            .. ")"
          )
        res.rulesets = vim.deepcopy(res.vault.loaded)
        add_entries(res, "vault", res.rulesets, loaded_names)
        break
      end
    elseif entries ~= nil then
      res.origin.rulesets = layer.name
      local paths, names = expand_entries(res, layer, entries)
      res.rulesets = paths
      add_entries(res, layer.name, paths, names)
      break
    end
  end

  -- gates and agent: from the lowest layer up, so a higher layer replaces the entries it names
  for i = #layers, 1, -1 do
    local layer = layers[i]
    if layer.values.gates then
      res.gates = merge.gates(res.gates, layer.values.gates)
      for name in pairs(layer.values.gates) do
        res.origin.gates[name] = layer.name
      end
    end
    if layer.values.agent then
      res.agent = merge.agent(res.agent, layer.values.agent)
      for key, value in pairs(layer.values.agent) do
        if key == "scopes" then
          for family in pairs(value) do
            res.origin.agent["scopes." .. family] = layer.name
          end
        else
          res.origin.agent[key] = layer.name
        end
      end
    end
  end

  -- the vault's own notes count where the result depends on the vault; a stale vault that nothing here needs is a warning
  if res.vault_needed then
    vim.list_extend(res.problems, vault_notes.problems)
    vim.list_extend(res.warnings, vault_notes.warnings)
  elseif res.vault and #vault_notes.problems > 0 then
    note(
      res.warnings,
      M.VAULT_WHERE[res.vault.source],
      "the vault is not usable; it is not needed here, the rulesets are named by the call or by setup()",
      nil,
      ": " .. res.vault.root
    )
  end

  return res
end

---One `rulesets` entry as a path: `@vault/<name>` through the vault, anything else as the `call` layer takes it.
---@param entry string
---@param opts? { vault?: string, project?: string }
---@return string|nil path
---@return string|nil err
function M.resolve_entry(entry, opts)
  local res = M.resolve({ rulesets = { entry }, vault = opts and opts.vault, project = opts and opts.project })
  M.notify(res)
  local err = M.error_text(res, false)
  if err then
    return nil, err
  end
  return res.rulesets[1], nil
end

---A line for a user who has no ruleset at all: how to get one. `nil` when there is something to load.
---@param res Rules.Settings
---@return string|nil
function M.nothing_configured(res)
  if #res.rulesets > 0 then
    return nil
  end
  if res.vault and res.vault.exists then
    return nil
  end
  return "no ruleset is configured: setup({ rulesets = { ... } }), or a vault: " .. M.NO_VAULT_HINT
end

return M
