-- TESTS/rule_file_spec.lua -- the one-file-per-rule form: how a file is told apart, what a rule file may say,
-- and that both forms load side by side with the same checks.
---@diagnostic disable: need-check-nil
local parser = require("rules.engine.parser")
local loader = require("rules.engine.loader")
local runner = require("rules.engine.runner")
local migrate = require("rules.engine.migrate")

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

--- Write a file byte for byte (`writefile` turns a newline inside a string into a NUL).
---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
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
  end)

  it("keeps a document that starts with a thematic break a document, closed or not", function()
    assert.are.equal("legacy", parser.classify({ "---", "", "# Doc" }))
    assert.are.equal("legacy", parser.classify({ "---", "just words" }))
    assert.are.equal("legacy", parser.classify({ "---" }))
    -- prose first: an `id:` further down is text, not a key
    assert.are.equal("legacy", parser.classify({ "---", "", "Some text: with a colon", "id: x" }))
    assert.are.equal("legacy", parser.classify({ "---", "title: A document", "", "```rule", "```" }))
  end)

  it("takes a frontmatter that starts like a rule file's and is never closed for a rule file, to tell the fault", function()
    assert.are.equal("rule", parser.classify({ "---", "id: A-1" }))
    assert.are.equal("rule", parser.classify({ "---", "severity: critical", "", "#### `A-1`" }))
    assert.are.equal("rule", parser.classify({ "---", "# a comment", "", "id: A-1", "severity: critical", "----", "text" }))
  end)

  it("accepts trailing blanks on the opening delimiter as it does on the closing one", function()
    assert.are.equal("rule", parser.classify({ "--- ", "id: A-1", "severity: critical", "---" }))
    assert.are.equal("rule", parser.classify({ "---\t", "id: A-1", "severity: critical", "---" }))
    assert.are.equal("rule", parser.classify({ "---", "id: A-1", "severity: critical", "---  " }))
    assert.are.equal("legacy", parser.classify({ "--- x", "id: A-1", "severity: critical", "---" }))
    assert.are.equal("legacy", parser.classify({ "----", "id: A-1", "severity: critical", "---" }))
  end)

  it("hands the frontmatter parser the lines up to the closing delimiter and no more", function()
    local frontmatter = require("lib.nvim.markdown.frontmatter")
    local real = frontmatter.parse
    local longest = 0
    frontmatter.parse = function(text, ...)
      longest = math.max(longest, #text)
      return real(text, ...)
    end
    local function with_tail(head)
      for i = 1, 20000 do
        head[#head + 1] = "a line of the document, number " .. i
      end
      return head
    end
    local ok, err = pcall(function()
      assert.are.equal("rule", parser.classify(with_tail({ "---", "id: A-1", "severity: critical", "---", "" })))
      assert.are.equal("legacy", parser.classify(with_tail({ "---", "", "# A document", "" })))
      assert.are.equal("rule", parser.classify(with_tail({ "---", "id: A-1", "", "" })))
    end)
    frontmatter.parse = real
    assert(ok, err)
    assert.is_true(longest < 200, ("the frontmatter parser was given %d bytes"):format(longest))
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
    fails({ 'id: A"1', "severity: critical" }, "letters, digits")
  end)

  it("accepts a rule file with or without a `family`, as long as it is the id's", function()
    local rules, errors = extract(rule_file({ "id: PRIN-01", "severity: critical" }, { "#### `PRIN-01`" }))
    assert.are.same({}, errors)
    assert.are.equal("PRIN-01", rules[1].id)
    rules, errors = extract(rule_file({ "id: PRIN-01", "severity: critical", "family: PRIN" }, { "#### `PRIN-01`" }))
    assert.are.same({}, errors)
    assert.are.equal(1, #rules)
    rules, errors = extract(rule_file({ "id: PRIN-01", "severity: critical", "family: PRIN-01" }, { "#### `PRIN-01`" }))
    assert.are.equal(0, #rules)
    assert.matches("`family` PRIN%-01 does not match the id's family PRIN", errors[1])
  end)

  it("checks the `family` against the family the runner matches", function()
    -- the runner takes the whole id for a family when no `-` follows the leading letters: a `family: DEP` on such an
    -- id would promise a rule that `--family=DEP` never runs
    local rules, errors = extract(rule_file({ "id: DEP2-01", "severity: critical", "family: DEP" }, { "#### `DEP2-01`" }))
    assert.are.equal(0, #rules)
    assert.matches("`family` DEP does not match the id's family DEP2%-01", errors[1])

    rules, errors = extract(rule_file({ "id: DEP2-01", "severity: critical", "family: DEP2-01" }, { "#### `DEP2-01`" }))
    assert.are.same({}, errors)
    assert.are.equal(1, #rules)
    assert.are.equal(1, #runner.check_family(rules, "DEP2-01", tmp_dir()))
    assert.are.equal(0, #runner.check_family(rules, "DEP", tmp_dir()))
  end)

  it("tells a frontmatter that is never closed, or closed by a mistyped delimiter", function()
    local body = { "", "#### `A-1`", "", "Text." }
    local cases = {
      never = { "---", "id: A-1", "severity: critical" },
      four = { "---", "id: A-1", "severity: critical", "----" },
      two = { "---", "id: A-1", "severity: critical", "--" },
      block = { "---", "id: A-1", "severity: critical", "", "```rule", "check = {},", "```" },
    }
    for name, head in pairs(cases) do
      local lines = vim.list_extend(vim.deepcopy(head), body)
      local rules, errors, path = extract(lines)
      assert.are.equal(0, #rules, name)
      assert.are.equal(1, #errors, name)
      assert.is_truthy(errors[1]:find(path .. ":1: frontmatter is not closed", 1, true), name .. ": " .. errors[1])
    end
  end)

  it("reads a rule file whose opening delimiter has trailing blanks", function()
    for _, opener in ipairs({ "--- ", "---\t" }) do
      local lines = rule_file({ "id: A-1", "severity: critical" }, { "#### `A-1`", "", "Text." })
      lines[1] = opener
      local rules, errors = extract(lines)
      assert.are.same({}, errors)
      assert.are.equal(1, #rules, vim.inspect(opener))
      assert.are.equal("Text.", rules[1].text)
    end
  end)

  it("names the line a fault sits on", function()
    local function at(frontmatter, line, pattern)
      local rules, errors, path = extract(rule_file(frontmatter, { "#### x" }))
      local label = table.concat(frontmatter, " | ")
      assert.are.equal(0, #rules, label)
      assert.is_truthy(errors[1]:find(path .. ":" .. line .. ": ", 1, true), label .. ": " .. errors[1])
      assert.matches(pattern, errors[1], label)
      return errors[1]
    end
    at({ "id: A-1", "severity: critical", "colour: red" }, 4, "unknown frontmatter key `colour`")
    at({ "id: A-1", "severity: urgent" }, 3, "invalid `severity`")
    at({ "id: A\\B", "severity: critical" }, 2, "it is the file name")
    at({ "id: [a, b]", "severity: critical" }, 2, "no string `id`")
    at({ "id: A-1", "severity: critical", "family: DEP" }, 4, "`family` DEP does not match")
    at({ "id: A-1", "severity: critical", "colour:", "  nested: x" }, 4, "`colour` is not understood")
    -- a value that is not a string is named by its kind, not printed as a table address
    local message = at({ "id: A-1", "severity: critical", "family: [A, B]" }, 4, "`family` must be a string")
    assert.is_nil(message:find("table:", 1, true))
  end)

  it("refuses a key written twice and a line that is no `key: value`", function()
    local rules, errors, path = extract(rule_file({ "id: A-1", "severity: critical", "severity: nice-to-have" }, { "#### x" }))
    assert.are.equal(0, #rules)
    assert.matches("`severity` appears more than once", errors[1])
    assert.is_truthy(errors[1]:find(path .. ":4: ", 1, true), errors[1])

    rules, errors, path = extract(rule_file({ "id: A-1", "severity: critical", "family A" }, { "#### x" }))
    assert.are.equal(0, #rules)
    assert.matches("not a `key: value` line", errors[1])
    assert.is_truthy(errors[1]:find(path .. ":4: ", 1, true), errors[1])
  end)

  it("keeps a bad id out of the messages that follow it", function()
    local function only_the_id_error(frontmatter)
      local rules, errors = extract(rule_file(frontmatter, { "#### x" }))
      assert.are.equal(0, #rules)
      assert.are.equal(1, #errors, vim.inspect(errors))
      assert.is_nil(errors[1]:find("%c"), vim.inspect(errors[1]))
      assert.is_true(#errors[1] < 400, #errors[1])
    end
    only_the_id_error({ "severity: urgent", "family: Z" }) -- no id at all
    only_the_id_error({ "id: A\27[2J-1", "severity: urgent", "family: Z" })
    only_the_id_error({ 'id: "A-1\\n[FAKE LOG] pwned"', "family: Z" })
    only_the_id_error({ "id: " .. string.rep("A", 100000), "family: Z" })
  end)

  it("keeps a long or control-character severity and family out of the messages as they are", function()
    local function error_of(frontmatter)
      local rules, errors = extract(rule_file(frontmatter, { "#### x" }))
      assert.are.equal(0, #rules)
      assert.is_nil(errors[1]:find("%c"), vim.inspect(errors[1]))
      assert.is_true(#errors[1] < 400, #errors[1])
      return errors[1]
    end
    error_of({ "id: A-1", "severity: " .. string.rep("x", 5000) })
    error_of({ "id: A-1", "severity: critical", "family: " .. string.rep("F", 5000) })
    assert.matches('`severity` "a%?b"', error_of({ "id: A-1", 'severity: "a\\nb"' }))
    assert.matches("`family` a%?b does not match", error_of({ "id: A-1", "severity: critical", 'family: "a\\nb"' }))
  end)

  it("limits the id to what is safe as a file name", function()
    local function id_is_refused(id)
      local rules, errors = extract(rule_file({ "id: " .. id, "severity: critical" }, { "#### x" }))
      assert.are.equal(0, #rules, id)
      assert.matches("it is the file name", errors[1], id)
    end
    for _, id in ipairs({
      "A/B",
      "A/../../../../escaped",
      "../A",
      "..",
      ".",
      ".hidden",
      "A..B",
      "A.",
      "A:1",
      "A\\B",
      "A B",
      "A*",
      "A%2e",
      "Ä-1",
    }) do
      id_is_refused(id)
    end

    -- every id of the shipped rulesets is `LETTERS-DIGITS`; these shapes stay valid too
    for _, id in ipairs({ "DEP-06", "LUA-01", "PERF-53", "I18N-01", "a_b", "V1.2-03", "X.Y", "A" }) do
      local rules, errors = extract(rule_file({ "id: " .. id, "severity: critical" }, { "#### x" }))
      assert.are.same({}, errors, id)
      assert.are.equal(id, rules[1].id)
    end
  end)

  it("cannot be used to make the migration write outside the ruleset", function()
    local outer = tmp_dir()
    local root = outer .. "/root"
    write(root .. "/regeln/DOC.md", {
      "# Doc",
      "",
      "## Section",
      "",
      "#### `A/../../../../escaped` — traversal",
      "",
      "```rule",
      'id = "A/../../../../escaped",',
      'severity = "critical",',
      "```",
      "",
      "Text.",
      "",
    })

    local report = migrate.run(root, { write = true })

    assert.is_true(#report.problems > 0)
    assert.are.same({}, report.written)
    assert.is_nil(vim.uv.fs_stat(outer .. "/escaped.md"))
    assert.is_nil(vim.uv.fs_stat(root .. "/_rules"))
  end)

  it("tells a NUL byte, which would shift the body, instead of reading the wrong lines", function()
    -- `readfile` hands a NUL over as a newline inside the line: the frontmatter parser then counts more lines than the file has
    local block = "```rule\ncheck = { type = 'grep', pattern = 'x' },\n```\n\nText.\n"
    local cases = {
      frontmatter = { "---\nid: A-1\nseverity: critical" .. string.rep("\0", 4) .. "\n---\n\n#### `A-1`\n\n" .. block, 3 },
      compact = { "---\nid: A-1\nseverity: critical\0\n---\n" .. block, 3 },
      body = { "---\nid: A-1\nseverity: critical\n---\n\n#### `A-1`\n\nText\0more\n", 8 },
    }
    for name, case in pairs(cases) do
      local path = tmp_dir() .. "/nul.md"
      write_raw(path, case[1])

      local rules, errors = parser.extract_rules(path)
      assert.are.equal(0, #rules, name)
      assert.is_truthy(
        errors[1]:find(path .. ":" .. case[2] .. ": the file contains a NUL byte", 1, true),
        name .. ": " .. errors[1]
      )

      local split, split_errors = parser.read_rule_file(path)
      assert.is_nil(split, name)
      assert.matches("NUL byte", split_errors[1])
    end
  end)

  it("reads a rule file with a byte order mark and CRLF line endings", function()
    local path = tmp_dir() .. "/crlf.md"
    write_raw(path, "\239\187\191---\r\nid: A-1\r\nseverity: critical\r\n---\r\n\r\n#### `A-1`\r\n\r\nText.\r\n")
    local rules, errors = parser.extract_rules(path)
    assert.are.same({}, errors)
    assert.are.equal(1, #rules)
    assert.are.equal("`A-1`", rules[1].title)
    assert.are.equal("Text.", rules[1].text)
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

  it("takes the title from the heading nearest above the block", function()
    local rules, errors = extract(rule_file({ "id: A-1", "severity: critical" }, {
      "# Intro",
      "",
      "#### `A-1` named",
      "",
      "```rule",
      "check = {},",
      "```",
      "",
      "Text.",
    }))
    assert.are.same({}, errors)
    assert.are.equal("`A-1` named", rules[1].title)
    assert.are.equal("Text.", rules[1].text)
  end)

  it("does not see a heading in a fence above the heading that names the rule", function()
    local body = { "```bash", "# a comment", "```", "#### `A-1` Real", "", "Text." }
    local rules, errors = extract(rule_file({ "id: A-1", "severity: critical" }, body))
    assert.are.same({}, errors)
    assert.are.equal("`A-1` Real", rules[1].title)
    assert.are.equal("Text.", rules[1].text)
    local split = parser.split_text("x.md", table.concat(rule_file({ "id: A-1", "severity: critical" }, body), "\n"))
    assert.are.equal(4, split.heading)
  end)

  it("reads the prose under a block that sits inside a longer fence like a document does", function()
    local body =
      { "#### `A-1`", "", "````markdown", "```rule", "check = {},", "```", "````", "", "Text.", "", "## Next", "", "more" }
    local rules, errors = extract(rule_file({ "id: A-1", "severity: critical" }, body))
    assert.are.same({}, errors)

    -- the same layout as a document: the closing line of the outer fence belongs to the text, the next heading ends it
    local doc =
      { "#### `A-1`", "", "````markdown", "```rule", 'id = "A-1",', 'severity = "critical",', "```", "````", "", "Text.", "" }
    vim.list_extend(doc, { "## Next", "", "more" })
    local path = tmp_dir() .. "/doc.md"
    write(path, doc)
    local from_document = parser.extract_rules(path)

    assert.are.equal("````\n\nText.", rules[1].text)
    assert.are.equal(from_document[1].text, rules[1].text)
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
    assert.are.same({ s = 3, e = 5, fence = 0 }, split.block)
  end)

  it("splits after the first heading when there is no block, below the nearest one when there is", function()
    local function split(body)
      return parser.split_text("x.md", table.concat(rule_file({ "id: A-1", "severity: critical" }, body), "\n"))
    end
    assert.are.equal(1, split({ "# Intro", "", "#### `A-1` named", "", "Text." }).heading)
    assert.are.equal(3, split({ "# Intro", "", "#### `A-1` named", "", "```rule", "```" }).heading)
    assert.is_nil(split({ "```rule", "```", "", "# After the block" }).heading)
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

describe("rules.engine.parser, a very long heading line", function()
  --- A whitespace run in the middle of a line is quadratic for `^(#+)%s+(.-)%s*$`: this many spaces cost it seconds.
  local GAP = string.rep(" ", 50000)

  ---@param path string
  ---@return Rules.ParsedRule[] rules
  ---@return number seconds
  local function timed_extract(path)
    local started = vim.uv.hrtime()
    local rules, errors = parser.extract_rules(path)
    local seconds = (vim.uv.hrtime() - started) / 1e9
    assert.are.same({}, errors)
    return rules, seconds
  end

  it("is read in linear time in a rule file, for the title and for the heading that ends the text", function()
    local path = tmp_dir() .. "/rule.md"
    write(
      path,
      rule_file(
        { "id: A-1", "severity: critical" },
        { "#### `A-1` a" .. GAP .. "b", "", "Text.", "", "## c" .. GAP .. "d", "more" }
      )
    )

    local rules, seconds = timed_extract(path)

    assert.are.equal("`A-1` a" .. GAP .. "b", rules[1].title)
    assert.are.equal("Text.", rules[1].text)
    assert.is_true(seconds < 2, ("took %.1f s"):format(seconds))
  end)

  it("is read in linear time in a document", function()
    local path = tmp_dir() .. "/doc.md"
    write(path, { "## `A-1` a" .. GAP .. "b", "", "```rule", 'id = "A-1",', 'severity = "critical",', "```", "Text." })

    local rules, seconds = timed_extract(path)

    assert.are.equal("`A-1` a" .. GAP .. "b", rules[1].title)
    assert.is_true(seconds < 2, ("took %.1f s"):format(seconds))
  end)
end)

describe("rules.engine.parser.family_of", function()
  it("is the family the runner matches, for every shape of id", function()
    for _, id in ipairs({ "DEP-01", "SEC-45", "DEP2-01", "DEP01", "ABC_01", "A", "1-2", "I18N-01", "a-b-c", "X.Y-1", "A--" }) do
      assert.are.equal(runner.family_of(id), parser.family_of(id), id)
    end
    assert.are.equal("DEP", parser.family_of("DEP-06"))
    assert.are.equal("DEP2-01", parser.family_of("DEP2-01"))
  end)

  it("is the family the migration writes into a rule file, so that the file reads back", function()
    local function convert(id)
      local text = table.concat({
        "# Doc",
        "",
        "## Section",
        "",
        "#### `" .. id .. "` — x",
        "",
        "```rule",
        'id = "' .. id .. '",',
        'severity = "critical",',
        "```",
        "",
        "Text.",
        "",
      }, "\n")
      return migrate.convert_document("regeln/DOC.md", text)
    end

    local c = convert("DEP2-01")
    assert.are.same({}, c.problems)
    assert.are.equal("DEP2-01", c.rule_files[1].family)
    assert.matches("\nfamily: DEP2%-01\n", c.rule_files[1].text)

    c = convert("DEP-01")
    assert.are.same({}, c.problems)
    assert.are.equal("DEP", c.rule_files[1].family)

    c = convert("1-01")
    assert.are.equal(1, #c.problems)
    assert.matches("does not start with letters", c.problems[1])
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
