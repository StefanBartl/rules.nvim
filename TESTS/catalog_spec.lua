-- TESTS/catalog_spec.lua -- the reading documents of a one-file-per-rule ruleset: anchors and the table of
-- contents, layouts, how a rule reads in a document, and building the documents on disk.
---@diagnostic disable: need-check-nil
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

---@param output string
---@param lines string[]
---@return string
local function layout_text(output, lines)
  return ("---\nkind: layout\noutput: %s\n---\n%s\n"):format(output, table.concat(lines, "\n"))
end

---@param id string
---@param severity string
---@param body string
---@return string
local function rule_text(id, severity, body)
  return ("---\nid: %s\nseverity: %s\n---\n\n%s"):format(id, severity, body)
end

describe("rules.engine.catalog.slug", function()
  it("drops what is not an ASCII letter, digit, hyphen or space and joins runs with one hyphen", function()
    assert.are.equal("lua-01-hart-oder-weich-aber-konsistent", catalog.slug("`LUA-01` — Hart oder weich, aber konsistent"))
    assert.are.equal("err-02-type-guards-literal-checks", catalog.slug("`ERR-02` — Type Guards & Literal Checks"))
    assert.are.equal("lua-03-dnne-re-exports", catalog.slug("`LUA-03` — Dünne Re-Exports"))
    assert.are.equal("libnvim-verwenden", catalog.slug("lib.nvim verwenden"))
  end)

  it("keeps the underscore unless told to drop it", function()
    assert.are.equal("web-11-if_match-mitsenden", catalog.slug("`WEB-11` — `if_match` mitsenden"))
    local params = vim.tbl_extend("force", catalog.TOC_DEFAULTS, { underscore = 0 })
    assert.are.equal("web-11-ifmatch-mitsenden", catalog.slug("`WEB-11` — `if_match` mitsenden", params))
  end)

  it("keeps letters of any alphabet and every space with unicode = 1", function()
    local params = vim.tbl_extend("force", catalog.TOC_DEFAULTS, { unicode = 1 })
    assert.are.equal("2-zustand-und-abhängigkeiten", catalog.slug("2. Zustand und Abhängigkeiten", params))
    assert.are.equal(
      "5-wann-läuft-es--auslöser-bewusst-wählen",
      catalog.slug("5. Wann läuft es? — Auslöser bewusst wählen", params)
    )
    assert.are.equal("großes-ö", catalog.slug("Großes Ö", params))
    assert.are.equal("a_b-c", catalog.slug("a_b C", params))
  end)

  it("leaves no hyphen at either end", function()
    assert.are.equal("a", catalog.slug("-- a --"))
    assert.are.equal("", catalog.slug("— ?"))
  end)
end)

describe("rules.engine.catalog table of contents", function()
  local doc = {
    "# Title",
    "",
    "## Table of content",
    "",
    "{{toc}}",
    "## One",
    "### One-A",
    "#### One-A-i",
    "##### too deep",
    "```bash",
    "## not a heading",
    "```",
    "## Two",
    "## One",
  }

  it("lists levels 2 to 4 by default, indented, without the title and its own heading", function()
    assert.are.same({
      "  - [One](#one)",
      "    - [One-A](#one-a)",
      "      - [One-A-i](#one-a-i)",
      "  - [Two](#two)",
      "  - [One](#one-1)",
    }, catalog.toc_lines(doc))
  end)

  it("follows the parameters", function()
    assert.are.same(
      { "- [One](#one)", "- [Two](#two)", "- [One](#one-1)" },
      catalog.toc_lines(doc, { max = 2, base = 0, step = 2, unicode = 0, underscore = 1 })
    )
    assert.are.same(
      { "- [One](#one)", "  - [One-A](#one-a)", "- [Two](#two)", "- [One](#one-1)" },
      catalog.toc_lines(doc, { max = 3, base = 0, step = 2, unicode = 0, underscore = 1 })
    )
    assert.are.same(
      { "    - [One](#one)", "        - [One-A](#one-a)", "    - [Two](#two)", "    - [One](#one-1)" },
      catalog.toc_lines(doc, { max = 3, base = 4, step = 4, unicode = 0, underscore = 1 })
    )
  end)

  it("reads the token", function()
    assert.are.same(catalog.TOC_DEFAULTS, catalog.parse_toc_token("{{toc}}"))
    assert.are.same(catalog.TOC_DEFAULTS, catalog.parse_toc_token("{{toc }}"))
    local params = catalog.parse_toc_token("{{toc max=2 base=0 unicode=1}}")
    assert.are.same({ max = 2, base = 0, step = 2, unicode = 1, underscore = 1 }, params)
    assert.are.same({ nil, nil }, { catalog.parse_toc_token("not a token") })
    assert.are.same({ nil, nil }, { catalog.parse_toc_token("{{rule A-1}}") })
  end)

  it("refuses a bad token", function()
    for _, line in ipairs({
      "{{toc max=9}}",
      "{{toc max=1}}",
      "{{toc max=x}}",
      "{{toc colour=1}}",
      "{{toc unicode=2}}",
      "{{toc base=-1}}",
      "{{toc max=2.5}}",
      "{{toc max=2 junk}}",
    }) do
      local params, err = catalog.parse_toc_token(line)
      assert.is_nil(params, line)
      assert.is_string(err, line)
    end
  end)

  it("writes the shortest token that gives the parameters", function()
    assert.are.equal("{{toc}}", catalog.toc_token(catalog.TOC_DEFAULTS))
    assert.are.equal(
      "{{toc max=2 base=0 unicode=1}}",
      catalog.toc_token({ max = 2, base = 0, step = 2, unicode = 1, underscore = 1 })
    )
    for _, params in ipairs({
      { max = 2, base = 0, step = 0, unicode = 0, underscore = 0 },
      { max = 6, base = 4, step = 4, unicode = 1, underscore = 1 },
    }) do
      assert.are.same(params, catalog.parse_toc_token(catalog.toc_token(params)))
    end
  end)
end)

