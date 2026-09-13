local gate = require("rules.engine.gate")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

describe("rules.engine.gate.run", function()
  local rules = {
    { id = "NEW-01", severity = "critical", check = { type = "grep", pattern = "vim%.loop%." } },
    { id = "REL-01", severity = "recommended", check = { type = "grep", pattern = "vim%.loop%." } },
    { id = "SEC-01", severity = "critical", check = { type = "grep", pattern = "does%.not%.occur" } },
  }

  it("runs every family in the list and concatenates the results", function()
    local dir = tmp_dir()
    vim.fn.writefile({ "vim.loop.new_timer()" }, dir .. "/a.lua")

    local results = gate.run(rules, { "NEW", "REL" }, dir)

    assert.are.equal(2, #results)
    local ids = { results[1].rule.id, results[2].rule.id }
    table.sort(ids)
    assert.are.same({ "NEW-01", "REL-01" }, ids)
  end)

  it("excludes families not named in the gate", function()
    local dir = tmp_dir()
    local results = gate.run(rules, { "NEW" }, dir)
    assert.are.equal(1, #results)
    assert.are.equal("NEW-01", results[1].rule.id)
  end)
end)

describe("rules.engine.gate.unknown_families", function()
  local rules = {
    { id = "NEW-01", severity = "critical" },
    { id = "REL-01", severity = "recommended" },
  }

  it("returns nothing when every configured family has a matching rule", function()
    assert.are.same({}, gate.unknown_families(rules, { "NEW", "REL" }))
  end)

  it("names a configured family with zero matching rules -- a typo or an unmigrated family", function()
    assert.are.same({ "LUA" }, gate.unknown_families(rules, { "NEW", "LUA" }))
  end)

  it("reports every unknown family, in the order they were configured", function()
    assert.are.same({ "ERR", "SEC" }, gate.unknown_families(rules, { "ERR", "NEW", "SEC" }))
  end)
end)

describe("rules.engine.gate.diff_files/scope_to_diff", function()
  ---@return string
  local function git_repo()
    local dir = tmp_dir()
    vim.fn.system({ "git", "-C", dir, "init", "-q" })
    vim.fn.system({ "git", "-C", dir, "config", "user.email", "test@test" })
    vim.fn.system({ "git", "-C", dir, "config", "user.name", "test" })
    vim.fn.writefile({ "unchanged" }, dir .. "/unchanged.lua")
    vim.fn.system({ "git", "-C", dir, "add", "-A" })
    vim.fn.system({ "git", "-C", dir, "commit", "-q", "-m", "base" })
    return dir
  end

  it("lists only files changed since the given ref", function()
    local dir = git_repo()
    vim.fn.writefile({ "changed" }, dir .. "/changed.lua")

    local changed, err = gate.diff_files(dir, "HEAD")

    assert.is_nil(err)
    assert.is_true(changed[vim.fs.normalize(vim.fn.fnamemodify(dir .. "/changed.lua", ":p"))])
    assert.is_nil(changed[vim.fs.normalize(vim.fn.fnamemodify(dir .. "/unchanged.lua", ":p"))])
  end)

  it("does not report the repo root itself when both a tracked change and an untracked file exist", function()
    local dir = git_repo()
    vim.fn.writefile({ "modified" }, dir .. "/unchanged.lua") -- tracked, now modified
    vim.fn.writefile({ "new" }, dir .. "/new_file.lua") -- untracked

    local changed, err = gate.diff_files(dir, "HEAD")

    assert.is_nil(err)
    assert.is_nil(changed[vim.fs.normalize(vim.fn.fnamemodify(dir, ":p"))])
    assert.is_true(changed[vim.fs.normalize(vim.fn.fnamemodify(dir .. "/unchanged.lua", ":p"))])
    assert.is_true(changed[vim.fs.normalize(vim.fn.fnamemodify(dir .. "/new_file.lua", ":p"))])
  end)

  it("reports an error, not a crash, for an invalid git ref", function()
    local dir = git_repo()
    local changed, err = gate.diff_files(dir, "not-a-real-ref")
    assert.is_nil(changed)
    assert.is_not_nil(err)
  end)

  it("downgrades a fail to pass when none of its findings are in the diff", function()
    local dir = tmp_dir()
    local changed_path = dir .. "/changed.lua"
    local untouched_path = dir .. "/untouched.lua"
    local results = {
      { rule = { id = "X-01" }, status = "fail", findings = { { file = untouched_path, line = 1, text = "x" } } },
    }
    local changed = { [vim.fs.normalize(vim.fn.fnamemodify(changed_path, ":p"))] = true }

    local scoped = gate.scope_to_diff(results, changed)

    assert.are.equal("pass", scoped[1].status)
    assert.are.equal(0, #scoped[1].findings)
  end)

  it("keeps a fail (narrowed to just the diff'd findings) when some are in the diff", function()
    local dir = tmp_dir()
    local changed_path = dir .. "/changed.lua"
    local untouched_path = dir .. "/untouched.lua"
    local results = {
      {
        rule = { id = "X-01" },
        status = "fail",
        findings = {
          { file = changed_path, line = 1, text = "in diff" },
          { file = untouched_path, line = 2, text = "not in diff" },
        },
      },
    }
    local changed = { [vim.fs.normalize(vim.fn.fnamemodify(changed_path, ":p"))] = true }

    local scoped = gate.scope_to_diff(results, changed)

    assert.are.equal("fail", scoped[1].status)
    assert.are.equal(1, #scoped[1].findings)
    assert.are.equal("in diff", scoped[1].findings[1].text)
  end)

  it("leaves manual/pass/waived results untouched", function()
    local results = {
      { rule = { id = "X-01" }, status = "manual", findings = {} },
      { rule = { id = "X-02" }, status = "pass", findings = {} },
      { rule = { id = "X-03" }, status = "waived", findings = {}, waiver_reason = "tracked" },
    }

    local scoped = gate.scope_to_diff(results, {})

    assert.are.equal("manual", scoped[1].status)
    assert.are.equal("pass", scoped[2].status)
    assert.are.equal("waived", scoped[3].status)
  end)
end)
