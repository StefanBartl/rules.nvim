-- The test body itself is the guard for every value used below -- see
-- NEW-41 in this ecosystem's own rule catalog for the reasoning.
---@diagnostic disable: need-check-nil
local parser = require("rules.engine.parser")

--- Write `lines` to a fresh temp file and return its path.
---@param lines string[]
---@return string
local function write_tmp(lines)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)
  return path
end

describe("rules.engine.parser", function()
  it("extracts a single well-formed rule block", function()
    local path = write_tmp({
      "### `DEP-01` — example",
      "",
      "```rule",
      'id = "DEP-01",',
      'severity = "recommended",',
      "```",
      "",
      "Some prose that is not part of the block.",
    })

    local rules, errors = parser.extract_rules(path)

    assert.are.equal(0, #errors)
    assert.are.equal(1, #rules)
    assert.are.equal("DEP-01", rules[1].id)
    assert.are.equal("recommended", rules[1].severity)
    assert.are.equal(path, rules[1].source_file)
    assert.are.equal(3, rules[1].source_line)
  end)

  it("extracts multiple rule blocks from one file", function()
    local path = write_tmp({
      "```rule",
      'id = "DEP-01",',
      'severity = "recommended",',
      "```",
      "",
      "```rule",
      'id = "DEP-02",',
      'severity = "recommended",',
      "```",
    })

    local rules, errors = parser.extract_rules(path)

    assert.are.equal(0, #errors)
    assert.are.equal(2, #rules)
    assert.are.equal("DEP-01", rules[1].id)
    assert.are.equal("DEP-02", rules[2].id)
  end)

  it("parses a check table embedded in the block", function()
    local path = write_tmp({
      "```rule",
      'id = "DEP-06",',
      'severity = "recommended",',
      'check = { type = "grep", pattern = "vim%.tbl_flatten%(" },',
      "```",
    })

    local rules = parser.extract_rules(path)

    assert.are.equal("grep", rules[1].check.type)
    assert.are.equal("vim%.tbl_flatten%(", rules[1].check.pattern)
  end)

  it("ignores a file with no ```rule marker at all", function()
    local path = write_tmp({
      "# Just prose",
      "",
      "| ID | Rule |",
      "| --- | --- |",
      "| `DEP-01` | some legacy table row |",
    })

    local rules, errors = parser.extract_rules(path)

    assert.are.equal(0, #rules)
    assert.are.equal(0, #errors)
  end)

  it("reports a block missing `id` as an error, not a rule", function()
    local path = write_tmp({
      "```rule",
      'severity = "recommended",',
      "```",
    })

    local rules, errors = parser.extract_rules(path)

    assert.are.equal(0, #rules)
    assert.are.equal(1, #errors)
    assert.matches("no string `id`", errors[1])
  end)

  it("reports an unterminated block as an error", function()
    local path = write_tmp({
      "```rule",
      'id = "DEP-01",',
    })

    local rules, errors = parser.extract_rules(path)

    assert.are.equal(0, #rules)
    assert.are.equal(1, #errors)
    assert.matches("unterminated", errors[1])
  end)

  it("reports an unreadable file as an error, not a crash", function()
    local rules, errors = parser.extract_rules("/definitely/not/a/real/path.md")

    assert.are.equal(0, #rules)
    assert.are.equal(1, #errors)
  end)
end)