describe("rules.engine.catalog.parse_layout", function()
  local function layout(output)
    return ("---\nkind: layout\noutput: %s\n---\n# T\n\n{{rule A-1}}\n"):format(output)
  end

  it("reads the output and the body", function()
    local parsed, err = catalog.parse_layout(layout("regeln/A.md"))
    assert.is_nil(err)
    assert.are.equal("regeln/A.md", parsed.output)
    assert.are.same({ "# T", "", "{{rule A-1}}" }, parsed.lines)
  end)

  it("reads a layout with CRLF line endings", function()
    local parsed = catalog.parse_layout((layout("a.md"):gsub("\n", "\r\n")))
    assert.are.same({ "# T", "", "{{rule A-1}}" }, parsed.lines)
  end)

  it("refuses what is not a layout", function()
    local parsed, err = catalog.parse_layout("# just a document\n")
    assert.is_nil(parsed)
    assert.matches("not a layout", err)
    assert.is_nil((catalog.parse_layout("---\ntitle: x\n---\n")))
    assert.is_nil((catalog.parse_layout("")))
  end)

  it("refuses an output that could leave the ruleset or is no document", function()
    for _, output in ipairs({
      "../outside.md",
      "a/../../b.md",
      "/abs.md",
      "C:/abs.md",
      "a\\b.md",
      "dir/",
      "./a.md",
      "a/./b.md",
      "notes.txt",
      "",
    }) do
      local parsed, err = catalog.parse_layout(layout(output))
      assert.is_nil(parsed, output)
      assert.is_string(err, output)
    end
    local missing, err = catalog.parse_layout("---\nkind: layout\n---\nbody\n")
    assert.is_nil(missing)
    assert.matches("`output`", err)
  end)
end)

