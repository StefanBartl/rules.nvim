-- TESTS/candidates_spec.lua -- what <Tab> offers for the arguments of `:Rules`: read live from the rulesets, never an error.
---@diagnostic disable: need-check-nil
local candidates = require("rules.ui.candidates")
local contract = require("rules.contract")
local ops = require("rules.ops")

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
local function rule_file(id)
  return table.concat({
    "---",
    "id: " .. id,
    "severity: critical",
    "family: " .. id:match("^(%a+)%-"),
    "---",
    "",
    "#### `" .. id .. "` — title of " .. id,
    "",
    "Text.",
    "",
  }, "\n")
end

describe("rules.ui.candidates.headings", function()
  it("lists the headings of a layout in order, without the frontmatter or a fenced code block", function()
    local text = table.concat({
      "---",
      "kind: layout",
      "output: regeln/DEP.md",
      "# not a heading: frontmatter",
      "---",
      "# Dependencies",
      "",
      "```lua",
      "# a comment in code",
      "```",
      "## Core Rules",
      "",
      "{{rule DEP-01}}",
      "### Deep",
      "#nospace",
    }, "\n")
    assert.are.same({ "Dependencies", "Core Rules", "Deep" }, candidates.headings(text))
  end)

  it("reads a layout with CR LF line endings", function()
    local text = table.concat({ "---", "kind: layout", "---", "# One", "## Two" }, "\r\n")
    assert.are.same({ "One", "Two" }, candidates.headings(text))
  end)
end)

describe("rules.ui.candidates", function()
  local root, other

  before_each(function()
    root = vim.fn.tempname() .. "/fixture/Checklists"
    other = vim.fn.tempname() .. "/fixture/Other"
    write_raw(root .. "/_rules/DEP/DEP-01.md", rule_file("DEP-01"))
    write_raw(root .. "/_rules/ERR/ERR-01.md", rule_file("ERR-01"))
    write_raw(root .. "/_rules/ERR/ERR-02.md", rule_file("ERR-02"))
    write_raw(
      root .. "/_layouts/regeln/DEP.md",
      "---\nkind: layout\noutput: regeln/DEP.md\n---\n# Deps\n\n## Core\n\n{{rule DEP-01}}\n"
    )
    write_raw(root .. "/_layouts/regeln/ERR.md", "---\nkind: layout\noutput: regeln/ERR.md\n---\n# Errors\n\n## Two Words\n")
    write_raw(other .. "/_rules/SEC/SEC-01.md", rule_file("SEC-01"))
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
    require("rules").setup({ rulesets = { root, other } })
    contract.clear_cache()
    candidates.reset()
  end)

  after_each(function()
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
    require("rules.config").setup({ rulesets = {} })
    contract.clear_cache()
    candidates.reset()
  end)

  it("lists the families and the ids of every ruleset, sorted", function()
    assert.are.same({ "DEP", "ERR", "SEC" }, candidates.families())
    assert.are.same({ "DEP-01", "ERR-01", "ERR-02", "SEC-01" }, candidates.ids())
  end)

  it("names the rulesets the way a document does", function()
    assert.are.same({ "Checklists", "Other" }, candidates.ruleset_names())
  end)

  it("lists the layouts, then the headings of one layout with a blank written for the command line", function()
    assert.are.same({ "regeln/DEP.md", "regeln/ERR.md" }, candidates.layout_outputs())
    assert.are.same({ "regeln/DEP.md", "regeln/ERR.md" }, candidates.places(""))
    assert.are.same({ "regeln/ERR.md" }, candidates.places("regeln/E"))
    assert.are.same({ "regeln/DEP.md#Deps", "regeln/DEP.md#Core" }, candidates.places("regeln/DEP.md#"))
    assert.are.same({ "regeln/ERR.md#Two\\ Words" }, candidates.places("regeln/ERR.md#Tw"))
    assert.are.same({}, candidates.places("regeln/NOPE.md#"))
  end)

  it("keeps a retired rule out of the ids", function()
    local retired = ops.run({ ops = { { op = "retire", id = "ERR-02" } } }, { rulesets = { root, other } })
    assert.is_true(retired.ok, vim.inspect(retired))
    assert.are.same({ "DEP-01", "ERR-01", "SEC-01" }, candidates.ids())
  end)

  it("lists the retired ids apart: a retired rule is a candidate to reinstate, a loaded one never", function()
    assert.are.same({}, candidates.retired_ids())
    local retired = ops.run(
      { ops = { { op = "retire", id = "ERR-02" }, { op = "retire", id = "SEC-01" } } },
      { rulesets = { root, other } }
    )
    assert.is_true(retired.ok, vim.inspect(retired))
    assert.are.same({ "ERR-02", "SEC-01" }, candidates.retired_ids())
    assert.are.same({ "DEP-01", "ERR-01" }, candidates.ids())
    -- a rule that is retired and loaded again (its id made again by hand) is no candidate: the door refuses it
    write_raw(root .. "/_rules/ERR/ERR-02.md", rule_file("ERR-02"))
    contract.clear_cache()
    assert.are.same({ "SEC-01" }, candidates.retired_ids())
  end)

  it("lists the headings of every layout for --section and the layouts for --layout, each once, a blank written", function()
    assert.are.same({ "Deps", "Core", "Errors", "Two\\ Words" }, candidates.sections(""))
    assert.are.same({ "Two\\ Words" }, candidates.sections("Tw"))
    assert.are.same({ "Core" }, candidates.sections("Co"))
    assert.are.same({}, candidates.sections("Nope"))
    assert.are.same({ "regeln/DEP.md", "regeln/ERR.md" }, candidates.layouts(""))
    assert.are.same({ "regeln/ERR.md" }, candidates.layouts("regeln/E"))
    assert.are.same({}, candidates.layouts("nope"))
  end)

  it("offers nothing, and raises nothing, where no ruleset is configured", function()
    require("rules.config").setup({ rulesets = {} })
    contract.clear_cache()
    candidates.reset()
    assert.are.same({}, candidates.families())
    assert.are.same({}, candidates.ids())
    assert.are.same({}, candidates.retired_ids())
    assert.are.same({}, candidates.sections(""))
    assert.are.same({}, candidates.layouts(""))
    assert.are.same({}, candidates.ruleset_names())
    assert.are.same({}, candidates.places(""))
  end)
end)

describe("rules.ops.layouts", function()
  it("lists the layouts of a ruleset folder with their output path, and none in a retired folder or a missing one", function()
    local root = vim.fn.tempname() .. "/fixture/Checklists"
    write_raw(root .. "/_layouts/regeln/B.md", "---\nkind: layout\noutput: regeln/B.md\n---\n# B\n")
    write_raw(root .. "/_layouts/regeln/A.md", "---\nkind: layout\noutput: regeln/A.md\n---\n# A\n")
    write_raw(root .. "/_retired/old.md", "---\nkind: layout\noutput: regeln/OLD.md\n---\n# Old\n")
    write_raw(root .. "/notes.md", "# just a note, no layout\n")
    local outputs = {}
    for _, layout in ipairs(ops.layouts(root)) do
      outputs[#outputs + 1] = layout.output
    end
    assert.are.same({ "regeln/A.md", "regeln/B.md" }, outputs)
    assert.are.same({}, ops.layouts(root .. "/missing"))
  end)
end)
