local verdicts = require("rules.engine.verdicts")

---@return string
local function tmp_root()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

---@param extra? table
---@return table
local function proposal(extra)
  return vim.tbl_extend("force", {
    rule_id = "DEP-01",
    status = "violation",
    proposed = true,
    verified = false,
    findings = { { file = "lua/a.lua", line = 12, quote = "require('x')" } },
    checked = { "lua/a.lua", "lua/b.lua" },
    unchecked = {},
    dropped = {},
  }, extra or {})
end

local ACCEPT = { by = "Stefan", date = "2026-10-22" }

---@param entries table
---@return string
local function entry_json(entries)
  return vim.json.encode(entries)
end

describe("rules.engine.verdicts.accept", function()
  it("writes the verdict of one proposal, with who, when, the evidence and where it came from", function()
    local root = tmp_root()

    local ok, err = verdicts.accept(root, proposal(), vim.tbl_extend("force", ACCEPT, { note = "seen it", model = "m1" }))
    local loaded, load_err = verdicts.load(root)

    assert.is_true(ok, err)
    assert.is_nil(load_err)
    assert.are.same({
      verdict = "violation",
      date = "2026-10-22",
      by = "Stefan",
      evidence = { { file = "lua/a.lua", line = 12 } },
      note = "seen it",
      from_proposal = { status = "violation", model = "m1" },
    }, loaded["DEP-01"])
  end)

  it("takes the checked files as the evidence of a compliant proposal", function()
    local root = tmp_root()

    assert.is_true(verdicts.accept(root, proposal({ status = "compliant", findings = {} }), ACCEPT))

    assert.are.same({ { file = "lua/a.lua" }, { file = "lua/b.lua" } }, verdicts.load(root)["DEP-01"].evidence)
  end)

  it("lets the person name the evidence", function()
    local root = tmp_root()

    assert.is_true(
      verdicts.accept(root, proposal(), vim.tbl_extend("force", ACCEPT, { evidence = { { file = "x.lua", line = 3 } } }))
    )

    assert.are.same({ { file = "x.lua", line = 3 } }, verdicts.load(root)["DEP-01"].evidence)
  end)

  it("keeps the verdicts of the other rules and replaces the one of the same rule", function()
    local root = tmp_root()
    assert.is_true(verdicts.accept(root, proposal({ rule_id = "A-01" }), ACCEPT))
    assert.is_true(verdicts.accept(root, proposal({ rule_id = "B-01" }), ACCEPT))
    assert.is_true(
      verdicts.accept(
        root,
        proposal({ rule_id = "A-01", status = "compliant", findings = {} }),
        { by = "Ann", date = "2026-10-23" }
      )
    )

    local loaded = verdicts.load(root)

    assert.are.equal("compliant", loaded["A-01"].verdict)
    assert.are.equal("Ann", loaded["A-01"].by)
    assert.are.equal("violation", loaded["B-01"].verdict)
  end)

  it("writes sorted keys, two spaces, LF and a final newline", function()
    local root = tmp_root()
    assert.is_true(verdicts.accept(root, proposal({ rule_id = "B-01" }), ACCEPT))
    assert.is_true(verdicts.accept(root, proposal({ rule_id = "A-01" }), ACCEPT))

    local fh = assert(io.open(verdicts.path(root), "rb"))
    local text = fh:read("*a")
    fh:close()

    assert.is_true(text:find('"A-01"', 1, true) < text:find('"B-01"', 1, true))
    assert.is_nil(text:find("\r", 1, true))
    assert.are.equal("\n", text:sub(-1))
    assert.are.equal(verdicts.encode(verdicts.load(root)), text)
    assert.is_truthy(text:find('\n  "A-01": {\n    "by"', 1, true))
  end)

  it("defaults the date to today", function()
    local root = tmp_root()

    assert.is_true(verdicts.accept(root, proposal(), { by = "Stefan" }))

    assert.are.equal(os.date("%Y-%m-%d"), verdicts.load(root)["DEP-01"].date)
  end)
end)

