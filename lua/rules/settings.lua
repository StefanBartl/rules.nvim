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
--- `@vault/<name>` in `rulesets` is an error that says so.
---
--- A file that is there but cannot be used (not JSON, wrong shape, a vault that is no folder) is a PROBLEM: the caller must
--- stop and say it, a broken file never becomes "no settings". Things that are odd but harmless (an unknown key, an
--- absolute path in a file that lives in a repository) are WARNINGS. Both are lists of notes; `format` writes one as
--- text, with the file's path for the user (health, notifications) or without any path of this machine (`portable`: the
--- documents of `rules-export/1`).
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

---@class Rules.Settings.Vault
---@field root string       the folder, absolute, `/`-separated
---@field source "call"|"setup"|"env"|"project"
---@field exists boolean    whether it is a folder
---@field rulesets string[] every folder under `<root>/rulesets/`, sorted (empty when it does not exist)
---@field loaded string[]|nil  the rulesets the vault itself offers: the `rulesets` of its own `.rules.json`, else `rulesets`

---@class Rules.Settings
---@field rulesets string[]
---@field gates table<string, string[]>
---@field agent Rules.AgentOpts
---@field lua_predicates boolean
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
local function note(list, who, text, file, detail)
  list[#list + 1] = { who = who, text = text, file = file, detail = detail }
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

---All problems as one text, `nil` when there are none.
---@param res Rules.Settings
---@param portable boolean|nil
---@return string|nil
function M.error_text(res, portable)
  if #res.problems == 0 then
    return nil
  end
  local lines = {}
  for _, n in ipairs(res.problems) do
    lines[#lines + 1] = M.format(n, portable)
  end
  return table.concat(lines, "\n")
end

---@type table<string, true>
local warned = {}

---Forget which warnings were shown (a new `setup()`, and specs).
function M.reset()
  warned = {}
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
local function file_notes(res, read, who)
  for _, problem in ipairs(read.problems) do
    local text = problem.key == "" and problem.message or ("%s %s"):format(problem.key, problem.message)
    note(res.problems, who, text, read.path)
  end
  if #read.unknown > 0 then
    local names = {}
    for _, entry in ipairs(read.unknown) do
      names[#names + 1] = schema.unknown_text(entry)
    end
    note(res.warnings, who, "unknown key(s) ignored: " .. table.concat(names, ", "), read.path)
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
---@param res Rules.Settings
---@param layer Rules.Settings.Layer
---@param entries string[]
---@return string[]
local function expand_entries(res, layer, entries)
  local out = {}
  local vault_ready = res.vault ~= nil and res.vault.exists
  for _, entry in ipairs(entries) do
    if entry == "@vault" or entry:sub(1, #M.VAULT_PREFIX) == M.VAULT_PREFIX then
      local name = entry:sub(#M.VAULT_PREFIX + 1)
      if entry == "@vault" or not valid_vault_name(name) then
        local text = ('rulesets entry %q: write "@vault/<name>", a folder name under the vault\'s %s/'):format(
          entry,
          M.VAULT_SUBDIR
        )
        note(res.problems, layer.who, text, layer.file)
      elseif not vault_ready then
        local text = ("rulesets entry %q needs a vault, and none is found: %s"):format(entry, M.NO_VAULT_HINT)
        note(res.problems, layer.who, text, layer.file)
      else
        out[#out + 1] = res.vault.root .. "/" .. M.VAULT_SUBDIR .. "/" .. name
      end
    elseif layer.is_file then
      local own = machine_path(entry)
      if own then
        local text = 'a rulesets entry is a path of this machine; use a path relative to the file, or "@vault/<name>"'
        note(res.warnings, layer.who, text, layer.file, (': "%s"'):format(entry))
      end
      out[#out + 1] = own and entry or (layer.base .. "/" .. entry)
    else
      out[#out + 1] = entry
    end
  end
  return out
end

---Resolve the settings.
---@param opts? { rulesets?: string[], gates?: table<string, string[]>, agent?: table, vault?: string, project?: string }
---  `project`: the root being checked; its `.rules.json` is read. Everything else is the `call` layer.
---@return Rules.Settings
function M.resolve(opts)
  opts = opts or {}
  local config = require("rules.config")
  ---@type Rules.Settings
  local res = {
    rulesets = {},
    gates = {},
    agent = vim.deepcopy(DEFAULTS.agent),
    lua_predicates = config.get().lua_predicates,
    vault = nil,
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
  }, "call")
  for _, problem in ipairs(call_checked.problems) do
    note(res.problems, "options", ("%s %s"):format(problem.key, problem.message))
  end
  local call = call_checked.clean
  local setup = config.explicit()

  if opts.project and opts.project ~= "" then
    res.project = file_mod.read(absolute(opts.project), "project")
    file_notes(res, res.project, "project " .. file_mod.NAME)
  end
  -- a refused file contributes nothing (and is reported as a problem)
  local project_cfg = res.project and #res.project.problems == 0 and res.project or nil

  local raw, source, base = vault_candidate(call, setup, project_cfg)
  if raw and source then
    local root = absolute(raw, base)
    if source == "project" and machine_path(raw) then
      note(
        res.warnings,
        "project " .. file_mod.NAME,
        "vault is a path of this machine; a file in a repository should not carry one"
          .. " (set $RULES_VAULT or setup({ vault = ... }), or write a path relative to the file)",
        res.project and res.project.path,
        (': "%s"'):format(raw)
      )
    end
    local exists = is_dir(root)
    local folders, has_dir = {}, false
    if exists then
      folders, has_dir = discover(root)
    else
      note(res.problems, M.VAULT_WHERE[source], "the vault is not a folder", nil, ": " .. root)
    end
    res.vault = { root = root, source = source, exists = exists, rulesets = folders }
    if exists and not has_dir then
      note(
        res.warnings,
        M.VAULT_WHERE[source],
        ("the vault has no %s/ folder: no rulesets are found in it"):format(M.VAULT_SUBDIR),
        nil,
        ": " .. root
      )
    end
    if exists then
      res.vault_file = file_mod.read(root, "vault")
      file_notes(res, res.vault_file, "vault " .. file_mod.NAME)
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

  -- rulesets: the highest layer that names them; a vault without a list of its own offers every folder under rulesets/
  local vault_ready = res.vault ~= nil and res.vault.exists
  for _, layer in ipairs(layers) do
    local entries = layer.values.rulesets
    if entries == nil and layer.name == "vault" and vault_ready then
      res.origin.rulesets = "vault (every folder under " .. M.VAULT_SUBDIR .. "/)"
      res.rulesets = vim.deepcopy(res.vault.rulesets)
      break
    end
    if entries ~= nil then
      res.origin.rulesets = layer.name
      res.rulesets = expand_entries(res, layer, entries)
      break
    end
  end

  -- what the vault itself offers: the list of its own file when it has one, else every folder under rulesets/
  if vault_ready and res.vault then
    local listed = layers[4].values.rulesets
    local scratch = { problems = {}, warnings = {}, vault = res.vault }
    ---@diagnostic disable-next-line: param-type-mismatch
    res.vault.loaded = listed and expand_entries(scratch, layers[4], listed) or vim.deepcopy(res.vault.rulesets)
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
