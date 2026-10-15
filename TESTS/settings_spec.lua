-- TESTS/settings_spec.lua -- `.rules.json` of a project and of a vault, the rank of the places, the vault, `@vault/<name>`.
---@diagnostic disable: need-check-nil
local config = require("rules.config")
local settings = require("rules.settings")
local schema = require("rules.config.schema")
-- loading it exports environment variables (lib.nvim's root registry): do it before the state guard looks, not in a case
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
---@param value table|string
local function write_json(path, value)
  write_raw(path, type(value) == "string" and value or vim.json.encode(value))
end

---@param path string
---@return string
local function norm(path)
  return (vim.fs.normalize(path):gsub("/+$", ""))
end

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

---@param messages { text: string }[]
---@param needle string
---@return boolean
local function mentions(messages, needle)
  for _, m in ipairs(messages) do
    if m.text:find(needle, 1, true) then
      return true
    end
  end
  return false
end

---A vault with two rulesets, `lua` and `native`, and no `.rules.json`.
---@return string vault
local function make_vault()
  local vault = tmp_dir() .. "/rules-vault"
  vim.fn.mkdir(vault .. "/rulesets/native", "p")
  vim.fn.mkdir(vault .. "/rulesets/lua", "p")
  return vault
end

---@param project string
---@param value table|string
local function project_file(project, value)
  write_json(project .. "/.rules.json", value)
end

local ENV = { "RULES_VAULT", "RULES_PROJECT", "RULES_RULESETS", "RULES_GATES" }

describe("rules.settings", function()
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

  describe("the rank of the places", function()
    it("is call, setup, project, vault, default -- the one list that decides", function()
      assert.are.same({ "call", "setup", "project", "vault", "default" }, settings.RANK)
    end)

    it("takes the defaults when nothing names anything", function()
      local res = settings.resolve({})
      assert.are.same({}, res.rulesets)
      assert.are.same({}, res.gates)
      assert.are.equal(8, res.agent.batch_size)
      assert.are.equal("default", res.origin.rulesets)
      assert.are.equal(0, #res.problems)
    end)

    it("ranks setup() over the project file over the vault file over the defaults (gates, per name)", function()
      local vault, project = make_vault(), tmp_dir()
      write_json(vault .. "/.rules.json", { gates = { release = { "VAULT" }, review = { "VAULT" }, only_vault = { "V" } } })
      project_file(project, { gates = { release = { "PROJECT" }, review = { "PROJECT" } } })
      config.setup({ vault = vault, gates = { release = { "SETUP" } } })

      local res = settings.resolve({ project = project })

      assert.are.same({ "SETUP" }, res.gates.release) -- setup() beats both files
      assert.are.same({ "PROJECT" }, res.gates.review) -- the project file beats the vault file
      assert.are.same({ "V" }, res.gates.only_vault) -- the vault file beats the defaults
      assert.are.equal("setup", res.origin.gates.release)
      assert.are.equal("project", res.origin.gates.review)
      assert.are.equal("vault", res.origin.gates.only_vault)
    end)

    it("ranks a call over setup() (the headless entry points)", function()
      config.setup({ gates = { release = { "SETUP" } }, rulesets = { "/from/setup" } })

      local res = settings.resolve({ gates = { release = { "CALL" } }, rulesets = { "/from/call" } })

      assert.are.same({ "CALL" }, res.gates.release)
      assert.are.same({ "/from/call" }, res.rulesets)
      assert.are.equal("call", res.origin.rulesets)
    end)

    it("takes rulesets whole from the highest place that names them, never a concatenation", function()
      local project = tmp_dir()
      project_file(project, { rulesets = { "docs/rules" } })

      local from_project = settings.resolve({ project = project })
      assert.are.same({ norm(project) .. "/docs/rules" }, from_project.rulesets)
      assert.are.equal("project", from_project.origin.rulesets)

      config.setup({ rulesets = { "/from/setup" } })
      local from_setup = settings.resolve({ project = project })
      assert.are.same({ "/from/setup" }, from_setup.rulesets)
      assert.are.equal("setup", from_setup.origin.rulesets)
    end)

    it("counts an empty list as naming the rulesets: a project can say 'none'", function()
      local vault, project = make_vault(), tmp_dir()
      project_file(project, { rulesets = {} })
      config.setup({ vault = vault })

      local res = settings.resolve({ project = project })

      assert.are.same({}, res.rulesets)
      assert.are.equal("project", res.origin.rulesets)
    end)

    it("merges agent field by field and the scopes by family, a list is replaced", function()
      local vault, project = make_vault(), tmp_dir()
      write_json(vault .. "/.rules.json", {
        agent = {
          backends = { "ollama" },
          batch_size = 4,
          deny = { ".env*" },
          scopes = { LUA = { include = { "lua/**" } }, NEW = { include = { "README.md" } } },
        },
      })
      project_file(project, { agent = { batch_size = 2, deny = {}, scopes = { LUA = { include = { "src/**" } } } } })
      config.setup({ vault = vault, agent = { max_context_bytes = 1000 } })

      local agent = settings.resolve({ project = project }).agent

      assert.are.same({ "ollama" }, agent.backends)
      assert.are.equal(2, agent.batch_size) -- project over vault
      assert.are.equal(1000, agent.max_context_bytes) -- setup over the default
      assert.are.same({}, agent.deny) -- an empty list clears the list below it
      assert.are.same({ "src/**" }, agent.scopes.LUA.include) -- the family is replaced ...
      assert.are.same({ "README.md" }, agent.scopes.NEW.include) -- ... the others stay
    end)

    it("does not let a file switch lua_predicates: that is setup() only", function()
      local project = tmp_dir()
      project_file(project, { lua_predicates = false })

      local res
      local messages = capture(function()
        res = settings.resolve({ project = project })
        settings.notify(res)
      end)

      assert.is_true(res.lua_predicates)
      assert.is_true(mentions(messages, "lua_predicates"))
      assert.is_true(mentions(messages, "setup() option only"))
    end)
  end)

  describe("fails loudly, never to zero settings", function()
    it("names the file and says it is not JSON", function()
      local project = tmp_dir()
      write_raw(project .. "/.rules.json", '{ "rulesets": [ ')

      local res = settings.resolve({ project = project })

      assert.are.equal(1, #res.problems)
      local text = settings.error_text(res, false)
      assert.is_truthy(text:find(norm(project) .. "/.rules.json", 1, true))
      assert.is_truthy(text:find("not valid JSON", 1, true))
    end)

    it("names the key of a value of the wrong shape", function()
      local project = tmp_dir()
      project_file(project, { rulesets = "docs/rules", gates = { release = "REL" }, agent = { batch_size = 0 } })

      local text = settings.error_text(settings.resolve({ project = project }), false)

      assert.is_truthy(text:find("rulesets must be a list of strings", 1, true))
      assert.is_truthy(text:find("gates.release must be a list of strings", 1, true))
      assert.is_truthy(text:find("agent.batch_size must be a whole number of 1 or more", 1, true))
    end)

    it("refuses an empty file, a list, a scalar and a null", function()
      for _, content in ipairs({ "", "[1, 2]", "5", "null", '"text"', '{"vault": null}', '{"agent": []}x' }) do
        local project = tmp_dir()
        write_raw(project .. "/.rules.json", content)
        local res = settings.resolve({ project = project })
        assert.is_true(#res.problems > 0, ("content %q must be refused"):format(content))
      end
    end)

    it("refuses a scope without include, and a family key that is no object", function()
      local project = tmp_dir()
      -- raw JSON: LUA is an empty OBJECT here (a Lua {} would encode as an empty list)
      project_file(project, '{"agent":{"scopes":{"LUA":{},"NEW":"x"}}}')

      local text = settings.error_text(settings.resolve({ project = project }), false)

      assert.is_truthy(text:find("agent.scopes.LUA needs include", 1, true))
      assert.is_truthy(text:find("agent.scopes.NEW must be", 1, true))
    end)

    it("a file that is a folder is a problem, a missing file is not", function()
      local project = tmp_dir()
      assert.are.equal(0, #settings.resolve({ project = project }).problems)
      vim.fn.mkdir(project .. "/.rules.json", "p")

      local res = settings.resolve({ project = project })

      assert.are.equal(1, #res.problems)
      assert.is_truthy(settings.error_text(res, false):find("must be a file", 1, true))
    end)

    it("a file over the size limit is refused, not read", function()
      local project = tmp_dir()
      write_raw(project .. "/.rules.json", '{"rulesets":[' .. ('"a",'):rep(300000) .. '"a"]}')

      local text = settings.error_text(settings.resolve({ project = project }), false)

      assert.is_truthy(text:find("is larger than", 1, true))
    end)

    it("skips a byte order mark an editor on Windows adds", function()
      local project = tmp_dir()
      write_raw(project .. "/.rules.json", "\239\187\191" .. '{"gates":{"release":["REL"]}}')

      local res = settings.resolve({ project = project })

      assert.are.equal(0, #res.problems)
      assert.are.same({ "REL" }, res.gates.release)
    end)

    it("a refused file stops the check: the error comes back, no rules are loaded and none are 'zero'", function()
      local project = tmp_dir()
      write_raw(project .. "/.rules.json", "{ nope")
      config.setup({ rulesets = { tmp_dir() } })
      local rules = require("rules")

      local json, code, results, err
      local messages = capture(function()
        json, code, results, err = rules.check_family_json("DEP", project)
      end)

      assert.is_nil(json)
      assert.is_nil(code)
      assert.is_nil(results)
      assert.is_truthy(err:find(norm(project) .. "/.rules.json", 1, true))
      assert.is_false(mentions(messages, "matches no loaded rule")) -- not the 'zero rules' story

      local gate_json, _, _, gate_err = rules.run_gate_json("release", project)
      assert.is_nil(gate_json)
      assert.is_truthy(gate_err:find(".rules.json", 1, true))

      local loaded
      local shown = capture(function()
        loaded = rules.load_rules(project)
      end)
      assert.are.same({}, loaded)
      assert.is_true(mentions(shown, ".rules.json"))
      assert.are.equal(vim.log.levels.ERROR, shown[#shown].level)
    end)

    it("opening the file of a rule says why it cannot, when the settings of the working directory are broken", function()
      local project = tmp_dir()
      write_raw(project .. "/.rules.json", "{ nope")
      config.setup({ rulesets = { tmp_dir() } })
      local previous = vim.fn.getcwd()
      vim.fn.chdir(project)

      local ok, messages = pcall(capture, function()
        require("rules.ui.cmd").open_rule("DEP-01")
      end)
      vim.fn.chdir(previous)

      assert(ok, messages)
      assert.are.equal(1, #messages) -- not silence
      assert.are.equal(vim.log.levels.ERROR, messages[1].level)
      assert.is_truthy(messages[1].text:find("could not open DEP-01", 1, true))
      assert.is_truthy(messages[1].text:find(".rules.json", 1, true))
    end)

    it("opening the file of a rule that does not exist stays quiet: the form has just made it", function()
      config.setup({ rulesets = { tmp_dir() } })

      local messages = capture(function()
        require("rules.ui.cmd").open_rule("NOPE-99")
      end)

      assert.are.same({}, messages)
    end)

    it("the contract answers an error document that names the file kind but no path of this machine", function()
      local project = tmp_dir()
      write_raw(project .. "/.rules.json", "{ nope")
      local text = require("rules.api").call("snapshot", nil, { project = project, rulesets = { tmp_dir() } })
      local doc = vim.json.decode(text)

      assert.are.equal("rules.error", doc.kind)
      assert.are.equal("invalid_argument", doc.code)
      assert.is_truthy(doc.message:find("project .rules.json", 1, true))
      assert.is_nil(text:find(norm(project), 1, true))
      assert.is_nil(text:find(project, 1, true))
    end)

    it("tells [] from {} in a file: a list is no object, an object is no list", function()
      local refused = {
        ["[]"] = "must be an object, got an empty list",
        ['{"rulesets":{}}'] = "rulesets must be a list of strings, got an empty object",
        ['{"gates":[]}'] = "gates must map a gate name to a list of family prefixes, got an empty list",
        ['{"agent":[]}'] = "agent must be an object, got an empty list",
        ['{"agent":{"deny":{}}}'] = "agent.deny must be a list of strings, got an empty object",
        ['{"agent":{"scopes":[]}}'] = "agent.scopes must map a family",
        ['{"agent":{"scopes":{"LUA":[]}}}'] = "agent.scopes.LUA must be { include = { ... } }, got an empty list",
        ['{"agent":{"scopes":{"LUA":{"include":{}}}}}'] = "agent.scopes.LUA.include must be a list of strings",
        ['{"gates":{"release":{}}}'] = "gates.release must be a list of strings, got an empty object",
      }
      for content, expected in pairs(refused) do
        local project = tmp_dir()
        write_raw(project .. "/.rules.json", content)

        local text = settings.error_text(settings.resolve({ project = project }), false)

        assert.is_truthy(text, content .. " must be refused")
        assert.is_truthy(text:find(expected, 1, true), content .. " -> " .. tostring(text))
      end
    end)

    it("takes [] where a list is meant and {} where an object is meant: an empty one is 'none'", function()
      for _, content in ipairs({
        "{}",
        '{"rulesets":[]}',
        '{"gates":{}}',
        '{"agent":{}}',
        '{"agent":{"deny":[],"scopes":{}}}',
        '{"rulesets":[],"gates":{},"agent":{"backends":[]}}',
      }) do
        local project = tmp_dir()
        write_raw(project .. "/.rules.json", content)

        local res = settings.resolve({ project = project })

        assert.are.equal(0, #res.problems, content)
      end
    end)

    it("a project file with an empty object for rulesets does not blank out the vault: it is refused", function()
      local vault, project = make_vault(), tmp_dir()
      config.setup({ vault = vault })
      project_file(project, '{"rulesets":{}}')

      local res = settings.resolve({ project = project })

      assert.is_true(#res.problems > 0)
      assert.is_truthy(settings.error_text(res, false):find("rulesets must be a list", 1, true))
    end)

    it("a vault that is no folder is a problem that names where it was set", function()
      vim.env.RULES_VAULT = tmp_dir() .. "/nowhere"

      local text = settings.error_text(settings.resolve({}), false)

      assert.is_truthy(text:find("$RULES_VAULT", 1, true))
      assert.is_truthy(text:find("not a folder", 1, true))
      local portable = settings.error_text(settings.resolve({}), true)
      assert.is_nil(portable:find("nowhere", 1, true))
    end)
  end)

  describe("warns about a key it does not know (ERR-50)", function()
    it("with the nearest known key as a hint, in a project file", function()
      local project = tmp_dir()
      project_file(
        project,
        { ruleset = { "a" }, agent = { batchsize = 3, scopes = { LUA = { include = { "x" }, exclude = {} } } } }
      )

      local res = settings.resolve({ project = project })

      assert.are.equal(0, #res.problems) -- harmless: the rest of the file is used
      assert.are.equal(1, #res.warnings)
      local text = settings.format(res.warnings[1], false)
      assert.is_truthy(text:find("ruleset (did you mean rulesets?)", 1, true))
      assert.is_truthy(text:find("agent.batchsize (did you mean batch_size?)", 1, true))
      assert.is_truthy(text:find("agent.scopes.LUA.exclude (did you mean include?)", 1, true))
    end)

    it("shows each warning once, however often the settings are resolved", function()
      local project = tmp_dir()
      project_file(project, { ruleset = { "a" } })

      local messages = capture(function()
        for _ = 1, 3 do
          settings.notify(settings.resolve({ project = project }))
        end
      end)

      assert.are.equal(1, #messages)
      assert.are.equal(vim.log.levels.WARN, messages[1].level)
    end)

    it("knows the new setup() keys: a typo of vault or agent gets a hint", function()
      local messages = capture(function()
        config.setup({ vaullt = "x", agnt = {} })
      end)

      assert.is_true(mentions(messages, "vaullt (did you mean vault?)"))
      assert.is_true(mentions(messages, "agnt (did you mean agent?)"))
    end)

    it("does not warn for the known keys", function()
      local vault = make_vault()
      local messages = capture(function()
        config.setup({ vault = vault, agent = { batch_size = 3 }, rulesets = {}, gates = {}, lua_predicates = true })
      end)
      assert.are.equal(0, #messages)
    end)

    it("says why vault does not belong in the vault's own file", function()
      local vault = make_vault()
      write_json(vault .. "/.rules.json", { vault = "/elsewhere" })
      config.setup({ vault = vault })

      local res = settings.resolve({})

      assert.are.equal(1, #res.warnings)
      assert.is_truthy(settings.format(res.warnings[1], false):find("does not name another vault", 1, true))
    end)

    it("does not let a project file or a vault file set keys: that is setup() only", function()
      local vault, project = make_vault(), tmp_dir()
      write_json(vault .. "/.rules.json", { keys = { form = { submit = "<C-g>" } } })
      project_file(project, { keys = { form = { close = false } } })
      config.setup({ vault = vault })

      local res = settings.resolve({ project = project })

      -- one warning for each file, naming the key and why it is not taken
      assert.are.equal(2, #res.warnings)
      for _, warning in ipairs(res.warnings) do
        local text = settings.format(warning, false)
        assert.is_truthy(text:find("keys", 1, true))
        assert.is_truthy(text:find("setup() option only", 1, true))
      end
      assert.are.equal("<C-s>", config.get().keys.form.submit)
      assert.are.equal("q", config.get().keys.form.close)
    end)

    it("drops only the bad field of agent, not the block: deny survives a bad batch_size (ERR-22)", function()
      local messages = capture(function()
        config.setup({
          agent = { batch_size = "many", deny = { ".env*" }, models = { "m" }, scopes = { LUA = { include = { "lua/**" } } } },
        })
      end)

      assert.is_true(mentions(messages, "agent.batch_size must be a whole number"))
      assert.are.same({ ".env*" }, config.get().agent.deny)
      assert.are.same({ "m" }, config.get().agent.models)
      assert.are.same({ "lua/**" }, config.get().agent.scopes.LUA.include)
      assert.are.equal(8, config.get().agent.batch_size) -- only the field that was wrong falls back
      assert.are.same({ ".env*" }, settings.resolve({}).agent.deny)
    end)

    it("drops only the bad scope and the bad list inside agent, whatever order the fields come in", function()
      local messages = capture(function()
        config.setup({
          agent = {
            deny = { ".env*" },
            backends = "ollama",
            scopes = { BAD = {}, OK = { include = { "a" } }, WORSE = { include = { 1 } } },
          },
        })
      end)

      assert.is_true(mentions(messages, "agent.backends must be a list of strings"))
      assert.is_true(mentions(messages, "agent.scopes.BAD needs include"))
      assert.is_true(mentions(messages, "agent.scopes.WORSE.include must be a list of non-empty strings"))
      assert.are.same({ ".env*" }, config.get().agent.deny)
      assert.are.same({}, config.get().agent.backends)
      assert.are.same({ OK = { include = { "a" } } }, config.get().agent.scopes)
    end)

    it("drops an invalid setup() value and warns (ERR-22), keeping the valid ones", function()
      local messages = capture(function()
        config.setup({ agent = { batch_size = "many" }, vault = 5, gates = { release = { "REL" } } })
      end)

      assert.is_true(mentions(messages, "agent.batch_size must be a whole number"))
      assert.is_true(mentions(messages, "vault must be a folder path"))
      assert.are.same({ release = { "REL" } }, config.get().gates)
      assert.is_nil(config.get().vault)
      assert.are.equal(8, config.get().agent.batch_size)
    end)
  end)

  describe("the vault is found, in this order", function()
    it("setup({ vault }) over $RULES_VAULT over the vault of the project file", function()
      local from_setup, from_env, from_project = make_vault(), make_vault(), make_vault()
      local project = tmp_dir()
      project_file(project, { vault = from_project })

      assert.are.equal("project", settings.resolve({ project = project }).vault.source)
      assert.are.equal(norm(from_project), settings.resolve({ project = project }).vault.root)

      vim.env.RULES_VAULT = from_env
      local env = settings.resolve({ project = project }).vault
      assert.are.equal("env", env.source)
      assert.are.equal(norm(from_env), env.root)

      config.setup({ vault = from_setup })
      local setup = settings.resolve({ project = project }).vault
      assert.are.equal("setup", setup.source)
      assert.are.equal(norm(from_setup), setup.root)

      local call = settings.resolve({ project = project, vault = from_project }).vault
      assert.are.equal("call", call.source)
    end)

    it("a vault path in the project file may be relative to the file", function()
      local base = tmp_dir()
      vim.fn.mkdir(base .. "/shared/rules-vault/rulesets/lua", "p")
      vim.fn.mkdir(base .. "/project", "p")
      project_file(base .. "/project", { vault = "../shared/rules-vault" })

      local res = settings.resolve({ project = base .. "/project" })

      assert.are.equal(0, #res.problems)
      assert.are.equal(1, #res.warnings) -- a vault named by a project file: used, but its rulesets are not trusted
      assert.is_truthy(settings.format(res.warnings[1], true):find("vault: a project file names the vault", 1, true))
      assert.is_true(vim.uv.fs_realpath(res.vault.root) == vim.uv.fs_realpath(base .. "/shared/rules-vault"))
    end)

    it("guesses nothing: without a vault there is no vault, and that is not a problem", function()
      local res = settings.resolve({ project = tmp_dir() })

      assert.is_nil(res.vault)
      assert.are.equal(0, #res.problems)
      assert.are.equal(0, #res.warnings)
      assert.is_truthy(settings.nothing_configured(res):find("$RULES_VAULT", 1, true))
    end)

    it("an absolute vault path in a project file warns: it is a path of this machine in a repository", function()
      local vault, project = make_vault(), tmp_dir()
      project_file(project, { vault = vault })

      local res = settings.resolve({ project = project })

      assert.are.equal(2, #res.warnings) -- the key itself (not trusted), and that it is a path of this machine
      local portable = settings.format(res.warnings[2], true)
      assert.is_truthy(portable:find("path of this machine", 1, true))
      assert.is_nil(portable:find(vault, 1, true)) -- the warning itself carries no path in a document
      assert.is_nil(settings.format(res.warnings[1], true):find(vault, 1, true))
      assert.is_truthy(settings.format(res.warnings[2], false):find(vault, 1, true))
    end)
  end)

  describe("every folder under rulesets/ is a ruleset (discovery)", function()
    it("loads the folders sorted by name, not the files and not the hidden ones", function()
      local vault = make_vault()
      vim.fn.mkdir(vault .. "/rulesets/.git", "p")
      write_raw(vault .. "/rulesets/NOTES.md", "not a ruleset")
      config.setup({ vault = vault })

      local res = settings.resolve({})

      assert.are.same({ norm(vault) .. "/rulesets/lua", norm(vault) .. "/rulesets/native" }, res.rulesets)
      assert.are.equal("vault (every folder under rulesets/)", res.origin.rulesets)
    end)

    it("the vault's own file may narrow ...", function()
      local vault = make_vault()
      write_json(vault .. "/.rules.json", { rulesets = { "rulesets/lua" } })
      config.setup({ vault = vault })

      assert.are.same({ norm(vault) .. "/rulesets/lua" }, settings.resolve({}).rulesets)
    end)

    it("... and extend, with a path relative to the file", function()
      local vault = make_vault()
      vim.fn.mkdir(vault .. "/extra/mine", "p")
      write_json(vault .. "/.rules.json", { rulesets = { "rulesets/lua", "extra/mine" } })
      config.setup({ vault = vault })

      local res = settings.resolve({})

      assert.are.same({ norm(vault) .. "/rulesets/lua", norm(vault) .. "/extra/mine" }, res.rulesets)
      assert.are.equal("vault", res.origin.rulesets)
    end)

    it("a vault file without rulesets (only gates) still offers every folder", function()
      local vault = make_vault()
      write_json(vault .. "/.rules.json", { gates = { release = { "REL" } } })
      config.setup({ vault = vault })

      local res = settings.resolve({})

      assert.are.equal(2, #res.rulesets)
      assert.are.same({ "REL" }, res.gates.release)
    end)

    it("a vault without a rulesets/ folder warns and offers none", function()
      local vault = tmp_dir() .. "/empty-vault"
      vim.fn.mkdir(vault, "p")
      config.setup({ vault = vault })

      local res = settings.resolve({})

      assert.are.same({}, res.rulesets)
      assert.are.equal(1, #res.warnings)
      assert.is_truthy(settings.format(res.warnings[1], false):find("no rulesets/ folder", 1, true))
    end)

    it("setup({ rulesets }) beats the discovery: the vault is then only there for @vault/<name>", function()
      local vault = make_vault()
      config.setup({ vault = vault, rulesets = { "@vault/native" } })

      assert.are.same({ norm(vault) .. "/rulesets/native" }, settings.resolve({}).rulesets)
    end)
  end)

  describe("@vault/<name>", function()
    it("is <vault>/rulesets/<name> in setup() and in a project file, with no machine path in the file", function()
      local vault, project = make_vault(), tmp_dir()
      project_file(project, { rulesets = { "@vault/lua", "docs/own" } })
      vim.env.RULES_VAULT = vault

      local res = settings.resolve({ project = project })

      assert.are.equal(0, #res.problems)
      assert.are.equal(0, #res.warnings) -- no absolute path in the file, so nothing to warn about
      assert.are.same({ norm(vault) .. "/rulesets/lua", norm(project) .. "/docs/own" }, res.rulesets)

      config.setup({ rulesets = { "@vault/native" } })
      assert.are.same({ norm(vault) .. "/rulesets/native" }, settings.resolve({ project = project }).rulesets)
    end)

    it("without a vault is an error that names the entry and how to get a vault", function()
      config.setup({ rulesets = { "@vault/lua" } })

      local text = settings.error_text(settings.resolve({}), false)

      assert.is_truthy(text:find('"@vault/lua" needs a vault', 1, true))
      assert.is_truthy(text:find("$RULES_VAULT", 1, true))
    end)

    it("cannot leave rulesets/: a name with .. or a separator or no name is refused", function()
      local vault = make_vault()
      vim.env.RULES_VAULT = vault
      local bad = { "@vault/../secret", "@vault/a/../b", "@vault", "@vault/", "@vault//a", "@vault/a\\b", "@vault/C:" }
      for _, entry in ipairs(bad) do
        config.setup({ rulesets = { entry } })
        local res = settings.resolve({})
        assert.is_true(#res.problems > 0, entry .. " must be refused")
        assert.are.same({}, res.rulesets, entry)
      end
    end)

    it("a relative entry of a file starts at the folder of that file, one of setup() at the working directory", function()
      local project = tmp_dir()
      project_file(project, { rulesets = { "a/b", "docs/rules" } })

      local res = settings.resolve({ project = project })

      assert.are.same({ norm(project) .. "/a/b", norm(project) .. "/docs/rules" }, res.rulesets)
      config.setup({ rulesets = { "rel/path" } })
      assert.are.same({ "rel/path" }, settings.resolve({ project = project }).rulesets)
    end)

    it("an absolute path in a project file warns, the same path in setup() does not", function()
      local project, ruleset = tmp_dir(), tmp_dir()
      project_file(project, { rulesets = { ruleset, "~/mine" } })

      local res = settings.resolve({ project = project })
      assert.are.equal(2, #res.warnings)
      for _, w in ipairs(res.warnings) do
        assert.is_truthy(settings.format(w, true):find("path of this machine", 1, true))
        assert.is_nil(settings.format(w, true):find(ruleset, 1, true))
      end
      assert.are.same({ ruleset, "~/mine" }, res.rulesets) -- still used: a warning is not a refusal

      config.setup({ rulesets = { ruleset } })
      assert.are.equal(0, #settings.resolve({}).warnings)
    end)

    it("scripts and the contract take it too: resolve_entry", function()
      local vault = make_vault()
      vim.env.RULES_VAULT = vault

      assert.are.equal(norm(vault) .. "/rulesets/lua", (settings.resolve_entry("@vault/lua")))
      assert.are.equal("some/dir", (settings.resolve_entry("some/dir")))
      vim.env.RULES_VAULT = nil
      local path, err = settings.resolve_entry("@vault/lua")
      assert.is_nil(path)
      assert.is_truthy(err:find("needs a vault", 1, true))
    end)
  end)

  describe("schema", function()
    it("checks one thing in one place for setup, a project file and a vault file", function()
      local checked = schema.check({ rulesets = { "a" }, vault = "x", lua_predicates = false }, "project")
      assert.are.same({ rulesets = { "a" }, vault = "x" }, checked.clean)
      assert.are.equal("lua_predicates", checked.unknown[1].key)

      local vault_checked = schema.check({ vault = "x" }, "vault")
      assert.is_nil(vault_checked.clean.vault)
      assert.are.equal("vault", vault_checked.unknown[1].key)
    end)

    it("takes an empty object and an empty list for 'nothing'", function()
      for _, value in ipairs({ {}, { gates = {} }, { gates = vim.empty_dict() } }) do
        assert.are.equal(0, #schema.check(value, "project").problems)
      end
    end)
  end)
end)
