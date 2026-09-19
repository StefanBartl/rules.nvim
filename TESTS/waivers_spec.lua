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

  it("SEC-33: rejects a multi-line reason instead of crashing report rendering later", function()
    -- nvim_buf_set_lines rejects any line containing "\n" -- a multi-line
    -- reason (legal JSON) would otherwise reach that call and throw at
    -- render time, naming report/window.lua instead of the waivers file.
    local dir = tmp_dir()
    vim.fn.writefile({ '{"DEP-01": "line one\\nline two"}' }, dir .. "/.rules-waivers.json")

    local w, err = waivers.load(dir)

    assert.are.same({}, w)
    assert.is_not_nil(err)
    assert.matches("newline", err)
  end)

  it("SEC-33: rejects a reason exceeding the length cap", function()
    local dir = tmp_dir()
    vim.fn.writefile({ '{"DEP-01": "' .. string.rep("x", 501) .. '"}' }, dir .. "/.rules-waivers.json")

    local w, err = waivers.load(dir)

    assert.are.same({}, w)
    assert.is_not_nil(err)
    assert.matches("exceeds", err)
  end)

  it("ERR-01: reports an error, not a crash, when readfile throws after filereadable passed", function()
    -- The TOCTOU window between `filereadable` and `readfile` -- removed,
    -- renamed, or exclusively locked in between -- `vim.fn.readfile` raises
    -- rather than returning an error value.
    local dir = tmp_dir()
    vim.fn.writefile({ '{"DEP-01": "tracked"}' }, dir .. "/.rules-waivers.json")

    local original_readfile = vim.fn.readfile
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.readfile = function()
      error("E484: Can't open file")
    end

    local ok, w, err = pcall(waivers.load, dir)
    vim.fn.readfile = original_readfile

    assert.is_true(ok)
    assert.are.same({}, w)
    assert.is_not_nil(err)
    assert.matches("could not read", err)
  end)

  it("SEC-33: rejects a waivers file exceeding the entry-count cap", function()
    local entries = {}
    for i = 1, 501 do
      entries[#entries + 1] = ('"DEP-%d": "waived"'):format(i)
    end
    local dir = tmp_dir()
    vim.fn.writefile({ "{" .. table.concat(entries, ",") .. "}" }, dir .. "/.rules-waivers.json")

    local w, err = waivers.load(dir)

    assert.are.same({}, w)
    assert.is_not_nil(err)
    assert.matches("more than", err)
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
