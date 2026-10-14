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

--- Every file and folder below `root` with its content (folders: `true`), to say that a run left the tree as it was.
---@param root string
---@return table<string, string|boolean>
local function snapshot(root)
  local out = {}
  for name, kind in vim.fs.dir(root, { depth = math.huge }) do
    out[name] = kind == "directory" or read(root .. "/" .. name)
  end
  return out
end

--- A directory link at `link` to `target`; false when the system does not let this user make one.
---@param target string
---@param link string
---@return boolean
local function link_dir(target, link)
  return vim.uv.fs_symlink(target, link, { dir = true, junction = true }) == true
end

--- Make `lib.nvim.fs.write.atomic` fail for the paths `fails` says so, for the length of `fn`.
---@param fails fun(path: string): boolean
---@param fn fun()
local function with_failing_writes(fails, fn)
  local real = require("lib.nvim.fs.write.atomic")
  package.loaded["lib.nvim.fs.write.atomic"] = function(path, content, opts)
    if fails(path) then
      return false, "rename failed: EPERM"
    end
    return real(path, content, opts)
  end
  local ok, err = pcall(fn)
  package.loaded["lib.nvim.fs.write.atomic"] = real
  assert(ok, err)
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
    assert.are.equal(2, c.toc_lines_changed)
    assert.are.same({
      { old = "- [A hand-made entry](#a)", new = "  - [Real](#real)" },
      { old = "- [Another](#b)", new = "      - [`A-1`](#a-1)" },
    }, c.toc_examples)
  end)

  it("counts an inserted line of the table of contents once, not once for every line after it", function()
    local text = doc({
      "# D",
      "",
      "## Table of content",
      "",
      "  - [Two](#two)",
      "  - [Three](#three)",
      "  - [Four](#four)",
      "  - [Five](#five)",
      "      - [`A-1`](#a-1)",
      "",
      "## One",
      "",
      "## Two",
      "",
      "## Three",
      "",
      "## Four",
      "",
      "## Five",
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
    assert.are.equal(1, c.toc_lines_changed, "one line is new: the entry of `One`")
    assert.are.same({}, c.toc_examples, "an inserted line has no old line to show")
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
    -- a refusal carries nothing of a conversion, at whatever stage it came
    assert.are.same({}, c.rule_files, label)
    assert.is_nil(c.document_text, label)
    assert.is_nil(c.layout_text, label)
    assert.are.equal("none", c.toc, label)
    assert.are.equal(0, c.toc_lines_changed, label)
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

  local RULE = { "#### `A-1`", "", "```rule", 'id = "A-1",', 'severity = "critical",', "```", "", "Text." }

  --- `lines`, then the rule above, as one document
  ---@param head string[]
  ---@return string
  local function with_rule(head)
    local lines = vim.list_extend({}, head)
    return doc(vim.list_extend(lines, RULE))
  end

  it("refuses what only the byte-for-byte proof can see, and says where", function()
    -- two blank lines below the block: every structural check passes, the rendering has one
    local text = doc({ "#### `A-1`", "", "```rule", 'id = "A-1",', 'severity = "critical",', "```", "", "", "Text." })
    refused(text, "differs from the original beyond its table of contents %(first difference at line 3%)", "two blank lines")
    -- the same through `run`: a refused document is not in the report as a conversion with rules
    local root = tmp_dir()
    write(root .. "/BAD.md", text)
    write(root .. "/GOOD.md", with_rule({}))
    local report = migrate.run(root)
    local rules = 0
    for _, c in ipairs(report.conversions) do
      rules = rules + #c.rule_files
    end
    assert.are.equal(1, rules, "only GOOD.md counts")
    assert.are.equal(1, #report.problems)
  end)

  it("refuses an output path a layout cannot name", function()
    local c = migrate.convert_document("a:b.md", with_rule({}))
    assert.matches("the layout does not read back", c.problems[1], 1, true)
    assert.are.same({}, c.rule_files)
    assert.is_nil(c.layout_text)
  end)

  it("refuses a rule file the reader does not take back", function()
    refused(
      doc({ "#### `A-1`", "", "```rule", 'id = "A-1",', 'severity = "urgent",', "```", "", "Text." }),
      "does not read back",
      "a severity that is none"
    )
  end)

  it("refuses an id that could leave its folder, before any path is made of it", function()
    local sep = string.char(92)
    for _, id in ipairs({ "A/../../../evil", "A/B", "A:x", "A" .. sep .. "x", "A-1/", "A.." }) do
      refused(
        doc({ "#### `A-1`", "", "```rule", ('id = "%s",'):format(id), 'severity = "critical",', "```", "", "Text." }),
        "does not read back",
        id
      )
    end
  end)

  it("does not echo a control character of an id into a message", function()
    local c = migrate.convert_document(
      "D.md",
      doc({
        "#### `A-1`",
        "",
        "```rule",
        'id = "A' .. string.char(27) .. '[2Jx",',
        'severity = "critical",',
        "```",
        "",
        "Text.",
        "",
        "#### `A-2`",
        "",
        "```rule",
        'id = "A' .. string.char(27) .. '[2Jx",',
        'severity = "critical",',
        "```",
        "",
        "Text.",
      })
    )
    assert.is_true(#c.problems >= 1)
    assert.is_nil(table.concat(c.problems, "\n"):find(string.char(27), 1, true))
  end)

  it("takes a fence of more than three backticks as one fence, as the loader does", function()
    local text = doc({
      "# D",
      "",
      "````markdown",
      "## An example heading",
      "",
      "#### `X-1` shown, not a rule",
      "````",
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
      "#### `A-2` — Two",
      "",
      "```rule",
      'id = "A-2",',
      'severity = "critical",',
      "```",
      "",
      "Text two.",
    })
    local c = migrate.convert_document("D.md", text)
    assert.are.same({}, c.problems)
    assert.are.equal(2, #c.rule_files, "both rules after the long fence, not only the last")
    assert.are.equal(text, (c.document_text:gsub("^[^\n]*\n", "", 1)))
    assert.matches("{{rule A-1}}", c.layout_text, 1, true)
    assert.matches("{{rule A-2}}", c.layout_text, 1, true)
    assert.is_nil(c.layout_text:find("```rule", 1, true), "no block is left in the layout as text")
  end)

  it("keeps the rules of a ruleset after a fence of four backticks (the loader sees them, and so does the result)", function()
    local before, root = tmp_dir(), tmp_dir()
    local text = doc({
      "# D",
      "",
      "````markdown",
      "an example",
      "````",
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
      "#### `A-2` — Two",
      "",
      "```rule",
      'id = "A-2",',
      'severity = "critical",',
      "```",
      "",
      "Text two.",
    })
    write(before .. "/D.md", text)
    write(root .. "/D.md", text)
    local report = migrate.run(root, { write = true })
    assert.are.same({}, report.problems)
    local cmp = migrate.compare(before, root)
    assert.are.equal(2, cmp.before)
    assert.are.equal(2, cmp.after)
    assert.are.same({}, cmp.missing)
    assert.are.same({}, cmp.different)
  end)

  it("refuses a ```rule line inside another fence: the loader reads it as a rule, the migration could not place it", function()
    refused(
      doc({
        "# D",
        "",
        "````markdown",
        "```rule",
        'id = "X-1",',
        'severity = "critical",',
        "```",
        "````",
        "",
        "#### `A-1`",
        "",
        "```rule",
        'id = "A-1",',
        'severity = "critical",',
        "```",
        "",
        "Text.",
      }),
      "line 4 is a ```rule line inside another fenced block",
      "an example of a block in a longer fence"
    )
    refused(
      doc({ "```markdown", "```rule", 'id = "X-1",', 'severity = "critical",', "```", "```", "", unpack(RULE) }),
      "inside another fenced block",
      "an example of a block in a fence of three"
    )
  end)

  it("refuses a byte order mark and a frontmatter at the top: the GENERATED header would push them down", function()
    refused("\239\187\191" .. with_rule({}), "byte order mark", "BOM")
    refused(with_rule({ "---", "title: Foo", "tags: [a]", "---", "" }), "starts with a frontmatter", "frontmatter")
    refused(with_rule({ "---   ", "title: Foo", "---", "" }), "starts with a frontmatter", "frontmatter, blanks after the dashes")
  end)

  it("does not take a thematic break at the top for a frontmatter", function()
    local text = with_rule({ "---", "Some words between two rules.", "---", "" })
    local c = migrate.convert_document("D.md", text)
    assert.are.same({}, c.problems)
    assert.are.equal(text, (c.document_text:gsub("^[^\n]*\n", "", 1)))
    local lone = with_rule({ "---", "" })
    assert.are.same({}, migrate.convert_document("D.md", lone).problems)
  end)

  it("reads a line of a hundred kilobytes in no time, whatever its shape", function()
    -- `- [` then `](#)x` over and over is a table-of-contents line to no one; the pattern that decided that took seconds
    local crafted = "- [" .. ("](#)x"):rep(20000)
    local text = with_rule({ "# D", "", crafted, "" })
    local started = vim.uv.hrtime()
    local c = migrate.convert_document("D.md", text)
    local ms = (vim.uv.hrtime() - started) / 1e6
    assert.are.same({}, c.problems)
    assert.are.equal("none", c.toc)
    assert.is_true(ms < 1000, ("took %d ms"):format(ms))
  end)

  it("searches the table-of-contents parameters over the heading and fence lines only, and each set once", function()
    local lines = { "# D", "", "- [A hand-made entry](#a)", "- [Another](#b)", "" }
    local rules = 300
    for i = 1, rules do
      vim.list_extend(lines, { ("#### `A-%d`"):format(i), "", "```rule", ('id = "A-%d",'):format(i) })
      vim.list_extend(lines, { 'severity = "critical",', "```", "", "Prose of the rule.", "" })
    end
    local calls, large = 0, 0
    local real = catalog.toc_lines
    catalog.toc_lines = function(list, params)
      calls = calls + 1
      if #list > 4 * rules then
        large = large + 1
      end
      return real(list, params)
    end
    local ok, c = pcall(migrate.convert_document, "D.md", doc(lines))
    catalog.toc_lines = real
    assert.is_true(ok, c)
    assert.are.same({}, c.problems)
    assert.are.equal("differs", c.toc, "no parameters give the hand-made lines: every set is tried")
    -- 5 `max` x 3 `base` x 3 `step` x 3 (`unicode = 0` with and without `_`, `unicode = 1` once), and the one render
    assert.are.equal(135 + 1, calls)
    assert.are.equal(1, large, "only the render walks the whole document")
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

  it("reports a path that is not a folder instead of finding nothing to do", function()
    local root = ruleset()
    for _, path in ipairs({ root .. "/does/not/exist", root .. "/notes.md" }) do
      for _, do_write in ipairs({ false, true }) do
        local report = migrate.run(path, { write = do_write })
        assert.matches("is not a directory", report.problems[1], path)
        assert.are.same({}, report.conversions, path)
        assert.are.same({}, report.written, path)
      end
    end
  end)

  it("writes nothing for an id that leads out of the folders", function()
    local outer = tmp_dir()
    local root = outer .. "/ruleset"
    write(
      root .. "/RULES.md",
      doc({ "#### `A-1`", "", "```rule", 'id = "A/../../../EVIL",', 'severity = "critical",', "```", "", "t" })
    )
    for _, do_write in ipairs({ false, true }) do
      local report = migrate.run(root, { write = do_write })
      assert.is_true(#report.problems >= 1)
      assert.are.same({}, report.written)
      assert.is_nil(report.rolled_back, "refused before a byte was written")
    end
    assert.is_nil(read(outer .. "/EVIL.md"), "not above the ruleset")
    assert.is_nil(read(root .. "/EVIL.md"), "not in it")
    assert.are.same({ "RULES.md" }, vim.fn.readdir(root))
  end)

  it("keeps a second lock on the path when the reader of rule files lets an id through", function()
    local outer = tmp_dir()
    local root = outer .. "/ruleset"
    write(
      root .. "/RULES.md",
      doc({ "#### `A-1`", "", "```rule", 'id = "A/../../../EVIL",', 'severity = "critical",', "```", "", "t" })
    )
    -- a reader that takes any id: what stands between the id and the file system is then the path check of `run`
    local real = parser.split_text
    parser.split_text = function(_, text)
      local id = text:match("\nid: ([^\n]+)\n")
      return { id = id, severity = "critical", lines = { "#### `A-1`", "", "t" }, offset = 6, heading = 1 }, {}
    end
    local ok, report = pcall(migrate.run, root, { write = true })
    parser.split_text = real
    assert(ok, report)
    assert.matches("is not below", table.concat(report.problems, "\n"), 1, true)
    assert.are.same({}, report.written)
    assert.is_nil(report.rolled_back, "refused before a byte was written")
    assert.is_nil(read(outer .. "/EVIL.md"))
    assert.are.same({ "RULES.md" }, vim.fn.readdir(root))
  end)

  it("takes a folder name in any spelling, and the header names the layout where the check finds it", function()
    local root = ruleset()
    local report = migrate.run(root, { write = true, rules_dir = ".\\src//rules/", layouts_dir = "./src/layouts/" })
    assert.are.same({}, report.problems)
    assert.is_truthy(read(root .. "/src/rules/A/A-1.md"))
    assert.is_truthy(read(root .. "/src/layouts/regeln/DOC.md"))
    assert.matches("from src/layouts/regeln/DOC.md", read(root .. "/regeln/DOC.md"), 1, true)
  end)

  it("refuses a folder name that leads out of the ruleset before it writes anything", function()
    local root = ruleset()
    local before = snapshot(root)
    local names = { "..", "../lay", "a/../../lay", "/abs", "C:/abs", "C:", "", ".", "./", "lay/.", "a:b", "x ", "x.", "a\\..\\b" }
    for _, name in ipairs(names) do
      for _, key in ipairs({ "layouts_dir", "rules_dir" }) do
        local report = migrate.run(root, { write = true, [key] = name })
        assert.is_true(#report.problems >= 1, key .. " " .. name)
        assert.matches(key, report.problems[1], 1, true)
        assert.are.same({}, report.written, key .. " " .. name)
      end
    end
    assert.are.same(before, snapshot(root))
    assert.is_nil(vim.uv.fs_stat(root .. "/../lay"), "nothing above the ruleset")
  end)

  it("does not take a layout the check cannot reach for one it has checked", function()
    local root = ruleset()
    local before = snapshot(root)
    -- the walk skips `.deps`: the check on disk would find no layout, and no fault in it
    local report = migrate.run(root, { write = true, layouts_dir = ".deps/lay" })
    assert.matches("proved nothing", table.concat(report.problems, "\n"))
    assert.is_true(report.rolled_back)
    assert.are.same({}, report.written)
    assert.are.same(before, snapshot(root))
  end)

  describe("a link on the way", function()
    it("does not write the rule files through a link out of the ruleset", function()
      local root = ruleset()
      local outside = tmp_dir()
      if not link_dir(outside, root .. "/_rules") then
        pending("no right to make a link here")
      end
      local report = migrate.run(root, { write = true })
      assert.is_true(#report.problems >= 1)
      assert.matches("leaves the ruleset", table.concat(report.problems, "\n"))
      assert.are.same({}, report.written)
      assert.are.same({}, vim.fn.readdir(outside), "nothing was made behind the link")
      assert.are.equal(DOC, read(root .. "/regeln/DOC.md"))
    end)

    it("does not write the layouts through one either", function()
      local root = ruleset()
      local outside = tmp_dir()
      if not link_dir(outside, root .. "/_layouts") then
        pending("no right to make a link here")
      end
      local report = migrate.run(root, { write = true })
      assert.matches("leaves the ruleset", table.concat(report.problems, "\n"))
      assert.are.same({}, report.written)
      assert.are.same({}, vim.fn.readdir(outside))
      assert.is_nil(read(root .. "/_rules/A/A-1.md"), "nothing at all was written")
    end)

    it("does not write below a folder that is a link either", function()
      local root = ruleset()
      local outside = tmp_dir()
      vim.fn.mkdir(root .. "/_rules", "p")
      if not link_dir(outside, root .. "/_rules/A") then
        pending("no right to make a link here")
      end
      local report = migrate.run(root, { write = true })
      assert.matches("leaves the ruleset", table.concat(report.problems, "\n"))
      assert.are.same({}, vim.fn.readdir(outside))
    end)
  end)

  describe("when a write fails", function()
    it("takes everything back when a document cannot be replaced after the files are written", function()
      local root = ruleset()
      local before = snapshot(root)
      with_failing_writes(function(path)
        return path:find("regeln/OTHER.md", 1, true) ~= nil
      end, function()
        local report = migrate.run(root, { write = true })
        assert.is_true(report.rolled_back)
        assert.are.same({}, report.written)
        assert.matches("EPERM", table.concat(report.problems, "\n"))
        -- DOC.md was replaced before OTHER.md failed: it is back, and the new files and their folders are gone
        assert.are.same(before, snapshot(root))
      end)

      -- the cause is gone: the same run goes through, nothing refuses as "already exists"
      local again = migrate.run(root, { write = true })
      assert.are.same({}, again.problems)
      assert.is_nil(again.rolled_back)
      assert.are.equal(3 + 2 + 2, #again.written)
    end)

    it("takes everything back when a new file cannot be written", function()
      local root = ruleset()
      local before = snapshot(root)
      with_failing_writes(function(path)
        return path:find("_rules/B/B-1.md", 1, true) ~= nil
      end, function()
        local report = migrate.run(root, { write = true })
        assert.is_true(report.rolled_back)
        assert.are.same({}, report.written)
        assert.are.same(before, snapshot(root))
      end)
    end)

    it("refuses a document it cannot write before it writes anything", function()
      local root = ruleset()
      local path = root .. "/regeln/OTHER.md"
      assert(vim.uv.fs_chmod(path, tonumber("444", 8)))
      local honoured = not vim.uv.fs_access(path, "W")
      local before = snapshot(root)
      local report = migrate.run(root, { write = true })
      vim.uv.fs_chmod(path, tonumber("644", 8))
      if not honoured then
        pending("this user can write to anything (root): nothing to refuse")
      end
      assert.matches("is not writable", table.concat(report.problems, "\n"), 1, true)
      assert.are.same({}, report.written)
      assert.is_nil(report.rolled_back, "nothing was written, so nothing is taken back")
      assert.are.same(before, snapshot(root))
    end)
  end)

  describe("the check on disk", function()
    it("takes everything back when a document it replaced is not what the generator makes", function()
      local root = ruleset()
      local before = snapshot(root)
      local real = catalog.build
      catalog.build = function(base, opts)
        local results, errors = real(base, opts)
        results[1].status = "stale"
        return results, errors
      end
      local ok, report = pcall(migrate.run, root, { write = true })
      catalog.build = real
      assert(ok, report)
      assert.matches("is stale after the migration", table.concat(report.problems, "\n"), 1, true)
      assert.is_true(report.rolled_back)
      assert.are.same({}, report.written)
      assert.are.same(before, snapshot(root))
    end)

    it("tells trouble elsewhere in the ruleset, and does not take the migration back for it", function()
      local root = ruleset()
      write(root .. "/other/BROKEN.md", "---\nkind: layout\noutput: ../escape.md\n---\ntext\n")
      local report = migrate.run(root, { write = true })
      assert.matches("BROKEN.md", table.concat(report.problems, "\n"), 1, true)
      assert.is_nil(report.rolled_back)
      assert.are.equal(3 + 2 + 2, #report.written)
      assert.matches("^" .. vim.pesc(parser.GENERATED_PREFIX), read(root .. "/regeln/DOC.md"))
    end)
  end)

  it("refuses two rules that would be one file on a case-insensitive system", function()
    if vim.fn.has("win32") == 0 and vim.fn.has("mac") == 0 then
      pending("on a case-sensitive file system A/A-1.md and a/a-1.md are two files")
    end
    local root = tmp_dir()
    write(
      root .. "/D.md",
      doc({
        "#### `A-1`",
        "",
        "```rule",
        'id = "A-1",',
        'severity = "critical",',
        "```",
        "",
        "Upper.",
        "",
        "#### `a-1`",
        "",
        "```rule",
        'id = "a-1",',
        'severity = "critical",',
        "```",
        "",
        "Lower.",
      })
    )
    local report = migrate.run(root, { write = true })
    assert.matches("would be one file", table.concat(report.problems, "\n"), 1, true)
    assert.are.same({}, report.written)
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
