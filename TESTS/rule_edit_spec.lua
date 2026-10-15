-- TESTS/rule_edit_spec.lua -- the text of a rule file (`rules.engine.rule_edit`): a divider line at the end of a text, CR LF
-- text, a text taken away, and blocks whose fields are not written one per line in the usual way.
---@diagnostic disable: need-check-nil
local rule_edit = require("rules.engine.rule_edit")
local parser = require("rules.engine.parser")
local ops = require("rules.ops")

---@param lines string[]
---@return string
local function doc(lines)
  return table.concat(lines, "\n") .. "\n"
end

---Whether a divider line stands directly under a line of text anywhere below the heading (it would make that line a
---heading, or glue to it).
---@param text string
---@return integer|nil line
local function glued_divider(text)
  local lines = vim.split(text, "\n", { plain = true })
  for i = 7, #lines do
    if
      parser.is_framing(lines[i])
      and lines[i]:match("%S")
      and lines[i - 1]:match("%S")
      and not parser.is_framing(lines[i - 1])
    then
      return i
    end
  end
  return nil
end

local SPEC = { id = "DEP-01", severity = "critical", title = "one" }

describe("rule_edit: a divider at the end of a text (G4-6)", function()
  local TEXTS = {
    ["---"] = "foo\n---",
    ["----"] = "foo\n----",
    ["***"] = "foo\n***",
    ["___"] = "foo\n___",
    ["under a table row"] = "| a | b |\n---",
    ["under a list item"] = "- a\n- b\n---",
    ["with blank lines behind"] = "foo\n---\n\n",
  }

  for name, text in pairs(TEXTS) do
    it("puts a blank line in front of a trailing divider (" .. name .. ") when a rule is made", function()
      local made = assert(rule_edit.render_new(vim.tbl_extend("force", SPEC, { text = text })))
      assert.is_nil(glued_divider(made), made)
      -- the text reads back as it was given, without the divider
      local rule = parser.parse_rule_text("DEP-01.md", made)
      assert.are.equal(parser.prose(vim.split(text, "\n", { plain = true })), rule.text)
    end)

    it("puts a blank line in front of a trailing divider (" .. name .. ") when a text is set", function()
      local base = assert(rule_edit.render_new(vim.tbl_extend("force", SPEC, { text = "Old." })))
      local changed = assert(rule_edit.apply("DEP-01.md", base, { text = text }))
      assert.is_nil(glued_divider(changed), changed)
      assert.are.equal(parser.prose(vim.split(text, "\n", { plain = true })), parser.parse_rule_text("DEP-01.md", changed).text)
    end)
  end

  it("leaves a text that has its blank line already, and a text without a divider, as it is", function()
    local text = "foo\n\n---"
    local made = assert(rule_edit.render_new(vim.tbl_extend("force", SPEC, { text = text })))
    assert.is_truthy(made:find("\nfoo\n\n---\n\n$"))
    assert.is_nil(made:find("---\n\n---", 1, true))
    local plain = assert(rule_edit.render_new(vim.tbl_extend("force", SPEC, { text = "foo\nbar" })))
    assert.is_truthy(plain:find("\nfoo\nbar\n\n---\n\n$"))
  end)
end)

describe("rule_edit: CR LF text and a text taken away (G4-7)", function()
  it("never writes a CR into a file that ends its lines with LF", function()
    local made = assert(rule_edit.render_new(vim.tbl_extend("force", SPEC, { text = "one\r\ntwo\r\n\r\nthree" })))
    assert.is_nil(made:find("\r", 1, true))
    assert.are.equal("one\ntwo\n\nthree", parser.parse_rule_text("DEP-01.md", made).text)
    local changed = assert(rule_edit.apply("DEP-01.md", made, { text = "a\r\nb" }))
    assert.is_nil(changed:find("\r", 1, true))
    -- and the file can be set again: it does not mix line endings
    local again = assert(rule_edit.apply("DEP-01.md", changed, { severity = "recommended" }))
    assert.is_truthy(again:find("severity: recommended", 1, true))
  end)

  it("writes CR LF into a file that ends its lines with CR LF, all of them", function()
    local made = assert(rule_edit.render_new(vim.tbl_extend("force", SPEC, { text = "Old." })))
    local crlf = (made:gsub("\n", "\r\n"))
    local changed = assert(rule_edit.apply("DEP-01.md", crlf, { text = "a\r\nb\nc" }))
    assert.is_nil(changed:find("[^\r]\n"))
    assert.is_nil(changed:find("\r\r", 1, true))
    assert.is_truthy(changed:find("a\r\nb\r\nc\r\n", 1, true))
    assert.is_truthy(assert(rule_edit.apply("DEP-01.md", changed, { severity = "recommended" })))
  end)

  it("is taken at the door of the operations too: CR LF is a line end, a lone CR is still refused", function()
    local base = vim.fn.tempname()
    local root = base .. "/fixture/Checklists"
    vim.fn.mkdir(root .. "/_rules/DEP", "p")
    vim.fn.mkdir(root .. "/_layouts/regeln", "p")
    local made = assert(rule_edit.render_new(vim.tbl_extend("force", SPEC, { text = "Old." })))
    local fh = assert(io.open(root .. "/_rules/DEP/DEP-01.md", "wb"))
    fh:write(made)
    fh:close()
    local opts = { rulesets = { root }, today = "2026-10-15" }
    local function run(op)
      return assert(ops.run({ ops = { op } }, opts)).results[1]
    end
    local new = run({ op = "new", family = "DEP", title = "two", severity = "critical", text = "a\r\nb" })
    assert.is_true(new.ok, vim.inspect(new))
    local file = assert(io.open(root .. "/_rules/DEP/" .. new.id .. ".md", "rb"))
    local bytes = file:read("*a")
    file:close()
    assert.is_nil(bytes:find("\r", 1, true))
    local set = run({ op = "set", id = "DEP-01", patch = { text = "x\r\ny" } })
    assert.is_true(set.ok, vim.inspect(set))
    local set_file = assert(io.open(root .. "/_rules/DEP/DEP-01.md", "rb"))
    local set_bytes = set_file:read("*a")
    set_file:close()
    assert.is_nil(set_bytes:find("\r", 1, true))
    assert.are.equal("x\ny", parser.parse_rule_text("DEP-01.md", set_bytes).text)
    local lone = run({ op = "set", id = "DEP-01", patch = { text = "x\ry" } })
    assert.is_false(lone.ok)
    assert.are.equal("invalid_argument", lone.error.code)
  end)

  it("leaves one blank line in front of the divider when the text is set to nothing, as a rule made without text has", function()
    local with = assert(rule_edit.render_new(vim.tbl_extend("force", SPEC, { text = "Some words." })))
    local without = assert(rule_edit.render_new(SPEC))
    assert.are.equal(without, (assert(rule_edit.apply("DEP-01.md", with, { text = "" }))))
    -- also with a block in front of the text
    local block_with = assert(rule_edit.render_new(vim.tbl_extend("force", SPEC, { text = "Words.", check = { type = "grep" } })))
    local block_without = assert(rule_edit.render_new(vim.tbl_extend("force", SPEC, { check = { type = "grep" } })))
    assert.are.equal(block_without, (assert(rule_edit.apply("DEP-01.md", block_with, { text = "" }))))
  end)
end)

