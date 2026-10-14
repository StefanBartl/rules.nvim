-- TESTS/form_spec.lua -- the Markdown form behind `:Rules new`: template, parse, up-front checks, the one tick.
---@diagnostic disable: need-check-nil
local form = require("rules.form")
-- the form reads the severities and the limits from the contract and the door: load them before the guards look
require("rules.contract")
require("rules.ops")

---@param lines string[]
---@param from string
---@return integer
local function line_of(lines, from)
  for i, line in ipairs(lines) do
    if line:find(from, 1, true) == 1 then
      return i
    end
  end
  error("no line starting with " .. from)
end

describe("rules.form.template", function()
  it("makes a form with one bullet per severity, the family and title prefilled, and the prose", function()
    local lines = form.template({ family = "DEP", title = "One", severity = "critical", text = "A\nB", place = "after DEP-01" })
    assert.are.equal("# New rule", lines[1])
    assert.is_true(vim.tbl_contains(lines, "Family: DEP"))
    assert.is_true(vim.tbl_contains(lines, "Title: One"))
    assert.is_true(vim.tbl_contains(lines, "Place: after DEP-01"))
    assert.is_true(vim.tbl_contains(lines, "- [x] critical"))
    assert.is_true(vim.tbl_contains(lines, "- [ ] recommended"))
    assert.is_true(vim.tbl_contains(lines, "- [ ] nice-to-have"))
    assert.are.same({ "## text", "A", "B" }, vim.list_slice(lines, line_of(lines, "## text"), #lines))
  end)

  it("asks for a ruleset only when there are several", function()
    assert.is_nil(table.concat(form.template({ rulesets = { "A" } }), "\n"):find("Ruleset:", 1, true))
    local lines = form.template({ rulesets = { "A", "B" }, ruleset = "B" })
    assert.is_true(vim.tbl_contains(lines, "Ruleset: B"))
  end)

  it("round-trips: what the template says is what parse reads", function()
    local parsed = form.parse(form.template({ family = "DEP", title = "One", severity = "recommended", text = "x\n\ny" }))
    assert.are.equal("DEP", parsed.family)
    assert.are.equal("One", parsed.title)
    assert.are.same({ "recommended" }, parsed.ticks)
    assert.are.equal("x\n\ny", parsed.text)
  end)
end)

describe("rules.form.parse", function()
  it("ignores hints and the report at the top, and a bullet outside the severity list", function()
    local parsed = form.parse({
      "! The form was not submitted:",
      "! - Title is required",
      "# New rule",
      "<!-- hint -->",
      "Family: ERR",
      "Title:   spaced  ",
      "",
      "## severity (one)",
      "- [X] critical",
      "",
      "## text",
      "- [x] this is prose, not a choice",
    })
    assert.are.equal("ERR", parsed.family)
    assert.are.equal("spaced", vim.trim(parsed.title))
    assert.are.same({ "critical" }, parsed.ticks)
    assert.are.equal("- [x] this is prose, not a choice", parsed.text)
  end)

  it("keeps the prose as typed, a line that looks like a field or a hint included", function()
    local parsed = form.parse({ "Family: A", "## text", "Family: not a field", "<!-- not a hint -->", "! not a report", "" })
    assert.are.equal("A", parsed.family)
    assert.are.equal("Family: not a field\n<!-- not a hint -->\n! not a report", parsed.text)
  end)

  it("names a ticked choice that is no severity", function()
    local parsed = form.parse({ "## severity (one)", "- [x] urgent" })
    assert.are.same({ "urgent" }, parsed.unknown)
  end)
end)

describe("rules.form.validate", function()
  local function valid(over)
    return vim.tbl_extend(
      "force",
      { family = "DEP", title = "T", ruleset = "", place = "", ticks = { "critical" }, unknown = {}, text = "" },
      over or {}
    )
  end

  it("turns a complete form into one new operation", function()
    local op, errors = form.validate(valid({ text = "Prose", ruleset = "R", place = "after DEP-01" }))
    assert.are.same(0, #errors)
    assert.are.same(
      { op = "new", family = "DEP", title = "T", severity = "critical", text = "Prose", ruleset = "R", after = "DEP-01" },
      op
    )
  end)

  it("leaves text, ruleset and place out when they are empty", function()
    assert.are.same({ op = "new", family = "DEP", title = "T", severity = "critical" }, (form.validate(valid())))
  end)

  it("names every missing required field at once", function()
    local op, errors = form.validate(valid({ family = " ", title = "", ticks = {} }))
    assert.is_nil(op)
    local text = table.concat(errors, "\n")
    assert.is_truthy(text:find("Family is required", 1, true))
    assert.is_truthy(text:find("Title is required", 1, true))
    assert.is_truthy(text:find("severity: tick one", 1, true))
  end)

  it("refuses a family that is not letters, several ticks, an unknown tick and a place it cannot read", function()
    local _, e1 = form.validate(valid({ family = "DEP-1" }))
    assert.is_truthy(e1[1]:find("letters only", 1, true))
    local _, e2 = form.validate(valid({ ticks = { "critical", "recommended" } }))
    assert.is_truthy(e2[1]:find("pick one, 2 are ticked", 1, true))
    local _, e3 = form.validate(valid({ ticks = {}, unknown = { "urgent" } }))
    assert.are.same({ "unknown severity: urgent" }, e3)
    local _, e4 = form.validate(valid({ place = "a.md#" }))
    assert.is_truthy(e4[1]:find("Place:", 1, true))
  end)
end)

describe("rules.form.toggle", function()
  local base = form.template({ severity = "recommended" })

  it("ticks one severity and clears the others", function()
    local out = form.toggle(base, line_of(base, "- [ ] critical"))
    assert.is_true(vim.tbl_contains(out, "- [x] critical"))
    assert.is_true(vim.tbl_contains(out, "- [ ] recommended"))
  end)

  it("clears a ticked bullet", function()
    local out = form.toggle(base, line_of(base, "- [x] recommended"))
    assert.is_true(vim.tbl_contains(out, "- [ ] recommended"))
  end)

  it("is nil off the list: a field line, and a bullet in the prose", function()
    assert.is_nil(form.toggle(base, line_of(base, "Family:")))
    local with_prose = form.template({ text = "- [ ] item" })
    assert.is_nil(form.toggle(with_prose, #with_prose))
  end)
end)

describe("rules.form.strip_errors", function()
  it("drops the report at the top and nothing else", function()
    local lines = { "! The form was not submitted:", "! - x", "# New rule", "## text", "! kept: prose" }
    assert.are.same({ "# New rule", "## text", "! kept: prose" }, form.strip_errors(lines))
  end)

  it("makes the report lines it later strips", function()
    local lines = form.error_lines({ "a", "b" })
    assert.are.same({ "! The form was not submitted:", "! - a", "! - b" }, lines)
    assert.are.same({}, form.strip_errors(lines))
  end)
end)