describe("rules.engine.verdicts.accept refusals", function()
  it("never takes a list: there is no accept-all", function()
    local root = tmp_root()

    local ok, err = verdicts.accept(root, { proposal({ rule_id = "A-01" }), proposal({ rule_id = "B-01" }) }, ACCEPT)

    assert.is_false(ok)
    assert.is_truthy(err:find("one proposal", 1, true))
    assert.are.equal(0, vim.fn.filereadable(verdicts.path(root)))
  end)

  it("refuses an unclear proposal: no answer is not a verdict", function()
    local root = tmp_root()

    local ok = verdicts.accept(root, proposal({ status = "unclear" }), ACCEPT)

    assert.is_false(ok)
    assert.are.equal(0, vim.fn.filereadable(verdicts.path(root)))
  end)

  it("refuses a proposal that says it is verified: the one who proposes does not confirm", function()
    local root = tmp_root()

    local ok, err = verdicts.accept(root, proposal({ verified = true }), ACCEPT)

    assert.is_false(ok)
    assert.is_truthy(err:find("verified", 1, true))
  end)

  it("refuses what is not a proposal of the agent", function()
    local root = tmp_root()

    assert.is_false(verdicts.accept(root, { rule_id = "DEP-01", status = "violation", verified = false }, ACCEPT))
    assert.is_false(verdicts.accept(root, { status = "violation", proposed = true, verified = false }, ACCEPT))
    assert.is_false(verdicts.accept(root, "DEP-01", ACCEPT))
  end)

  it("needs a person, and takes the name from the caller, never from the proposal", function()
    local root = tmp_root()

    assert.is_false(verdicts.accept(root, proposal({ by = "the agent" }), {}))
    assert.is_false(verdicts.accept(root, proposal(), { by = "   " }))
    assert.is_false(verdicts.accept(root, proposal(), { by = "two\nlines" }))
    assert.are.equal(0, vim.fn.filereadable(verdicts.path(root)))
  end)

  it("refuses a bad date, a bad note and bad evidence, and writes nothing", function()
    local root = tmp_root()

    assert.is_false(verdicts.accept(root, proposal(), { by = "S", date = "22.10.2026" }))
    assert.is_false(verdicts.accept(root, proposal(), { by = "S", note = "a\nb" }))
    assert.is_false(verdicts.accept(root, proposal(), { by = "S", evidence = { { file = "../x.lua" } } }))
    assert.is_false(verdicts.accept(root, proposal(), { by = "S", evidence = { { file = "src/**/*.lua" } } }))
    assert.is_false(verdicts.accept(root, proposal(), { by = "S", evidence = { { file = "a.lua", line = 0 } } }))
    assert.are.equal(0, vim.fn.filereadable(verdicts.path(root)))
  end)

  it("stops on an existing file it cannot use instead of overwriting it", function()
    local root = tmp_root()
    vim.fn.writefile({ "{ not json" }, verdicts.path(root))

    local ok, err = verdicts.accept(root, proposal(), ACCEPT)

    assert.is_false(ok)
    assert.is_truthy(err:find("could not parse", 1, true))
    assert.are.same({ "{ not json" }, vim.fn.readfile(verdicts.path(root)))
  end)

  it("does not write through a link", function()
    local root = tmp_root()
    vim.fn.writefile({ "{}" }, root .. "/elsewhere.json")
    local linked = vim.uv.fs_symlink(root .. "/elsewhere.json", verdicts.path(root))
    if not linked then
      pending("symlink creation not permitted on this machine")
      return
    end

    local ok, err = verdicts.accept(root, proposal(), ACCEPT)

    assert.is_false(ok)
    assert.is_truthy(err:find("link", 1, true))
    assert.are.same({ "{}" }, vim.fn.readfile(root .. "/elsewhere.json"))
  end)
end)

