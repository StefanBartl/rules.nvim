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
end)
