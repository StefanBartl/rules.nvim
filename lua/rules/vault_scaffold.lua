---@module 'rules.vault_scaffold'
---@brief The scaffold `:RulesVault create` makes: a folder with the files of a rules-vault, never over what is there.
---@description
--- A rules-vault is a repository of its own with the rulesets under `rulesets/<name>/` (docs/CONFIG.md). This module
--- plans and makes the files a new one starts with:
---
---   README.md                          what it is, how it is laid out
---   .rules.json                        `rulesets` and `gates`, paths relative to the file
---   .gitattributes                     `* text=auto eol=lf` (the byte-for-byte checks need one line ending)
---   .gitignore
---   .github/workflows/ci.yml           from `templates/rules-vault-ci.yml` of this plugin
---   rulesets/<name>/_rules/.gitkeep    the ruleset: rule files and layouts, empty for now
---   rulesets/<name>/_layouts/.gitkeep
---
--- An existing folder is used as it is: only what is missing is made, and **a file that is there is never touched**
--- (it is reported as kept). `git init` happens only when asked for, and nothing here ever adds a remote, pushes, or
--- reaches GitHub.
---
--- Not its job: the question, notifications and the clipboard (`rules.ui.vault_cmd`).

local M = {}

---The name of the ruleset when none is given.
M.DEFAULT_NAME = "default"

---The workflow template, in this plugin.
M.TEMPLATE = "templates/rules-vault-ci.yml"

---The setup line that keeps a vault.
---@param root string
---@return string
function M.setup_line(root)
  return ("vault = %q,"):format(root)
end

local README = [[
# Rules vault

The rulesets of one person, in a repository of their own. [rules.nvim](https://github.com/StefanBartl/rules.nvim)
reads them; nothing else is in here.

```
.rules.json                 rulesets and gates of this vault (paths relative to the file)
rulesets/<name>/            one ruleset per folder; <name> is what a document calls it
  _rules/<FAMILY>/<ID>.md   one file per rule
  _layouts/<doc>.md         one layout per reading document (sections, order, introduction)
  <generated documents>     made by `:Rules catalog`, never by hand
```

## Working with it

- Make and change rules with `:Rules new`, `:Rules set`, `:Rules retire` (the engine is the only writer), look
  around with `:RulesVault open|find|grep|tree <ruleset|ID|FAMILY>`.
- Pull before you make a rule: two machines that make a rule in one family without a pull make the same id.
- Commit and push by hand. The CI (`.github/workflows/ci.yml`) checks the reading documents, that every ruleset
  loads without errors, and that writing keeps the files byte for byte.

## Letting rules.nvim find it

Set `vault = "<path of this folder>"` in the `setup()` of rules.nvim, or `$RULES_VAULT`. Nothing is guessed.
]]

local GITIGNORE = [[
# editors and systems
.DS_Store
Thumbs.db
*.swp
*~

# the CI checks out rules.nvim and lib.nvim here
.deps/
]]

local GITATTRIBUTES = "* text=auto eol=lf\n"

---The names Windows keeps for devices: a folder of that name cannot be used there, with or without an extension.
local DEVICE_NAMES = { CON = true, PRN = true, AUX = true, NUL = true }

---Whether `name` may be the folder of a ruleset: letters, digits, `.`, `_` and `-`; it starts with a letter or digit,
---does not end with a dot, and is no Windows device name.
---@param name any
---@return boolean ok
---@return string|nil why
function M.check_name(name)
  if type(name) ~= "string" or name == "" then
    return false, "a ruleset needs a name"
  end
  if not name:match("^[%w][%w._-]*$") then
    return false, ("'%s' is not a usable ruleset name (letters, digits, '.', '_', '-'; not starting with a symbol)"):format(name)
  end
  if name:sub(-1) == "." then
    return false, ("'%s' is not a usable ruleset name: it ends with a dot"):format(name)
  end
  local stem = name:match("^([^.]*)"):upper()
  if DEVICE_NAMES[stem] or stem:match("^COM%d$") or stem:match("^LPT%d$") then
    return false, ("'%s' is a reserved name on Windows"):format(name)
  end
  return true, nil
end

---@param path string
---@return table|nil stat
local function lstat(path)
  return (vim.uv or vim.loop).fs_lstat(path)
end

---@param dir string
---@return boolean
local function is_empty_dir(dir)
  local handle = (vim.uv or vim.loop).fs_scandir(dir)
  return handle == nil or (vim.uv or vim.loop).fs_scandir_next(handle) == nil
end

---The folder and ruleset name of `create`, checked before anything is asked or made.
---@param dir any
---@param name any  nil: `DEFAULT_NAME`
---@return { root: string, name: string }|nil target
---@return string|nil err
function M.check_target(dir, name)
  if type(dir) ~= "string" or vim.trim(dir) == "" then
    return nil, "a vault needs a folder"
  end
  -- required here, not at the top: loading `lib.nvim.fs.roots` exports environment variables, which `setup()` must not
  local expanded = require("lib.nvim.cross.fs.expand_path")(vim.trim(dir))
  local root = vim.fs.normalize(vim.fn.fnamemodify(expanded, ":p")):gsub("(.)/+$", "%1")
  if root:match("^%a:/?$") or root == "/" then
    return nil, "refusing to use a drive or filesystem root as a vault: " .. root
  end
  local stat = (vim.uv or vim.loop).fs_stat(root)
  if stat and stat.type ~= "directory" then
    return nil, root .. " is a file"
  end
  if name == nil or name == "" then
    name = M.DEFAULT_NAME
  end
  local ok, why = M.check_name(name)
  if not ok then
    return nil, why
  end
  return { root = root, name = name }, nil
end

---The text of the workflow, from the template of this plugin.
---@return string|nil text
---@return string|nil err
local function template_text()
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))))
  local path = M.template_path or (plugin_root .. "/" .. M.TEMPLATE)
  local text, err = require("lib.nvim.fs.read")(path)
  if not text then
    return nil, ("the workflow template is missing (%s): %s"):format(path, tostring(err))
  end
  return text, nil
