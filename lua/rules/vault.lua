---@module 'rules.vault'
---@brief The rules-vault: where it is, which rulesets it offers, whether it is a clean git repository.
---@description
--- A vault is a folder (its own repository) with the rulesets of a person under `rulesets/<name>/`. It is found, in this
--- order, from `vault` of the call, `setup({ vault = ... })`, `$RULES_VAULT`, then the `vault` of the project's
--- `.rules.json`. A path is never guessed: no vault is a normal state and answers with a message, not an error.
---
--- This module is the small public face of that (`rules.settings` does the work and ranks the places): the
--- `:RulesVault` command (`rules.ui.vault_cmd`) takes its `roots` from here.
---
---```lua
--- local vault = require("rules.vault")
--- local root, err = vault.root()          -- nil, "no vault is configured: ..." when there is none
--- local where = vault.source()            -- "setup" | "env" | "project" | "call" | nil
--- local folders = vault.rulesets()        -- { "<root>/rulesets/lua", "<root>/rulesets/native" }
---```
---
--- `opts.project` is the project root whose `.rules.json` may name a vault (default: the working directory, the root
--- `:Rules check` uses). The names of the rulesets in a document stay the folder names (`lua`, `native`), never these
--- paths (`rules-export/1`).
---
--- Reads only: `git_state` runs `git rev-parse` and `git status --porcelain` (no network, no lock, a timeout), and
--- says nothing when git is not installed.

local settings = require("rules.settings")

local M = {}

---The start of the message `root` gives when nothing names a vault (a normal state, unlike a vault that is named but
---unusable): a front end that tells the two apart tests for it with `is_none`.
M.NONE = "no vault is configured"

---Whether a message of `root` says that no vault is configured at all.
---@param message string|nil
---@return boolean
function M.is_none(message)
  return type(message) == "string" and message:sub(1, #M.NONE) == M.NONE
end

---@class Rules.Vault.Opts
---@field project? string  the root being checked (default: the working directory)
---@field vault? string    a vault to use instead of the configured one (the `call` layer)

---@param opts Rules.Vault.Opts|nil
---@return Rules.Settings
local function resolve(opts)
  opts = opts or {}
  return settings.resolve({ project = opts.project or vim.fn.getcwd(), vault = opts.vault })
end

---The vault folder, or `nil` and the reason: nothing is configured (a normal state), what is configured is not a folder,
---or a file that names the vault cannot be used.
---@param opts Rules.Vault.Opts|nil
---@return string|nil root  absolute, `/`-separated
---@return string|nil message
function M.root(opts)
  local res = resolve(opts)
  if res.vault and res.vault.exists then
    return res.vault.root, nil
  end
  local problem = settings.error_text(res, false)
  if problem then
    return nil, problem
  end
  return nil, M.NONE .. ": " .. settings.NO_VAULT_HINT
end

---Where the vault was named: `"call"`, `"setup"`, `"env"` ($RULES_VAULT) or `"project"`; `nil` without a vault.
---@param opts Rules.Vault.Opts|nil
---@return "call"|"setup"|"env"|"project"|nil
function M.source(opts)
  local res = resolve(opts)
  return res.vault and res.vault.source or nil
end

---The rulesets the vault offers, as folders: the list in its own `.rules.json` when it has one, otherwise every folder
---under `<vault>/rulesets/` (sorted by name). Empty without a vault.
---@param opts Rules.Vault.Opts|nil
---@return string[]
function M.rulesets(opts)
  local res = resolve(opts)
  if res.vault and res.vault.exists then
    return vim.deepcopy(res.vault.loaded or res.vault.rulesets)
  end
  return {}
end

---@class Rules.Vault.GitState
---@field repo boolean      the vault is the top of a git work tree
---@field inside string|nil the top of the work tree the vault lies in, when it is not its own
---@field clean boolean|nil nothing to commit (untracked files count); nil when git could not tell
---@field changes integer   how many paths `git status` lists
---@field error string|nil  why git could not tell (a timeout, a failure)

---@param a string
---@param b string
---@return boolean
local function same_folder(a, b)
  local normkey = require("lib.nvim.fs.normkey")
  local x, y = normkey(a), normkey(b)
  if vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1 then
    x, y = x:lower(), y:lower()
  end
  return x == y
end

---Whether `root` is a git repository and has nothing to commit. Read only: `git rev-parse --show-toplevel` and
---`git status --porcelain` with `--no-optional-locks` (the index is not touched), no network, five seconds at most each.
---@param root string
---@return Rules.Vault.GitState|nil state  `nil` when git is not installed: nothing to say
function M.git_state(root)
  if vim.fn.executable("git") ~= 1 then
    return nil
  end
  local git = require("lib.nvim.git")
  local opts = { dir = root, timeout_ms = 5000, read_only = true, no_lazy_fetch = true }
  local top = git.run({ "rev-parse", "--show-toplevel" }, opts)
  if top.timed_out then
    return { repo = false, changes = 0, error = "git did not answer within 5 seconds" }
  end
  if top.code ~= 0 then
    return { repo = false, changes = 0 }
  end
  local toplevel = vim.trim(top.stdout)
  local state = { repo = same_folder(toplevel, root), changes = 0 }
  if not state.repo then
    state.inside = toplevel
  end
  local status = git.run({ "status", "--porcelain" }, opts)
  if status.timed_out or status.code ~= 0 then
    state.error = status.timed_out and "git status did not answer within 5 seconds"
      or vim.trim(status.stderr or "git status failed")
    return state
  end
  local count = 0
  for line in status.stdout:gmatch("[^\r\n]+") do
    if line ~= "" then
      count = count + 1
    end
  end
  state.changes, state.clean = count, count == 0
  return state
end

return M
