local validate = require("rules.engine.agent.validate")

local RULE = { id = "DEP-01" }

--- A tree with `lua/a.lua` (five lines) and `lua/b.lua`, and the list of files a request carried.
---@return string root
---@return string[] sent
local function tree()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/lua", "p")
  vim.fn.writefile({ "local a = 1", "local b = require('x')", "local c = 3", "local d = 4", "local e = 5" }, dir .. "/lua/a.lua")
  vim.fn.writefile({ "return {}" }, dir .. "/lua/b.lua")
  return dir, { "lua/a.lua", "lua/b.lua" }
end

---@param entries table[]
---@return string
local function answer(entries)
  return vim.json.encode({ results = entries })
end

---@param extra? table
---@return table
local function violation(extra)
  return vim.tbl_extend("force", {
    rule = "DEP-01",
    verdict = "violation",
    checked = { "lua/a.lua" },
    findings = { { file = "lua/a.lua", line = 2, quote = "require('x')", why = "hidden dependency" } },
  }, extra or {})
end

describe("rules.engine.agent.validate a proposal", function()
  it("keeps a finding whose quote is in the file at the named line", function()
    local root, sent = tree()

    local result = validate.validate(RULE, answer({ violation() }), root, { sent = sent })

    assert.are.equal("violation", result.status)
    assert.are.equal(1, #result.findings)
    assert.are.equal("lua/a.lua", result.findings[1].file)
    assert.are.equal(2, result.findings[1].line)
    assert.are.equal("hidden dependency", result.findings[1].why)
  end)

  it("is a proposal, never a verdict: proposed, not verified, and no field that could read as a pass", function()
    local root, sent = tree()

    local violating = validate.validate(RULE, answer({ violation() }), root, { sent = sent })
    local compliant = validate.validate(
      RULE,
      answer({ { rule = "DEP-01", verdict = "compliant", checked = { "lua/b.lua" } } }),
      root,
      { sent = sent }
    )

    for _, result in ipairs({ violating, compliant }) do
      assert.is_true(result.proposed)
      assert.is_false(result.verified)
      assert.are_not.equal("pass", result.status)
    end
    assert.are.equal("compliant", compliant.status)
  end)

  it("finds a quote a few lines away from the named line, and not further", function()
    local root, sent = tree()
    local near = violation({ findings = { { file = "lua/a.lua", line = 5, quote = "require('x')" } } })
    local far = violation({ findings = { { file = "lua/a.lua", line = 5, quote = "require('x')" } } })

    assert.are.equal("violation", validate.validate(RULE, answer({ near }), root, { sent = sent }).status)
    assert.are.equal("unclear", validate.validate(RULE, answer({ far }), root, { sent = sent, window = 2 }).status)
  end)

  it("compares the quote literally, ignoring only the whitespace around it and the line endings", function()
    local root, sent = tree()
    vim.fn.writefile({ "x = 1", "y = 2" }, root .. "/lua/b.lua")
    local entry = violation({ findings = { { file = "lua/b.lua", line = 1, quote = "  x = 1\r\ny = 2 " } } })

    local result = validate.validate(RULE, answer({ entry }), root, { sent = sent })

    assert.are.equal("violation", result.status)
    assert.are.equal("x = 1\ny = 2", result.findings[1].quote)
  end)

  it("drops a finding that is not in the file and keeps the others", function()
    local root, sent = tree()
    local entry = violation({
      findings = {
        { file = "lua/a.lua", line = 2, quote = "require('x')" },
        { file = "lua/a.lua", line = 2, quote = "require('invented')" },
      },
    })

    local result = validate.validate(RULE, answer({ entry }), root, { sent = sent })

    assert.are.equal("violation", result.status)
    assert.are.equal(1, #result.findings)
    assert.are.equal(1, #result.dropped)
    assert.is_truthy(result.dropped[1].reason:find("does not occur", 1, true))
  end)

  it("turns a violation none of whose findings survive into unclear, naming what was dropped", function()
    local root, sent = tree()
    local entry = violation({ findings = { { file = "lua/a.lua", line = 2, quote = "not there" } } })

    local result = validate.validate(RULE, answer({ entry }), root, { sent = sent })

    assert.are.equal("unclear", result.status)
    assert.are.same({}, result.findings)
    assert.are.equal(1, #result.dropped)
  end)

  it("drops a finding in a file that was not sent, even when the file exists", function()
    local root, sent = tree()
    vim.fn.writefile({ "secret" }, root .. "/lua/secret.lua")
    local entry = violation({ findings = { { file = "lua/secret.lua", line = 1, quote = "secret" } } })

    local result = validate.validate(RULE, answer({ entry }), root, { sent = sent })

    assert.are.equal("unclear", result.status)
    assert.is_truthy(result.dropped[1].reason:find("was not sent", 1, true))
  end)

  it("drops a finding whose path climbs out of the tree", function()
    local root, sent = tree()
    local entry = violation({ findings = { { file = "../a.lua", line = 1, quote = "x" } } })

    assert.are.equal("unclear", validate.validate(RULE, answer({ entry }), root, { sent = sent }).status)
  end)

  it("drops a finding with a bad line, an empty quote or the wrong types", function()
    local root, sent = tree()
    local entry = violation({
      findings = {
        { file = "lua/a.lua", line = 0, quote = "require('x')" },
        { file = "lua/a.lua", line = 1.5, quote = "require('x')" },
        { file = "lua/a.lua", line = "2", quote = "require('x')" },
        { file = "lua/a.lua", line = 2, quote = "   " },
        { file = "lua/a.lua", line = 99, quote = "require('x')" },
        "not an object",
      },
    })

    local result = validate.validate(RULE, answer({ entry }), root, { sent = sent })

    assert.are.equal("unclear", result.status)
    assert.are.equal(6, #result.dropped)
  end)

  it("accepts the answer in one fenced json block", function()
    local root, sent = tree()
    local text = "```json\n" .. answer({ violation() }) .. "\n```"

    assert.are.equal("violation", validate.validate(RULE, text, root, { sent = sent }).status)
  end)
end)

describe("rules.engine.agent.validate what is never a guess", function()
  it("makes text that is not JSON unclear and attaches it", function()
    local root, sent = tree()

    local result = validate.validate(RULE, "Looks fine to me!", root, { sent = sent })

    assert.are.equal("unclear", result.status)
    assert.are.equal("Looks fine to me!", result.raw)
  end)

  it("makes JSON around prose unclear: nothing but one fenced block is stripped", function()
    local root, sent = tree()
    local text = "Here you go: " .. answer({ violation() })

    assert.are.equal("unclear", validate.validate(RULE, text, root, { sent = sent }).status)
  end)

  it("makes an answer outside the schema unclear and attaches it", function()
    local root, sent = tree()
    local cases = {
      vim.json.encode({ rules = {} }),
      vim.json.encode({ results = "none" }),
      vim.json.encode({ "a list" }),
      "42",
      answer({ { rule = "DEP-01", verdict = "maybe", checked = {} } }),
      answer({ { rule = "DEP-01", verdict = "violation", checked = "lua/a.lua" } }),
      answer({ { rule = "DEP-01", verdict = "violation", checked = {}, findings = "x" } }),
    }

    for _, text in ipairs(cases) do
      local result = validate.validate(RULE, text, root, { sent = sent })
      assert.are.equal("unclear", result.status, text)
      assert.are.equal(text, result.raw, text)
    end
  end)

  it("makes a rule the answer does not mention unclear, not missing", function()
    local root, sent = tree()

    local result = validate.validate(RULE, answer({ violation({ rule = "OTHER-01" }) }), root, { sent = sent })

    assert.are.equal("unclear", result.status)
    assert.is_truthy(result.reason:find("does not mention", 1, true))
  end)

  it("takes only the entry of its own rule from a batch answer", function()
    local root, sent = tree()
    local text = answer({
      violation({ rule = "OTHER-01", verdict = "compliant", findings = {} }),
      violation(),
    })

    assert.are.equal("violation", validate.validate(RULE, text, root, { sent = sent }).status)
  end)

  it("makes a rule named twice unclear", function()
    local root, sent = tree()

    local result = validate.validate(RULE, answer({ violation(), violation() }), root, { sent = sent })

    assert.are.equal("unclear", result.status)
    assert.is_truthy(result.reason:find("more than once", 1, true))
  end)

  it("makes an answer unclear when `checked` names a file that was not sent", function()
    local root, sent = tree()

    local result =
      validate.validate(RULE, answer({ violation({ checked = { "lua/a.lua", "lua/other.lua" } }) }), root, { sent = sent })

    assert.are.equal("unclear", result.status)
    assert.is_truthy(result.reason:find("not sent", 1, true))
  end)

  it("makes compliant unclear when no file is named as looked at", function()
    local root, sent = tree()

    local result =
      validate.validate(RULE, answer({ { rule = "DEP-01", verdict = "compliant", checked = {} } }), root, { sent = sent })

    assert.are.equal("unclear", result.status)
  end)

  it("makes compliant with findings unclear: the answer contradicts itself", function()
    local root, sent = tree()

    local result = validate.validate(RULE, answer({ violation({ verdict = "compliant" }) }), root, { sent = sent })

    assert.are.equal("unclear", result.status)
  end)

  it("passes the model's own unclear on, with its reason", function()
    local root, sent = tree()
    local entry = { rule = "DEP-01", verdict = "unclear", reason = "needs the build config" }

    local result = validate.validate(RULE, answer({ entry }), root, { sent = sent })

    assert.are.equal("unclear", result.status)
    assert.are.equal("needs the build config", result.reason)
  end)

  it("is unclear without the list of sent files, however good the answer", function()
    local root = tree()

    assert.are.equal("unclear", validate.validate(RULE, answer({ violation() }), root, {}).status)
    assert.are.equal("unclear", validate.validate(RULE, answer({ violation() }), root, { sent = "lua/a.lua" }).status)
  end)

  it("is unclear for an answer that is not text", function()
    local root, sent = tree()

    assert.are.equal("unclear", validate.validate(RULE, nil, root, { sent = sent }).status)
  end)

  it("never throws on a JSON null where a value is expected", function()
    local root, sent = tree()
    local text = '{"results":[{"rule":"DEP-01","verdict":"violation","checked":null,"findings":null}]}'

    assert.are.equal("unclear", validate.validate(RULE, text, root, { sent = sent }).status)
  end)
end)