end

---Seam: another path of the workflow template (the specs; `nil`: the one in this plugin).
---@type string|nil
M.template_path = nil

---@class Rules.Vault.PlanItem
---@field rel string       the path below the vault folder
---@field kind "file"|"keep"   a file with content, or a `.gitkeep` that keeps an empty folder in git
---@field state "make"|"kept"  `kept`: it is there already and stays as it is
---@field content string

---@class Rules.Vault.Plan
---@field root string
---@field name string
---@field existed boolean      the vault folder is there already
---@field items Rules.Vault.PlanItem[]
---@field git "no"|"init"|"already"|"inside"  `no`: not asked for; `already`: it is a repository; `inside`: in another one
---@field git_top string|nil

---What `--git` would do in a folder: `init`, `already` (the folder is a repository of its own), or `inside` (it lies in
---another repository, which `git init` must not nest a second one in). A folder that is not there yet is judged by the
---nearest folder above it that is.
---@param root string
---@return "init"|"already"|"inside" what
---@return string|nil top  the repository it lies in
function M.git_plan(root)
  local probe = root
  while not lstat(probe) do
    local parent = vim.fs.dirname(probe)
    if parent == probe or parent == "" or parent == "." then
      break
    end
    probe = parent
  end
  local state = require("rules.vault").git_state(probe)
  if not state then
    return "init", nil
  end
  if state.repo then
    return probe == root and "already" or "inside", probe ~= root and probe or nil
  end
  if state.inside then
    return "inside", state.inside
  end
  return "init", nil
end

---What `create` would make, in the order it makes it. Reads the disk, writes nothing.
---@param target { root: string, name: string }
---@param opts? { git?: boolean }
---@return Rules.Vault.Plan|nil plan
---@return string|nil err
function M.plan(target, opts)
  local root, name = target.root, target.name
  local workflow, err = template_text()
  if not workflow then
    return nil, err
  end
  -- the file as a person reads it: one key to a line (the name is checked: nothing in it needs escaping)
  local rules_json = ('{\n  "rulesets": ["rulesets/%s"],\n  "gates": {}\n}\n'):format(name)
  ---@type Rules.Vault.PlanItem[]
  local items = {
    { rel = "README.md", kind = "file", content = README },
    { rel = ".rules.json", kind = "file", content = rules_json },
    { rel = ".gitattributes", kind = "file", content = GITATTRIBUTES },
    { rel = ".gitignore", kind = "file", content = GITIGNORE },
    { rel = ".github/workflows/ci.yml", kind = "file", content = workflow },
    { rel = ("rulesets/%s/_rules/.gitkeep"):format(name), kind = "keep", content = "" },
    { rel = ("rulesets/%s/_layouts/.gitkeep"):format(name), kind = "keep", content = "" },
  }
  for _, item in ipairs(items) do
    local path = root .. "/" .. item.rel
    if lstat(path) then
      item.state = "kept"
    elseif item.kind == "keep" then
      -- a folder that has files in it needs no placeholder
      local dir = vim.fs.dirname(path)
      item.state = (lstat(dir) and not is_empty_dir(dir)) and "kept" or "make"
    else
      item.state = "make"
    end
  end
  local plan = { root = root, name = name, existed = lstat(root) ~= nil, items = items, git = "no" }
  if opts and opts.git then
    plan.git, plan.git_top = M.git_plan(root)
  end
  return plan, nil
end

