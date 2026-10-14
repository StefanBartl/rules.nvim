-- TESTS/vault_spec.lua -- the rules-vault: the Lua API, git state, :checkhealth, the contract and the headless tools.
---@diagnostic disable: need-check-nil
local config = require("rules.config")
local settings = require("rules.settings")
local vault_api = require("rules.vault")
local api = require("rules.api")
local contract = require("rules.contract")

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

local DEP_DOCUMENT = table.concat({
  "# Dependencies",
  "",
  "### `DEP-01` — one",
  "",
  "```rule",
  'id = "DEP-01",',
  'severity = "recommended",',
  'check = { type = "grep", pattern = "foo" },',
  "```",
  "",
  "Text of one.",
  "",
  "### `DEP-09` — nine",
  "",
  "```rule",
  'id = "DEP-09",',
  'severity = "critical",',
  "```",
  "",
  "Text of nine.",
  "",
}, "\n")

local ERR_RULE = table.concat({
  "---",
  "id: ERR-100",
  "severity: nice-to-have",
  "family: ERR",
  "---",
  "",
  "#### `ERR-100` — a rule of its own",
  "",
  "Prose of the rule.",
  "",
}, "\n")

---A vault with two rulesets: `lua` (a document) and `native` (one file per rule). Returns the vault and both folders.
---@return string vault, string lua, string native
local function make_vault()
  local vault = tmp_dir() .. "/rules-vault"
  write_raw(vault .. "/rulesets/lua/DEP.md", DEP_DOCUMENT)
  write_raw(vault .. "/rulesets/native/_rules/ERR/ERR-100.md", ERR_RULE)
  return vault, vault .. "/rulesets/lua", vault .. "/rulesets/native"
end

local ENV = { "RULES_VAULT", "RULES_PROJECT", "RULES_RULESETS", "RULES_GATES" }