describe("rules.engine.catalog.segment_lines", function()
  local function split(text)
    return assert(parser.split_text("x.md", text))
  end

  it("puts the block in under the heading when the file has none", function()
    local segment = catalog.segment_lines(split(rule_text("A-1", "critical", "#### `A-1` — T\n\nText.\n")))
    assert.are.same({
      "#### `A-1` — T",
      "",
      "```rule",
      'id = "A-1",',
      'severity = "critical",',
      "```",
      "",
      "Text.",
    }, segment)
  end)

  it("puts the identity lines into the block the file has, at its place", function()
    local segment = catalog.segment_lines(
      split(rule_text("A-1", "recommended", "#### `A-1`\n\nProse first.\n\n```rule\ncheck = {},\n```\n\nAfter.\n"))
    )
    assert.are.same({
      "#### `A-1`",
      "",
      "Prose first.",
      "",
      "```rule",
      'id = "A-1",',
      'severity = "recommended",',
      "check = {},",
      "```",
      "",
      "After.",
    }, segment)
  end)

  it("fills an empty block as a marker for the place", function()
    local segment = catalog.segment_lines(split(rule_text("A-1", "critical", "#### `A-1`\n\nIntro.\n\n```rule\n```\n\nText.\n")))
    assert.are.same(
      { "#### `A-1`", "", "Intro.", "", "```rule", 'id = "A-1",', 'severity = "critical",', "```", "", "Text." },
      segment
    )
  end)

  it("sits at the top when the file has no heading", function()
    local segment = catalog.segment_lines(split(rule_text("A-1", "critical", "Only text.\n")))
    assert.are.same({ "```rule", 'id = "A-1",', 'severity = "critical",', "```", "", "Only text." }, segment)
  end)

  it("reads back to the same rule", function()
    local text =
      rule_text("A-1", "recommended", '#### `A-1` — T\n\n```rule\ncheck = { type = "grep", pattern = "x" },\n```\n\nText.\n')
    local path = tmp_dir() .. "/A-1.md"
    write(path, text)
    local file_rule = parser.extract_rules(path)[1]

    local doc = tmp_dir() .. "/doc.md"
    write(doc, table.concat(catalog.segment_lines(split(text)), "\n") .. "\n")
    local doc_rule = parser.extract_rules(doc)[1]

    for _, key in ipairs({ "id", "severity", "title", "text" }) do
      assert.are.equal(file_rule[key], doc_rule[key], key)
    end
    assert.are.same(file_rule.check, doc_rule.check)
  end)
end)

