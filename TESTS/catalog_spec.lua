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

--- How long `fn` takes, in seconds.
---@param fn fun()
---@return number
local function seconds(fn)
  local started = vim.uv.hrtime()
  fn()
  return (vim.uv.hrtime() - started) / 1e9
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

  it("keeps the letters and digits of scripts that have no case with unicode = 1", function()
    local params = vim.tbl_extend("force", catalog.TOC_DEFAULTS, { unicode = 1 })
    assert.are.equal("日本語-regeln", catalog.slug("日本語 Regeln", params))
    assert.are.equal("한국어-x", catalog.slug("한국어 x", params))
    assert.are.equal("עברית-x", catalog.slug("עברית x", params))
    assert.are.equal("ไทย-x", catalog.slug("ไทย x", params))
    assert.are.equal("हिन्दी-x", catalog.slug("हिन्दी x", params))
    assert.are.equal("١٢٣-x", catalog.slug("١٢٣ x", params))
    -- punctuation, symbols and emoji still go
    assert.are.equal("ab", catalog.slug("a€b", params))
    assert.are.equal("ab", catalog.slug("a😀b", params))
    assert.are.equal("ab", catalog.slug("a—b", params))
    -- the signs × and ÷ are no letters, whatever 'iskeyword' says
    assert.are.equal("3--4-matrix", catalog.slug("3 × 4 matrix", params))
    assert.are.equal("10--2", catalog.slug("10 ÷ 2", params))
  end)

  it("does not depend on 'iskeyword' for the anchors of Latin-1 letters", function()
    local params = vim.tbl_extend("force", catalog.TOC_DEFAULTS, { unicode = 1 })
    local saved = vim.o.iskeyword
    vim.o.iskeyword = "a-z,A-Z,_"
    local slug = catalog.slug("Größe Café × ÿ", params)
    vim.o.iskeyword = saved
    assert.are.equal("größe-café--ÿ", slug)
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

  it("hands the anchor parameters on to the anchors", function()
    local headings = { "# T", "## `WEB-11` — `if_match`", "## Große Straße" }
    local function anchors(params)
      return vim.tbl_map(function(line)
        return line:match("%(#(.-)%)")
      end, catalog.toc_lines(headings, vim.tbl_extend("force", catalog.TOC_DEFAULTS, params)))
    end
    assert.are.same({ "web-11-if_match", "groe-strae" }, anchors({}))
    assert.are.same({ "web-11-ifmatch", "groe-strae" }, anchors({ underscore = 0 }))
    assert.are.same({ "web-11--if_match", "große-straße" }, anchors({ unicode = 1 }))
  end)

  it("hands the parameters of a {{toc}} token on to the anchors of the document", function()
    local layout = assert(catalog.parse_layout(layout_text("a.md", { "{{toc underscore=0}}", "## if_match", "## if_match" })))
    local text = catalog.render(layout, function()
      return nil, "unused"
    end)
    assert.are.equal("  - [if_match](#ifmatch)\n  - [if_match](#ifmatch-1)\n## if_match\n## if_match\n", text)
  end)

  it("numbers every repeat of an anchor", function()
    assert.are.same(
      { "  - [A](#a)", "  - [A](#a-1)", "  - [A](#a-2)", "  - [A](#a-3)" },
      catalog.toc_lines({ "# T", "## A", "## A", "## A", "## A" })
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

  it("takes whitespace after the token, but not before it", function()
    assert.are.same(catalog.TOC_DEFAULTS, catalog.parse_toc_token("{{toc}}  "))
    assert.are.same(catalog.TOC_DEFAULTS, catalog.parse_toc_token("{{toc}}\t"))
    assert.are.same(catalog.TOC_DEFAULTS, catalog.parse_toc_token("{{toc}}\r"))
    assert.are.same({ max = 2, base = 2, step = 2, unicode = 0, underscore = 1 }, catalog.parse_toc_token("{{toc max=2}} "))
    assert.are.same({ nil, nil }, { catalog.parse_toc_token("  {{toc}}") })
    assert.are.same({ nil, nil }, { catalog.parse_toc_token("{{toc}} and more") })
  end)

  it("is not slowed down by a hostile line", function()
    -- a run of blanks, then a character that ends the token for good: the pattern this replaced was cubic in the run
    local blanks = "{{toc" .. (" "):rep(3000) .. "x"
    assert.are.same({ nil, nil }, { catalog.parse_toc_token(blanks) })
    assert.is_true(seconds(function()
      catalog.parse_toc_token(blanks)
    end) < 0.25)

    -- a long token: its parameters are searched for `=`, which a run of non-blanks makes quadratic
    local long = "{{toc " .. ("a"):rep(20000) .. "}}"
    local params, err = catalog.parse_toc_token(long)
    assert.is_nil(params)
    assert.matches("longer than", err)
    assert.is_true(seconds(function()
      catalog.parse_toc_token(long)
    end) < 0.25)

    -- a long line that only starts like a token is text, as before
    assert.are.same({ nil, nil }, { catalog.parse_toc_token("{{toc " .. ("a"):rep(20000)) })
  end)

  it("is not slowed down by a heading with a long run of blanks in it", function()
    local spaced = { "# T", "## a" .. (" "):rep(40000) .. "b" }
    local lines
    assert.is_true(seconds(function()
      lines = catalog.toc_lines(spaced)
    end) < 0.25)
    assert.are.equal(1, #lines)
    assert.matches("^  %- %[a +b%]%(#a%-b%)$", lines[1])
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

  it("refuses an output that is not a valid file name on every system", function()
    for _, output in ipairs({
      "docs/x:y.md", -- on NTFS a stream of the file `x`
      "docs/q?.md",
      "docs/a*.md",
      "docs/bad<name>.md",
      "docs/a|b.md",
      'docs/"q".md',
      "a//b.md",
      "docs./x.md", -- Windows drops the dot: `docs/x.md`
      "docs /x.md",
    }) do
      local parsed, err = catalog.parse_layout(layout(output))
      assert.is_nil(parsed, output)
      assert.is_string(err, output)
    end
    assert.are.equal("my docs/a-b_c.md", assert(catalog.parse_layout(layout("my docs/a-b_c.md"))).output)
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

  it("fills every whole-line token, also one in a fence or a comment, which the layout editor does not see", function()
    -- documented difference (docs/RULESET-FORMAT.md, "What the editor takes for a heading or a token"): the editor
    -- (`rules.engine.layout_edit`) refuses to place an id a second time that stands like this, because the generator
    -- would place it twice
    local layout_edit = require("rules.engine.layout_edit")
    local lines = { "## S", "", "~~~", "{{rule A-1}}", "~~~", "", "<!--", "{{rule A-2}}", "-->" }
    local layout = assert(catalog.parse_layout(layout_text("a.md", lines)))
    local text, problems, used = catalog.render(layout, lookup)
    assert.are.same({}, problems)
    assert.are.same({ "A-1", "A-2" }, used)
    assert.is_truthy(text:find("Text one.", 1, true))
    assert.is_truthy(text:find("Text two.", 1, true))
    local source = layout_text("a.md", lines)
    assert.is_false(layout_edit.has(source, "A-1"))
    assert.is_false(layout_edit.has(source, "A-2"))
    assert.is_nil((layout_edit.place(source, "A-1", { section = "S" })))
  end)

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

  it("takes a token followed by whitespace, as the editors leave it", function()
    local layout = assert(catalog.parse_layout(layout_text("a.md", { "{{rule A-1}} ", "{{rule A-2}}\t", "{{toc}}  " })))
    local text, problems, used = catalog.render(layout, lookup)
    assert.are.same({}, problems)
    assert.are.same({ "A-1", "A-2" }, used)
    assert.is_nil(text:find("{{", 1, true))
    assert.matches("%- %[`A%-1` — One%]", text)
  end)

  it("is not slowed down by a hostile line", function()
    local hostile = "{{toc" .. (" "):rep(3000) .. "x"
    local layout = assert(catalog.parse_layout(layout_text("a.md", { hostile, "{{rule" .. (" "):rep(30000) .. "x" })))
    local text, problems
    assert.is_true(seconds(function()
      text, problems = catalog.render(layout, lookup)
    end) < 0.5)
    assert.are.same({}, problems)
    assert.are.equal(hostile .. "\n{{rule" .. (" "):rep(30000) .. "x\n", text)
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

  it("names only rule files as in no layout, and reads a document once however many rules it holds", function()
    --- Build a ruleset with a layout and one document of `n` rules; how often the document was read, and the result.
    local function build_with_document(n)
      local root = ruleset()
      local blocks = {}
      for i = 1, n do
        blocks[#blocks + 1] = ('## R%d\n\n```rule\nid = "OLD-%d",\nseverity = "critical",\n```\n'):format(i, i)
      end
      write(root .. "/legacy.md", "# Legacy\n\n" .. table.concat(blocks, "\n"))
      local reads = 0
      local original = vim.fn.readfile
      vim.fn.readfile = function(path, ...)
        if tostring(path):find("legacy.md", 1, true) then
          reads = reads + 1
        end
        return original(path, ...)
      end
      local ok, results = pcall(catalog.build, root, { check = true })
      vim.fn.readfile = original
      assert(ok, results)
      return reads, results
    end

    local few, results = build_with_document(3)
    local many = build_with_document(40)
    assert.are.same({ "ERR-01" }, results[1].unused)
    assert.are.equal(few, many, "the document is read the same number of times for 3 rules and for 40")
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

  --- The result of the layout `name` (a part of its path).
  ---@param results Rules.CatalogResult[]
  ---@param name string
  ---@return Rules.CatalogResult
  local function result_of(results, name)
    for _, result in ipairs(results) do
      if result.layout:find(name, 1, true) then
        return result
      end
    end
    error("no result for " .. name)
  end

  describe("with an output that would destroy something", function()
    it("keeps a layout whose output is the layout itself", function()
      local root = ruleset()
      local text = layout_text("_layouts/self.md", { "{{rule DEP-01}}" })
      write(root .. "/_layouts/self.md", text)

      for _, opts in ipairs({ {}, { check = true }, {} }) do
        local self = result_of(catalog.build(root, opts), "self.md")
        assert.are.equal("error", self.status)
        assert.matches("is a layout", self.problems[1])
        assert.are.equal(text, read(root .. "/_layouts/self.md"))
      end
      assert.are.equal(1, select(3, require("rules").catalog(root)))
    end)

    it("keeps a rule file whose path is the output", function()
      local root = ruleset()
      local rule_path = root .. "/_rules/DEP/DEP-02.md"
      local before = read(rule_path)
      write(root .. "/_layouts/EVIL.md", layout_text("_rules/DEP/DEP-02.md", { "{{rule DEP-01}}" }))

      local evil = result_of(catalog.build(root), "EVIL.md")

      assert.are.equal("error", evil.status)
      assert.matches("is a rule file", evil.problems[1])
      assert.are.equal(before, read(rule_path))
      assert.are.equal(3, #require("rules.engine.loader").load({ root }))
    end)

    it("keeps another layout whose path is the output", function()
      local root = ruleset()
      local other = layout_text("other.md", { "{{rule ERR-01}}" })
      write(root .. "/_layouts/other.md", other)
      write(root .. "/_layouts/EVIL.md", layout_text("_layouts/other.md", { "{{rule DEP-01}}" }))

      local results = catalog.build(root)

      assert.are.equal("error", result_of(results, "EVIL.md").status)
      assert.are.equal(other, read(root .. "/_layouts/other.md"))
      assert.are.equal("written", result_of(results, "other.md").status)
    end)

    it("keeps a document with rules whose path is the output", function()
      local root = ruleset()
      local legacy = '```rule\nid = "OLD-1",\nseverity = "critical",\n```\n'
      write(root .. "/legacy.md", legacy)
      write(root .. "/_layouts/EVIL.md", layout_text("legacy.md", { "{{rule DEP-01}}" }))

      for _, adopt in ipairs({ false, true }) do
        local evil = result_of(catalog.build(root, { adopt = adopt }), "EVIL.md")
        assert.are.equal("error", evil.status)
        assert.matches("document with rules", evil.problems[1])
        assert.are.equal(legacy, read(root .. "/legacy.md"))
      end
    end)

    it("says the same of a path that only spells another one differently", function()
      if vim.fn.has("win32") == 0 and vim.fn.has("mac") == 0 then
        pending("the file system tells the cases apart")
      end
      local root = ruleset()
      -- the folder in another case: the same file
      local text = layout_text("_LAYOUTS/self.md", { "{{rule DEP-01}}" })
      write(root .. "/_layouts/self.md", text)

      local self = result_of(catalog.build(root), "self.md")

      assert.are.equal("error", self.status)
      assert.matches("is a layout", self.problems[1])
      assert.are.equal(text, read(root .. "/_layouts/self.md"))
    end)

    it("gives an output to the first layout and refuses it to the next", function()
      local root = ruleset()
      write(root .. "/_layouts/regeln/DEP2.md", layout_text("regeln/DEP.md", { "{{rule ERR-01}}" }))

      local results = catalog.build(root)
      assert.are.equal("written", result_of(results, "regeln/DEP.md").status)
      local second = result_of(results, "DEP2.md")
      assert.are.equal("error", second.status)
      assert.matches("already the output of _layouts/regeln/DEP.md", second.problems[1])
      local first_text = read(root .. "/regeln/DEP.md")
      assert.matches("from _layouts/regeln/DEP.md", first_text)

      -- not "written" over and over, and not "stale" for good: the second is an error every time, the first is done
      for _, opts in ipairs({ { check = true }, {}, { check = true } }) do
        results = catalog.build(root, opts)
        assert.are.equal("unchanged", result_of(results, "regeln/DEP.md").status)
        assert.are.equal("error", result_of(results, "DEP2.md").status)
      end
      assert.are.equal(first_text, read(root .. "/regeln/DEP.md"))
      assert.are.equal(1, select(3, require("rules").catalog(root, { check = true })))
    end)

    it("counts the rules of a layout that is refused as placed: the output is the fault to tell", function()
      local root = ruleset()
      write(root .. "/_layouts/EVIL.md", layout_text("_layouts/EVIL.md", { "{{rule ERR-01}}" }))
      local results = catalog.build(root)
      assert.are.same({}, results[1].unused)
    end)
  end)

  describe("with an output that already exists", function()
    it("does not replace a document nobody generated", function()
      local root = ruleset()
      local readme = "# My notes\n\nWritten by hand.\n"
      write(root .. "/regeln/DEP.md", readme)

      for _, opts in ipairs({ { check = true }, {} }) do
        local result = catalog.build(root, opts)[1]
        assert.are.equal("error", result.status)
        assert.matches("not a generated document", result.problems[1])
        assert.are.equal(readme, read(root .. "/regeln/DEP.md"))
      end
      assert.are.equal(1, select(3, require("rules").catalog(root)))
    end)

    it("replaces it when it is adopted, and from then on it is a generated document", function()
      local root = ruleset()
      write(root .. "/regeln/DEP.md", "# My notes\n")

      assert.are.equal("stale", catalog.build(root, { adopt = true, check = true })[1].status)
      assert.are.equal("written", catalog.build(root, { adopt = true })[1].status)
      assert.matches("^" .. vim.pesc(parser.GENERATED_PREFIX), read(root .. "/regeln/DEP.md"))
      assert.are.equal("unchanged", catalog.build(root, { check = true })[1].status)
    end)

    it("replaces an empty file and a generated document", function()
      local root = ruleset()
      write(root .. "/regeln/DEP.md", "")
      assert.are.equal("written", catalog.build(root)[1].status)
      write(root .. "/_rules/DEP/DEP-01.md", rule_text("DEP-01", "critical", "#### `DEP-01` — Eins\n\nAnders.\n"))
      assert.are.equal("written", catalog.build(root)[1].status)
      write(root .. "/regeln/DEP.md", "\n  \n")
      assert.are.equal("written", catalog.build(root)[1].status)
    end)

    it("knows a generated document that starts with a byte order mark", function()
      local root = ruleset()
      catalog.build(root)
      write(root .. "/_rules/DEP/DEP-01.md", rule_text("DEP-01", "critical", "#### `DEP-01` — Eins\n\nAnders.\n"))
      write(root .. "/regeln/DEP.md", "\239\187\191" .. read(root .. "/regeln/DEP.md"))
      assert.are.equal("written", catalog.build(root)[1].status)
    end)
  end)

  describe("with a link on the way of the output", function()
    --- A directory link at `link` to `target`; false when the system does not let this user make one.
    ---@param target string
    ---@param link string
    ---@return boolean
    local function link_dir(target, link)
      return vim.uv.fs_symlink(target, link, { dir = true, junction = true }) == true
    end

    it("does not write through it out of the ruleset", function()
      local root = ruleset()
      local outside = tmp_dir()
      write(outside .. "/keep.md", "ORIGINAL\n")
      if not link_dir(outside, root .. "/link") then
        pending("no right to make a link here")
      end
      write(root .. "/_layouts/EVIL.md", layout_text("link/keep.md", { "{{rule DEP-01}}" }))
      write(root .. "/_layouts/EVIL2.md", layout_text("link/new/pwn.md", { "{{rule DEP-01}}" }))

      for _, opts in ipairs({ { check = true }, {} }) do
        local results = catalog.build(root, opts)
        for _, name in ipairs({ "EVIL.md", "EVIL2.md" }) do
          assert.are.equal("error", result_of(results, name).status, name)
          assert.matches("leaves the ruleset", result_of(results, name).problems[1])
        end
      end
      assert.are.equal("ORIGINAL\n", read(outside .. "/keep.md"))
      assert.are.same({ "keep.md" }, vim.fn.readdir(outside), "nothing else was made there")
      assert.are.equal("unchanged", result_of(catalog.build(root), "regeln/DEP.md").status, "the honest layout was written above")
    end)

    it("does not write through a link below a folder either", function()
      local root = ruleset()
      local outside = tmp_dir()
      vim.fn.mkdir(root .. "/docs", "p")
      if not link_dir(outside, root .. "/docs/sub") then
        pending("no right to make a link here")
      end
      write(root .. "/_layouts/EVIL.md", layout_text("docs/sub/deep/x.md", { "{{rule DEP-01}}" }))

      assert.are.equal("error", result_of(catalog.build(root), "EVIL.md").status)
      assert.are.same({}, vim.fn.readdir(outside))
    end)

    it("writes through a link that stays inside the ruleset", function()
      local root = ruleset()
      vim.fn.mkdir(root .. "/real", "p")
      if not link_dir(root .. "/real", root .. "/alias") then
        pending("no right to make a link here")
      end
      write(root .. "/_layouts/ALIAS.md", layout_text("alias/x.md", { "{{rule DEP-01}}" }))

      assert.are.equal("written", result_of(catalog.build(root), "ALIAS.md").status)
      assert.is_truthy(read(root .. "/real/x.md"))
    end)
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

  it("gives exit code 1 for an output that would destroy a file, and writes nothing", function()
    local root = tmp_dir()
    write(root .. "/_rules/DEP/DEP-01.md", rule_text("DEP-01", "critical", "#### `DEP-01` — Eins\n\nText.\n"))
    write(root .. "/README.md", "# Hand-written\n")
    write(root .. "/_layouts/DEP.md", "---\nkind: layout\noutput: README.md\n---\n{{rule DEP-01}}\n")

    for _, opts in ipairs({ { check = true }, {} }) do
      local results, errors, code = require("rules").catalog(root, opts)
      assert.are.equal(1, code)
      assert.are.equal("error", results[1].status)
      assert.are.same({}, errors)
      assert.are.equal("# Hand-written\n", read(root .. "/README.md"))
    end

    local _, _, adopted = require("rules").catalog(root, { adopt = true })
    assert.are.equal(0, adopted)
    assert.matches("^" .. vim.pesc(parser.GENERATED_PREFIX), read(root .. "/README.md"))
  end)

  it("reports a ruleset entry that is a single file (it is no folder), without a path of this machine", function()
    local root = tmp_dir()
    write(root .. "/one.md", "# x\n")
    require("rules.config").setup({ rulesets = { root .. "/one.md" } })
    local results, errors, code = require("rules").catalog()
    assert.are.same({}, results)
    assert.are.same({ "ruleset one.md (setup({ rulesets })) is not a folder" }, errors)
    assert.are.equal(1, code)
    require("rules.config").setup({ rulesets = {} })
  end)
end)
