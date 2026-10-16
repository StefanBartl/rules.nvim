-- TESTS/gaps_spec.lua -- the numbers a family skips (DEP-01, DEP-03, no DEP-02): the pure finder, the field of the load
-- result (apart from `load_errors`, and not in any document of rules-export/1), and `scripts/ruleset.lua check` with
-- `--gaps` / `--strict-gaps`. A gap is a hint: quiet without the flag, an exit 1 only with `--strict-gaps`.
---@diagnostic disable: need-check-nil
local api = require("rules.api")
local contract = require("rules.contract")
local gaps = require("rules.engine.gaps")

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

---@param id string
---@return string
local function rule_text(id)
  local family = id:match("^(%a+)%-")
  return ("---\nid: %s\nseverity: critical\nfamily: %s\n---\n\n#### `%s`\n\nText.\n"):format(id, family, id)
end

---A ruleset with the given live ids and retired ids (`_rules/<FAMILY>/<ID>.md`, `_retired/<FAMILY>/<ID>.md`).
---@param live string[]
---@param retired? string[]
---@return string root
local function ruleset(live, retired)
  local root = tmp_dir() .. "/Checklists"
  for _, id in ipairs(live) do
    write(("%s/_rules/%s/%s.md"):format(root, id:match("^(%a+)%-"), id), rule_text(id))
  end
  for _, id in ipairs(retired or {}) do
    write(("%s/_retired/%s/%s.md"):format(root, id:match("^(%a+)%-"), id), rule_text(id))
  end
  return root
end

