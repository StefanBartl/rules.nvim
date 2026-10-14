-- TESTS/ops_spec.lua -- `rules-ops/1`: new, set, retire, reinstate, move; the file text, the layouts, the step back.
---@diagnostic disable: need-check-nil
local contract = require("rules.contract")
local rule_edit = require("rules.engine.rule_edit")
local layout_edit = require("rules.engine.layout_edit")
local parser = require("rules.engine.parser")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param path string
---@return string|nil
local function read_raw(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

local function rule_file(id, severity, title, body, block)
  local out = { "---", "id: " .. id, "severity: " .. severity, "family: " .. id:match("^(%a+)%-"), "---", "" }
  out[#out + 1] = "#### `" .. id .. "` — " .. title
  out[#out + 1] = ""
  if block then
    out[#out + 1] = "```rule"
    for _, line in ipairs(block) do
      out[#out + 1] = line
    end
    out[#out + 1] = "```"
    out[#out + 1] = ""
  end
  for _, line in ipairs(body) do
    out[#out + 1] = line
  end
  return table.concat(out, "\n") .. "\n"
end

local LAYOUT_DEP = table.concat({
  "---",
  "kind: layout",
  "output: regeln/DEP.md",
  "---",
  "# Dependencies",
  "",
  "## Core",
  "",
  "{{rule DEP-01}}",
  "{{rule DEP-02}}",
  "",
  "## Extra",
  "",
  "{{rule DEP-03}}",
  "",
}, "\n")

local LAYOUT_ERR = table.concat({
  "---",
  "kind: layout",
  "output: regeln/ERR.md",
  "---",
  "# Errors",
  "",
  "{{rule ERR-01}}",
  "",
}, "\n")

---@return string root, table opts
local function fixture()
  local root = tmp_dir() .. "/fixture/Checklists"
  write_raw(root .. "/_rules/DEP/DEP-01.md", rule_file("DEP-01", "recommended", "one", { "Text of one.", "Second line." }))
  write_raw(
    root .. "/_rules/DEP/DEP-02.md",
    rule_file("DEP-02", "critical", "two", { "Text of two." }, { 'check = { type = "grep", pattern = "foo" },' })
  )
  write_raw(
    root .. "/_rules/DEP/DEP-03.md",
    rule_file(
      "DEP-03",
      "nice-to-have",
      "three",
      { "Text of three." },
      { 'check = { type = "lua_predicate", predicate = function() return true end },' }
    )
  )
  write_raw(root .. "/_rules/ERR/ERR-01.md", rule_file("ERR-01", "critical", "err", { "Err text." }))
  write_raw(root .. "/_layouts/regeln/DEP.md", LAYOUT_DEP)
  write_raw(root .. "/_layouts/regeln/ERR.md", LAYOUT_ERR)
  return root, { rulesets = { root }, today = "2026-10-14" }
end

---@param opts table
---@param list table[]
---@param extra? table
---@return table doc
local function run(opts, list, extra)
  local ops = require("rules.ops")
  local params = vim.tbl_extend("force", { ops = list }, extra or {})
  local doc, err = ops.run(params, opts)
  assert(doc, vim.inspect(err))
  return doc
end

---@param opts table
---@param op table
---@param extra? table
---@return table entry
local function one(opts, op, extra)
  return run(opts, { op }, extra).results[1]
end

local function ids_of(opts)
  contract.clear_cache()
  local view = assert(contract.view(opts))
  local out = {}
  for _, rule in ipairs(view.rules) do
    out[#out + 1] = rule.id
  end
  return out
end

describe("rules.engine.rule_edit", function()
  local PATH = "DEP-01.md"
  local BASE = rule_file("DEP-01", "recommended", "one", { "Text of one.", "", "Second para." })

  it("changes the severity and nothing else", function()
    local new = assert(rule_edit.apply(PATH, BASE, { severity = "critical" }))
    assert.are.equal((BASE:gsub("severity: recommended", "severity: critical")), new)
  end)

  it("changes the title, keeping the heading level and the id", function()
    local new = assert(rule_edit.apply(PATH, BASE, { title = "another title" }))
    assert.are.equal((BASE:gsub("one\n", "another title\n", 1)), new)
  end)

  it("replaces the prose and leaves the frontmatter and the heading", function()
    local new = assert(rule_edit.apply(PATH, BASE, { text = "New prose." }))
    local rule = parser.parse_rule_text(PATH, new)
    assert.are.equal("New prose.", rule.text)
    assert.are.equal(BASE:match("^(.-)Text of one"), new:match("^(.-)New prose"))
  end)

  it("leaves a separator line under the prose where it is (only the prose is replaced)", function()
    local framed = BASE .. "\n---\n"
    local same = assert(rule_edit.apply(PATH, framed, { text = "Text of one.\n\nSecond para." }))
    assert.are.equal(framed, same)
    local new = assert(rule_edit.apply(PATH, framed, { text = "Other." }))
    assert.are.equal("---\n", new:sub(-4))
    assert.are.equal("Other.", parser.parse_rule_text(PATH, new).text)
  end)

  it("keeps CR LF line endings and a missing final newline", function()
    local crlf = (BASE:gsub("\n", "\r\n"))
    local new = assert(rule_edit.apply(PATH, crlf, { text = "A\nB" }))
    assert.is_nil(new:find("[^\r]\n"))
    assert.is_truthy(new:find("A\r\nB\r\n", 1, true))
    local bare = BASE:sub(1, -2)
    local out = assert(rule_edit.apply(PATH, bare, { severity = "critical" }))
    assert.are.equal("critical", parser.parse_rule_text(PATH, out).severity)
    assert.are.equal(".", out:sub(-1))
  end)

  it("adds, changes and removes a check", function()
    local with = assert(rule_edit.apply(PATH, BASE, { check = { type = "grep", pattern = "x%.y" } }))
    local rule = parser.parse_rule_text(PATH, with)
    assert.are.same({ type = "grep", pattern = "x%.y" }, rule.check)
    assert.is_truthy(with:find("```rule", 1, true))
    local without = assert(rule_edit.apply(PATH, with, { check = vim.NIL }))
    assert.are.equal(BASE, without)
  end)

  it("refuses a check on a block with a function or a comment", function()
    local fn = rule_file(
      "DEP-01",
      "critical",
      "f",
      { "T." },
      { "check = { type = 'lua_predicate', predicate = function() end }," }
    )
    local _, why = rule_edit.apply(PATH, fn, { check = { type = "grep", pattern = "x" } })
    assert.is_truthy(why:find("function", 1, true))
    local note = rule_file("DEP-01", "critical", "f", { "T." }, { "-- why", 'check = { type = "grep", pattern = "x" },' })
    local _, why2 = rule_edit.apply(PATH, note, { check = vim.NIL })
    assert.is_truthy(why2:find("comment", 1, true))
  end)

  it("changes the severity of a block with a comment and a function in place, writing nothing else of the block", function()
    local block = {
      "-- why this rule is here: severity = 'nice-to-have' is not meant",
      'severity = "recommended", -- the same as the frontmatter',
      "check = { type = 'lua_predicate', predicate = function() local severity = 1 return severity end },",
    }
    local base = rule_file("DEP-01", "recommended", "f", { "T." }, block)
    local new = assert(rule_edit.apply(PATH, base, { severity = "critical" }))
    local want =
      base:gsub("severity: recommended", "severity: critical", 1):gsub('severity = "recommended"', 'severity = "critical"', 1)
    assert.are.equal(want, new)
    assert.are.equal("critical", parser.parse_rule_text(PATH, new).severity)
    -- a nested severity key is not the block's own
    local nested = rule_file(
      "DEP-01",
      "recommended",
      "n",
      { "T." },
      { 'check = { type = "grep", pattern = "x", severity = "keep" },' }
    )
    local kept = assert(rule_edit.apply(PATH, nested, { severity = "critical" }))
    assert.is_truthy(kept:find('severity = "keep"', 1, true))
  end)

  it("takes a string that holds two dashes for a string, not for a comment", function()
    local grep = { type = "grep", pattern = "x" }
    for _, line in ipairs({
      'check = { type = "grep", pattern = "--color" },',
      "check = { type = 'grep', pattern = '--color' },",
      "check = { type = 'grep', pattern = [==[a--b]==] },",
    }) do
      local text = rule_file("DEP-01", "critical", "f", { "T." }, { line })
      local new, why = rule_edit.apply(PATH, text, { check = grep })
      assert.is_truthy(new, why)
      assert.are.same(grep, parser.parse_rule_text(PATH, new).check)
    end
    for _, block in ipairs({
      { 'check = { type = "grep", pattern = "a" }, -- note' },
      { "--[==[ a long", "note ]==]", 'check = { type = "grep", pattern = "a" },' },
    }) do
      local _, why = rule_edit.apply(PATH, rule_file("DEP-01", "critical", "f", { "T." }, block), { check = grep })
      assert.is_truthy(why and why:find("comment", 1, true), vim.inspect(block))
    end
  end)

  it("keeps CR LF when the last line has no line break, and does not take that for mixed endings", function()
    local crlf = (BASE:gsub("\n", "\r\n")):sub(1, -3)
    assert.are.equal(".", crlf:sub(-1))
    local new, why = rule_edit.apply(PATH, crlf, { severity = "critical" })
    assert.is_truthy(new, why)
    assert.are.equal(".", new:sub(-1))
    assert.are.equal((crlf:gsub("severity: recommended", "severity: critical")), new)
    local _, mixed = rule_edit.apply(PATH, "---\r\nid: DEP-01\nseverity: critical\n---\r\n#### x", { severity = "critical" })
    assert.is_truthy(mixed:find("mixes", 1, true))
  end)

  it("refuses a text that would not read back as written", function()
    local _, why = rule_edit.apply(PATH, BASE, { text = "Para.\n\n## A heading\n\nMore." })
    assert.is_truthy(why:find("read back", 1, true))
  end)

  it("refuses a file that mixes line endings", function()
    local _, why = rule_edit.apply(PATH, "---\r\nid: DEP-01\nseverity: critical\n---\n", { severity = "critical" })
    assert.is_truthy(why:find("mixes", 1, true))
  end)

  it("writes a Lua table the block reads back, strings with quotes and backslashes included", function()
    local value = { type = "grep", pattern = 'a"b' .. string.char(92) .. "c", list = { "x", "y" }, n = 3, flag = true }
    local text = assert(rule_edit.lua_value(value))
    local back = assert(load("return " .. text))()
    assert.are.same(value, back)
  end)
end)

describe("rules.engine.layout_edit", function()
  it("finds where a token stands and puts one in and takes it out again", function()
    local at = layout_edit.locate(LAYOUT_DEP, "DEP-02")
    assert.are.same({ section = "Core", prev = "DEP-01" }, at)
    assert.is_true(layout_edit.has(LAYOUT_DEP, "DEP-03"))

    local out = assert(layout_edit.remove(LAYOUT_DEP, "DEP-02"))
    assert.is_false(layout_edit.has(out, "DEP-02"))
    local back = assert(layout_edit.place(out, "DEP-02", { after = "DEP-01" }))
    assert.are.equal(LAYOUT_DEP, back)
  end)

  it("places into a section, at its start or its end", function()
    local first = assert(layout_edit.place(LAYOUT_DEP, "NEW-01", { section = "Core", first = true }))
    assert.is_truthy(first:find("## Core\n\n{{rule NEW-01}}\n{{rule DEP-01}}", 1, true))
    local last = assert(layout_edit.place(LAYOUT_DEP, "NEW-01", { section = "Core" }))
    assert.is_truthy(last:find("{{rule DEP-02}}\n{{rule NEW-01}}\n", 1, true))
    local _, why = layout_edit.place(LAYOUT_DEP, "NEW-01", { section = "Nope" })
    assert.is_truthy(why:find("no section", 1, true))
  end)

  it("refuses a rule that is in the layout already, and an anchor that is not", function()
    assert.is_nil((layout_edit.place(LAYOUT_DEP, "DEP-01", { after = "DEP-02" })))
    assert.is_nil((layout_edit.place(LAYOUT_DEP, "NEW-01", { after = "GHOST-01" })))
  end)

  it("keeps CR LF line endings", function()
    local crlf = (LAYOUT_DEP:gsub("\n", "\r\n"))
    local out = assert(layout_edit.place(crlf, "NEW-01", { after = "DEP-01" }))
    assert.is_nil(out:find("[^\r]\n"))
  end)
end)

describe("rules-ops/1 new", function()
  it("creates the file with the next free id and puts it in the layout", function()
    local root, opts = fixture()
    local entry =
      one(opts, { op = "new", family = "DEP", title = "four", severity = "recommended", text = "Four.", after = "DEP-02" })
    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("DEP-04", entry.id)
    assert.are.equal("created", entry.outcome)
    assert.are.same({ "DEP-04" }, entry.changed_ids)
    assert.are.equal("regeln/DEP.md", entry.placed.layout)
    assert.is_truthy(read_raw(root .. "/_rules/DEP/DEP-04.md"):find("Four.", 1, true))
    assert.is_truthy(vim.tbl_contains(ids_of(opts), "DEP-04"))
    -- the document was made again, with the rule in it
    local doc = read_raw(root .. "/regeln/DEP.md")
    assert.is_truthy(doc:find("DEP-04", 1, true))
    assert.is_true(doc:find("DEP-02", 1, true) < doc:find("DEP-04", 1, true))
  end)

  it("starts a family at 01 and keeps the id of a retired rule taken", function()
    local _, opts = fixture()
    local fresh = one(opts, { op = "new", family = "NEW", title = "first", severity = "critical" })
    assert.are.equal("NEW-01", fresh.id)
    local retired = one(opts, { op = "retire", id = "DEP-03" })
    assert.is_true(retired.ok, vim.inspect(retired))
    local next_one = one(opts, { op = "new", family = "DEP", title = "after the retired", severity = "critical" })
    assert.are.equal("DEP-04", next_one.id)
  end)

  it("writes nothing on a dry run and says what it would do", function()
    local root, opts = fixture()
    local doc = run(
      opts,
      { { op = "new", family = "DEP", title = "dry", severity = "critical", after = "DEP-01" } },
      { dry_run = true }
    )
    assert.is_true(doc.dry_run)
    assert.are.equal("would_create", doc.results[1].outcome)
    assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-04.md"))
    assert.are.equal(LAYOUT_DEP, read_raw(root .. "/_layouts/regeln/DEP.md"))
  end)

  it("refuses bad input before writing anything", function()
    local root, opts = fixture()
    local cases = {
      { op = "new", family = "D-P", title = "t", severity = "critical" },
      { op = "new", family = "DEP", title = "t", severity = "huge" },
      { op = "new", family = "DEP", title = "two\nlines", severity = "critical" },
      { op = "new", family = "DEP", title = "t", severity = "critical", check = { pattern = "x" } },
      { op = "new", family = "DEP", title = "t", severity = "critical", after = "DEP-01", before = "DEP-02" },
      { op = "new", family = "DEP", title = "t", severity = "critical", section = "Core" },
      { op = "new", family = "DEP", title = "t", severity = "critical", text = "## a heading" },
    }
    for _, case in ipairs(cases) do
      local entry = one(opts, case)
      assert.is_false(entry.ok, vim.inspect(case))
      assert.are.equal("invalid_argument", entry.error.code, vim.inspect(case))
    end
    assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-04.md"))
  end)

  it("takes the new file back when the layout cannot take the rule", function()
    local root, opts = fixture()
    local entry = one(opts, { op = "new", family = "DEP", title = "t", severity = "critical", after = "GHOST-01" })
    assert.is_false(entry.ok)
    assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-04.md"))
  end)
end)

describe("rules-ops/1 set", function()
  it("changes fields and answers the etags, what was before and the inverse", function()
    local root, opts = fixture()
    local path = root .. "/_rules/DEP/DEP-01.md"
    local original = read_raw(path)
    local entry = one(opts, { op = "set", id = "DEP-01", patch = { severity = "critical", text = "Changed." } })
    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("changed", entry.outcome)
    assert.are_not.equal(entry.etag_before, entry.etag_after)
    assert.are.equal("recommended", entry.before.severity)
    assert.are.equal("Text of one.\nSecond line.", entry.before.text)

    -- the inverse brings the bytes back
    local back = one(opts, entry.inverse)
    assert.is_true(back.ok, vim.inspect(back))
    assert.are.equal(original, read_raw(path))
  end)

  it("is a conflict when the file is not the version the caller saw, and a match writes", function()
    local root, opts = fixture()
    local entry =
      one(opts, { op = "set", id = "DEP-01", patch = { severity = "critical" }, if_match = "sha256:0000000000000000" })
    assert.is_false(entry.ok)
    assert.are.equal("conflict", entry.error.code)
    assert.are.equal("sha256:0000000000000000", entry.error.details.expected)
    assert.is_truthy(entry.error.details.actual:match("^sha256:%x+$"))
    assert.is_truthy(read_raw(root .. "/_rules/DEP/DEP-01.md"):find("severity: recommended", 1, true))

    local ok = one(opts, { op = "set", id = "DEP-01", patch = { severity = "critical" }, if_match = entry.error.details.actual })
    assert.is_true(ok.ok, vim.inspect(ok))
  end)

  it("reports unchanged, and writes nothing on a dry run", function()
    local root, opts = fixture()
    local same = one(opts, { op = "set", id = "DEP-01", patch = { severity = "recommended" } })
    assert.are.equal("unchanged", same.outcome)
    local before = read_raw(root .. "/_rules/DEP/DEP-01.md")
    local dry = run(opts, { { op = "set", id = "DEP-01", patch = { text = "X." } } }, { dry_run = true }).results[1]
    assert.are.equal("would_change", dry.outcome)
    assert.is_truthy(dry.diff.after:find("X.", 1, true))
    assert.are.equal(before, read_raw(root .. "/_rules/DEP/DEP-01.md"))
  end)

  it("refuses a rule in a document, a function check, an unknown id and bad patches", function()
    local root, opts = fixture()
    write_raw(
      root .. "/DOC.md",
      table.concat({
        "### `DOC-01` — in a document",
        "",
        "```rule",
        'id = "DOC-01",',
        'severity = "critical",',
        "```",
        "",
        "Text.",
        "",
      }, "\n")
    )
    local doc = one(opts, { op = "set", id = "DOC-01", patch = { severity = "recommended" } })
    assert.is_false(doc.ok)
    assert.is_truthy(doc.error.message:find("many rules", 1, true))

    local fn = one(opts, { op = "set", id = "DEP-03", patch = { check = vim.NIL } })
    assert.is_false(fn.ok)
    assert.is_truthy(fn.error.message:find("function", 1, true))
    -- the function rule's prose can still be changed
    local prose = one(opts, { op = "set", id = "DEP-03", patch = { text = "Changed three." } })
    assert.is_true(prose.ok, vim.inspect(prose))
    assert.is_truthy(read_raw(root .. "/_rules/DEP/DEP-03.md"):find("function() return true end", 1, true))

    local missing = one(opts, { op = "set", id = "NOPE-01", patch = { severity = "critical" } })
    assert.are.equal("not_found", missing.error.code)
    for _, patch in ipairs({ {}, { colour = "red" }, { severity = "huge" }, { title = "a\nb" }, { text = "x\1y" } }) do
      local bad = one(opts, { op = "set", id = "DEP-01", patch = patch })
      assert.is_false(bad.ok, vim.inspect(patch))
      assert.are.equal("invalid_argument", bad.error.code, vim.inspect(patch))
    end
  end)

  it("leaves other rules and a CR LF file's line endings alone", function()
    local root, opts = fixture()
    local path = root .. "/_rules/DEP/DEP-01.md"
    local crlf = (read_raw(path):gsub("\n", "\r\n"))
    write_raw(path, crlf)
    local other = read_raw(root .. "/_rules/DEP/DEP-02.md")
    local entry = one(opts, { op = "set", id = "DEP-01", patch = { title = "retitled" } })
    assert.is_true(entry.ok, vim.inspect(entry))
    local after = read_raw(path)
    assert.is_nil(after:find("[^\r]\n"))
    assert.is_truthy(after:find("retitled", 1, true))
    assert.are.equal(other, read_raw(root .. "/_rules/DEP/DEP-02.md"))
  end)
end)

describe("rules-ops/1 retire, reinstate, move", function()
  it("retires a rule out of the run and the layout, and reinstates it to the same place", function()
    local root, opts = fixture()
    local path = root .. "/_rules/DEP/DEP-02.md"
    local original = read_raw(path)
    local entry = one(opts, { op = "retire", id = "DEP-02", replaced_by = "DEP-01", reason = "superseded" })
    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("retired", entry.outcome)
    assert.is_nil(read_raw(path))
    assert.is_truthy(read_raw(root .. "/_retired/DEP/DEP-02.md"):find("replaced_by: DEP-01", 1, true))
    assert.is_false(vim.tbl_contains(ids_of(opts), "DEP-02"))
    assert.is_false(layout_edit.has(read_raw(root .. "/_layouts/regeln/DEP.md"), "DEP-02"))
    assert.is_nil(read_raw(root .. "/regeln/DEP.md"):find("DEP-02", 1, true))

    local snapshot = assert(contract.snapshot(opts))
    assert.are.equal("DEP-02", snapshot.retired[1].id)
    assert.are.equal("DEP-01", snapshot.retired[1].replaced_by)
    -- the retired file is not read as a rule (it would be a load error: it has keys a rule file has not)
    assert.are.same({}, snapshot.load_errors)

    local back = one(opts, entry.inverse)
    assert.is_true(back.ok, vim.inspect(back))
    assert.are.equal(original, read_raw(path))
    assert.are.equal(LAYOUT_DEP, read_raw(root .. "/_layouts/regeln/DEP.md"))
    assert.is_nil(read_raw(root .. "/_retired/DEP/DEP-02.md"))
  end)

  it("refuses to retire what does not exist, to replace a rule with itself and to name a rule that is not there", function()
    local _, opts = fixture()
    assert.are.equal("not_found", one(opts, { op = "retire", id = "NOPE-01" }).error.code)
    assert.is_false(one(opts, { op = "retire", id = "DEP-01", replaced_by = "DEP-01" }).ok)
    assert.are.equal("not_found", one(opts, { op = "retire", id = "DEP-01", replaced_by = "GHOST-01" }).error.code)
    assert.are.equal("not_found", one(opts, { op = "reinstate", id = "DEP-01" }).error.code)
  end)

  it("moves a rule within a layout and to another one, and the inverse moves it back", function()
    local root, opts = fixture()
    local entry = one(opts, { op = "move", id = "DEP-01", after = "DEP-02" })
    assert.is_true(entry.ok, vim.inspect(entry))
    local text = read_raw(root .. "/_layouts/regeln/DEP.md")
    assert.is_true(text:find("DEP-02", 1, true) < text:find("DEP-01", 1, true))
    local back = one(opts, entry.inverse)
    assert.is_true(back.ok, vim.inspect(back))
    assert.are.equal(LAYOUT_DEP, read_raw(root .. "/_layouts/regeln/DEP.md"))

    local across = one(opts, { op = "move", id = "DEP-03", after = "ERR-01" })
    assert.is_true(across.ok, vim.inspect(across))
    assert.are.equal("regeln/ERR.md", across.placed.layout)
    assert.is_false(layout_edit.has(read_raw(root .. "/_layouts/regeln/DEP.md"), "DEP-03"))
    assert.is_true(layout_edit.has(read_raw(root .. "/_layouts/regeln/ERR.md"), "DEP-03"))
    local home = one(opts, across.inverse)
    assert.is_true(home.ok, vim.inspect(home))
    assert.are.equal(LAYOUT_DEP, read_raw(root .. "/_layouts/regeln/DEP.md"))
    assert.are.equal(LAYOUT_ERR, read_raw(root .. "/_layouts/regeln/ERR.md"))
  end)

  it("does not move a rule next to itself, and a rule file is not touched by a move", function()
    local root, opts = fixture()
    local before = read_raw(root .. "/_rules/DEP/DEP-01.md")
    assert.is_false(one(opts, { op = "move", id = "DEP-01", after = "DEP-01" }).ok)
    assert.is_true(one(opts, { op = "move", id = "DEP-01", section = "Extra", layout = "regeln/DEP.md" }).ok)
    assert.are.equal(before, read_raw(root .. "/_rules/DEP/DEP-01.md"))
  end)

  it("reports unchanged when a move puts the rule where it already is, on a real run and a dry run", function()
    local root, opts = fixture()
    local layout = root .. "/_layouts/regeln/DEP.md"
    local doc_before = read_raw(root .. "/regeln/DEP.md")
    for _, place in ipairs({ { after = "DEP-01" }, { section = "Core", layout = "regeln/DEP.md" } }) do
      local op = vim.tbl_extend("force", { op = "move", id = place.after and "DEP-02" or "DEP-01" }, place)
      op.first = place.section and true or nil
      for _, extra in ipairs({ {}, { dry_run = true } }) do
        local entry = one(opts, op, extra)
        assert.is_true(entry.ok, vim.inspect(entry))
        assert.are.equal("unchanged", entry.outcome, vim.inspect(op))
        assert.are.same({}, entry.changed_ids)
        assert.is_nil(entry.inverse)
        assert.is_nil(entry.catalog)
        assert.are.equal(LAYOUT_DEP, read_raw(layout))
        assert.are.equal(doc_before, read_raw(root .. "/regeln/DEP.md"))
      end
    end
    -- a real change still moves, and a dry run of it says so without writing
    local dry = one(opts, { op = "move", id = "DEP-01", after = "DEP-02" }, { dry_run = true })
    assert.are.equal("would_move", dry.outcome)
    assert.are.equal(LAYOUT_DEP, read_raw(layout))
  end)

  it("reinstates a retired rule into a place, and a dry run says what the real run does", function()
    local root, opts = fixture()
    local original = read_raw(root .. "/_rules/DEP/DEP-02.md")
    assert.is_true(one(opts, { op = "retire", id = "DEP-02" }).ok)
    local retired_file = root .. "/_retired/DEP/DEP-02.md"
    local retired = read_raw(retired_file)
    local layout_after_retire = read_raw(root .. "/_layouts/regeln/DEP.md")

    local op = { op = "reinstate", id = "DEP-02", after = "DEP-03" }
    local dry = one(opts, op, { dry_run = true })
    assert.is_true(dry.ok, vim.inspect(dry))
    assert.are.equal("would_reinstate", dry.outcome)
    assert.are.equal("regeln/DEP.md", dry.placed.layout)
    assert.are.equal(retired, read_raw(retired_file))
    assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-02.md"))
    assert.are.equal(layout_after_retire, read_raw(root .. "/_layouts/regeln/DEP.md"))

    local real = one(opts, op)
    assert.is_true(real.ok, vim.inspect(real))
    assert.are.equal("reinstated", real.outcome)
    assert.are.same(dry.placed, real.placed)
    assert.are.same({ "DEP-02" }, real.changed_ids)
    assert.are.equal(original, read_raw(root .. "/_rules/DEP/DEP-02.md"))
    assert.is_nil(read_raw(retired_file))
    assert.is_true(vim.tbl_contains(ids_of(opts), "DEP-02"))
    local layout = read_raw(root .. "/_layouts/regeln/DEP.md")
    assert.is_true(layout:find("DEP-03", 1, true) < layout:find("DEP-02", 1, true))
    -- the inverse retires it again
    assert.is_true(one(opts, real.inverse).ok)
    assert.is_false(vim.tbl_contains(ids_of(opts), "DEP-02"))
  end)

  it("refuses a reinstate whose place does not exist the same way on a dry run and a real run, and writes nothing", function()
    local root, opts = fixture()
    assert.is_true(one(opts, { op = "retire", id = "DEP-02" }).ok)
    local retired_file = root .. "/_retired/DEP/DEP-02.md"
    local retired = read_raw(retired_file)
    local layout = read_raw(root .. "/_layouts/regeln/DEP.md")
    for _, op in ipairs({
      { op = "reinstate", id = "DEP-02", after = "GHOST-01" },
      { op = "reinstate", id = "DEP-02", section = "Core", layout = "regeln/NOPE.md" },
    }) do
      local dry = one(opts, op, { dry_run = true })
      local real = one(opts, op)
      assert.is_false(dry.ok, vim.inspect(op))
      assert.is_false(real.ok, vim.inspect(op))
      assert.are.equal("invalid_argument", dry.error.code, vim.inspect(dry))
      assert.are.equal(dry.error.code, real.error.code, vim.inspect(real))
      assert.are.equal(retired, read_raw(retired_file))
      assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-02.md"))
      assert.are.equal(layout, read_raw(root .. "/_layouts/regeln/DEP.md"))
    end
  end)
end)

describe("rules-ops/1 the whole request", function()
  it("refuses a malformed request as a whole, before anything runs", function()
    local root, opts = fixture()
    local ops = require("rules.ops")
    local doc, err =
      ops.run({ ops = { { op = "set", id = "DEP-01", patch = { severity = "critical" } }, { op = "frobnicate" } } }, opts)
    assert.is_nil(doc)
    assert.are.equal("invalid_argument", err.code)
    assert.is_truthy(read_raw(root .. "/_rules/DEP/DEP-01.md"):find("severity: recommended", 1, true))
  end)

  it("runs every operation on its own and says ok only when all were", function()
    local _, opts = fixture()
    local doc = run(opts, {
      { op = "set", id = "DEP-01", patch = { severity = "critical" } },
      { op = "set", id = "NOPE-01", patch = { severity = "critical" } },
      { op = "set", id = "DEP-02", patch = { severity = "recommended" } },
    })
    assert.is_false(doc.ok)
    assert.is_true(doc.results[1].ok)
    assert.is_false(doc.results[2].ok)
    assert.is_true(doc.results[3].ok)
    assert.are.same({ 1, 2, 3 }, { doc.results[1].n, doc.results[2].n, doc.results[3].n })
  end)

  it("answers through the api door, flat, and keeps the root out of every entry", function()
    local root, opts = fixture()
    local api = require("rules.api")
    local text, code = api.call(
      "ops",
      vim.json.encode({ client_op_id = "c-1", ops = { { op = "set", id = "NOPE-01", patch = { severity = "critical" } } } }),
      opts
    )
    assert.is_nil(code)
    local doc = vim.json.decode(text)
    assert.are.equal("rules.result", doc.kind)
    assert.are.equal("c-1", doc.client_op_id)
    assert.is_nil(text:lower():find(vim.fs.normalize(root):lower(), 1, true))
  end)

  it("hello lists the operations and says it is not read only", function()
    local doc = contract.hello({ rulesets = {} })
    assert.is_false(doc.read_only)
    assert.are.same({ "new", "set", "retire", "reinstate", "move" }, doc.ops)
    assert.is_true(vim.tbl_contains(doc.capabilities, "ops"))
  end)
end)

describe("rules-ops/1 a step back", function()
  local real_atomic = require("lib.nvim.fs.write.atomic")
  local failing

  ---Load `rules.ops` again with a write that fails where `fail(path, nth)` says so.
  ---@param fail fun(path: string, nth: integer): boolean
  ---@return table ops
  local function ops_with_failing_write(fail)
    local count = {}
    package.loaded["lib.nvim.fs.write.atomic"] = function(path, content, opts)
      count[path] = (count[path] or 0) + 1
      if fail(path, count[path]) then
        return false, "injected failure"
      end
      return real_atomic(path, content, opts)
    end
    package.loaded["rules.ops"] = nil
    failing = require("rules.ops")
    return failing
  end

  after_each(function()
    package.loaded["lib.nvim.fs.write.atomic"] = real_atomic
    package.loaded["rules.ops"] = nil
    require("rules.ops")
  end)

  it("puts the files back when a later step of retire fails", function()
    local root, opts = fixture()
    -- the rule is in two layouts: the second one cannot be written
    write_raw(root .. "/_layouts/regeln/EXTRA.md", "---\nkind: layout\noutput: regeln/EXTRA.md\n---\n{{rule DEP-02}}\n")
    local ops = ops_with_failing_write(function(path)
      return path:find("EXTRA.md", 1, true) ~= nil
    end)
    local before = read_raw(root .. "/_rules/DEP/DEP-02.md")
    local doc = assert(ops.run({ ops = { { op = "retire", id = "DEP-02" } } }, opts))
    local entry = doc.results[1]
    assert.is_false(entry.ok)
    assert.are.equal("io", entry.error.code)
    assert.are.equal(before, read_raw(root .. "/_rules/DEP/DEP-02.md"))
    assert.is_nil(read_raw(root .. "/_retired/DEP/DEP-02.md"))
    assert.are.equal(LAYOUT_DEP, read_raw(root .. "/_layouts/regeln/DEP.md"))
  end)

  it("names what it could not put back", function()
    local root, opts = fixture()
    write_raw(root .. "/_layouts/regeln/EXTRA.md", "---\nkind: layout\noutput: regeln/EXTRA.md\n---\n{{rule DEP-02}}\n")
    local ops = ops_with_failing_write(function(path, nth)
      -- EXTRA fails; DEP is written once, then its restore fails too
      if path:find("EXTRA.md", 1, true) then
        return true
      end
      return path:find("regeln/DEP.md", 1, true) ~= nil and nth >= 2
    end)
    local doc = assert(ops.run({ ops = { { op = "retire", id = "DEP-02" } } }, opts))
    local entry = doc.results[1]
    assert.is_false(entry.ok)
    assert.are.equal("rollback_incomplete", entry.error.code)
    assert.is_truthy(entry.error.message:find("DEP.md", 1, true))
    assert.are.equal(1, #entry.error.details.not_restored)
  end)
end)
