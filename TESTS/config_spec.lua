local config = require("rules.config")

describe("rules.config.setup", function()
  it("accepts a valid rulesets list and gates table", function()
    config.setup({ rulesets = { "/a", "/b" }, gates = { release = { "REL" } } })

    assert.are.same({ "/a", "/b" }, config.get().rulesets)
    assert.are.same({ release = { "REL" } }, config.get().gates)
  end)

  it("ERR-22: an invalid rulesets value degrades to the default instead of propagating", function()
    config.setup({ rulesets = { "/a" } }) -- establish a known non-default state first
    config.setup({ rulesets = "not-a-list" })

    assert.are.same({}, config.get().rulesets) -- DEFAULTS.rulesets
  end)

  it("ERR-22: a rulesets list with a non-string entry degrades to the default", function()
    config.setup({ rulesets = { "/a" } })
    config.setup({ rulesets = { "/a", 5 } })

    assert.are.same({}, config.get().rulesets)
  end)

  it("ERR-22: an invalid gates value degrades to the default instead of propagating", function()
    config.setup({ gates = { release = { "REL" } } })
    config.setup({ gates = "not-a-table" })

    assert.are.same({}, config.get().gates) -- DEFAULTS.gates
  end)

  it("ERR-22: a gates entry whose family list has a non-string entry degrades to the default", function()
    config.setup({ gates = { release = { "REL" } } })
    config.setup({ gates = { release = { "REL", 5 } } })

    assert.are.same({}, config.get().gates)
  end)

  it("leaves an unrelated valid key untouched when the other key is invalid", function()
    config.setup({ rulesets = { "/a" }, gates = "not-a-table" })

    assert.are.same({ "/a" }, config.get().rulesets)
    assert.are.same({}, config.get().gates)
  end)

  it("ERR-50: warns with a did-you-mean hint on a typo'd top-level key, instead of silently dropping it", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    local original_notify = vim.notify
    local messages = {}
    vim.notify = function(msg, _)
      messages[#messages + 1] = msg
    end

    config.setup({ ruleset = { "/a" } }) -- typo: "ruleset", not "rulesets"
    vim.notify = original_notify

    assert.are.same({}, config.get().rulesets) -- the typo'd value never lands
    assert.is_true(#messages > 0)
    assert.matches("ruleset", messages[#messages])
    assert.matches("did you mean rulesets", messages[#messages])
  end)

  it("ERR-50: does not warn for the two known top-level keys", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    local original_notify = vim.notify
    local messages = {}
    vim.notify = function(msg, _)
      messages[#messages + 1] = msg
    end

    config.setup({ rulesets = { "/a" }, gates = { release = { "REL" } } })
    vim.notify = original_notify

    assert.are.equal(0, #messages)
  end)
end)
