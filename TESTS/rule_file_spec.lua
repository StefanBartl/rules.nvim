-- TESTS/rule_file_spec.lua -- the one-file-per-rule form: how a file is told apart, what a rule file may say,
-- and that both forms load side by side with the same checks.
---@diagnostic disable: need-check-nil
local parser = require("rules.engine.parser")
local loader = require("rules.engine.loader")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

---@param path string
---@param lines string[]
local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

---@param frontmatter string[]  the lines between the `---` delimiters
---@param body string[]
---@return string[]
local function rule_file(frontmatter, body)
  local out = { "---" }
  vim.list_extend(out, frontmatter)
  out[#out + 1] = "---"
  out[#out + 1] = ""
  vim.list_extend(out, body)
  return out
end

local PLAIN = rule_file({ "id: DEP-01", "severity: recommended", "family: DEP" }, {
  "#### `DEP-01` — Titel der Regel",
  "",
  "Der Text der Regel.",
  "Zweite Zeile.",
})

describe("rules.engine.parser.classify", function()
  it("tells the kinds of file apart from their first lines", function()
    assert.are.equal("legacy", parser.classify({ "# A document", "", "```rule", 'id = "A-1",', "```" }))
    assert.are.equal("legacy", parser.classify({}))
    assert.are.equal("generated", parser.classify({ parser.GENERATED_PREFIX .. " from x: do not edit -->", "# T" }))
    assert.are.equal("layout", parser.classify({ "---", "kind: layout", "output: a.md", "---", "# T" }))
    assert.are.equal("rule", parser.classify(PLAIN))
  end)

  it("takes a frontmatter without an id for a legacy document", function()
    assert.are.equal("legacy", parser.classify({ "---", "title: A document", "---", "", "```rule", "```" }))
  end)

  it("does not mistake two separators around prose for a frontmatter", function()
    assert.are.equal("legacy", parser.classify({ "---", "just some words", "---", "", "text" }))
    assert.are.equal("legacy", parser.classify({ "---", "id: A-1" })) -- never closed
  end)

  it("reads a rule file that starts with a byte order mark as a generated catalog only when it is one", function()
    assert.are.equal("generated", parser.classify({ "\239\187\191" .. parser.GENERATED_PREFIX .. " from x -->" }))
  end)

  it("treats a frontmatter whose id is unreadable as a rule file, so the error is told", function()
    assert.are.equal("rule", parser.classify({ "---", "id: [a, b]", "severity: critical", "---" }))
  end)
end)

describe("rules.engine.parser.extract_rules, a rule file", function()
  ---@param lines string[]
  ---@return Rules.ParsedRule[] rules, string[] errors, string path
  local function extract(lines)
    local path = tmp_dir() .. "/rule.md"
    write(path, lines)
    local rules, errors = parser.extract_rules(path)
    return rules, errors, path
  end

  it("reads a rule that has no block at all", function()
    local rules, errors, path = extract(PLAIN)

    assert.are.same({}, errors)
    assert.are.equal(1, #rules)
    local rule = rules[1]
    assert.are.equal("DEP-01", rule.id)
    assert.are.equal("recommended", rule.severity)
    assert.is_nil(rule.check)
    assert.is_nil(rule.agent)
    assert.are.equal("`DEP-01` — Titel der Regel", rule.title)
    assert.is_nil(rule.section)
    assert.are.equal("Der Text der Regel.\nZweite Zeile.", rule.text)
    assert.are.equal(path, rule.source_file)
    -- the heading is the 7th line of the file (5 of frontmatter, a blank line, then the heading)
    assert.are.equal(7, rule.source_line)
  end)

  it("reads a rule whose block holds only what the frontmatter cannot say", function()
    local rules, errors = extract(rule_file({ "id: DEP-06", "severity: critical" }, {
      "#### `DEP-06` — grep",
      "",
      "```rule",
      'check = { type = "grep", pattern = "vim%.tbl_flatten%(" },',
      "```",
      "",
      "Prose after the block.",
    }))

    assert.are.same({}, errors)
    assert.are.equal("grep", rules[1].check.type)
    assert.are.equal("critical", rules[1].severity)
    assert.are.equal("Prose after the block.", rules[1].text)
    assert.are.equal(8, rules[1].source_line) -- the block's own line, as in a legacy document
  end)

  it("accepts a block that repeats id and severity when they agree with the frontmatter", function()
    local rules, errors = extract(rule_file({ "id: DEP-02", "severity: recommended" }, {
      "#### `DEP-02`",
      "",
      "```rule",
      'id = "DEP-02",',
      'severity = "recommended",',
      "```",
    }))
    assert.are.same({}, errors)
    assert.are.equal("DEP-02", rules[1].id)
  end)

  it("refuses a block whose id or severity differs from the frontmatter", function()
    local rules, errors = extract(rule_file({ "id: DEP-02", "severity: recommended" }, {
      "```rule",
      'id = "DEP-99",',
      "```",
    }))
    assert.are.equal(0, #rules)
    assert.matches("block `id` DEP%-99 differs from the frontmatter `id` DEP%-02", errors[1])

    rules, errors = extract(rule_file({ "id: DEP-02", "severity: recommended" }, {
      "```rule",
      'severity = "critical",',
      "```",
    }))
    assert.are.equal(0, #rules)
    assert.matches("block `severity` critical differs from the frontmatter `severity` recommended", errors[1])
  end)

  it("keeps an empty block as a marker", function()
    local rules, errors = extract(rule_file({ "id: DEP-03", "severity: nice-to-have" }, {
      "#### `DEP-03`",
      "",
      "```rule",
      "```",
      "",
      "Text.",
    }))
    assert.are.same({}, errors)
    assert.are.equal("nice-to-have", rules[1].severity)
    assert.are.equal("Text.", rules[1].text)
  end)

  it("validates the frontmatter the way a block is validated", function()
    local function fails(frontmatter, pattern)
      local rules, errors = extract(rule_file(frontmatter, { "#### x" }))
      assert.are.equal(0, #rules, table.concat(frontmatter, " | "))
      assert.matches(pattern, errors[1], table.concat(frontmatter, " | "))
    end
    fails({ "severity: critical" }, "no string `id`")
    fails({ "id: A-1" }, "no string `severity`")
    fails({ "id: A-1", "severity: urgent" }, "invalid `severity`")
    fails({ "id: A-1", "severity: critical", "colour: red" }, "unknown frontmatter key `colour`")
    fails({ "id: A-1", "severity: critical", "family: DEP" }, "`family` DEP does not match")
    fails({ "id: [a, b]", "severity: critical" }, "no string `id`")
    fails({ "id: " .. string.rep("A", 101), "severity: critical" }, "at most 100 bytes")
    fails({ 'id: A"1', "severity: critical" }, "no control characters, quote or backslash")
  end)

  it("takes the family from the id, and lets the frontmatter leave it out", function()
    local rules, errors = extract(rule_file({ "id: PRIN-01", "severity: critical" }, { "#### `PRIN-01`" }))
    assert.are.same({}, errors)
    assert.are.equal("PRIN-01", rules[1].id)
    rules, errors = extract(rule_file({ "id: PRIN-01", "severity: critical", "family: PRIN" }, { "#### `PRIN-01`" }))
    assert.are.same({}, errors)
    assert.are.equal(1, #rules)
  end)

  it("refuses an unterminated block and two blocks", function()
    local rules, errors = extract(rule_file({ "id: A-1", "severity: critical" }, { "```rule", "check = {}," }))
    assert.are.equal(0, #rules)
    assert.matches("unterminated ```rule block", errors[1])

    rules, errors = extract(rule_file({ "id: A-1", "severity: critical" }, {
      "```rule",
      "```",
      "text",
      "```rule",
      "```",
    }))
    assert.are.equal(0, #rules)
    assert.matches("more than one ```rule block", errors[1])
  end)

  it("evaluates the block in the empty environment", function()
    local rules, errors = extract(rule_file({ "id: A-1", "severity: critical" }, {
      "```rule",
      'check = { type = os.execute("echo hi") },',
      "```",
    }))
    assert.are.equal(0, #rules)
    assert.is_true(#errors >= 1)
  end)

  it("drops an invalid agent and reports it, the rule stays", function()
    local rules, errors = extract(rule_file({ "id: A-1", "severity: critical" }, {
      "```rule",
      'agent = { colour = "red" },',
      "```",
    }))
    assert.are.equal(1, #rules)
    assert.is_nil(rules[1].agent)
    assert.matches("invalid `agent` field", errors[1])
  end)

  it("keeps a valid agent", function()
    local rules, errors = extract(rule_file({ "id: A-1", "severity: critical" }, {
      "```rule",
      'agent = { question = "Is it?", max_files = 3 },',
      "```",
    }))
    assert.are.same({}, errors)
    assert.are.equal("Is it?", rules[1].agent.question)
    assert.are.equal(3, rules[1].agent.max_files)
  end)

  it("leaves a heading that does not name the rule without a title", function()
    local rules = extract(rule_file({ "id: A-1", "severity: critical" }, { "#### Something else", "", "Text." }))
    assert.is_nil(rules[1].title)
    assert.are.equal("Text.", rules[1].text)
  end)

  it("ends the text at the next heading and does not see a heading in a fence", function()
    local rules = extract(rule_file({ "id: A-1", "severity: critical" }, {
      "#### `A-1`",
      "",
      "Before.",
      "```bash",
      "# a comment, not a heading",
      "```",
      "After the fence.",
      "---",
      "",
      "## The next section",
      "never in the text",
    }))
    assert.are.equal("Before.\n```bash\n# a comment, not a heading\n```\nAfter the fence.", rules[1].text)
  end)

  it("has an empty text when nothing follows", function()
    local rules = extract(rule_file({ "id: A-1", "severity: critical" }, { "#### `A-1`" }))
    assert.are.equal("", rules[1].text)
  end)

  it("reads a file without a heading", function()
    local rules, errors = extract(rule_file({ "id: A-1", "severity: critical" }, { "Only text." }))
    assert.are.same({}, errors)
    assert.are.equal("Only text.", rules[1].text)
    assert.is_nil(rules[1].title)
  end)

  it("yields nothing for a catalog the generator wrote and for a layout", function()
    local rules, errors = extract({
      parser.GENERATED_PREFIX .. " from x: do not edit -->",
      "```rule",
      'id = "DEP-01",',
      'severity = "critical",',
      "```",
    })
    assert.are.same({}, rules)
    assert.are.same({}, errors)

    rules, errors = extract({ "---", "kind: layout", "output: a.md", "---", "{{rule DEP-01}}" })
    assert.are.same({}, rules)
    assert.are.same({}, errors)
  end)

  it("still reads a legacy document that starts with a frontmatter without an id", function()
    local rules, errors = extract({
      "---",
      "title: Notes",
      "---",
      "",
      "```rule",
      'id = "DEP-01",',
      'severity = "critical",',
      "```",
    })
    assert.are.same({}, errors)
    assert.are.equal(1, #rules)
  end)
end)

describe("rules.engine.parser.read_rule_file and split_text", function()
  it("splits a file into the parts the generator needs", function()
    local path = tmp_dir() .. "/r.md"
    write(path, PLAIN)
    local split, errors = parser.read_rule_file(path)

    assert.are.same({}, errors)
    assert.are.equal("DEP-01", split.id)
    assert.are.equal("DEP", split.family)
    assert.are.equal(1, split.heading)
    assert.is_nil(split.block)
    assert.are.equal("#### `DEP-01` — Titel der Regel", split.lines[1])
    assert.are.equal(6, split.offset)
    assert.are.equal(2, parser.implicit_split(split)) -- the heading and the blank line under it
  end)

  it("gives the same from a text", function()
    local split = parser.split_text("x.md", table.concat(PLAIN, "\n") .. "\n")
    assert.are.equal("DEP-01", split.id)
    assert.are.equal(4, #split.lines)
  end)

  it("finds the block", function()
    local split = parser.split_text(
      "x.md",
      table.concat(rule_file({ "id: A-1", "severity: critical" }, { "# h", "", "```rule", "check = {},", "```", "", "t" }), "\n")
    )
    assert.are.same({ s = 3, e = 5 }, split.block)
  end)

  it("reports what is not a rule file", function()
    local split, errors = parser.split_text("x.md", "# just a document\n")
    assert.is_nil(split)
    assert.matches("not a rule file", errors[1])
    split, errors = parser.read_rule_file(tmp_dir() .. "/missing.md")
    assert.is_nil(split)
    assert.is_true(#errors >= 1)
  end)

  it("has no heading to split after when there is none", function()
    local split = parser.split_text("x.md", table.concat(rule_file({ "id: A-1", "severity: critical" }, { "text" }), "\n"))
    assert.is_nil(split.heading)
    assert.are.equal(0, parser.implicit_split(split))
  end)
end)

describe("rules.engine.loader, both forms", function()
  it("loads a legacy document and rule files in one run", function()
    local dir = tmp_dir()
    write(dir .. "/doc.md", { "```rule", 'id = "OLD-01",', 'severity = "recommended",', "```" })
    write(dir .. "/_rules/NEW/NEW-01.md", rule_file({ "id: NEW-01", "severity: critical" }, { "#### `NEW-01`", "", "Text." }))
    write(
      dir .. "/_rules/NEW/NEW-02.md",
      rule_file({ "id: NEW-02", "severity: critical" }, { "#### `NEW-02`", "", "```rule", "check = {},", "```" })
    )

    local rules, errors = loader.load({ dir })

    assert.are.same({}, errors)
    local ids = {}
    for _, rule in ipairs(rules) do
      ids[#ids + 1] = rule.id
    end
    table.sort(ids)
    assert.are.same({ "NEW-01", "NEW-02", "OLD-01" }, ids)
  end)

  it("reports an id that is in both forms as a duplicate", function()
    local dir = tmp_dir()
    write(dir .. "/doc.md", { "```rule", 'id = "DEP-01",', 'severity = "recommended",', "```" })
    write(dir .. "/DEP-01.md", rule_file({ "id: DEP-01", "severity: critical" }, { "#### `DEP-01`" }))

    local rules, errors = loader.load({ dir })

    assert.are.equal(1, #rules)
    assert.are.equal(1, #errors)
    assert.matches("duplicate rule id DEP%-01", errors[1])
  end)

  it("does not load a catalog next to the rule files it was made from", function()
    local dir = tmp_dir()
    write(dir .. "/_rules/DEP/DEP-01.md", rule_file({ "id: DEP-01", "severity: critical" }, { "#### `DEP-01`" }))
    write(dir .. "/regeln/DEP.md", {
      parser.GENERATED_PREFIX .. " from _layouts/DEP.md: do not edit -->",
      "#### `DEP-01`",
      "",
      "```rule",
      'id = "DEP-01",',
      'severity = "critical",',
      "```",
    })
    write(dir .. "/_layouts/DEP.md", { "---", "kind: layout", "output: regeln/DEP.md", "---", "{{rule DEP-01}}" })

    local rules, errors = loader.load({ dir })

    assert.are.same({}, errors)
    assert.are.equal(1, #rules)
    assert.matches("_rules", rules[1].source_file)
  end)

  it("applies the same limits to a rule file", function()
    local dir = tmp_dir()
    write(dir .. "/a.md", rule_file({ "id: A-1", "severity: urgent" }, { "x" }))
    write(dir .. "/b.md", rule_file({ "id: B-1", "severity: critical" }, { "x" }))

    local rules, errors = loader.load({ dir })

    assert.are.equal(1, #rules)
    assert.are.equal("B-1", rules[1].id)
    assert.are.equal(1, #errors)
  end)

  it("loads a single rule file given as a ruleset path", function()
    local dir = tmp_dir()
    write(dir .. "/one.md", rule_file({ "id: A-1", "severity: critical" }, { "x" }))
    local rules, errors = loader.load({ dir .. "/one.md" })
    assert.are.same({}, errors)
    assert.are.equal(1, #rules)
  end)
end)
