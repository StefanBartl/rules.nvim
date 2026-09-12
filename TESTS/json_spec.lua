local json = require("rules.report.json")

local function result(id, severity, status, findings)
  return { rule = { id = id, severity = severity }, status = status, findings = findings or {} }
end

describe("rules.report.json.to_entries", function()
  it("carries id, severity, status and findings through unchanged", function()
    local results = {
      result("DEP-01", "recommended", "fail", { { file = "a.lua", line = 3, text = "vim.loop.new_timer()" } }),
    }

    local entries = json.to_entries(results)

    assert.are.equal(1, #entries)
    assert.are.equal("DEP-01", entries[1].id)
    assert.are.equal("recommended", entries[1].severity)
    assert.are.equal("fail", entries[1].status)
    assert.are.equal("a.lua", entries[1].findings[1].file)
  end)
end)

describe("rules.report.json.encode", function()
  it("round-trips through vim.json.decode", function()
    local results = { result("DEP-01", "recommended", "pass") }

    local decoded = vim.json.decode(json.encode(results))

    assert.are.equal("DEP-01", decoded[1].id)
    assert.are.equal("pass", decoded[1].status)
  end)
end)

describe("rules.report.json.exit_code", function()
  it("is 0 when nothing failed", function()
    local results = { result("DEP-01", "recommended", "pass") }
    assert.are.equal(0, json.exit_code(results))
  end)

  it("is 0 when only a non-critical rule failed", function()
    local results = { result("DEP-01", "recommended", "fail", { { file = "a", line = 1, text = "x" } }) }
    assert.are.equal(0, json.exit_code(results))
  end)

  it("is 1 when a critical rule failed", function()
    local results = { result("SEC-01", "critical", "fail", { { file = "a", line = 1, text = "x" } }) }
    assert.are.equal(1, json.exit_code(results))
  end)

  it("is 1 when a critical rule's check errored", function()
    local results = { result("SEC-01", "critical", "error", { { file = "a", line = 1, text = "boom" } }) }
    assert.are.equal(1, json.exit_code(results))
  end)

  it("ignores a critical rule with no automated check (manual)", function()
    local results = { result("SEC-01", "critical", "manual") }
    assert.are.equal(0, json.exit_code(results))
  end)
end)