describe("rules.engine.catalog.render", function()
  local files = {
    ["A-1"] = rule_text("A-1", "critical", "#### `A-1` — One\n\nText one.\n"),
    ["A-2"] = rule_text("A-2", "recommended", "#### `A-2` — Two\n\nText two.\n"),
  }
  local function lookup(id)
    if not files[id] then
      return nil, "no such rule file"
    end
    return parser.split_text(id .. ".md", files[id])
  end

  it("puts the rules in the order of the tokens and the table of contents where it is asked", function()
    local layout = assert(catalog.parse_layout(layout_text("a.md", {
      "# Title",
      "",
      "## Table of content",
      "",
      "{{toc}}",
      "",
      "## First",
      "",
      "{{rule A-2}}",
      "## Second",
      "{{rule A-1}}",
    })))
    local text, problems, used = catalog.render(layout, lookup, "<!-- header -->")

    assert.are.same({}, problems)
    assert.are.same({ "A-2", "A-1" }, used)
    assert.are.equal(
      table.concat({
        "<!-- header -->",
        "# Title",
        "",
        "## Table of content",
        "",
        "  - [First](#first)",
        "      - [`A-2` — Two](#a-2-two)",
        "  - [Second](#second)",
        "      - [`A-1` — One](#a-1-one)",
        "",
        "## First",
        "",
        "#### `A-2` — Two",
        "",
        "```rule",
        'id = "A-2",',
        'severity = "recommended",',
        "```",
        "",
        "Text two.",
        "## Second",
        "#### `A-1` — One",
        "",
        "```rule",
        'id = "A-1",',
        'severity = "critical",',
        "```",
        "",
        "Text one.",
        "",
      }, "\n"),
      text
    )
  end)

  it("needs no header and no table", function()
    local layout = assert(catalog.parse_layout("---\nkind: layout\noutput: a.md\n---\ntext\n{{rule A-1}}\n"))
    local text = catalog.render(layout, lookup)
    assert.are.equal("text", text:match("^[^\n]*"))
  end)

  it("tells every token it cannot fill and builds nothing", function()
    local layout = assert(catalog.parse_layout(layout_text("a.md", {
      "{{rule A-1}}",
      "{{rule NOPE-1}}",
      "{{rule A-1}}",
      "{{toc}}",
      "{{toc}}",
      "{{toc max=9}}",
    })))
    local text, problems = catalog.render(layout, lookup)

    assert.is_nil(text)
    assert.are.equal(4, #problems)
    assert.matches("line 2: rule NOPE%-1: no such rule file", table.concat(problems, "\n"))
    assert.matches("line 3: rule A%-1 is placed twice", table.concat(problems, "\n"))
    assert.matches("line 5: more than one {{toc}}", table.concat(problems, "\n"))
    assert.matches("line 6: bad table of contents parameter", table.concat(problems, "\n"))
  end)

  it("takes a token only when it is the whole line", function()
    local layout = assert(catalog.parse_layout("---\nkind: layout\noutput: a.md\n---\nsay {{rule A-1}} in prose\n  {{toc}}\n"))
    local text, problems = catalog.render(layout, lookup)
    assert.are.same({}, problems)
    assert.are.equal("say {{rule A-1}} in prose\n  {{toc}}\n", text)
  end)

  it("makes a header that cannot end its comment early", function()
    local header = catalog.header("a--b>/c.md")
    assert.matches("^" .. vim.pesc(parser.GENERATED_PREFIX), header)
    assert.is_nil(header:sub(1, -4):find("%-%->"))
    assert.matches(" %-%->$", header)
  end)
end)

describe("rules.engine.catalog.build", function()
  ---@return string root
  local function ruleset()
    local root = tmp_dir()
    write(root .. "/_rules/DEP/DEP-01.md", rule_text("DEP-01", "critical", "#### `DEP-01` — Eins\n\nText eins.\n"))
    write(
      root .. "/_rules/DEP/DEP-02.md",
      rule_text(
        "DEP-02",
        "recommended",
        '#### `DEP-02` — Zwei\n\n```rule\ncheck = { type = "grep", pattern = "x" },\n```\n\nText zwei.\n'
      )
    )
    write(root .. "/_rules/ERR/ERR-01.md", rule_text("ERR-01", "critical", "#### `ERR-01` — Drei\n\nText drei.\n"))
    write(
      root .. "/_layouts/regeln/DEP.md",
      layout_text("regeln/DEP.md", {
        "# Deprecated",
        "",
        "## Table of content",
        "",
        "{{toc}}",
        "",
        "## Calls",
        "",
        "{{rule DEP-01}}",
        "{{rule DEP-02}}",
      })
    )
    return root
  end

  it("writes the document the first time and leaves it alone the second", function()
    local root = ruleset()

    local results, errors = catalog.build(root)
    assert.are.same({}, errors)
    assert.are.equal(1, #results)
    assert.are.equal("written", results[1].status)
    assert.are.equal(root .. "/regeln/DEP.md", results[1].output)
    local text = read(root .. "/regeln/DEP.md")
    assert.matches("^" .. vim.pesc(parser.GENERATED_PREFIX) .. " from _layouts/regeln/DEP.md", text)
    assert.matches("# Deprecated\n", text, 1, true)
    assert.matches('id = "DEP%-01",\nseverity = "critical",', text)
    assert.matches('id = "DEP%-02",\nseverity = "recommended",\ncheck =', text)

    local mtime = vim.uv.fs_stat(root .. "/regeln/DEP.md").mtime
    vim.uv.sleep(1100)
    results = catalog.build(root)
    assert.are.equal("unchanged", results[1].status)
    local again = vim.uv.fs_stat(root .. "/regeln/DEP.md").mtime
    assert.are.same({ mtime.sec, mtime.nsec }, { again.sec, again.nsec }, "an unchanged document is not written")
  end)

  it("says which documents are out of date with check, and writes nothing", function()
    local root = ruleset()
    catalog.build(root)
    write(root .. "/_rules/DEP/DEP-01.md", rule_text("DEP-01", "critical", "#### `DEP-01` — Eins\n\nText eins, geändert.\n"))

    local results = catalog.build(root, { check = true })
    assert.are.equal("stale", results[1].status)
    assert.is_nil(read(root .. "/regeln/DEP.md"):find("geändert", 1, true))

    results = catalog.build(root)
    assert.are.equal("written", results[1].status)
    assert.is_truthy(read(root .. "/regeln/DEP.md"):find("geändert", 1, true))
    assert.are.equal("unchanged", catalog.build(root, { check = true })[1].status)
  end)

  it("says a missing document is stale", function()
    local root = ruleset()
    local results = catalog.build(root, { check = true })
    assert.are.equal("stale", results[1].status)
    assert.is_nil(read(root .. "/regeln/DEP.md"))
  end)

  it("keeps a document that is CRLF as CRLF, and compares without the line endings", function()
    local root = ruleset()
    catalog.build(root)
    local lf = read(root .. "/regeln/DEP.md")
    write(root .. "/regeln/DEP.md", (lf:gsub("\n", "\r\n")))

    assert.are.equal("unchanged", catalog.build(root, { check = true })[1].status)

    write(root .. "/_rules/DEP/DEP-01.md", rule_text("DEP-01", "critical", "#### `DEP-01` — Eins\n\nAnders.\n"))
    assert.are.equal("written", catalog.build(root)[1].status)
    local text = read(root .. "/regeln/DEP.md")
    assert.is_truthy(text:find("Anders.\r\n", 1, true))
    assert.is_nil(text:find("[^\r]\n"))
  end)

  it("does not load the document it made as rules", function()
    local root = ruleset()
    catalog.build(root)
    local rules, errors = require("rules.engine.loader").load({ root })
    assert.are.same({}, errors)
    assert.are.equal(3, #rules)
  end)

  it("names a rule that is in no layout", function()
    local root = ruleset()
    local results = catalog.build(root)
    assert.are.same({ "ERR-01" }, results[1].unused)
  end)

  it("reports a layout it cannot fill and writes nothing for it", function()
    local root = ruleset()
    write(root .. "/_layouts/regeln/BAD.md", "---\nkind: layout\noutput: regeln/BAD.md\n---\n{{rule NOPE-9}}\n")

    local results = catalog.build(root)

    assert.are.equal(2, #results)
    local bad
    for _, result in ipairs(results) do
      if result.layout:find("BAD.md", 1, true) then
        bad = result
      end
    end
    assert.are.equal("error", bad.status)
    assert.matches("NOPE%-9", bad.problems[1])
    assert.is_nil(read(root .. "/regeln/BAD.md"))
    assert.is_truthy(read(root .. "/regeln/DEP.md"))
  end)

  it("reports a layout whose output leaves the ruleset", function()
    local root = ruleset()
    write(root .. "/_layouts/EVIL.md", "---\nkind: layout\noutput: ../escape.md\n---\ntext\n")
    local results = catalog.build(root)
    local statuses = {}
    for _, result in ipairs(results) do
      statuses[result.status] = (statuses[result.status] or 0) + 1
    end
    assert.are.equal(1, statuses.error)
    assert.is_nil(read(vim.fs.dirname(root) .. "/escape.md"))
  end)

  it("reports a rule that is not in a rule file", function()
    local root = ruleset()
    write(root .. "/legacy.md", '```rule\nid = "OLD-1",\nseverity = "critical",\n```\n')
    write(root .. "/_layouts/OLD.md", "---\nkind: layout\noutput: out/OLD.md\n---\n{{rule OLD-1}}\n")

    local results = catalog.build(root)

    local old
    for _, result in ipairs(results) do
      if result.layout:find("OLD.md", 1, true) then
        old = result
      end
    end
    assert.are.equal("error", old.status)
    assert.matches("not a rule file", old.problems[1])
  end)

  it("returns nothing for a folder without layouts", function()
    local results, errors = catalog.build(tmp_dir())
    assert.are.same({}, results)
    assert.are.same({}, errors)
  end)

  it("passes the load errors of the ruleset on", function()
    local root = ruleset()
    write(root .. "/_rules/DEP/DEP-DUP.md", rule_text("DEP-01", "critical", "#### `DEP-01`\n"))
    local results, errors = catalog.build(root, { check = true })
    assert.are.equal(1, #results)
    assert.are.equal(1, #errors)
    assert.matches("duplicate rule id DEP%-01", errors[1])
  end)
end)

describe("rules.catalog", function()
  it("builds every folder in rulesets and gives an exit code", function()
    local root = tmp_dir()
    write(root .. "/_rules/DEP/DEP-01.md", rule_text("DEP-01", "critical", "#### `DEP-01` — Eins\n\nText.\n"))
    write(root .. "/_layouts/DEP.md", "---\nkind: layout\noutput: DEP.md\n---\n{{rule DEP-01}}\n")
    require("rules.config").setup({ rulesets = { root } })

    local results, errors, code = require("rules").catalog(nil, { check = true })
    assert.are.equal(1, code)
    assert.are.equal("stale", results[1].status)
    assert.are.same({}, errors)

    local built, built_errors, built_code = require("rules").catalog()
    assert.are.equal(0, built_code)
    assert.are.equal("written", built[1].status)
    assert.are.same({}, built_errors)

    local _, _, code_after = require("rules").catalog(root, { check = true })
    assert.are.equal(0, code_after)

    require("rules.config").setup({ rulesets = {} })
  end)

  it("ignores a ruleset entry that is a single file", function()
    local root = tmp_dir()
    write(root .. "/one.md", "# x\n")
    require("rules.config").setup({ rulesets = { root .. "/one.md" } })
    local results, errors, code = require("rules").catalog()
    assert.are.same({}, results)
    assert.are.same({}, errors)
    assert.are.equal(0, code)
    require("rules.config").setup({ rulesets = {} })
  end)
end)
