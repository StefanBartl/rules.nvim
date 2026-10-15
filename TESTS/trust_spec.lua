-- TESTS/trust_spec.lua -- the trust gate: a `lua_predicate` runs only in a ruleset the user named himself.
--
-- The fixture is a foreign repository: a `.rules.json` that names a ruleset whose predicate writes a marker file. The
-- marker is the proof, not the status: it exists exactly when the Lua of the ruleset ran.
---@diagnostic disable: need-check-nil
local config = require("rules.config")
local settings = require("rules.settings")
local rules = require("rules")
require("lib.nvim.cross.fs.expand_path")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param path string
---@return string
local function norm(path)
  return (vim.fs.normalize(path):gsub("/+$", ""))
end

---@param path string
---@return boolean
local function exists(path)
  return (vim.uv or vim.loop).fs_stat(path) ~= nil
end

---A ruleset whose predicate writes `marker` and whose grep rule looks for a word the repository has.
---@param marker string
---@return string
local function ruleset_text(marker)
  return table.concat({
    "```rule",
    'id = "PRD-01",',
    'severity = "critical",',
    ('check = { type = "lua_predicate", fn = function(root) local f = io.open(%q, "w")'):format(norm(marker))
      .. ' if f then f:write("ran") f:close() end return true end },',
    "```",
    "",
    "```rule",
    'id = "PRG-01",',
    'severity = "critical",',
    'check = { type = "grep", pattern = "forbiddenword", include = "%.txt$" },',
    "```",
    "",
  }, "\n")
end

---A foreign repository: `.rules.json` with `entries` as its rulesets, the ruleset in `rules/`, a file the grep finds.
---@param entries string[]|nil  default { "rules" }
---@return string repo, string marker, string base
local function foreign_repo(entries)
  local base = tmp_dir()
  local repo = base .. "/repo"
  local marker = base .. "/marker.txt"
  write_raw(repo .. "/rules/p.md", ruleset_text(marker))
  write_raw(repo .. "/.rules.json", vim.json.encode({ rulesets = entries or { "rules" } }))
  write_raw(repo .. "/src.txt", "forbiddenword\n")
  return repo, marker, base
end

---@param repo string
---@param family string
---@return Rules.Result[]
local function check(repo, family)
  local _, _, results, err = rules.check_family_json(family, repo)
  assert.is_nil(err)
  return results
end

local ENV = { "RULES_VAULT", "RULES_PROJECT", "RULES_RULESETS", "RULES_GATES", "RULES_TRUST" }

