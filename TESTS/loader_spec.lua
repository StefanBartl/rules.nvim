local loader = require("rules.engine.loader")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

---@param dir string
---@param name string
---@param lines string[]
local function write_file(dir, name, lines)
  vim.fn.writefile(lines, dir .. "/" .. name)
end

describe("rules.engine.loader", function()
  it("merges rules from every .md file under a directory", function()
    local dir = tmp_dir()
    write_file(dir, "a.md", { "```rule", 'id = "DEP-01",', 'severity = "recommended",', "```" })
    write_file(dir, "b.md", { "```rule", 'id = "DEP-02",', 'severity = "recommended",', "```" })

    local rules, errors = loader.load({ dir })

    assert.are.equal(0, #errors)
    assert.are.equal(2, #rules)
  end)

  it("accepts a single .md file as a ruleset path", function()
    local dir = tmp_dir()
    write_file(dir, "only.md", { "```rule", 'id = "DEP-01",', 'severity = "recommended",', "```" })

    local rules, errors = loader.load({ dir .. "/only.md" })

    assert.are.equal(0, #errors)
    assert.are.equal(1, #rules)
  end)

  it("records a duplicate id across two files as an error and keeps the first", function()
    local dir = tmp_dir()
    write_file(dir, "a.md", { "```rule", 'id = "DEP-01",', 'severity = "recommended",', "```" })
    write_file(dir, "b.md", { "```rule", 'id = "DEP-01",', 'severity = "critical",', "```" })

    local rules, errors = loader.load({ dir })

    assert.are.equal(1, #rules)
    assert.are.equal("recommended", rules[1].severity)
    assert.are.equal(1, #errors)
    assert.matches("duplicate rule id DEP%-01", errors[1])
  end)

  it("does not double-count a file reachable through two overlapping ruleset paths", function()
    local dir = tmp_dir()
    write_file(dir, "a.md", { "```rule", 'id = "DEP-01",', 'severity = "recommended",', "```" })

    -- The directory and an explicit path to a file already inside it --
    -- a plausible config mistake, not two genuinely different rulesets.
    local rules, errors = loader.load({ dir, dir .. "/a.md" })

    assert.are.equal(1, #rules)
    assert.are.equal(0, #errors)
  end)

  it("returns nothing without erroring for a directory that genuinely has zero .md files", function()
    local dir = tmp_dir()

    local rules, errors = loader.load({ dir })

    assert.are.equal(0, #rules)
    assert.are.equal(0, #errors)
  end)

  it("ERR-11: records an error for a path that resolves to neither a directory nor a readable .md file", function()
    -- "empty, nothing to report" and "empty, because the path never
    -- resolved at all" used to look identical -- a typo'd or `~`-prefixed
    -- path silently loaded zero rules with no signal anywhere.
    local rules, errors = loader.load({ "/definitely/does/not/exist" })

    assert.are.equal(0, #rules)
    assert.are.equal(1, #errors)
    assert.matches("does/not/exist", errors[1])
  end)

  it("finds .md files under a directory whose name contains glob-special characters", function()
    -- XP-01: `vim.fn.globpath` interprets `~`/`[`/`?`/`*`/`{}` in its PATH
    -- argument too, not just the pattern -- a ruleset directory containing
    -- one of these would silently glob-match nothing under the old
    -- globpath-based implementation, despite genuinely existing and
    -- containing rules.
    local parent = tmp_dir()
    local dir = parent .. "/rules[v1]"
    vim.fn.mkdir(dir, "p")
    write_file(dir, "a.md", { "```rule", 'id = "DEP-01",', 'severity = "recommended",', "```" })

    local rules, errors = loader.load({ dir })

    assert.are.equal(0, #errors)
    assert.are.equal(1, #rules)
  end)

  it("ERR-11: expands a $VAR-style ruleset path instead of treating it as literal and unresolvable", function()
    -- README.md/docs/BINDINGS.md's own quickstart example is a `~`-prefixed
    -- path; `vim.fn.isdirectory("~/x")` does NOT expand `~` on its own, so
    -- that documented example silently loaded zero rules before this.
    -- `$VAR` is used here instead of `~` to stay hermetic (no dependency on
    -- the test machine's actual home directory).
    local dir = tmp_dir()
    write_file(dir, "a.md", { "```rule", 'id = "DEP-01",', 'severity = "recommended",', "```" })
    vim.env.RULES_NVIM_TEST_RULESET_DIR = dir

    local rules, errors = loader.load({ "$RULES_NVIM_TEST_RULESET_DIR" })
    vim.env.RULES_NVIM_TEST_RULESET_DIR = nil

    assert.are.equal(0, #errors)
    assert.are.equal(1, #rules)
  end)
end)

---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param id string
---@return string
local function rule_file_text(id)
  return ("---\nid: %s\nseverity: critical\nfamily: %s\n---\n\n#### `%s`\n\nText.\n"):format(id, id:match("^(%a+)"), id)
end

---A retired rule file: the original with the facts of its retirement added after the lines of the frontmatter.
---@param id string
---@return string
local function retired_file_text(id)
  local head = "---\nid: %s\nseverity: critical\nfamily: %s\nstatus: retired\nretired: 2026-01-01\n---\n"
  return (head .. "\n#### `%s`\n\nText.\n"):format(id, id:match("^(%a+)"), id)
end

---@return string
local function new_ruleset()
  return (vim.fn.tempname():gsub("\\", "/")) .. "/ruleset"
end

describe("rules.engine.loader: the retired rules keep their ids", function()
  it("a live rule and a retired one with the same id are a duplicate, and the retired one is not loaded", function()
    -- the two machines: A made AAA-05 and retired it, B (no pull in between) made it again; git merges without a conflict
    local root = new_ruleset()
    write_raw(root .. "/_rules/AAA/AAA-05.md", rule_file_text("AAA-05"))
    write_raw(root .. "/_retired/AAA/AAA-05.md", retired_file_text("AAA-05"))

    local rules, errors = loader.load({ root })

    assert.are.equal(1, #rules)
    assert.are.equal(root .. "/_rules/AAA/AAA-05.md", rules[1].source_file)
    assert.are.equal(1, #errors, vim.inspect(errors))
    assert.matches("duplicate rule id AAA-05: ", errors[1], 1, true)
    assert.matches("_rules/AAA/AAA-05.md", errors[1], 1, true)
    assert.matches("_retired/AAA/AAA-05.md", errors[1], 1, true)
  end)

  it("also across two rulesets", function()
    local live, retired = new_ruleset(), new_ruleset()
    write_raw(live .. "/_rules/AAA/AAA-05.md", rule_file_text("AAA-05"))
    write_raw(retired .. "/_retired/AAA/AAA-05.md", retired_file_text("AAA-05"))

    assert.are.equal(0, #select(2, loader.load({ live })))
    assert.are.equal(0, #select(2, loader.load({ retired })))
    local _, errors = loader.load({ live, retired })
    assert.are.equal(1, #errors, vim.inspect(errors))
    assert.matches("duplicate rule id AAA-05", errors[1], 1, true)
  end)

  it("a retired rule alone, or beside other ids, is no error", function()
    local root = new_ruleset()
    write_raw(root .. "/_rules/AAA/AAA-06.md", rule_file_text("AAA-06"))
    write_raw(root .. "/_retired/AAA/AAA-05.md", retired_file_text("AAA-05"))
    local rules, errors = loader.load({ root })
    assert.are.equal(1, #rules)
    assert.are.same({}, errors)
  end)

  it("one id retired twice is a duplicate as well", function()
    local root = new_ruleset()
    write_raw(root .. "/_retired/AAA/AAA-05.md", retired_file_text("AAA-05"))
    write_raw(root .. "/_retired/OLD/AAA-05.md", retired_file_text("AAA-05"))
    local _, errors = loader.load({ root })
    assert.are.equal(1, #errors, vim.inspect(errors))
    assert.matches("duplicate rule id AAA-05", errors[1], 1, true)
  end)

  it("a retired file named for one id that says another is told, and takes both ids", function()
    local root = new_ruleset()
    write_raw(root .. "/_rules/AAA/AAA-07.md", rule_file_text("AAA-07"))
    write_raw(root .. "/_retired/AAA/AAA-05.md", retired_file_text("AAA-07"))
    local _, errors = loader.load({ root })
    local text = table.concat(errors, "\n")
    assert.matches("named for AAA-05 but its frontmatter says `id: AAA-07`", text, 1, true)
    assert.matches("duplicate rule id AAA-07", text, 1, true)
  end)

  it("a retired file that does not read is a problem: no frontmatter, empty, conflict marker", function()
    local root = new_ruleset()
    write_raw(root .. "/_retired/AAA/AAA-01.md", "# just a note\n")
    write_raw(root .. "/_retired/AAA/AAA-02.md", "")
    write_raw(root .. "/_retired/AAA/AAA-03.md", "<<<<<<< HEAD\n" .. retired_file_text("AAA-03") .. "=======\n>>>>>>> other\n")
    local _, errors = loader.load({ root })
    assert.are.equal(3, #errors, vim.inspect(errors))
    local text = table.concat(errors, "\n")
    assert.matches("AAA-01.md: a retired rule needs a frontmatter with its `id`", text, 1, true)
    assert.matches("AAA-02.md: a retired rule needs a frontmatter with its `id`", text, 1, true)
    assert.matches("AAA-03.md:1: merge-conflict marker `<<<<<<<`", text, 1, true)
  end)

  it("a README and other files that are no .md file in _retired/ are no retired rule", function()
    local root = new_ruleset()
    write_raw(root .. "/_retired/README.md", "# What lies here\n")
    write_raw(root .. "/_retired/AAA/.gitkeep", "")
    write_raw(root .. "/_retired/AAA/notes.txt", "x")
    assert.are.same({}, select(2, loader.load({ root })))
    assert.are.same({}, loader.retired(root))
  end)

  it("a folder _retired above the ruleset does not make its rules retired", function()
    local root = (vim.fn.tempname():gsub("\\", "/")) .. "/_retired/ruleset"
    write_raw(root .. "/_rules/AAA/AAA-05.md", rule_file_text("AAA-05"))
    local rules, errors = loader.load({ root })
    assert.are.equal(1, #rules)
    assert.are.same({}, errors)
  end)
end)

describe("rules.engine.loader: a file under _rules/ that yields no rule is an error", function()
  ---@param name string  the file below `_rules/`
  ---@param text string
  ---@return string[] errors
  ---@return integer rules
  local function load_with(name, text)
    local root = new_ruleset()
    write_raw(root .. "/_rules/AAA/AAA-01.md", rule_file_text("AAA-01"))
    write_raw(root .. "/_rules/" .. name, text)
    local rules, errors = loader.load({ root })
    return errors, #rules
  end

  it("an empty file", function()
    local errors, rules = load_with("AAA/AAA-02.md", "")
    assert.are.equal(1, rules)
    assert.are.equal(1, #errors, vim.inspect(errors))
    assert.matches("AAA-02.md: the file is empty", errors[1], 1, true)
  end)

  it("a file with blanks only", function()
    local errors = load_with("AAA/AAA-02.md", "\n  \n\t\n")
    assert.are.equal(1, #errors, vim.inspect(errors))
    assert.matches("the file is empty", errors[1], 1, true)
  end)

  it("a file without a frontmatter", function()
    local errors = load_with("AAA/AAA-02.md", "#### `AAA-02`\n\nText without a frontmatter.\n")
    assert.are.equal(1, #errors, vim.inspect(errors))
    assert.matches("AAA-02.md: no rule in this file", errors[1], 1, true)
  end)

  it("a file with a frontmatter but no id", function()
    local errors = load_with("AAA/AAA-02.md", "---\ntitle: x\n---\n\n#### `AAA-02`\n")
    assert.are.equal(1, #errors, vim.inspect(errors))
    assert.matches("no rule in this file", errors[1], 1, true)
  end)

  it("a file that starts with merge-conflict markers, and one with markers further down", function()
    local at_top = "<<<<<<< HEAD\n" .. rule_file_text("AAA-02") .. "=======\n" .. rule_file_text("AAA-02") .. ">>>>>>> other\n"
    local errors = load_with("AAA/AAA-02.md", at_top)
    assert.are.equal(1, #errors, vim.inspect(errors))
    assert.matches("AAA-02.md:1: merge-conflict marker `<<<<<<<`", errors[1], 1, true)

    -- the frontmatter is whole, the text is where the two sides meet: the file still yields a rule, and is no good
    local in_text = rule_file_text("AAA-02") .. "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> other\n"
    local errors2, rules2 = load_with("AAA/AAA-02.md", in_text)
    assert.are.equal(2, rules2)
    assert.are.equal(1, #errors2, vim.inspect(errors2))
    assert.matches("merge-conflict marker `<<<<<<<`", errors2[1], 1, true)
    assert.matches("AAA-02.md:10:", errors2[1], 1, true)
  end)

  it("a lone ======= or >>>>>>> line at the start of a line counts as well, one in a code fence does not", function()
    local errors = load_with("AAA/AAA-02.md", rule_file_text("AAA-02") .. "=======\n")
    assert.matches("marker `=======`", table.concat(errors, "\n"), 1, true)
    errors = load_with("AAA/AAA-02.md", rule_file_text("AAA-02") .. ">>>>>>> theirs\n")
    assert.matches("marker `>>>>>>>`", table.concat(errors, "\n"), 1, true)
    local example = rule_file_text("AAA-02") .. "\n```text\n<<<<<<< HEAD\n=======\n>>>>>>> other\n```\n"
    assert.are.same({}, (load_with("AAA/AAA-02.md", example)))
  end)

  it("a file with a fault in its frontmatter is told once, not once more as one without a rule", function()
    local errors = load_with("AAA/AAA-02.md", "---\nid: AAA-02\nseverity: urgent\n---\n\n#### `AAA-02`\n")
    assert.are.equal(1, #errors, vim.inspect(errors))
    assert.matches("invalid `severity`", errors[1], 1, true)
  end)

  it("a file directly in _rules/ and one deeper down are rule files too", function()
    assert.are.equal(1, #load_with("AAA-02.md", ""))
    assert.are.equal(1, #load_with("AAA/deeper/AAA-02.md", ""))
  end)

  it("what is no rule file stays allowed: .gitkeep, a README.md, a layout, a generated document, other file types", function()
    local root = new_ruleset()
    write_raw(root .. "/_rules/AAA/AAA-01.md", rule_file_text("AAA-01"))
    write_raw(root .. "/_rules/.gitkeep", "")
    write_raw(root .. "/_rules/AAA/.gitkeep", "")
    write_raw(root .. "/_rules/README.md", "# What lies here\n")
    write_raw(root .. "/_rules/AAA/readme.md", "")
    write_raw(root .. "/_rules/AAA/notes.txt", "x")
    write_raw(root .. "/_rules/AAA/layout.md", "---\nkind: layout\noutput: out.md\n---\n# D\n")
    write_raw(root .. "/_rules/AAA/doc.md", "<!-- GENERATED by rules.nvim from x: do not edit -->\n# D\n")
    local rules, errors = loader.load({ root })
    assert.are.equal(1, #rules)
    assert.are.same({}, errors)
  end)

  it("a document with ```rule blocks yields its rules in _rules/ too, and its prose is no fault", function()
    local root = new_ruleset()
    write_raw(root .. "/_rules/AAA/doc.md", '#### `AAA-01`\n\n```rule\nid = "AAA-01",\nseverity = "critical",\n```\n\nText.\n')
    local rules, errors = loader.load({ root })
    assert.are.equal(1, #rules)
    assert.are.same({}, errors)
  end)

  it("outside _rules/ a .md file without a rule is an ordinary document: empty, notes, a README, a title", function()
    local root = new_ruleset()
    write_raw(root .. "/_rules/AAA/AAA-01.md", rule_file_text("AAA-01"))
    write_raw(root .. "/notes/empty.md", "")
    write_raw(root .. "/notes/todo.md", "# Notes\n\nNothing here.\n")
    write_raw(root .. "/README.md", "# A ruleset\n")
    write_raw(root .. "/_layouts/L.md", "---\nkind: layout\noutput: L.md\n---\n# L\n\n{{rule AAA-01}}\n")
    write_raw(root .. "/notes/title.md", "Title\n=======\n\ntext\n")
    local rules, errors = loader.load({ root })
    assert.are.equal(1, #rules)
    assert.are.same({}, errors)
  end)

  it("a document in the legacy form outside _rules/ still loads", function()
    local root = new_ruleset()
    write_raw(
      root .. "/regeln/DEP.md",
      '# Deps\n\nIntro.\n\n#### `DEP-01`\n\n```rule\nid = "DEP-01",\nseverity = "critical",\n```\n\nText.\n'
    )
    write_raw(root .. "/regeln/EMPTY.md", "")
    local rules, errors = loader.load({ root })
    assert.are.equal(1, #rules)
    assert.are.same({}, errors)
  end)
end)
