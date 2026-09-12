local runner = require("rules.engine.runner")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

describe("rules.engine.runner.family_of", function()
  it("extracts the leading-letter prefix", function()
    assert.are.equal("DEP", runner.family_of("DEP-01"))
    assert.are.equal("SEC", runner.family_of("SEC-45"))
    assert.are.equal("PERF", runner.family_of("PERF-53"))
  end)
end)

describe("rules.engine.runner.check_family", function()
  local rules = {
    { id = "DEP-01", severity = "recommended", check = { type = "grep", pattern = "vim%.loop%." } },
    { id = "DEP-02", severity = "recommended", check = nil },
    { id = "SEC-01", severity = "critical", check = { type = "grep", pattern = "does%.not%.occur" } },
  }

  it("only runs rules in the requested family", function()
    local dir = tmp_dir()
    vim.fn.writefile({ "vim.loop.new_timer()" }, dir .. "/a.lua")

    local results = runner.check_family(rules, "DEP", dir)

    assert.are.equal(2, #results)
    for _, res in ipairs(results) do
      assert.are.equal("DEP", runner.family_of(res.rule.id))
    end
  end)

  it("reports a rule with no check as manual, never as pass", function()
    local dir = tmp_dir()

    local results = runner.check_family(rules, "DEP", dir)

    local manual = vim.tbl_filter(function(r)
      return r.rule.id == "DEP-02"
    end, results)[1]

    assert.are.equal("manual", manual.status)
  end)

  it("reports a rule whose pattern occurs as fail with findings", function()
    local dir = tmp_dir()
    vim.fn.writefile({ "vim.loop.new_timer()" }, dir .. "/a.lua")

    local results = runner.check_family(rules, "DEP", dir)

    local dep01 = vim.tbl_filter(function(r)
      return r.rule.id == "DEP-01"
    end, results)[1]

    assert.are.equal("fail", dep01.status)
    assert.are.equal(1, #dep01.findings)
  end)
end)