---@param found Rules.FamilyGaps[]
---@return table<string, string>  family -> the ranges, spelled
local function spelled(found)
  local out = {}
  for _, gap in ipairs(found) do
    local parts = {}
    for _, range in ipairs(gap.ranges) do
      parts[#parts + 1] = range.from == range.to and tostring(range.from) or (range.from .. "-" .. range.to)
    end
    out[gap.family] = table.concat(parts, ",")
  end
  return out
end

describe("rules.engine.gaps", function()
  it("finds the numbers between the smallest and the largest of a family, as ranges", function()
    local found = gaps.find({ "DEP-01", "DEP-03", "DEP-04", "DEP-08", "LUA-01", "LUA-02" })
    assert.are.equal(1, #found, "LUA is numbered without a hole")
    local gap = found[1]
    assert.are.equal("DEP", gap.family)
    assert.are.equal(1, gap.first)
    assert.are.equal(8, gap.last)
    assert.are.equal(4, gap.taken)
    assert.are.equal(4, gap.missing)
    assert.are.same({ { from = 2, to = 2 }, { from = 5, to = 7 } }, gap.ranges)
    assert.are.equal(4, gaps.total(found))
  end)

  it("sees no gap before the smallest number or after the largest, nor in one id", function()
    assert.are.same({}, gaps.find({ "DEP-05", "DEP-06", "DEP-07" }), "a family may start above 01")
    assert.are.same({}, gaps.find({ "DEP-09" }))
    assert.are.same({}, gaps.find({}))
  end)

  it("takes DEP-1 and DEP-01 for one number, and a repeated id once", function()
    assert.are.same({}, gaps.find({ "DEP-1", "DEP-01", "DEP-02", "DEP-2" }))
    local found = gaps.find({ "DEP-1", "DEP-001", "DEP-3" })
    assert.are.equal(1, found[1].missing)
    assert.are.equal(3, found[1].width, "the widest spelling of the family")
  end)

  it("starts at zero when the family does", function()
    assert.are.same({ DEP = "1-2" }, spelled(gaps.find({ "DEP-00", "DEP-03" })))
  end)

  it("leaves out an id of another shape and a number of more than 15 digits", function()
    local found = gaps.find({ "DEP-01", "DEP2-05", "DEP", "DEP-A", "DEP-02-03", "DEP-1000000000000000000", "DEP-02" })
    assert.are.same({}, found)
  end)

  it("lists the families in byte order", function()
    local found = gaps.find({ "ZED-01", "ZED-03", "ABC-01", "ABC-03", "Mid-01", "Mid-03" })
    assert.are.same(
      { "ABC", "Mid", "ZED" },
      vim.tbl_map(function(gap)
        return gap.family
      end, found)
    )
  end)

  it("spells the ids in the width of the family, and says how many ranges it leaves out", function()
    assert.are.equal(
      "DEP: DEP-02, DEP-05..DEP-07 not taken between DEP-01 and DEP-08",
      gaps.text(gaps.find({ "DEP-01", "DEP-03", "DEP-04", "DEP-08" })[1])
    )
    assert.are.equal("DEP: DEP-0002 not taken between DEP-0001 and DEP-0003", gaps.text(gaps.find({ "DEP-0001", "DEP-3" })[1]))
    local many = {}
    for n = 1, 40, 2 do
      many[#many + 1] = ("DEP-%02d"):format(n)
    end
    local text = gaps.text(gaps.find(many)[1])
    assert.matches("and 7 more range(s)", text, 1, true)
    assert.is_nil(text:find("DEP-38", 1, true), "the cut ranges are not spelled")
  end)
end)

describe("the gaps of a load result", function()
  it("counts a retired rule as taken: it leaves no gap", function()
    local root = ruleset({ "DEP-01", "DEP-03" }, { "DEP-02" })
    local view = assert(contract.view({ rulesets = { root } }))
    assert.are.same({}, view.gaps)
    assert.are.same({}, view.load_errors)
    assert.are.same({}, assert(contract.gaps({ rulesets = { root } })))
  end)

  it("reports the number of a deleted rule, apart from the load errors", function()
    local root = ruleset({ "DEP-01", "DEP-03", "DEP-04", "DEP-07" })
    local view = assert(contract.view({ rulesets = { root } }))
    assert.are.same({ DEP = "2,5-6" }, spelled(view.gaps))
    assert.are.same({}, view.load_errors, "a gap is no load error")
    assert.are.same({ DEP = "2,5-6" }, spelled(assert(contract.gaps({ rulesets = { root } }))))
  end)

  it("takes the rulesets together: a family split over two has no gap where the other one holds the number", function()
    local a = ruleset({ "DEP-01", "DEP-02" })
    local b = ruleset({ "DEP-03", "DEP-05" })
    assert.are.same({ DEP = "4" }, spelled(assert(contract.gaps({ rulesets = { a, b } }))))
    assert.are.same({}, assert(contract.gaps({ rulesets = { a } })))
  end)

  it("changes no document of rules-export/1", function()
    local root = ruleset({ "DEP-01", "DEP-03" })
    local text = api.call("snapshot", nil, { rulesets = { root } })
    local doc = vim.json.decode(text)
    assert.are.same({}, doc.load_errors)
    assert.is_nil(doc.gaps, "the hint is not in the snapshot")
    assert.is_nil(text:find("gaps", 1, true))
    for _, family in ipairs(doc.families) do
      assert.is_nil(family.gaps)
    end
  end)
end)

-- @spawn: every case starts the script in its own nvim
describe("scripts/ruleset.lua check --gaps @spawn", function()
  local script =
    assert(vim.api.nvim_get_runtime_file("scripts/ruleset.lua", false)[1], "scripts/ruleset.lua is not on the runtimepath")
  local lib_marker = assert(vim.api.nvim_get_runtime_file("lua/lib/nvim", false)[1], "lib.nvim is not on the runtimepath")
  local lib_dir = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(lib_marker)))

  ---@param ... string
  ---@return { code: integer, stdout: string, stderr: string }
  local function run(...)
    local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script, ... }
    local done = vim.system(cmd, { text = true, env = { LIB_NVIM_DIR = lib_dir } }):wait(60000)
    return { code = done.code, stdout = done.stdout or "", stderr = done.stderr or "" }
  end

  it("says nothing about gaps without a flag, and exits 0", function()
    local root = ruleset({ "DEP-01", "DEP-03" })
    local result = run("check", root)
    assert.are.equal(0, result.code, result.stdout)
    assert.is_nil(result.stdout:find("not taken", 1, true), result.stdout)
    assert.matches("ok: every ruleset loads without errors", result.stdout, 1, true)
  end)

  it("--gaps lists the numbers a family skips as notes and still exits 0", function()
    local root = ruleset({ "DEP-01", "DEP-03", "DEP-04", "DEP-08", "LUA-01", "LUA-02" })
    local result = run("check", "--gaps", root)
    assert.are.equal(0, result.code, result.stdout)
    assert.matches("  note: DEP: DEP-02, DEP-05..DEP-07 not taken between DEP-01 and DEP-08", result.stdout, 1, true)
    assert.is_nil(result.stdout:find("LUA: ", 1, true), "a family without a hole is not listed")
    assert.matches("4 number(s) not taken in 1 family(ies)", result.stdout, 1, true)
    assert.matches("ok: every ruleset loads without errors", result.stdout, 1, true)
  end)

  it("--gaps on a ruleset without a hole says 0 and exits 0", function()
    local root = ruleset({ "DEP-01", "DEP-02" })
    local result = run("check", "--gaps", root)
    assert.are.equal(0, result.code, result.stdout)
    assert.matches("0 number(s) not taken in 0 family(ies)", result.stdout, 1, true)
  end)

  it("--strict-gaps fails on a gap and names it", function()
    local root = ruleset({ "DEP-01", "DEP-03" })
    local result = run("check", "--strict-gaps", root)
    assert.are.equal(1, result.code, result.stdout)
    assert.matches("  gap: DEP: DEP-02 not taken between DEP-01 and DEP-03", result.stdout, 1, true)
    assert.matches("FAILED: 1 family(ies) skip numbers (--strict-gaps)", result.stdout, 1, true)
    assert.is_nil(result.stdout:find("ok: every ruleset", 1, true))
  end)

  it("--strict-gaps is green when a retired rule holds the number", function()
    local root = ruleset({ "DEP-01", "DEP-03" }, { "DEP-02" })
    local result = run("check", "--strict-gaps", root)
    assert.are.equal(0, result.code, result.stdout)
    assert.matches("ok: every ruleset loads without errors", result.stdout, 1, true)
  end)

  it("--strict-gaps judges the folders it checks, together", function()
    local a = ruleset({ "DEP-01", "DEP-02" })
    local b = ruleset({ "DEP-04" })
    assert.are.equal(0, run("check", "--strict-gaps", a).code)
    assert.are.equal(0, run("check", "--strict-gaps", b).code)
    -- with --vault=D and no folder: every ruleset the vault offers
    local vault = tmp_dir()
    write(vault .. "/rulesets/one/_rules/DEP/DEP-01.md", rule_text("DEP-01"))
    write(vault .. "/rulesets/two/_rules/DEP/DEP-03.md", rule_text("DEP-03"))
    local result = run("check", "--strict-gaps", "--vault=" .. vault)
    assert.are.equal(1, result.code, result.stdout)
    assert.matches("DEP-02 not taken between DEP-01 and DEP-03", result.stdout, 1, true)
    write(vault .. "/rulesets/two/_rules/DEP/DEP-02.md", rule_text("DEP-02"))
    assert.are.equal(0, run("check", "--strict-gaps", "--vault=" .. vault).code)
  end)

  it("a load error still wins: it fails the run whatever the flag says", function()
    local root = ruleset({ "DEP-01", "DEP-03" })
    write(root .. "/_rules/DEP/DEP-01-copy.md", rule_text("DEP-01"))
    local result = run("check", "--gaps", root)
    assert.are.equal(1, result.code, result.stdout)
    assert.matches("duplicate rule id DEP-01", result.stdout, 1, true)
  end)

  it("is wrong usage for the flags on another command or with a value", function()
    local root = ruleset({ "DEP-01" })
    for _, args in ipairs({
      { "catalog", "--gaps", root },
      { "catalog", "--strict-gaps", root },
      { "migrate", "--gaps", root },
      { "check", "--gaps=1", root },
      { "check", "--strict-gaps=true", root },
      { "check", "--strict", root },
    }) do
      local result = run(unpack(args))
      assert.are.equal(2, result.code, table.concat(args, " "))
      assert.matches("usage:", result.stderr, 1, true)
    end
  end)
end)
