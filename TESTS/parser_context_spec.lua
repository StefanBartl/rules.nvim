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

describe("rules.engine.parser text, title and section", function()
  it("keeps the prose under a block as `text`, up to the next heading", function()
    local path = write_tmp({
      "#### `DEP-01` — example",
      "",
      "```rule",
      'id = "DEP-01",',
      'severity = "recommended",',
      "```",
      "",
      "First paragraph.",
      "",
      "Second paragraph.",
      "",
      "#### `DEP-02` — next",
    })

    local rules = parser.extract_rules(path)

    assert.are.equal("First paragraph.\n\nSecond paragraph.", rules[1].text)
  end)

  it("ends `text` at the next rule block when two blocks share one heading", function()
    local path = write_tmp({
      "## Both",
      "```rule",
      'id = "DEP-01",',
      'severity = "recommended",',
      "```",
      "about the first",
      "```rule",
      'id = "DEP-02",',
      'severity = "recommended",',
      "```",
      "about the second",
    })

    local rules = parser.extract_rules(path)

    assert.are.equal("about the first", rules[1].text)
    assert.are.equal("about the second", rules[2].text)
  end)

  it("gives a rule with nothing under it an empty string, not nil", function()
    local path = write_tmp({ "```rule", 'id = "DEP-01",', 'severity = "recommended",', "```", "#### next" })

    local rules = parser.extract_rules(path)

    assert.are.equal("", rules[1].text)
  end)

  it("drops the blank lines and thematic breaks that only frame the prose", function()
    local path = write_tmp({
      "```rule",
      'id = "DEP-01",',
      'severity = "recommended",',
      "```",
      "",
      "Body.",
      "",
      "---",
      "",
      "## Next section",
    })

    local rules = parser.extract_rules(path)

    assert.are.equal("Body.", rules[1].text)
  end)

  it("treats the heading that names the rule as `title` and the one above it as `section`", function()
    local path = write_tmp({
      "# Whole file",
      "## 1. Documentation",
      "#### `REL-01` — README present",
      "```rule",
      'id = "REL-01",',
      'severity = "critical",',
      "```",
      "#### `REL-02` — second",
      "```rule",
      'id = "REL-02",',
      'severity = "critical",',
      "```",
      "## 2. Packaging",
      "#### `REL-03` — third",
      "```rule",
      'id = "REL-03",',
      'severity = "critical",',
      "```",
    })

    local rules = parser.extract_rules(path)

    assert.are.equal("`REL-01` — README present", rules[1].title)
    assert.are.equal("1. Documentation", rules[1].section)
    assert.are.equal("1. Documentation", rules[2].section)
    assert.are.equal("2. Packaging", rules[3].section)
  end)

  it("uses the nearest heading as `section` when it does not name the rule", function()
    local path = write_tmp({ "# File", "## Group", "```rule", 'id = "DEP-01",', 'severity = "recommended",', "```" })

    local rules = parser.extract_rules(path)

    assert.is_nil(rules[1].title)
    assert.are.equal("Group", rules[1].section)
  end)

  it("leaves `title` and `section` nil for a block with no heading above it", function()
    local path = write_tmp({ "```rule", 'id = "DEP-01",', 'severity = "recommended",', "```" })

    local rules = parser.extract_rules(path)

    assert.is_nil(rules[1].title)
    assert.is_nil(rules[1].section)
  end)

  it("does not read a `# comment` inside another fenced block as a heading", function()
    local path = write_tmp({
      "## Real section",
      "#### `DEP-01` — example",
      "```bash",
      "# this is a shell comment",
      "echo hi",
      "```",
      "```rule",
      'id = "DEP-01",',
      'severity = "recommended",',
      "```",
      "Run it like this:",
      "```bash",
      "# another shell comment",
      "make",
      "```",
      "After.",
    })

    local rules = parser.extract_rules(path)

    assert.are.equal("Real section", rules[1].section)
    assert.is_truthy(rules[1].text:find("# another shell comment", 1, true))
    assert.matches("After%.", rules[1].text)
  end)

  it("keeps reading headings after a ```rule example shown inside a longer fence", function()
    local path = write_tmp({
      "## Format",
      "````markdown",
      "### `DEP-06` — example",
      "```rule",
      'id = "DEP-06",',
      'severity = "recommended",',
      "```",
      "````",
      "## After the example",
      "```rule",
      'id = "DEP-07",',
      'severity = "recommended",',
      "```",
    })

    local rules = parser.extract_rules(path)

    assert.are.equal(2, #rules)
    assert.are.equal("After the example", rules[2].section)
  end)

  it("lets the parser own `text`, `title` and `section` over a field of the same name in the block", function()
    local path = write_tmp({
      "## Real",
      "```rule",
      'id = "DEP-01",',
      'severity = "recommended",',
      'section = "from the block",',
      'text = "from the block",',
      "```",
      "from the prose",
    })

    local rules = parser.extract_rules(path)

    assert.are.equal("Real", rules[1].section)
    assert.are.equal("from the prose", rules[1].text)
  end)
end)

describe("rules.engine.parser agent field", function()
  ---@param agent_src string  the right-hand side of `agent = ...`
  ---@return Rules.ParsedRule[] rules
  ---@return string[] errors
  local function parse_with_agent(agent_src)
    return parser.extract_rules(write_tmp({
      "```rule",
      'id = "DEP-01",',
      'severity = "recommended",',
      "agent = " .. agent_src .. ",",
      "```",
    }))
  end

  it("keeps a valid agent field", function()
    local rules, errors = parse_with_agent('{ question = "Any god object?", include = { "lua/**/*.lua" }, max_files = 20 }')

    assert.are.equal(0, #errors)
    assert.are.same({ question = "Any god object?", include = { "lua/**/*.lua" }, max_files = 20 }, rules[1].agent)
  end)

  it("accepts a rule with no agent field, leaving it nil", function()
    local rules, errors = parser.extract_rules(write_tmp({ "```rule", 'id = "DEP-01",', 'severity = "recommended",', "```" }))

    assert.are.equal(0, #errors)
    assert.is_nil(rules[1].agent)
  end)

  it("keeps the rule but drops and reports an invalid agent field", function()
    local bad = {
      '"just a string"',
      '{ qustion = "typo" }',
      '{ question = "" }',
      '{ include = "lua/**" }',
      "{ include = {} }",
      "{ include = { 5 } }",
      "{ max_files = 0 }",
      "{ max_files = 1.5 }",
      '{ max_files = "3" }',
    }
    for _, src in ipairs(bad) do
      local rules, errors = parse_with_agent(src)

      assert.are.equal(1, #rules, src .. ": the rule must survive an optional hint gone wrong")
      assert.is_nil(rules[1].agent, src)
      assert.are.equal(1, #errors, src)
      assert.matches("invalid `agent` field", errors[1])
    end
  end)
end)

describe("rules.engine.parser sandbox", function()
  it("fails a block whose body calls into the host, instead of running it", function()
    local path = write_tmp({
      "```rule",
      'id = os.getenv("HOME"),',
      'severity = "recommended",',
      "```",
    })

    local rules, errors = parser.extract_rules(path)

    assert.are.equal(0, #rules)
    assert.are.equal(1, #errors)
    assert.matches("global 'os'", errors[1])
  end)

  it("cannot reach `vim`, `io` or `require` from a block body", function()
    for _, call in ipairs({ "vim.fn.getcwd()", 'io.open("x")', 'require("rules")' }) do
      local rules, errors = parser.extract_rules(write_tmp({
        "```rule",
        'id = "DEP-01",',
        'severity = "recommended",',
        "marker = " .. call .. ",",
        "```",
      }))

      assert.are.equal(0, #rules, call)
      assert.are.equal(1, #errors, call)
    end
  end)

  -- The guard for the budget: without it this does not fail, it hangs. A bare
  -- count hook never fires inside a JIT-compiled loop.
  it("aborts a runaway loop in a block body and reports it", function()
    local path = write_tmp({
      "```rule",
      "id = (function() while true do end end)(),",
      'severity = "recommended",',
      "```",
    })

    local rules, errors = parser.extract_rules(path)

    assert.are.equal(0, #rules)
    assert.are.equal(1, #errors)
    assert.matches("instruction budget exceeded", errors[1])
  end)

  it("still parses the blocks after a hostile one in the same file", function()
    local path = write_tmp({
      "```rule",
      'id = os.getenv("HOME"),',
      'severity = "recommended",',
      "```",
      "```rule",
      'id = "DEP-02",',
      'severity = "recommended",',
      "```",
    })

    local rules, errors = parser.extract_rules(path)

    assert.are.equal(1, #errors)
    assert.are.equal(1, #rules)
    assert.are.equal("DEP-02", rules[1].id)
  end)
end)

describe("rules.engine.parser bounds on a block's own text", function()
  --- A one-rule file whose block carries `extra` as additional fields.
  ---@param extra string[]
  ---@return string
  local function file_with(extra)
    local lines = { "```rule", 'id = "BND-01",', 'severity = "recommended",' }
    vim.list_extend(lines, extra)
    vim.list_extend(lines, { "```" })
    return write_tmp(lines)
  end

  it("rejects an id with a control character, so a report line cannot be split", function()
    -- the backslash-n lives inside the block's Lua string, so it is built here;
    -- written as an escape it would become a real line break of the file
    local backslash = string.char(92)
    local path = write_tmp({ "```rule", 'id = "BND' .. backslash .. 'n01",', 'severity = "recommended",', "```" })

    local rules, errors = parser.extract_rules(path)

    assert.are.equal(0, #rules)
    assert.matches("control characters", errors[1])
  end)

  it("rejects an id that is longer than a rule id has any reason to be", function()
    local path = write_tmp({ "```rule", 'id = "' .. string.rep("A", 101) .. '",', 'severity = "recommended",', "```" })

    local rules, errors = parser.extract_rules(path)

    assert.are.equal(0, #rules)
    assert.matches("at most 100 bytes", errors[1])
  end)

  it("drops an oversized agent question but keeps the rule", function()
    local path = file_with({ 'agent = { question = "' .. string.rep("q", 4001) .. '" },' })

    local rules, errors = parser.extract_rules(path)

    assert.are.equal(1, #rules)
    assert.is_nil(rules[1].agent)
    assert.matches("longer than 4000 bytes", errors[1])
  end)

  it("drops an agent whose include list is unreasonably long", function()
    local globs = {}
    for i = 1, 51 do
      globs[i] = '"lua/' .. i .. '/**/*.lua"'
    end
    local path = file_with({ "agent = { include = { " .. table.concat(globs, ", ") .. " } }," })

    local rules, errors = parser.extract_rules(path)

    assert.are.equal(1, #rules)
    assert.is_nil(rules[1].agent)
    assert.matches("more than 50 entries", errors[1])
  end)

  it("still accepts an ordinary agent block", function()
    local path = file_with({ 'agent = { question = "Is it?", include = { "lua/**/*.lua" }, max_files = 3 },' })

    local rules, errors = parser.extract_rules(path)

    assert.are.equal(0, #errors)
    assert.are.equal("Is it?", rules[1].agent.question)
  end)
end)