---@param fn fun()
---@return { text: string, level: integer }[]
local function capture(fn)
  local original = vim.notify
  local messages = {}
  vim.notify = function(msg, level)
    messages[#messages + 1] = { text = msg, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = original
  assert(ok, err)
  return messages
end

describe("rules.vault", function()
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

  describe("the Lua API", function()
    it("says there is no vault, with a message and no error, when nothing names one", function()
      local project = tmp_dir()

      local root, message = vault_api.root({ project = project })

      assert.is_nil(root)
      assert.is_truthy(message:find("no vault is configured", 1, true))
      assert.is_truthy(message:find("$RULES_VAULT", 1, true))
      assert.is_nil(vault_api.source({ project = project }))
      assert.are.same({}, vault_api.rulesets({ project = project }))
    end)

    it("gives the root, where it came from and the rulesets it offers", function()
      local vault, lua, native = make_vault()
      vim.env.RULES_VAULT = vault

      local root = vault_api.root({ project = tmp_dir() })

      assert.are.equal(norm(vault), root)
      assert.are.equal("env", vault_api.source({ project = tmp_dir() }))
      assert.are.same({ norm(lua), norm(native) }, vault_api.rulesets({ project = tmp_dir() }))

      config.setup({ vault = vault })
      assert.are.equal("setup", vault_api.source({ project = tmp_dir() }))
    end)

    it("takes the project of the working directory by default", function()
      local vault = make_vault()
      local project = tmp_dir()
      write_raw(project .. "/.rules.json", vim.json.encode({ vault = vault }))
      local cwd = vim.fn.getcwd()
      vim.fn.chdir(project)
      local ok, err = pcall(function()
        assert.are.equal("project", vault_api.source())
        assert.are.equal(norm(vault), vault_api.root())
      end)
      vim.fn.chdir(cwd)
      assert.is_true(ok, err)
    end)

    it("the vault's own file narrows what it offers", function()
      local vault, lua = make_vault()
      write_raw(vault .. "/.rules.json", vim.json.encode({ rulesets = { "rulesets/lua" } }))
      vim.env.RULES_VAULT = vault

      assert.are.same({ norm(lua) }, vault_api.rulesets({ project = tmp_dir() }))
    end)

    it("answers a vault that is no folder and a broken file with the reason, not with 'no vault'", function()
      vim.env.RULES_VAULT = tmp_dir() .. "/gone"
      local _, message = vault_api.root({ project = tmp_dir() })
      assert.is_truthy(message:find("not a folder", 1, true))

      vim.env.RULES_VAULT = nil
      local project = tmp_dir()
      write_raw(project .. "/.rules.json", "{ broken")
      local _, broken = vault_api.root({ project = project })
      assert.is_truthy(broken:find("not valid JSON", 1, true))
    end)
  end)

  describe("git_state", function()
    ---@return string
    local function git_repo()
      local dir = tmp_dir()
      vim.fn.system({ "git", "-C", dir, "init", "-q" })
      vim.fn.system({ "git", "-C", dir, "config", "user.email", "test@test" })
      vim.fn.system({ "git", "-C", dir, "config", "user.name", "test" })
      return dir
    end

    it("says nothing when git is not installed", function()
      local original = vim.fn.executable
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.fn.executable = function()
        return 0
      end
      local state = vault_api.git_state(tmp_dir())
      vim.fn.executable = original
      assert.is_nil(state)
    end)

    it("tells a folder that is no repository", function()
      if vim.fn.executable("git") ~= 1 then
        pending("git is not installed")
      end
      local state = vault_api.git_state(tmp_dir())
      assert.is_false(state.repo)
    end)

    it("tells a clean repository from one with something to commit, and reads nothing but state", function()
      if vim.fn.executable("git") ~= 1 then
        pending("git is not installed")
      end
      local dir = git_repo()
      write_raw(dir .. "/rulesets/lua/DEP.md", DEP_DOCUMENT)
      vim.fn.system({ "git", "-C", dir, "add", "-A" })
      vim.fn.system({ "git", "-C", dir, "commit", "-q", "-m", "base" })

      local clean = vault_api.git_state(dir)
      assert.is_true(clean.repo)
      assert.is_true(clean.clean)
      assert.are.equal(0, clean.changes)

      write_raw(dir .. "/rulesets/lua/NEW.md", "new")
      write_raw(dir .. "/rulesets/lua/DEP.md", DEP_DOCUMENT .. "\nmore\n")
      local dirty = vault_api.git_state(dir)
      assert.is_true(dirty.repo)
      assert.is_false(dirty.clean)
      assert.are.equal(2, dirty.changes)
    end)

    it("knows a folder inside another repository is not a repository of its own", function()
      if vim.fn.executable("git") ~= 1 then
        pending("git is not installed")
      end
      local dir = git_repo()
      vim.fn.mkdir(dir .. "/sub", "p")

      local state = vault_api.git_state(dir .. "/sub")

      assert.is_false(state.repo)
      assert.is_truthy(state.inside)
    end)

    it("compares the top of the work tree by real path (macOS /var is /private/var)", function()
      if vim.fn.executable("git") ~= 1 then
        pending("git is not installed")
      end
      local dir = git_repo()
      local real = vim.uv.fs_realpath(dir)

      assert.is_true(vault_api.git_state(real).repo)
      assert.is_true(vault_api.git_state(dir).repo)
    end)
  end)

  describe(":checkhealth", function()
    ---@param project string|nil
    ---@return string[] lines
    local function health(project)
      local lines = {}
      local names = { "start", "ok", "warn", "error", "info" }
      local original = {}
      for _, name in ipairs(names) do
        original[name] = vim.health[name]
        vim.health[name] = function(message)
          lines[#lines + 1] = name .. ": " .. tostring(message)
        end
      end
      local cwd = vim.fn.getcwd()
      if project then
        vim.fn.chdir(project)
      end
      local ok, err = pcall(require("rules.health").check)
      vim.fn.chdir(cwd)
      for _, name in ipairs(names) do
        vim.health[name] = original[name]
      end
      assert(ok, err)
      return lines
    end

    ---@param lines string[]
    ---@param needle string
    ---@return string|nil
    local function line_with(lines, needle)
      for _, line in ipairs(lines) do
        if line:find(needle, 1, true) then
          return line
        end
      end
      return nil
    end

    it("says a project file is optional when there is none, and the vault is too", function()
      local lines = health(tmp_dir())

      assert.is_truthy(line_with(lines, "info: no .rules.json in"))
      assert.is_truthy(line_with(lines, "info: no vault configured (optional)"))
    end)

    it("shows the vault, where the value came from, its rulesets and its git state", function()
      if vim.fn.executable("git") ~= 1 then
        pending("git is not installed")
      end
      local vault = make_vault()
      vim.fn.system({ "git", "-C", vault, "init", "-q" })
      vim.env.RULES_VAULT = vault

      local lines = health(tmp_dir())

      local found = line_with(lines, "ok: vault ")
      assert.is_truthy(found)
      assert.is_truthy(found:find(norm(vault), 1, true))
      assert.is_truthy(found:find("from $RULES_VAULT", 1, true))
      assert.is_truthy(line_with(lines, "the vault offers 2 ruleset(s): lua, native"))
      assert.is_truthy(line_with(lines, "uncommitted path(s)")) -- init without a commit: everything is untracked
      assert.is_truthy(line_with(lines, "rulesets come from: vault (every folder under rulesets/)"))
      assert.is_truthy(line_with(lines, "ok: 3 rule(s) loaded from 2 ruleset path(s), no errors"))
    end)

    it("shows that a project file was loaded and which settings came from where", function()
      local project = tmp_dir()
      write_raw(project .. "/.rules.json", vim.json.encode({ gates = { release = { "DEP" } }, agent = { batch_size = 3 } }))
      local vault = make_vault()
      config.setup({ vault = vault })

      local lines = health(project)

      local loaded = line_with(lines, "ok: project file ")
      assert.is_truthy(loaded)
      assert.is_truthy(loaded:find(norm(project) .. "/.rules.json", 1, true))
      assert.is_truthy(line_with(lines, "gates: release (project)"))
      assert.is_truthy(line_with(lines, "agent settings: batch_size (project)"))
    end)

    it("reports a broken project file as an error and loads nothing from it", function()
      local project = tmp_dir()
      write_raw(project .. "/.rules.json", '{"rulesets": 5}')

      local lines = health(project)

      local err = line_with(lines, "error: ")
      assert.is_truthy(line_with(lines, "rulesets must be a list of strings"))
      assert.is_truthy(err)
      assert.is_truthy(line_with(lines, "error: rulesets are not loaded"))
    end)

    it("warns about an unknown key and a machine path", function()
      local project = tmp_dir()
      local own = tmp_dir()
      write_raw(project .. "/.rules.json", vim.json.encode({ ruleset = {}, rulesets = { own } }))

      local lines = health(project)

      assert.is_truthy(line_with(lines, "unknown key(s) ignored: ruleset (did you mean rulesets?)"))
      assert.is_truthy(line_with(lines, "path of this machine"))
    end)
  end)

  describe("rules-export/1", function()
    ---@param doc table
    ---@return table
    local function stable(doc)
      local copy = vim.deepcopy(doc)
      copy.generated_at, copy.digest, copy.engine = nil, nil, nil
      return copy
    end

    ---@param method string
    ---@param request string|nil
    ---@param opts table
    ---@return table
    local function document(method, request, opts)
      local text, code = api.call(method, request, opts)
      assert.is_nil(code, text)
      return stable(vim.json.decode(text))
    end

    it("a vault with two rulesets gives the documents of the same two folders passed one by one", function()
      local vault, lua, native = make_vault()
      local explicit = { rulesets = { lua, native } }
      local by_vault = { vault = vault }

      for _, case in ipairs({
        { "snapshot", nil },
        { "list", '{"params":{"limit":10}}' },
        { "rule", '{"params":{"id":"ERR-100"}}' },
        { "next_id", '{"params":{"family":"DEP"}}' },
        { "sources", nil },
      }) do
        assert.are.same(document(case[1], case[2], explicit), document(case[1], case[2], by_vault), case[1])
      end
    end)

    it("reads $RULES_VAULT, with nothing else configured, exactly like the option", function()
      local vault, lua, native = make_vault()
      vim.env.RULES_VAULT = vault

      local from_env = document("snapshot", nil, {})

      assert.are.same(document("snapshot", nil, { rulesets = { lua, native } }), from_env)
      assert.are.equal(3, from_env.counts.rules)
    end)

    it("names a ruleset by its folder, never by a path of this machine", function()
      local vault = make_vault()
      vim.env.RULES_VAULT = vault

      for _, method in ipairs({ "snapshot", "sources", "list" }) do
        local text = api.call(method, method == "list" and '{"params":{"limit":10}}' or nil, {})
        assert.is_nil(text:find(norm(vault), 1, true), method)
        assert.is_nil(text:find(vault, 1, true), method)
        assert.is_nil(text:find(vim.fs.dirname(vault), 1, true), method)
      end
      local doc = vim.json.decode((api.call("snapshot", nil, {})))
      assert.are.equal("lua", doc.source.id) -- the first folder of the vault, by name
      local sources = {}
      for _, item in ipairs(doc.sources) do
        sources[#sources + 1] = item.path
      end
      assert.are.same({ "lua/DEP.md", "native/_rules/ERR/ERR-100.md" }, sources)
      for _, rule in ipairs(doc.rules) do
        assert.is_truthy(rule.source:match("^lua/") or rule.source:match("^native/"), rule.source)
      end
    end)

    it("ranks the call over setup() over the vault: an explicit ruleset list is not widened by the vault", function()
      local vault, lua, native = make_vault()
      vim.env.RULES_VAULT = vault
      config.setup({ rulesets = { native } })

      assert.are.equal(1, document("snapshot", nil, {}).counts.files)
      assert.are.equal(1, document("snapshot", nil, { rulesets = { lua } }).counts.files)
      assert.are.equal(2, document("snapshot", nil, { rulesets = { "@vault/lua", "@vault/native" } }).counts.files)
    end)

    it("takes the gates of the vault file and of the project file, the project over the vault", function()
      local vault = make_vault()
      write_raw(vault .. "/.rules.json", vim.json.encode({ gates = { release = { "DEP" }, review = { "ERR" } } }))
      local project = tmp_dir()
      write_raw(project .. "/.rules.json", vim.json.encode({ gates = { release = { "ERR" } } }))
      vim.env.RULES_VAULT = vault

      local without_project = document("snapshot", nil, {})
      local by_name = {}
      for _, g in ipairs(without_project.gates) do
        by_name[g.name] = g
      end
      assert.are.same({ "DEP" }, by_name.release.families)
      assert.are.same({ "ERR" }, by_name.review.families)

      local with_project = document("snapshot", nil, { project = project })
      by_name = {}
      for _, g in ipairs(with_project.gates) do
        by_name[g.name] = g
      end
      assert.are.same({ "ERR" }, by_name.release.families)
      assert.are.same({ "ERR" }, by_name.review.families)
    end)

    it("answers a vault that is no folder as an error document without the path", function()
      local gone = tmp_dir() .. "/gone"
      local doc = vim.json.decode((api.call("snapshot", nil, { vault = gone })))

      assert.are.equal("rules.error", doc.kind)
      assert.are.equal("invalid_argument", doc.code)
      assert.is_truthy(doc.message:find("not a folder", 1, true))
      assert.is_nil(doc.message:find("gone", 1, true))
    end)

    it("the host reads $RULES_VAULT", function()
      local vault = make_vault()
      vim.env.RULES_VAULT = vault

      local reply = require("rules.host").handle("5\tsnapshot\t")
      local doc = vim.json.decode(reply:match("^5\t(.*)$"))

      assert.are.equal("rules.snapshot", doc.kind)
      assert.are.equal(3, doc.counts.rules)
    end)

    it("the ops door writes into the vault's ruleset it picks", function()
      local vault = make_vault()
      vim.env.RULES_VAULT = vault
      local request =
        '{"client_op_id":"c-1","dry_run":true,"ops":[{"op":"new","family":"DEP","title":"from the vault","severity":"critical"}]}'

      local doc = vim.json.decode((api.call("ops", request, {})))

      assert.are.equal("rules.result", doc.kind)
      assert.is_true(doc.ok, vim.inspect(doc))
    end)

    it("the editor's helper uses the working directory as the project", function()
      assert.are.equal(vim.fn.getcwd(), contract.editor_opts().project)
      assert.are.equal("x", contract.editor_opts({ project = "x" }).project)
    end)
  end)

  describe("the headless tools", function()
    local lib_dir = vim.env.LIB_NVIM_DIR
    local plugin_root = vim.fs.dirname(
      vim.fs.dirname(
        vim.fs.normalize(vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("lua/rules/contract.lua", false)[1], ":p"))
      )
    )
    plugin_root = vim.fs.dirname(plugin_root)

    ---@param script string
    ---@param args string[]
    ---@param env table<string, string>|nil
    ---@return vim.SystemCompleted
    local function run(script, args, env)
      local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", plugin_root .. "/scripts/" .. script }
      vim.list_extend(cmd, args)
      local full = vim.tbl_extend("force", { LIB_NVIM_DIR = lib_dir }, env or {})
      return vim.system(cmd, { text = true, env = full }):wait(30000)
    end

    ---@param text string
    ---@return table
    local function stable_json(text)
      local doc = vim.json.decode(text)
      doc.generated_at, doc.digest, doc.engine = nil, nil, nil
      return doc
    end

    it("scripts/rules.lua finds the vault through $RULES_VAULT and answers what two --ruleset flags answer", function()
      if not lib_dir or lib_dir == "" then
        pending("LIB_NVIM_DIR is not set: the script cannot find lib.nvim")
      end
      local vault, lua, native = make_vault()

      local by_env = run("rules.lua", { "call", "snapshot" }, { RULES_VAULT = vault })
      local explicit = run("rules.lua", { "call", "snapshot", "--ruleset=" .. lua, "--ruleset=" .. native })

      assert.are.equal(0, by_env.code, by_env.stderr)
      assert.are.equal(0, explicit.code, explicit.stderr)
      assert.are.same(stable_json(explicit.stdout), stable_json(by_env.stdout))
      assert.is_nil(by_env.stdout:find(norm(vault), 1, true))
    end)

    it("scripts/rules.lua takes --vault, @vault/<name> and --project, and a broken file is exit code 1", function()
      if not lib_dir or lib_dir == "" then
        pending("LIB_NVIM_DIR is not set: the script cannot find lib.nvim")
      end
      local vault = make_vault()
      local project = tmp_dir()
      write_raw(project .. "/.rules.json", vim.json.encode({ rulesets = { "@vault/native" } }))

      local by_flag = run("rules.lua", { "call", "snapshot", "--vault=" .. vault, "--project=" .. project })
      assert.are.equal(0, by_flag.code, by_flag.stderr)
      assert.are.equal(1, vim.json.decode(by_flag.stdout).counts.rules) -- only native, as the project file says

      local by_env = run("rules.lua", { "call", "snapshot" }, { RULES_VAULT = vault, RULES_PROJECT = project })
      assert.are.equal(1, vim.json.decode(by_env.stdout).counts.rules)

      local named = run("rules.lua", { "call", "snapshot", "--ruleset=@vault/lua" }, { RULES_VAULT = vault })
      assert.are.equal(2, vim.json.decode(named.stdout).counts.rules)

      write_raw(project .. "/.rules.json", "{ broken")
      local broken = run("rules.lua", { "call", "snapshot", "--project=" .. project }, { RULES_VAULT = vault })
      assert.are.equal(1, broken.code)
      local doc = vim.json.decode(broken.stdout)
      assert.are.equal("invalid_argument", doc.code)
      assert.is_nil(broken.stdout:find(norm(project), 1, true))
    end)

    it("scripts/ruleset.lua catalog takes @vault/<name> and, without a folder, every ruleset of the vault", function()
      if not lib_dir or lib_dir == "" then
        pending("LIB_NVIM_DIR is not set: the script cannot find lib.nvim")
      end
      local vault = make_vault()

      local one = run("ruleset.lua", { "catalog", "--check", "@vault/lua" }, { RULES_VAULT = vault })
      assert.are.equal(0, one.code, one.stderr .. one.stdout)
      assert.is_truthy(one.stdout:find("no layouts found under", 1, true))
      assert.is_truthy(one.stdout:find("rulesets/lua", 1, true))

      local all = run("ruleset.lua", { "catalog", "--check" }, { RULES_VAULT = vault })
      assert.are.equal(0, all.code, all.stderr .. all.stdout)
      assert.is_truthy(all.stdout:find("rulesets/lua", 1, true))
      assert.is_truthy(all.stdout:find("rulesets/native", 1, true))

      local none = run("ruleset.lua", { "catalog", "--check" }, {})
      assert.are.equal(2, none.code)
      assert.is_truthy(none.stderr:find("no ruleset folder is configured", 1, true))

      local no_vault = run("ruleset.lua", { "catalog", "--check", "@vault/lua" }, {})
      assert.are.equal(2, no_vault.code)
      assert.is_truthy(no_vault.stderr:find("needs a vault", 1, true))
    end)
  end)

  describe("the editor", function()
    it("tells once, not on every command, that nothing is configured", function()
      local rules = require("rules")
      config.setup({})

      local first = capture(function()
        rules.load_rules(tmp_dir())
      end)
      local second = capture(function()
        rules.load_rules(tmp_dir())
      end)

      -- other specs of this process may have told it already; what matters is that it is never told twice
      assert.is_true(#first + #second <= 1)
      for _, m in ipairs(first) do
        assert.is_truthy(m.text:find("no ruleset is configured", 1, true))
        assert.is_truthy(m.text:find("$RULES_VAULT", 1, true))
      end
    end)

    it("loads the rules of the vault for :Rules check", function()
      local vault = make_vault()
      vim.env.RULES_VAULT = vault
      local target = tmp_dir()
      write_raw(target .. "/a.txt", "nothing")

      local json, _, results, err
      capture(function()
        json, _, results, err = require("rules").check_family_json("DEP", target)
      end)

      assert.is_nil(err)
      assert.is_truthy(json)
      assert.are.equal(2, #results)
    end)
  end)
end)