---@param plan Rules.Vault.Plan
---@param state "make"|"kept"
---@return string[]
local function rels(plan, state)
  local out = {}
  for _, item in ipairs(plan.items) do
    if item.state == state then
      out[#out + 1] = item.rel
    end
  end
  return out
end

---What `create` is about to do and what is left to the user, in the order it happens. The last step is the one that is
---easy to forget and has no effect until it is done, so it is the one that is marked.
---@param plan Rules.Vault.Plan
---@return string
function M.plan_text(plan)
  local make, kept = rels(plan, "make"), rels(plan, "kept")
  local lines = {
    "Create a rules vault",
    "",
    "  1. Folder (name and location):",
    "       " .. plan.root .. (plan.existed and "   (exists: it is used as it is)" or "   (is made)"),
    "  2. Files, made only where they are missing; a file that is there is never overwritten:",
  }
  if #make > 0 then
    for _, rel in ipairs(make) do
      lines[#lines + 1] = "       + " .. rel
    end
  else
    lines[#lines + 1] = "       nothing to make: everything is there already"
  end
  for _, rel in ipairs(kept) do
    lines[#lines + 1] = "       = " .. rel .. "   (there already, stays as it is)"
  end
  if plan.git == "init" then
    lines[#lines + 1] = "  3. git init in the folder (--git). No remote is added, nothing is pushed or published."
  elseif plan.git == "already" then
    lines[#lines + 1] = "  3. The folder is a git repository already (--git has nothing to do). No remote, nothing is pushed."
  elseif plan.git == "inside" then
    lines[#lines + 1] = "  3. The folder lies inside another repository (" .. tostring(plan.git_top) .. "): --git makes none."
  else
    lines[#lines + 1] = "  3. No git repository is made (--git does that). No remote, nothing is published."
  end
  vim.list_extend(lines, {
    "",
    "  >>> 4. REQUIRED, and done by you afterwards <<<",
    "       Write the path into the setup of rules.nvim:",
    "           " .. M.setup_line(plan.root),
    "       (or set $RULES_VAULT). Without this step rules.nvim will NOT find",
    "       the vault. Nothing is read from it until then.",
  })
  return table.concat(lines, "\n")
end

---@class Rules.Vault.Created
---@field root string
---@field existed boolean
---@field made string[]   the paths made, relative to the vault
---@field kept string[]   the paths that were there and stay
---@field git string      what happened to git: a sentence

---Make what the plan lists, file by file, each only if it is still missing at the moment it is made (an exclusive create:
---a file that appeared in between is kept and reported, never overwritten). Stops at the first failure and says what was
---made until then.
---@param plan Rules.Vault.Plan
---@return Rules.Vault.Created|nil result
---@return string|nil err
function M.create(plan)
  local create = require("lib.nvim.fs.create_exclusive")
  local mkdirp = require("lib.nvim.fs.mkdirp")
  local made, kept = {}, {}
  local existed = plan.existed
  if not existed then
    local ok, err = mkdirp(plan.root)
    if not ok then
      return nil, ("cannot create %s: %s"):format(plan.root, tostring(err))
    end
  end
  for _, item in ipairs(plan.items) do
    if item.state == "kept" then
      kept[#kept + 1] = item.rel
    else
      local ok, err = create(plan.root .. "/" .. item.rel, item.content)
      if ok then
        made[#made + 1] = item.rel
      elseif create.is_exists(err) then
        kept[#kept + 1] = item.rel
      else
        return nil,
          ("cannot write %s: %s%s"):format(
            plan.root .. "/" .. item.rel,
            tostring(err),
            #made > 0 and (" (made until then: %s)"):format(table.concat(made, ", ")) or ""
          )
      end
    end
  end
  ---@type Rules.Vault.Created
  local result = { root = plan.root, existed = existed, made = made, kept = kept, git = "not asked for (--git)" }
  if plan.git == "init" then
    local git = require("lib.nvim.git").run({ "init" }, { dir = plan.root, timeout_ms = 15000 })
    if git.code == 0 then
      result.git = "git init done (no remote)"
    else
      result.git = "git init failed: " .. vim.trim(git.stderr or git.stdout or ("exit code " .. tostring(git.code)))
    end
  elseif plan.git == "already" then
    result.git = "already a git repository"
  elseif plan.git == "inside" then
    result.git = "inside another repository (" .. tostring(plan.git_top) .. "): none made"
  end
  return result, nil
end

---The message after the vault was made: the same required step, once more and impossible to miss.
---@param res Rules.Vault.Created
---@param copied? boolean  false when the line could not be put in the register (nil counts as copied)
---@return string
function M.created_message(res, copied)
  local lines = {
    (res.existed and "Used the existing folder " or "Created the vault ") .. res.root,
    #res.made > 0 and ("made: " .. table.concat(res.made, ", ")) or "nothing new to make",
  }
  if #res.kept > 0 then
    lines[#lines + 1] = "kept as they were: " .. table.concat(res.kept, ", ")
  end
  vim.list_extend(lines, {
    "git: " .. res.git,
    "",
    "!! ONE STEP IS LEFT, AND IT IS YOURS !!",
    "Without it rules.nvim does not find this vault:",
    "  add   " .. M.setup_line(res.root),
    "  to the setup (opts) of rules.nvim, or set $RULES_VAULT.",
    (copied == false and "The + register could not be written, copy the line yourself." or "The line is in the + register.")
      .. " Commit and push by hand: nothing here touches a remote.",
  })
  return table.concat(lines, "\n")
end

return M