describe("the trust gate", function()
  local saved
  before_each(function()
    saved = {}
    for _, name in ipairs(ENV) do
      saved[name] = vim.env[name]
      vim.env[name] = nil
    end
    config.setup({})
    settings.reset()
  end)
  after_each(function()
    for _, name in ipairs(ENV) do
      vim.env[name] = saved[name]
    end
    config.setup({})
    settings.reset()
  end)

  describe("a ruleset that a project .rules.json names", function()
    it("does not run its lua_predicate: the rule is an error that says so, and nothing is written", function()
      local repo, marker = foreign_repo()

      local results = check(repo, "PRD")

      assert.is_false(exists(marker), "the predicate of a foreign ruleset ran")
      assert.are.equal("error", results[1].status) -- never 'pass', never silent
      assert.is_truthy(results[1].findings[1].text:find("not run: ruleset is not trusted", 1, true))
      assert.is_nil(results[1].findings[1].text:find(norm(repo), 1, true)) -- no path of this machine in the message
    end)

    it("still runs its other checks", function()
      local repo = foreign_repo()

      local results = check(repo, "PRG")

      assert.are.equal("fail", results[1].status) -- the grep ran and found the word
    end)

    it("is untrusted whatever the entry looks like: relative, .., absolute, @vault/<name>", function()
      local vault = tmp_dir() .. "/vault"
      local base = tmp_dir()
      local marker = base .. "/marker.txt"
      write_raw(vault .. "/rulesets/lua/p.md", ruleset_text(marker))
      write_raw(base .. "/shared/p.md", ruleset_text(marker))
      write_raw(base .. "/project/src.txt", "x\n")
      vim.env.RULES_VAULT = vault
      local entries = { "../shared", base .. "/shared", "@vault/lua" }
      for _, entry in ipairs(entries) do
        write_raw(base .. "/project/.rules.json", vim.json.encode({ rulesets = { entry } }))
        settings.reset()

        local results = check(base .. "/project", "PRD")

        assert.is_false(exists(marker), "entry " .. entry .. " ran its predicate")
        assert.are.equal("error", results[1].status, entry)
      end
    end)

    it("is untrusted in the settings result, with where it came from", function()
      local repo = foreign_repo()

      local res = settings.resolve({ project = repo })

      assert.are.equal(1, #res.entries)
      assert.is_false(res.entries[1].trusted)
      assert.are.equal("project", res.entries[1].origin)
      assert.are.equal("rules", res.entries[1].name)
      assert.is_false(settings.trust_check(res)(repo .. "/rules/p.md"))
    end)

    it("runs once the folder is in setup({ trust }): the folder itself, or one above it", function()
      for _, trusted in ipairs({ "/rules", "", "/rules/../rules/" }) do
        local repo, marker = foreign_repo()
        config.setup({ trust = { repo .. trusted } })

        local results = check(repo, "PRD")

        assert.is_true(exists(marker), "trust " .. trusted)
        assert.are.equal("pass", results[1].status)
      end
    end)

    it("is compared by real path: a link to the folder is no way around, and another spelling is no obstacle", function()
      local repo, marker, base = foreign_repo()
      -- the trusted folder is spelled through a link
      local link = base .. "/link-to-repo"
      local ok = (vim.uv or vim.loop).fs_symlink(repo, link, { dir = true, junction = true })
      if not ok then
        pending("this system cannot make a link here")
      end
      config.setup({ trust = { link .. "/rules" } })

      check(repo, "PRD")

      assert.is_true(exists(marker))
    end)

    it("stays untrusted when another folder is trusted", function()
      local repo, marker = foreign_repo()
      config.setup({ trust = { tmp_dir() } })

      check(repo, "PRD")

      assert.is_false(exists(marker))
    end)

    it("is trusted by $RULES_TRUST, a list of paths", function()
      local repo, marker = foreign_repo()
      vim.env.RULES_TRUST = tmp_dir() .. ";" .. repo .. "/rules"

      check(repo, "PRD")

      assert.is_true(exists(marker))
    end)

    it("is trusted when the call says so (a headless tool: --trust)", function()
      local repo = foreign_repo()

      local res = settings.resolve({ project = repo, trust = { repo .. "/rules" } })

      assert.is_true(res.entries[1].trusted)
      assert.is_true(settings.trust_check(res)(repo .. "/rules/p.md"))
      local nothing = settings.resolve({ project = repo, trust = {} })
      assert.is_false(nothing.entries[1].trusted)
    end)

    it("cannot grant itself trust: `trust` in a project file is an unknown key", function()
      local repo, marker = foreign_repo()
      write_raw(repo .. "/.rules.json", vim.json.encode({ rulesets = { "rules" }, trust = { "rules" } }))

      local res = settings.resolve({ project = repo })
      check(repo, "PRD")

      assert.is_false(exists(marker))
      assert.are.equal(1, #res.warnings)
      assert.is_truthy(settings.format(res.warnings[1], false):find("trust", 1, true))
      assert.is_truthy(settings.format(res.warnings[1], false):find("setup() option only", 1, true))
    end)
  end)

  describe("a ruleset the user named himself", function()
    it("runs its lua_predicate: setup({ rulesets })", function()
      local repo, marker = foreign_repo()
      config.setup({ rulesets = { repo .. "/rules" } })

      local results = check(repo, "PRD") -- the project file names it too; setup() wins and it is the user's

      assert.is_true(exists(marker))
      assert.are.equal("pass", results[1].status)
    end)

    it("runs its lua_predicate: setup({ rulesets }) with a project that has no file", function()
      local repo, marker = foreign_repo()
      os.remove(repo .. "/.rules.json")
      config.setup({ rulesets = { repo .. "/rules" } })

      check(repo, "PRD")

      assert.is_true(exists(marker))
    end)

    it("runs its lua_predicate: the vault of $RULES_VAULT and of setup({ vault })", function()
      local vault = tmp_dir() .. "/vault"
      local base = tmp_dir()
      local marker = base .. "/marker.txt"
      write_raw(vault .. "/rulesets/lua/p.md", ruleset_text(marker))
      write_raw(base .. "/project/src.txt", "x\n")

      vim.env.RULES_VAULT = vault
      check(base .. "/project", "PRD")
      assert.is_true(exists(marker), "$RULES_VAULT")

      os.remove(marker)
      vim.env.RULES_VAULT = nil
      config.setup({ vault = vault })
      check(base .. "/project", "PRD")
      assert.is_true(exists(marker), "setup({ vault })")
    end)

    it("does not run it in a vault that the project file names", function()
      local base = tmp_dir()
      local marker = base .. "/marker.txt"
      write_raw(base .. "/vault/rulesets/lua/p.md", ruleset_text(marker))
      write_raw(base .. "/project/.rules.json", vim.json.encode({ vault = "../vault" }))
      write_raw(base .. "/project/src.txt", "x\n")

      local results = check(base .. "/project", "PRD")
      local res = settings.resolve({ project = base .. "/project" })

      assert.is_false(exists(marker))
      assert.are.equal("error", results[1].status)
      assert.are.equal("project", res.vault.source)
      assert.is_false(res.entries[1].trusted)
      assert.are.equal("vault", res.entries[1].origin)
    end)

    it("runs it in that vault once the vault is trusted", function()
      local base = tmp_dir()
      local marker = base .. "/marker.txt"
      write_raw(base .. "/vault/rulesets/lua/p.md", ruleset_text(marker))
      write_raw(base .. "/project/.rules.json", vim.json.encode({ vault = "../vault" }))
      write_raw(base .. "/project/src.txt", "x\n")
      config.setup({ trust = { base .. "/vault" } })

      check(base .. "/project", "PRD")

      assert.is_true(exists(marker))
    end)

    it("does not run it when a link inside the trusted folder leads out of it", function()
      local base = tmp_dir()
      local marker = base .. "/marker.txt"
      write_raw(base .. "/elsewhere/p.md", ruleset_text(marker))
      write_raw(base .. "/mine/readme.txt", "x\n")
      local ok = (vim.uv or vim.loop).fs_symlink(base .. "/elsewhere/p.md", base .. "/mine/p.md", {})
      if not ok then
        pending("this system cannot make a file link here")
      end
      write_raw(base .. "/project/src.txt", "x\n")
      config.setup({ rulesets = { base .. "/mine" } })

      local results = check(base .. "/project", "PRD")

      assert.is_false(exists(marker), "a file that lies outside the trusted folder ran")
      assert.are.equal("error", results[1].status)
    end)

    it("is still switched off by lua_predicates = false", function()
      local repo, marker = foreign_repo()
      config.setup({ rulesets = { repo .. "/rules" }, lua_predicates = false })

      local results = check(repo, "PRD")

      assert.is_false(exists(marker))
      assert.is_truthy(results[1].findings[1].text:find("lua_predicates is off", 1, true))
    end)
  end)

  describe("warnings that name the key, with no machine path in a document", function()
    it("an entry that leaves the project folder", function()
      local base = tmp_dir()
      write_raw(base .. "/project/.rules.json", vim.json.encode({ rulesets = { "../shared", "inside/rules" } }))

      local res = settings.resolve({ project = base .. "/project" })

      assert.are.equal(1, #res.warnings) -- the one outside only
      local portable = settings.format(res.warnings[1], true)
      assert.is_truthy(portable:find("rulesets entry leaves the project folder", 1, true))
      assert.is_nil(portable:find(norm(base), 1, true))
      assert.is_nil(portable:find("shared", 1, true))
    end)

    it("an absolute entry says it is not trusted", function()
      local base = tmp_dir()
      write_raw(base .. "/project/.rules.json", vim.json.encode({ rulesets = { base .. "/abs" } }))

      local res = settings.resolve({ project = base .. "/project" })

      assert.are.equal(1, #res.warnings)
      local portable = settings.format(res.warnings[1], true)
      assert.is_truthy(portable:find("path of this machine", 1, true))
      assert.is_truthy(portable:find("lua_predicate", 1, true))
      assert.is_nil(portable:find(norm(base), 1, true))
    end)

    it("a vault key in a project file", function()
      local base = tmp_dir()
      write_raw(base .. "/vault/rulesets/lua/p.md", "x\n")
      write_raw(base .. "/project/.rules.json", vim.json.encode({ vault = "../vault" }))

      local res = settings.resolve({ project = base .. "/project" })

      assert.are.equal(1, #res.warnings)
      local portable = settings.format(res.warnings[1], true)
      assert.is_truthy(portable:find("vault: a project file names the vault", 1, true))
      assert.is_nil(portable:find(norm(base), 1, true))
    end)

    it("no warning for the entries of setup() or for a vault named by setup()", function()
      local base = tmp_dir()
      write_raw(base .. "/vault/rulesets/lua/p.md", "x\n")
      config.setup({ vault = base .. "/vault", rulesets = { "../anything" } })

      assert.are.equal(0, #settings.resolve({}).warnings)
    end)
  end)

  describe("setup({ trust })", function()
    it("is a list of strings: anything else is dropped with a warning (ERR-22)", function()
      local messages = {}
      local original = vim.notify
      vim.notify = function(msg)
        messages[#messages + 1] = msg
      end
      local ok, err = pcall(config.setup, { trust = "/some/folder" })
      vim.notify = original
      assert(ok, err)

      assert.are.same({}, config.get().trust)
      assert.is_truthy(table.concat(messages, "\n"):find("trust must be a list of strings", 1, true))
    end)

    it("is a known key: no unknown-key warning", function()
      local messages = {}
      local original = vim.notify
      vim.notify = function(msg)
        messages[#messages + 1] = msg
      end
      local ok, err = pcall(config.setup, { trust = { "/some/folder" } })
      vim.notify = original
      assert(ok, err)

      assert.are.equal(0, #messages)
      assert.are.same({ "/some/folder" }, config.get().trust)
    end)

    it("a typo gets the usual hint", function()
      local messages = {}
      local original = vim.notify
      vim.notify = function(msg)
        messages[#messages + 1] = msg
      end
      pcall(config.setup, { trusts = { "/some/folder" } })
      vim.notify = original

      assert.is_truthy(table.concat(messages, "\n"):find("trusts (did you mean trust?)", 1, true))
    end)
  end)

  describe("a headless process", function()
    local lib_dir = vim.env.LIB_NVIM_DIR
    local plugin_root = vim.fs.dirname(
      vim.fs.dirname(
        vim.fs.dirname(
          vim.fs.normalize(vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("lua/rules/contract.lua", false)[1], ":p"))
        )
      )
    )

    ---@param script string  the name under scripts/
    ---@param args string[]
    ---@param env table<string, string>|nil
    ---@return vim.SystemCompleted
    local function run_script(script, args, env)
      local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", plugin_root .. "/scripts/" .. script }
      vim.list_extend(cmd, args)
      return vim.system(cmd, { text = true, env = vim.tbl_extend("force", { LIB_NVIM_DIR = lib_dir }, env or {}) }):wait(30000)
    end

    ---Run the check of a family in a fresh Neovim, the way a CI job does, and give back the status of the first rule.
    ---@param repo string
    ---@param env table<string, string>|nil
    ---@return string status
    local function headless_check(repo, env)
      local script = tmp_dir() .. "/check.lua"
      write_raw(
        script,
        table.concat({
          ("vim.opt.rtp:prepend(vim.fn.escape(%q, ','))"):format(norm(plugin_root)),
          ("vim.opt.rtp:append(vim.fn.escape(%q, ','))"):format(norm(lib_dir)),
          ("local _, _, results, err = require('rules').check_family_json('PRD', %q)"):format(norm(repo)),
          "io.stdout:write(results and results[1].status or ('error: ' .. tostring(err)))",
          "",
        }, "\n")
      )
      local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script }
      local done = vim.system(cmd, { text = true, env = env }):wait(30000)
      assert.are.equal(0, done.code, done.stderr)
      return done.stdout
    end

    it("trusts nothing a project file names, and the folders of $RULES_TRUST", function()
      if not lib_dir or lib_dir == "" then
        pending("LIB_NVIM_DIR is not set: the child process cannot find lib.nvim")
      end
      local repo, marker = foreign_repo()

      assert.are.equal("error", headless_check(repo))
      assert.is_false(exists(marker))

      assert.are.equal("pass", headless_check(repo, { RULES_TRUST = repo .. "/rules" }))
      assert.is_true(exists(marker))
    end)

    it("scripts/rules.lua takes --trust (repeatable) and refuses it without a value", function()
      if not lib_dir or lib_dir == "" then
        pending("LIB_NVIM_DIR is not set: the script cannot find lib.nvim")
      end
      local repo = foreign_repo()

      local ok =
        run_script("rules.lua", { "call", "snapshot", "--project=" .. repo, "--trust=" .. repo, "--trust=" .. tmp_dir() })
      local bare = run_script("rules.lua", { "call", "snapshot", "--trust" })
      local empty = run_script("rules.lua", { "call", "snapshot", "--trust=" })

      assert.are.equal(0, ok.code, ok.stderr .. ok.stdout)
      assert.are.equal(2, bare.code)
      assert.are.equal(2, empty.code)
    end)

    it("scripts/ruleset.lua takes --trust on every command", function()
      if not lib_dir or lib_dir == "" then
        pending("LIB_NVIM_DIR is not set: the script cannot find lib.nvim")
      end
      local repo = foreign_repo()

      local done = run_script("ruleset.lua", { "check", "--trust=" .. repo, repo .. "/rules" })
      local bare = run_script("ruleset.lua", { "check", "--trust" })

      assert.are.equal(0, done.code, done.stderr .. done.stdout)
      assert.are.equal(2, bare.code)
    end)
  end)
end)
