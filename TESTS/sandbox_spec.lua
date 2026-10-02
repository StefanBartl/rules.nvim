---@diagnostic disable: need-check-nil
local sandbox = require("rules.util.sandbox")

describe("rules.util.sandbox.eval_table", function()
  it("evaluates a table-constructor body", function()
    local value, err = sandbox.eval_table('id = "A", n = 1 + 1', "t")

    assert.is_nil(err)
    assert.are.equal("A", value.id)
    assert.are.equal(2, value.n)
  end)

  it("reports a syntax error as a message, not a raise", function()
    local value, err = sandbox.eval_table("id = = 1", "chunk@x")

    assert.is_nil(value)
    assert.matches("chunk@x", err)
  end)

  it("reports a runtime error as one line", function()
    local value, err = sandbox.eval_table("id = missing.field", "t")

    assert.is_nil(value)
    assert.is_nil(err:find("\n", 1, true), "an error must fit one report line")
  end)

  it("gives the body no globals at all", function()
    for _, name in ipairs({ "vim", "os", "io", "require", "string", "ipairs", "print", "_G" }) do
      -- Reading an absent global is nil, not an error: what matters is that none is visible.
      local value = sandbox.eval_table("seen = " .. name .. " ~= nil", "t")
      assert.is_false(value.seen, name)
    end
  end)

  it("leaves the host's JIT and debug hook as it found them, on success and on failure", function()
    local jit_lib = rawget(_G, "jit")
    local jit_before = jit_lib and jit_lib.status()
    local hook = function() end
    debug.sethook(hook, "", 1e9)

    sandbox.eval_table('id = "A"', "t")
    local after_ok = debug.gethook()
    sandbox.eval_table("id = (function() while true do end end)()", "t")
    local after_failure = debug.gethook()
    debug.sethook()

    assert.are.equal(hook, after_ok)
    assert.are.equal(hook, after_failure)
    if jit_lib then
      assert.are.equal(jit_before, jit_lib.status())
    end
  end)
end)

describe("rules.util.sandbox.rebind", function()
  it("gives a predicate created by eval_table its environment back", function()
    local value = sandbox.eval_table("check = { fn = function() return vim ~= nil end }", "t")
    assert.is_false(value.check.fn(), "inside the sandbox the predicate sees no `vim`")

    assert.is_true(sandbox.rebind(value.check.fn))

    assert.is_true(value.check.fn())
  end)

  it("refuses a function it did not create", function()
    local own = function()
      return 1
    end

    assert.is_false(sandbox.rebind(own))
  end)
end)