describe("rules.engine.verdicts.load", function()
  it("reads a missing file as no verdicts", function()
    local loaded, err = verdicts.load(tmp_root())

    assert.are.same({}, loaded)
    assert.is_nil(err)
  end)

  it("reports a broken file as an error, never as no verdicts", function()
    local cases = {
      "{ nope",
      '["DEP-01"]',
      '{"DEP-01": "fine"}',
      '{"DEP-01": {"verdict": "unclear", "date": "2026-10-22", "by": "S"}}',
      '{"DEP-01": {"verdict": "compliant", "date": "2026-13-40", "by": "S"}}',
      '{"DEP-01": {"verdict": "compliant", "date": "2026-10-22"}}',
      '{"DEP-01": {"verdict": "compliant", "date": "2026-10-22", "by": "S", "extra": 1}}',
      '{"DEP-01": {"verdict": "compliant", "date": "2026-10-22", "by": "S", "evidence": [{"file": "/abs.lua"}]}}',
      '{"DEP-01": {"verdict": "compliant", "date": "2026-10-22", "by": "S", "evidence": [{"file": "a.lua", "line": "3"}]}}',
      '{"DEP-01": {"verdict": "compliant", "date": "2026-10-22", "by": "S", "evidence": "a.lua"}}',
      '{"DEP-01": {"verdict": "compliant", "date": "2026-10-22", "by": "S", "from_proposal": {"status": "unclear"}}}',
      '{"DEP-01": {"verdict": "compliant", "date": "2026-10-22", "by": "S", "note": "a\\nb"}}',
      '{"DEP-01": null}',
    }

    for _, text in ipairs(cases) do
      local root = tmp_root()
      vim.fn.writefile({ text }, verdicts.path(root))
      local loaded, err = verdicts.load(root)
      assert.are.same({}, loaded, text)
      assert.is_string(err, text)
    end
  end)

  it("reports a folder where the file belongs as an error", function()
    local root = tmp_root()
    vim.fn.mkdir(verdicts.path(root), "p")

    local _, err = verdicts.load(root)

    assert.is_string(err)
  end)

  it("reads a file with a byte order mark", function()
    local root = tmp_root()
    vim.fn.writefile(
      { "\239\187\191" .. entry_json({ ["DEP-01"] = { verdict = "compliant", date = "2026-10-22", by = "S" } }) },
      verdicts.path(root)
    )

    local loaded, err = verdicts.load(root)

    assert.is_nil(err)
    assert.are.equal("compliant", loaded["DEP-01"].verdict)
  end)

  it("caps the number of verdicts", function()
    local doc = {}
    for n = 1, verdicts.MAX_VERDICTS + 1 do
      doc["R-" .. n] = { verdict = "compliant", date = "2026-10-22", by = "S" }
    end

    local entries, err = verdicts.parse(entry_json(doc), "f")

    assert.is_nil(entries)
    assert.is_truthy(err:find("more than", 1, true))
  end)
end)

describe("rules.engine.verdicts.orphaned", function()
  it("lists the verdicts of rules that no longer exist, sorted", function()
    local entries = {
      ["B-02"] = { verdict = "compliant" },
      ["A-01"] = { verdict = "compliant" },
      ["C-03"] = { verdict = "compliant" },
    }

    assert.are.same({ "A-01", "B-02" }, verdicts.orphaned(entries, { { id = "C-03" } }))
  end)
end)

describe("rules.engine.verdicts.stale", function()
  local entries = {
    ["A-01"] = {
      verdict = "compliant",
      date = "2026-10-10",
      by = "S",
      evidence = { { file = "lua/a.lua" }, { file = "lua/b.lua", line = 2 } },
    },
    ["B-01"] = { verdict = "violation", date = "2026-10-10", by = "S", evidence = {} },
  }

  it("calls a verdict stale when a file of its evidence changed after the day it was accepted", function()
    local stale = verdicts.stale(entries, { files = { ["lua/b.lua"] = "2026-10-11" } })

    assert.are.same({ { id = "A-01", reasons = { "file lua/b.lua changed 2026-10-11" } } }, stale)
  end)

  it("calls it stale when the text of the rule changed after that day", function()
    local stale = verdicts.stale(entries, { rules = { ["B-01"] = "2026-10-12" } })

    assert.are.same({ { id = "B-01", reasons = { "rule changed 2026-10-12" } } }, stale)
  end)

  it("keeps a verdict current when the change is on the same day or before", function()
    local stale = verdicts.stale(entries, {
      files = { ["lua/a.lua"] = "2026-10-10", ["lua/b.lua"] = "2026-10-01" },
      rules = { ["A-01"] = "2026-10-10" },
    })

    assert.are.same({}, stale)
  end)

  it("ignores changes of files the evidence does not name, and says everything that changed, sorted by id", function()
    local stale = verdicts.stale(entries, {
      files = { ["lua/other.lua"] = "2026-11-01", ["lua/a.lua"] = "2026-10-20" },
      rules = { ["A-01"] = "2026-10-15", ["B-01"] = "2026-10-15" },
    })

    assert.are.equal(2, #stale)
    assert.are.equal("A-01", stale[1].id)
    assert.are.same({ "rule changed 2026-10-15", "file lua/a.lua changed 2026-10-20" }, stale[1].reasons)
    assert.are.equal("B-01", stale[2].id)
  end)

  it("needs no changes at all", function()
    assert.are.same({}, verdicts.stale(entries, {}))
  end)
end)
