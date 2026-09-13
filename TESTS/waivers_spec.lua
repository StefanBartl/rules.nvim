local waivers = require("rules.engine.waivers")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

describe("rules.engine.waivers.load", function()
  it("returns no waivers and no error when the file is missing", function()
    local w, err = waivers.load(tmp_dir())
    assert.are.same({}, w)
    assert.is_nil(err)
  end)

  it("loads a valid waivers file", function()
    local dir = tmp_dir()
    vim.fn.writefile({ '{"DEP-01": "false positive, tracked in JIRA-123"}' }, dir .. "/.rules-waivers.json")

    local w, err = waivers.load(dir)

    assert.is_nil(err)
    assert.are.equal("false positive, tracked in JIRA-123", w["DEP-01"])
  end)

  it("reports an error, not a crash, on unparseable JSON", function()
    local dir = tmp_dir()
    vim.fn.writefile({ "not json" }, dir .. "/.rules-waivers.json")

    local w, err = waivers.load(dir)

    assert.are.same({}, w)
    assert.is_not_nil(err)
  end)

  it("accepts an empty object as zero waivers, not an error", function()
    local dir = tmp_dir()
    vim.fn.writefile({ "{}" }, dir .. "/.rules-waivers.json")

    local w, err = waivers.load(dir)

    assert.are.same({}, w)
    assert.is_nil(err)
  end)

  it("rejects a JSON array instead of silently waiving nothing", function()
    local dir = tmp_dir()
    vim.fn.writefile({ '["DEP-01", "DEP-02"]' }, dir .. "/.rules-waivers.json")

    local w, err = waivers.load(dir)

    assert.are.same({}, w)
    assert.is_not_nil(err)
    assert.matches("not a list", err)
  end)

  it("rejects a non-string reason instead of silently waiving with garbage", function()
    local dir = tmp_dir()
    vim.fn.writefile({ '{"DEP-01": true}' }, dir .. "/.rules-waivers.json")

    local w, err = waivers.load(dir)

    assert.are.same({}, w)
    assert.is_not_nil(err)
  end)
end)

describe("rules.engine.waivers.orphaned", function()
  local rules = {
    { id = "DEP-01", severity = "recommended" },
    { id = "DEP-02", severity = "recommended" },
  }

  it("returns nothing when every waiver matches a loaded rule", function()
    local w = { ["DEP-01"] = "tracked", ["DEP-02"] = "tracked" }
    assert.are.same({}, waivers.orphaned(w, rules))
  end)

  it("names a waiver id with no matching rule -- retired or mistyped", function()
    local w = { ["DEP-01"] = "tracked", ["DEP-99"] = "stale" }
    assert.are.same({ "DEP-99" }, waivers.orphaned(w, rules))
  end)

  it("returns every orphaned id, sorted", function()
    local w = { ["DEP-99"] = "stale", ["DEP-50"] = "also stale" }
    assert.are.same({ "DEP-50", "DEP-99" }, waivers.orphaned(w, rules))
  end)
end)
