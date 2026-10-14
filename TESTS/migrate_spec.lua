-- TESTS/migrate_spec.lua -- the conversion of a ruleset of documents into one file per rule, and the proof that
-- it loses nothing.
---@diagnostic disable: need-check-nil
local migrate = require("rules.engine.migrate")
local catalog = require("rules.engine.catalog")
local parser = require("rules.engine.parser")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return (path:gsub("\\", "/"))
end

---@param path string
---@param text string
local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param path string
---@return string|nil
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

---@param lines string[]
---@return string
local function doc(lines)
  return table.concat(lines, "\n") .. "\n"
end

local DOC = doc({
  "# Doc",
  "",
  "## Table of content",
  "",
  "  - [Section](#section)",
  "      - [`A-1` — One](#a-1-one)",
  "      - [`A-2` — Two](#a-2-two)",
  "  - [After](#after)",
  "",
  "---",
  "",
  "## Section",
  "",
  "Intro prose.",
  "",
  "#### `A-1` — One",
  "",
  "```rule",
  'id = "A-1",',
  'severity = "critical",',
  "```",
  "",
  "Text one.",
  "",
  "---",
  "",
  "#### `A-2` — Two",
  "",
  "```rule",
  'id = "A-2",',
  'severity = "recommended",',
  'check = { type = "grep", pattern = "x" },',
  "```",
  "",
  "Text two.",
  "",
  "## After",
  "",
  "Closing words.",
})

