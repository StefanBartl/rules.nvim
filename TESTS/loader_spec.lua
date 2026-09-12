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

  it("returns nothing for an empty or missing path, without erroring", function()
    local rules, errors = loader.load({ "/definitely/does/not/exist" })

    assert.are.equal(0, #rules)
    assert.are.equal(0, #errors)
  end)
end)
