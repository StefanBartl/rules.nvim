-- The `lua_predicates` trust option, from the config key down to the runner.
---@diagnostic disable: need-check-nil
local config = require("rules.config")
local rules = require("rules")
local runner = require("rules.engine.runner")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

describe("rules.config.setup lua_predicates", function()
  it("defaults to true, so a user's own rulesets keep working", function()
    config.setup({})

    assert.is_true(config.get().lua_predicates)
  end)

  it("accepts false", function()
    config.setup({ lua_predicates = false })

    assert.is_false(config.get().lua_predicates)
    config.setup({})
  end)

  it("ERR-22: a non-boolean value degrades to the default instead of propagating", function()
    config.setup({ lua_predicates = false })
    config.setup({ lua_predicates = "no" })

    assert.is_true(config.get().lua_predicates)
  end)
end)

describe("rules.engine.runner.check_family lua_predicates", function()
  local function always_true()
    return true
  end

  ---@param id string
  ---@return table
  local function predicate_rule(id)
    return { id = id, severity = "recommended", check = { type = "lua_predicate", fn = always_true } }
  end

  local predicates = { predicate_rule("PRD-01"), predicate_rule("PRD-02") }

  it("runs predicates when no policy is given", function()
    local results = runner.check_family(predicates, "PRD", tmp_dir())

    assert.are.equal("pass", results[1].status)
    assert.are.equal("pass", results[2].status)
  end)

  it("reports every predicate as an error, visibly, when lua_predicates is false", function()
    local results = runner.check_family(predicates, "PRD", tmp_dir(), {}, { lua_predicates = false })

    for _, res in ipairs(results) do
      assert.are.equal("error", res.status)
      assert.matches("predicate not trusted", res.findings[1].text)
    end
  end)

  it("lets a function decide per rule", function()
    local results = runner.check_family(predicates, "PRD", tmp_dir(), {}, {
      lua_predicates = function(rule)
        return rule.id == "PRD-02"
      end,
    })

    assert.are.equal("error", results[1].status)
    assert.are.equal("pass", results[2].status)
  end)

  it("does not consult the policy for a rule that has no predicate", function()
    local asked = {}
    local mixed = {
      { id = "ASK-01", severity = "recommended", check = { type = "file_exists", path = "a.lua" } },
      { id = "ASK-02", severity = "recommended" },
      predicate_rule("ASK-03"),
    }
    local dir = tmp_dir()
    vim.fn.writefile({ "x" }, dir .. "/a.lua")

    runner.check_family(mixed, "ASK", dir, {}, {
      lua_predicates = function(rule)
        asked[#asked + 1] = rule.id
        return true
      end,
    })

    assert.are.same({ "ASK-03" }, asked)
  end)

  it("treats a policy that throws as untrusted instead of aborting the family", function()
    local results = runner.check_family(predicates, "PRD", tmp_dir(), {}, {
      lua_predicates = function()
        error("trust store unreadable")
      end,
    })

    assert.are.equal(2, #results)
    for _, res in ipairs(results) do
      assert.are.equal("error", res.status)
      assert.matches("predicate not trusted", res.findings[1].text)
    end
  end)

  it("does not touch the other check types when predicates are off", function()
    local mixed = {
      { id = "MIX-01", severity = "recommended", check = { type = "file_exists", path = "a.lua" } },
      { id = "MIX-02", severity = "recommended" },
    }
    local dir = tmp_dir()
    vim.fn.writefile({ "x" }, dir .. "/a.lua")

    local results = runner.check_family(mixed, "MIX", dir, {}, { lua_predicates = false })

    assert.are.equal("pass", results[1].status)
    assert.are.equal("manual", results[2].status)
  end)
end)

describe("rules.check_family_json lua_predicates", function()
  --- A predicate parsed from a real block, the way a ruleset on disk is loaded.
  ---@return string dir
  local function predicate_ruleset()
    local dir = tmp_dir()
    vim.fn.writefile({
      "```rule",
      'id = "PRD-01",',
      'severity = "critical",',
      'check = { type = "lua_predicate", fn = function(root) return vim.fn.isdirectory(root) == 1 end },',
      "```",
    }, dir .. "/p.md")
    return dir
  end

  it("runs a parsed predicate with the real environment by default", function()
    config.setup({ rulesets = { predicate_ruleset() } })

    local _, code, results = rules.check_family_json("PRD", tmp_dir())

    assert.are.equal("pass", results[1].status)
    assert.are.equal(0, code)
  end)

  it("reports a parsed predicate as an error once setup({ lua_predicates = false }) says so", function()
    config.setup({ rulesets = { predicate_ruleset() }, lua_predicates = false })

    local _, _, results = rules.check_family_json("PRD", tmp_dir())

    assert.are.equal("error", results[1].status)
    assert.matches("predicate not trusted", results[1].findings[1].text)
    config.setup({})
  end)
end)