describe("rules.engine.migrate.convert_document", function()
  it("makes a file per rule and a layout, and proves they give the document back", function()
    local c = migrate.convert_document("regeln/DOC.md", DOC)

    assert.are.same({}, c.problems)
    assert.are.equal(2, #c.rule_files)
    assert.are.equal("A-1", c.rule_files[1].id)
    assert.are.equal("A", c.rule_files[1].family)
    -- no block left in the file of a rule that had only id and severity
    assert.are.equal(
      doc({ "---", "id: A-1", "severity: critical", "family: A", "---", "", "#### `A-1` — One", "", "Text one.", "", "---", "" }),
      c.rule_files[1].text
    )
    -- the block of the second keeps only what the frontmatter cannot say
    assert.are.equal(
      doc({
        "---",
        "id: A-2",
        "severity: recommended",
        "family: A",
        "---",
        "",
        "#### `A-2` — Two",
        "",
        "```rule",
        'check = { type = "grep", pattern = "x" },',
        "```",
        "",
        "Text two.",
        "",
      }),
      c.rule_files[2].text
    )
    assert.are.equal("same", c.toc)
    assert.matches("kind: layout\noutput: regeln/DOC.md\n---\n", c.layout_text, 1, true)
    assert.matches("{{rule A-1}}", c.layout_text, 1, true)
    assert.matches("{{toc}}", c.layout_text, 1, true)
    assert.is_nil(c.layout_text:find("Text one", 1, true), "the layout holds no rule text")
    assert.is_truthy(c.layout_text:find("Intro prose.", 1, true))
    assert.matches("^" .. vim.pesc(parser.GENERATED_PREFIX), c.document_text)
    assert.are.equal(DOC, c.document_text:gsub("^[^\n]*\n", "", 1))
  end)

  it("refuses prose between the heading and the block: the heading is not the one above the block", function()
    local c = migrate.convert_document(
      "D.md",
      doc({
        "#### `A-1` — One",
        "",
        "Prose before the block.",
        "",
        "```rule",
        'id = "A-1",',
        'severity = "critical",',
        "```",
        "",
        "After.",
      })
    )
    assert.matches("no heading above it", c.problems[1])
    assert.are.same({}, c.rule_files)
  end)

  it("finds the parameters that give the table of contents it was handed", function()
    local text = doc({
      "# D",
      "",
      "## Table of content",
      "",
      "- [1. Größe](#1-größe)",
      "- [2. Zwei_Wörter](#2-zwei_wörter)",
      "",
      "## 1. Größe",
      "",
      "#### `A-1`",
      "",
      "```rule",
      'id = "A-1",',
      'severity = "critical",',
      "```",
      "",
      "## 2. Zwei_Wörter",
    })
    local c = migrate.convert_document("D.md", text)
    assert.are.same({}, c.problems)
    assert.are.equal("same", c.toc)
    assert.matches("{{toc max=2 base=0 unicode=1}}", c.layout_text, 1, true)
    assert.are.equal(text, c.document_text:gsub("^[^\n]*\n", "", 1))
  end)

  it("counts the lines of a table of contents it cannot reproduce", function()
    local text = doc({
      "# D",
      "",
      "- [A hand-made entry](#a)",
      "- [Another](#b)",
      "",
      "## Real",
      "",
      "#### `A-1`",
      "",
      "```rule",
      'id = "A-1",',
      'severity = "critical",',
      "```",
      "",
      "Text.",
    })
    local c = migrate.convert_document("D.md", text)
    assert.are.same({}, c.problems)
    assert.are.equal("differs", c.toc)
    assert.is_true(c.toc_lines_changed >= 2)
    assert.is_truthy(c.toc_examples[1].old)
  end)

  it("has no table of contents to speak of in a document without one", function()
    local c = migrate.convert_document(
      "D.md",
      doc({ "#### `A-1`", "", "```rule", 'id = "A-1",', 'severity = "critical",', "```", "", "Text." })
    )
    assert.are.same({}, c.problems)
    assert.are.equal("none", c.toc)
  end)

  local function refused(text, pattern, label)
    local c = migrate.convert_document("D.md", text)
    assert.is_true(#c.problems >= 1, label)
    assert.matches(pattern, c.problems[1], label)
    assert.are.same({}, c.rule_files, label)
    assert.is_nil(c.document_text, label)
  end

  it("refuses what it cannot convert without loss", function()
    local rule = { "#### `A-1`", "", "```rule", 'id = "A-1",', 'severity = "critical",', "```", "", "t" }
    refused((doc(rule):gsub("\n", "\r\n")), "CRLF", "CRLF")
    refused(table.concat(rule, "\n"), "does not end with a newline", "no final newline")
    refused(doc({ "# no rules here" }), "has no ```rule block", "no block")
    refused(doc({ "#### `A-1`", "", "```rule", 'id = "A-1",' }), "ends inside a fenced block", "unterminated")
    refused(
      doc({ "#### `A-1`", "", "```rule", 'severity = "critical",', 'id = "A-1",', "```", "", "t" }),
      "does not start with `id",
      "id and severity in the other order"
    )
    refused(doc({ "#### `A-1`", "", "```rule", 'id = "A-1",', "```", "", "t" }), "does not start with `id", "no severity")
    refused(
      doc({ "#### `A-1`", "```rule", 'id = "A-1",', 'severity = "critical",', "```", "", "t" }),
      "no blank line above",
      "no blank above"
    )
    refused(
      doc({ "#### `A-1`", "", "```rule", 'id = "A-1",', 'severity = "critical",', "```", "t" }),
      "no blank line below",
      "no blank below"
    )
    refused(
      doc({ "Text without a heading", "", "```rule", 'id = "A-1",', 'severity = "critical",', "```", "", "t" }),
      "no heading above",
      "no heading"
    )
    refused(
      doc({
        "#### `A-1`",
        "",
        "```rule",
        'id = "A-1",',
        'severity = "critical",',
        "```",
        "",
        "#### `A-1` again",
        "",
        "```rule",
        'id = "A-1",',
        'severity = "critical",',
        "```",
        "",
      }),
      "appears twice",
      "the same id twice"
    )
    refused(
      doc({ "#### `1-1`", "", "```rule", 'id = "1-1",', 'severity = "critical",', "```", "", "t" }),
      "does not start with letters",
      "an id without leading letters"
    )
  end)
end)

describe("rules.engine.migrate.run", function()
  ---@return string root
  local function ruleset()
    local root = tmp_dir()
    write(root .. "/regeln/DOC.md", DOC)
    write(
      root .. "/regeln/OTHER.md",
      doc({ "#### `B-1` — Other", "", "```rule", 'id = "B-1",', 'severity = "nice-to-have",', "```", "", "Other text." })
    )
    write(root .. "/notes.md", "# Notes\n\nNo rules in here.\n")
    return root
  end

  it("writes nothing without write, and says what it would do", function()
    local root = ruleset()
    local report = migrate.run(root)

    assert.are.same({}, report.problems)
    assert.are.equal(2, #report.conversions)
    assert.are.same({}, report.written)
    assert.are.equal(DOC, read(root .. "/regeln/DOC.md"))
    assert.is_nil(read(root .. "/_rules/A/A-1.md"))
  end)

  it("writes the files, replaces the documents and proves it on disk", function()
    local root = ruleset()
    local before = tmp_dir()
    write(before .. "/regeln/DOC.md", DOC)
    write(before .. "/regeln/OTHER.md", read(root .. "/regeln/OTHER.md"))

    local report = migrate.run(root, { write = true })

    assert.are.same({}, report.problems)
    assert.are.equal(3 + 2 + 2, #report.written, "three rule files, two layouts, two documents")
    assert.is_truthy(read(root .. "/_rules/A/A-1.md"))
    assert.is_truthy(read(root .. "/_rules/A/A-2.md"))
    assert.is_truthy(read(root .. "/_rules/B/B-1.md"))
    assert.matches("kind: layout", read(root .. "/_layouts/regeln/DOC.md"))
    assert.matches("^" .. vim.pesc(parser.GENERATED_PREFIX), read(root .. "/regeln/DOC.md"))
    assert.are.equal("# Notes\n\nNo rules in here.\n", read(root .. "/notes.md"), "a document without rules is left alone")

    local cmp = migrate.compare(before, root)
    assert.are.equal(3, cmp.before)
    assert.are.equal(3, cmp.after)
    assert.are.same({}, cmp.missing)
    assert.are.same({}, cmp.added)
    assert.are.same({}, cmp.different)
    assert.are.equal(0, cmp.errors_before)
    assert.are.equal(0, cmp.errors_after)

    for _, result in ipairs(catalog.build(root, { check = true })) do
      assert.are.equal("unchanged", result.status)
    end
  end)

  it("finds nothing more to convert the second time", function()
    local root = ruleset()
    migrate.run(root, { write = true })
    local again = migrate.run(root, { write = true })
    assert.are.equal(0, #again.conversions)
    assert.are.same({}, again.problems)
    assert.are.same({}, again.written)
  end)

  it("takes other names for the folders", function()
    local root = ruleset()
    local report = migrate.run(root, { write = true, rules_dir = "src/rules", layouts_dir = "src/layouts" })
    assert.are.same({}, report.problems)
    assert.is_truthy(read(root .. "/src/rules/A/A-1.md"))
    assert.is_truthy(read(root .. "/src/layouts/regeln/DOC.md"))
    assert.matches("from src/layouts/regeln/DOC.md", read(root .. "/regeln/DOC.md"))
  end)

  it("writes nothing at all when one document cannot be converted", function()
    local root = ruleset()
    write(root .. "/regeln/BAD.md", doc({ "#### `C-1`", "```rule", 'id = "C-1",', 'severity = "critical",', "```", "t" }))

    local report = migrate.run(root, { write = true })

    assert.is_true(#report.problems >= 1)
    assert.are.same({}, report.written)
    assert.is_nil(read(root .. "/_rules/A/A-1.md"))
    assert.are.equal(DOC, read(root .. "/regeln/DOC.md"))
  end)

  it("refuses an id that is in two documents", function()
    local root = ruleset()
    write(
      root .. "/regeln/COPY.md",
      doc({ "#### `B-1` — Copy", "", "```rule", 'id = "B-1",', 'severity = "critical",', "```", "", "t" })
    )
    local report = migrate.run(root, { write = true })
    assert.is_true(#report.problems >= 1)
    assert.matches("rule B%-1 is in", table.concat(report.problems, "\n"))
    assert.are.same({}, report.written)
  end)

  it("does not overwrite a file that is there", function()
    local root = ruleset()
    write(root .. "/_rules/A/A-1.md", "mine\n")
    local report = migrate.run(root, { write = true })
    assert.is_true(#report.problems >= 1)
    assert.matches("already exists", table.concat(report.problems, "\n"))
    assert.are.equal("mine\n", read(root .. "/_rules/A/A-1.md"))
    assert.are.equal(DOC, read(root .. "/regeln/DOC.md"))
  end)
end)

describe("rules.engine.migrate.compare", function()
  local function ruleset(rules)
    local root = tmp_dir()
    for i, rule in ipairs(rules) do
      write(
        root .. ("/d%d.md"):format(i),
        doc({
          "#### `" .. rule.id .. "` — T",
          "",
          "```rule",
          'id = "' .. rule.id .. '",',
          'severity = "' .. rule.severity .. '",',
          rule.extra or "",
          "```",
          "",
          rule.text or "text",
        })
      )
    end
    return root
  end

  it("is quiet for equal rulesets and names every difference otherwise", function()
    local a = ruleset({
      { id = "A-1", severity = "critical" },
      { id = "A-2", severity = "critical" },
      { id = "A-3", severity = "critical", extra = 'check = { type = "grep", pattern = "x" },' },
      { id = "A-4", severity = "critical" },
    })
    local b = ruleset({
      { id = "A-1", severity = "critical" },
      { id = "A-2", severity = "recommended" },
      { id = "A-3", severity = "critical", extra = 'check = { type = "grep", pattern = "y" },' },
      { id = "A-5", severity = "critical" },
    })

    local same = migrate.compare(a, a)
    assert.are.same({}, same.different)
    assert.are.same({}, same.missing)

    local cmp = migrate.compare(a, b)
    assert.are.same({ "A-4" }, cmp.missing)
    assert.are.same({ "A-5" }, cmp.added)
    local by_id = {}
    for _, d in ipairs(cmp.different) do
      by_id[d.id] = d.fields
    end
    assert.are.same({ "severity" }, by_id["A-2"])
    assert.are.same({ "check" }, by_id["A-3"])
    assert.is_nil(by_id["A-1"])
  end)

  it("sees a different text", function()
    local a = ruleset({ { id = "A-1", severity = "critical", text = "one" } })
    local b = ruleset({ { id = "A-1", severity = "critical", text = "two" } })
    assert.are.same({ { id = "A-1", fields = { "text" } } }, migrate.compare(a, b).different)
  end)
end)
