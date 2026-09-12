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
