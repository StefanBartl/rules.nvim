-- TESTS/family_spec.lua -- the family of `new`: uppercase A-Z for a new one, any spelling for one the ruleset has (G5-4).
---@diagnostic disable: need-check-nil
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
    "severity: recommended",
    "family: " .. id:match("^(%a+)%-"),
    "---",
    "",
    "#### `" .. id .. "` — title of " .. id,
    "",
    "Text.",
    "",
    "---",
    "",
  }, "\n")
end

---A ruleset whose families are `Dep` (mixed case) and `lint` (lower case), and `DEP`.
---@return string root, table opts
local function fixture()
  local root = vim.fn.tempname() .. "/fixture/Checklists"
  write_raw(root .. "/_rules/Dep/Dep-01.md", rule_file("Dep-01"))
  write_raw(root .. "/_rules/lint/lint-04.md", rule_file("lint-04"))
  write_raw(root .. "/_rules/UPPER/UPPER-01.md", rule_file("UPPER-01"))
  return root, { rulesets = { root }, today = "2026-10-15" }
end

---@param opts table
---@param op table
---@param extra? table
---@return table entry
local function one(opts, op, extra)
  local result = assert(ops.run(vim.tbl_extend("force", { ops = { op } }, extra or {}), opts))
  return result.results[1]
end

describe("family_error", function()
  it("asks for uppercase letters of a new family, and takes a known one as it is spelled", function()
    local known = function(family)
      return family == "Dep" or family == "lint"
    end
    assert.is_nil(ops.family_error("DEP"))
    assert.is_nil(ops.family_error("ABCDEFGHIJKL"))
    for _, family in ipairs({ "Dep", "dep", "Fix", "DEP2", "D-P", "", "ABCDEFGHIJKLM", 5 }) do
      assert.is_string(ops.family_error(family), tostring(family))
      assert.is_string(ops.family_error(family, function()
        return false
      end))
    end
    assert.is_nil(ops.family_error("Dep", known))
    assert.is_nil(ops.family_error("lint", known))
    -- the exact spelling: `dep` is not `Dep`, and a known name that is no family (a digit, a dash) is none
    assert.is_string(ops.family_error("dep", known))
    assert.is_string(ops.family_error("Dep-1", function()
      return true
    end))
    assert.is_string(ops.family_error("", function()
      return true
    end))
  end)
end)

describe("rules-ops/1 new: the family", function()
  it("takes a family the ruleset has in the spelling it has (Dep-01), and numbers on from there", function()
    local root, opts = fixture()
    local entry = one(opts, { op = "new", family = "Dep", title = "two", severity = "critical" })
    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("Dep-02", entry.id)
    assert.is_truthy(vim.uv.fs_stat(root .. "/_rules/Dep/Dep-02.md"))
    local lower = one(opts, { op = "new", family = "lint", title = "five", severity = "critical" })
    assert.is_true(lower.ok, vim.inspect(lower))
    assert.are.equal("lint-05", lower.id)
    -- a dry run says the same
    local dry = one(opts, { op = "new", family = "Dep", title = "three", severity = "critical" }, { dry_run = true })
    assert.is_true(dry.ok, vim.inspect(dry))
    assert.are.equal("Dep-03", dry.id)
  end)

  it("refuses a new family that is not uppercase letters, also one that only differs in case from one the ruleset has", function()
    local root, opts = fixture()
    for _, family in ipairs({ "Fix", "dep", "DEP2", "LINT2", "Lint" }) do
      local entry = one(opts, { op = "new", family = family, title = "t", severity = "critical" })
      assert.is_false(entry.ok, family)
      assert.are.equal("invalid_argument", entry.error.code, family)
      assert.is_truthy(entry.error.message:find("1 to 12 uppercase letters A-Z", 1, true), entry.error.message)
    end
    assert.are.equal(0, vim.fn.isdirectory(root .. "/_rules/Fix"))
    -- a new family in capitals still goes
    local entry = one(opts, { op = "new", family = "FIX", title = "t", severity = "critical" })
    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("FIX-01", entry.id)
    -- a retired rule keeps its family known
    assert.is_true(one(opts, { op = "retire", id = "FIX-01" }).ok)
    contract.clear_cache()
    assert.is_true(one(opts, { op = "retire", id = "lint-04" }).ok)
    local again = one(opts, { op = "new", family = "lint", title = "again", severity = "critical" })
    assert.is_true(again.ok, vim.inspect(again))
    assert.are.equal("lint-05", again.id)
  end)
end)