describe("rule_edit: a block that is not written one field to a line (G5-3)", function()
  ---@param block string[]
  ---@return string
  local function rule_with(block)
    local lines = { "---", "id: DEP-01", "severity: critical", "family: DEP", "---", "", "#### `DEP-01` — one", "", "```rule" }
    vim.list_extend(lines, block)
    vim.list_extend(lines, { "```", "", "Text.", "", "---", "" })
    return doc(lines)
  end

  local COMMA_FIRST = {
    'check = { type = "grep", pattern = "x" }',
    ', agent = { question = "why" }',
  }
  local COMMA_FIRST_THREE = {
    'severity = "critical"',
    ', check = { type = "grep", pattern = "x" }',
    ', agent = { question = "why" }',
  }

  for name, block in pairs({ two = COMMA_FIRST, three = COMMA_FIRST_THREE }) do
    it("sets agent and check in a comma-first block (" .. name .. " fields)", function()
      local text = rule_with(block)
      local agent = assert(rule_edit.apply("DEP-01.md", text, { agent = { question = "NEW" } }))
      local rule = parser.parse_rule_text("DEP-01.md", agent)
      assert.are.same({ question = "NEW" }, rule.agent)
      assert.are.same({ type = "grep", pattern = "x" }, rule.check)
      local check = assert(rule_edit.apply("DEP-01.md", text, { check = { type = "grep", pattern = "NEW" } }))
      rule = parser.parse_rule_text("DEP-01.md", check)
      assert.are.same({ type = "grep", pattern = "NEW" }, rule.check)
      assert.are.same({ question = "why" }, rule.agent)
      local removed = assert(rule_edit.apply("DEP-01.md", text, { agent = vim.NIL }))
      rule = parser.parse_rule_text("DEP-01.md", removed)
      assert.is_nil(rule.agent)
      assert.are.same({ type = "grep", pattern = "x" }, rule.check)
      -- everything outside the block is as it was
      assert.are.equal(text:match("^(.-)```rule"), agent:match("^(.-)```rule"))
      assert.are.equal(text:match("```\n(.*)$"), agent:match("```\n(.*)$"))
    end)
  end

  it("still edits a block with a field to a line line by line (the other field stays byte for byte)", function()
    local block = { 'check = { type = "grep",   pattern = "x" },', 'agent = { question = "why" },' }
    local text = rule_with(block)
    local changed = assert(rule_edit.apply("DEP-01.md", text, { agent = { question = "NEW" } }))
    assert.is_truthy(changed:find('check = { type = "grep",   pattern = "x" },\n', 1, true))
    assert.is_truthy(changed:find('agent = { question = "NEW" },\n', 1, true))
  end)

  it("edits the last of two check fields, the one that counts, and writes the block again to remove the key", function()
    local block = {
      'check = { type = "grep", pattern = "first" },',
      'severity = "critical",',
      'check = { type = "grep", pattern = "last" },',
    }
    local text = rule_with(block)
    local changed = assert(rule_edit.apply("DEP-01.md", text, { check = { type = "grep", pattern = "NEW" } }))
    assert.are.same({ type = "grep", pattern = "NEW" }, parser.parse_rule_text("DEP-01.md", changed).check)
    assert.is_truthy(changed:find('check = { type = "grep", pattern = "first" },\n', 1, true))
    local removed = assert(rule_edit.apply("DEP-01.md", text, { check = vim.NIL }))
    assert.is_nil(parser.parse_rule_text("DEP-01.md", removed).check)
    assert.is_nil(removed:find("first", 1, true))
  end)
end)
