-- TESTS/waiver_ops_spec.lua -- `rules-ops/1` waive, renew, remove and the `rules.waivers` document: the project, the
-- file, compare-and-set, the lock, the inverse, no path of this machine; and `scripts/ruleset.lua check --waivers`.
--
-- The date is always `opts.today` (a fixed day): nothing here depends on the real one.
---@diagnostic disable: need-check-nil
local etag = require("lib.nvim.fs.etag")
local waivers = require("rules.engine.waivers")
-- loaded here, with the other modules the specs name: its first load sets variables of the environment (lib.nvim roots)
require("rules.ops")
require("rules.api")

local TODAY = "2030-10-15"

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param path string
---@return string|nil
local function read_raw(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
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
    "#### `" .. id .. "` — a rule",
    "",
    "Text of " .. id .. ".",
    "",
    "---",
    "",
  }, "\n")
end

---@class Spec.Fixture
---@field ruleset string
---@field project string
---@field file string  the waivers file of the project
---@field opts table

---@return Spec.Fixture
local function fixture()
  local base = tmp_dir()
  local ruleset = base .. "/ruleset/Checklists"
  write_raw(ruleset .. "/_rules/DEP/DEP-01.md", rule_file("DEP-01"))
  write_raw(ruleset .. "/_rules/DEP/DEP-02.md", rule_file("DEP-02"))
  write_raw(ruleset .. "/_rules/ERR/ERR-01.md", rule_file("ERR-01"))
  local project = base .. "/project"
  vim.fn.mkdir(project, "p")
  return {
    ruleset = ruleset,
    project = project,
    file = project .. "/.rules-waivers.json",
    opts = { rulesets = { ruleset }, project = project, today = TODAY },
  }
end

---@param opts table
---@param list table[]
---@param extra? table
---@return table doc
local function run(opts, list, extra)
  local ops = require("rules.ops")
  local doc, err = ops.run(vim.tbl_extend("force", { ops = list }, extra or {}), opts)
  assert(doc, vim.inspect(err))
  return doc
end

---@param opts table
---@param op table
---@param extra? table
---@return table entry
local function one(opts, op, extra)
  return run(opts, { op }, extra).results[1]
end

---@param entry table
---@param code string
local function refused(entry, code)
  assert.is_false(entry.ok, vim.inspect(entry))
  assert.are.equal(code, entry.error.code, vim.inspect(entry))
end

---Assert that a text names none of the folders, in any spelling (slashes either way, the real path).
---@param text string
---@param ... string
local function assert_no_path(text, ...)
  for _, path in ipairs({ ... }) do
    for _, p in ipairs({ path, vim.uv.fs_realpath(path) }) do
      local forward = (p:gsub("\\", "/"))
      local back = (forward:gsub("/", "\\"))
      assert.is_nil(text:find(forward, 1, true), "the text names " .. forward)
      assert.is_nil(text:find(back, 1, true), "the text names " .. back)
    end
  end
end

---The files of a folder, sorted (a temp file or a lock left behind shows here).
---@param dir string
---@return string[]
local function listing(dir)
  local out = {}
  for name in vim.fs.dir(dir) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

describe("rules-ops/1 waive", function()
  it("writes the waiver to the project's file, canonically, and answers with both etags and the inverse", function()
    local fx = fixture()

    local entry = one(
      fx.opts,
      { op = "waive", id = "DEP-01", reason = "legacy call site", expires = "2030-12-31", paths = { "src", "docs/**/*.md" } }
    )

    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("waived", entry.outcome)
    local text = read_raw(fx.file)
    assert.are.equal(
      table.concat({
        "{",
        '  "DEP-01": {',
        '    "expires": "2030-12-31",',
        '    "paths": [',
        '      "src",',
        '      "docs/**/*.md"',
        "    ],",
        '    "reason": "legacy call site"',
        "  }",
        "}",
        "",
      }, "\n"),
      text
    )
    assert.are.equal(etag.of(""), entry.etag_before)
    assert.are.equal(etag.of(text), entry.etag_after)
    assert.are.same({ "DEP-01" }, entry.changed_ids)
    assert.are.same({ op = "remove", id = "DEP-01", if_match = entry.etag_after }, entry.inverse)
    -- the loader reads what the writer wrote
    local entries, err = waivers.load_entries(fx.project)
    assert.is_nil(err)
    assert.are.same({ reason = "legacy call site", expires = "2030-12-31", paths = { "src", "docs/**/*.md" } }, entries["DEP-01"])
  end)

  it("a waiver with only a reason is written in the short form, the one every older tool reads", function()
    local fx = fixture()

    one(fx.opts, { op = "waive", id = "DEP-01", reason = "just because" })

    assert.are.equal('{\n  "DEP-01": "just because"\n}\n', read_raw(fx.file))
  end)

  it("keeps the waivers that were there: their meaning, in whichever form they were", function()
    local fx = fixture()
    write_raw(fx.file, '{"ERR-01": "old form", "DEP-02": {"reason": "dated", "expires": "2031-01-01"}}')

    one(fx.opts, { op = "waive", id = "DEP-01", reason = "new" })

    local entries = waivers.load_entries(fx.project)
    assert.are.same({ reason = "old form" }, entries["ERR-01"])
    assert.are.same({ reason = "dated", expires = "2031-01-01" }, entries["DEP-02"])
    assert.are.same({ reason = "new" }, entries["DEP-01"])
    -- a waiver with only a reason stays a text
    assert.matches('"ERR%-01": "old form"', read_raw(fx.file))
  end)

  it("the inverse (remove) puts the file back to what the waive found", function()
    local fx = fixture()
    write_raw(fx.file, '{\n  "ERR-01": "old form"\n}\n')
    local before = read_raw(fx.file)

    local entry = one(fx.opts, { op = "waive", id = "DEP-01", reason = "new", expires = "2030-11-01" })
    local undo = one(fx.opts, entry.inverse)

    assert.is_true(undo.ok, vim.inspect(undo))
    assert.are.equal("removed", undo.outcome)
    assert.are.equal(before, read_raw(fx.file))
  end)

  it("dry_run answers with the file before and after and writes nothing", function()
    local fx = fixture()

    local entry = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r" }, { dry_run = true })

    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("would_waive", entry.outcome)
    assert.are.equal("", entry.diff.before)
    assert.are.equal('{\n  "DEP-01": "r"\n}\n', entry.diff.after)
    assert.is_nil(entry.inverse)
    assert.is_nil(read_raw(fx.file))
    assert.are.same({}, listing(fx.project))
  end)

  it("a rule id no ruleset has is invalid_argument and nothing is written", function()
    local fx = fixture()

    local entry = one(fx.opts, { op = "waive", id = "NOPE-99", reason = "r" })

    refused(entry, "invalid_argument")
    assert.matches("NOPE%-99", entry.error.message)
    assert.is_nil(read_raw(fx.file))
  end)

  it("a waiver for a rule that is gone from the rulesets can still be renewed and removed", function()
    local fx = fixture()
    write_raw(fx.file, '{"OLD-07": "rule was retired"}')

    local renewed = one(fx.opts, { op = "renew", id = "OLD-07", expires = "2031-01-01" })
    local removed = one(fx.opts, { op = "remove", id = "OLD-07" })

    assert.is_true(renewed.ok, vim.inspect(renewed))
    assert.is_true(removed.ok, vim.inspect(removed))
    assert.are.same({}, waivers.load_entries(fx.project))
  end)

  it("needs an id and a reason, a reason that says something, on one line", function()
    local fx = fixture()
    refused(one(fx.opts, { op = "waive", id = "DEP-01" }), "invalid_argument")
    refused(one(fx.opts, { op = "waive", reason = "r" }), "invalid_argument")
    refused(one(fx.opts, { op = "waive", id = "DEP-01", reason = "   " }), "invalid_argument")
    refused(one(fx.opts, { op = "waive", id = "DEP-01", reason = "two\nlines" }), "invalid_argument")
    refused(one(fx.opts, { op = "waive", id = "DEP-01", reason = "bell\7" }), "invalid_argument")
    refused(one(fx.opts, { op = "waive", id = "DEP-01", reason = string.rep("x", 501) }), "invalid_argument")
    assert.is_nil(read_raw(fx.file))
  end)

  it("a date that is none is invalid_argument: not real, with a time, with a zone, the wrong shape", function()
    local fx = fixture()
    local dates = { "2030-02-30", "2031-02-29", "2030-10-15T10:00:00", "2030-10-15Z", "15.10.2026", "2030-1-5", "soon" }
    for _, date in ipairs(dates) do
      refused(one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", expires = date }), "invalid_argument")
    end
    assert.is_nil(read_raw(fx.file))
  end)

  it("a date in the past is taken, with a warning: it is expired from the start", function()
    local fx = fixture()

    local entry = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", expires = "2030-10-14" })

    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal(1, #entry.warnings)
    assert.matches("expired", entry.warnings[1])
    -- today itself is a day it is valid through: no warning
    local ok = one(fx.opts, { op = "waive", id = "DEP-02", reason = "r", expires = TODAY })
    assert.is_nil(ok.warnings)
  end)

  it("paths that are not relative, not clean or empty are invalid_argument", function()
    local fx = fixture()
    for _, paths in ipairs({
      { "../x" },
      { "src/../../x" },
      { "/etc" },
      { "C:/x" },
      { "src\\a" },
      { "" },
      {},
      { "a", "a" },
      { "{x" },
    }) do
      refused(one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", paths = paths }), "invalid_argument")
    end
    assert.is_nil(read_raw(fx.file))
  end)

  it("a request that gives paths as a text, not a list, is refused before anything runs", function()
    local fx = fixture()
    local doc, err = require("rules.ops").run({ ops = { { op = "waive", id = "DEP-01", reason = "r", paths = "src" } } }, fx.opts)
    assert.is_nil(doc)
    assert.are.equal("invalid_argument", err.code)
    assert.matches("paths", err.message)
  end)

  it("the same waiver again is unchanged and writes nothing; another one for the id says to renew", function()
    local fx = fixture()
    one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", expires = "2030-12-31" })
    local bytes = read_raw(fx.file)

    local again = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", expires = "2030-12-31" })
    local other = one(fx.opts, { op = "waive", id = "DEP-01", reason = "another" })

    assert.is_true(again.ok, vim.inspect(again))
    assert.are.equal("unchanged", again.outcome)
    assert.are.equal(again.etag_before, again.etag_after)
    assert.is_nil(again.inverse)
    refused(other, "invalid_argument")
    assert.matches("renew", other.error.message)
    assert.are.equal(bytes, read_raw(fx.file))
  end)

  it("holds the cap of waivers in a file", function()
    local fx = fixture()
    local parts = {}
    for i = 1, waivers.MAX_WAIVERS do
      parts[#parts + 1] = ('"OLD-%d": "r"'):format(i)
    end
    write_raw(fx.file, "{" .. table.concat(parts, ",") .. "}")

    local entry = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r" })

    refused(entry, "payload_too_large")
  end)
end)

describe("rules-ops/1 waive: compare-and-set", function()
  it("if_match is the etag of the file: a project without one has the etag of an empty file", function()
    local fx = fixture()

    local entry = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", if_match = etag.of("") })

    assert.is_true(entry.ok, vim.inspect(entry))
  end)

  it("another version is a conflict with expected and actual, and nothing is written", function()
    local fx = fixture()
    write_raw(fx.file, '{"ERR-01": "r"}')
    local bytes = read_raw(fx.file)

    local entry = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", if_match = etag.of("something else") })

    assert.is_false(entry.ok)
    assert.are.equal("conflict", entry.outcome)
    assert.are.equal("conflict", entry.error.code)
    assert.are.equal(etag.of("something else"), entry.error.details.expected)
    assert.are.equal(etag.of(bytes), entry.error.details.actual)
    assert.are.equal(bytes, read_raw(fx.file))
  end)

  it("a chain of replays works: each answer's etag_after is the next if_match", function()
    local fx = fixture()
    local a = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r" })
    local b = one(fx.opts, { op = "waive", id = "DEP-02", reason = "r", if_match = a.etag_after })
    local c = one(fx.opts, { op = "remove", id = "DEP-01", if_match = b.etag_after })
    local stale = one(fx.opts, { op = "remove", id = "DEP-02", if_match = a.etag_after })

    assert.is_true(c.ok, vim.inspect(c))
    refused(stale, "conflict")
  end)
end)

describe("rules-ops/1 renew", function()
  ---@return Spec.Fixture
  local function with_waiver()
    local fx = fixture()
    one(fx.opts, { op = "waive", id = "DEP-01", reason = "legacy", expires = "2030-10-01", paths = { "src" } })
    return fx
  end

  it("gives a waiver a new last day and keeps the reason and the paths", function()
    local fx = with_waiver()

    local entry = one(fx.opts, { op = "renew", id = "DEP-01", expires = "2031-04-01" })

    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("renewed", entry.outcome)
    assert.are.same({ reason = "legacy", expires = "2031-04-01", paths = { "src" } }, waivers.load_entries(fx.project)["DEP-01"])
    assert.are.same({ expires = "2030-10-01" }, entry.before)
  end)

  it("takes a new reason too", function()
    local fx = with_waiver()

    local entry = one(fx.opts, { op = "renew", id = "DEP-01", expires = "2031-04-01", reason = "ticket 4711" })

    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("ticket 4711", waivers.load_entries(fx.project)["DEP-01"].reason)
    assert.are.same({ expires = "2030-10-01", reason = "legacy" }, entry.before)
  end)

  it("renewing an expired waiver is the use case: it needs no warning", function()
    local fx = with_waiver()

    local entry = one(fx.opts, { op = "renew", id = "DEP-01", expires = "2031-04-01" })

    assert.is_nil(entry.warnings)
  end)

  it("the inverse puts the old last day back, also one that is expired", function()
    local fx = with_waiver()
    local before = read_raw(fx.file)

    local entry = one(fx.opts, { op = "renew", id = "DEP-01", expires = "2031-04-01", reason = "ticket 4711" })
    local undo = one(fx.opts, entry.inverse)

    assert.is_true(undo.ok, vim.inspect(undo))
    assert.are.equal(before, read_raw(fx.file))
  end)

  it("no_expiry takes the last day away, and its inverse gives it back; a waiver that had none gets it back as none", function()
    local fx = with_waiver()
    local before = read_raw(fx.file)

    local entry = one(fx.opts, { op = "renew", id = "DEP-01", no_expiry = true })
    assert.is_true(entry.ok, vim.inspect(entry))
    assert.is_nil(waivers.load_entries(fx.project)["DEP-01"].expires)
    one(fx.opts, entry.inverse)
    assert.are.equal(before, read_raw(fx.file))

    -- a waiver in the short form: renew gives it a day, the inverse takes it away again
    write_raw(fx.file, '{\n  "DEP-02": "plain"\n}\n')
    local dated = one(fx.opts, { op = "renew", id = "DEP-02", expires = "2031-01-01" })
    assert.are.same({ no_expiry = true }, dated.before)
    assert.are.same({ op = "renew", id = "DEP-02", no_expiry = true, if_match = dated.etag_after }, dated.inverse)
    one(fx.opts, dated.inverse)
    assert.are.equal('{\n  "DEP-02": "plain"\n}\n', read_raw(fx.file))
  end)

  it("a waiver that is not there is not_found", function()
    local fx = with_waiver()

    refused(one(fx.opts, { op = "renew", id = "DEP-02", expires = "2031-04-01" }), "not_found")
  end)

  it("needs a new day or no_expiry, not both, and a real date", function()
    local fx = with_waiver()
    refused(one(fx.opts, { op = "renew", id = "DEP-01" }), "invalid_argument")
    refused(one(fx.opts, { op = "renew", id = "DEP-01", expires = "2031-04-01", no_expiry = true }), "invalid_argument")
    refused(one(fx.opts, { op = "renew", id = "DEP-01", expires = "2031-02-29" }), "invalid_argument")
    refused(one(fx.opts, { op = "renew", id = "DEP-01", expires = "2031-04-01T00:00" }), "invalid_argument")
    refused(one(fx.opts, { op = "renew", id = "DEP-01", expires = "2031-04-01", reason = "a\nb" }), "invalid_argument")
    refused(one(fx.opts, { op = "renew", id = "DEP-01", expires = "2031-04-01", reason = "  " }), "invalid_argument")
  end)

  it("the same values again are unchanged", function()
    local fx = with_waiver()
    local bytes = read_raw(fx.file)

    local entry = one(fx.opts, { op = "renew", id = "DEP-01", expires = "2030-10-01", reason = "legacy" })

    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("unchanged", entry.outcome)
    assert.are.equal(bytes, read_raw(fx.file))
  end)

  it("honours if_match and dry_run", function()
    local fx = with_waiver()
    local bytes = read_raw(fx.file)

    refused(one(fx.opts, { op = "renew", id = "DEP-01", expires = "2031-04-01", if_match = etag.of("x") }), "conflict")
    local dry = one(fx.opts, { op = "renew", id = "DEP-01", expires = "2031-04-01" }, { dry_run = true })

    assert.are.equal("would_renew", dry.outcome)
    assert.matches('"expires": "2031%-04%-01"', dry.diff.after)
    assert.are.equal(bytes, dry.diff.before)
    assert.are.equal(bytes, read_raw(fx.file))
  end)
end)

describe("rules-ops/1 remove", function()
  it("drops the waiver and answers with what it was; the inverse waives it again with the same values", function()
    local fx = fixture()
    one(fx.opts, { op = "waive", id = "DEP-01", reason = "legacy", expires = "2030-12-31", paths = { "src", "lib/*.lua" } })
    one(fx.opts, { op = "waive", id = "DEP-02", reason = "kept" })
    local before = read_raw(fx.file)

    local entry = one(fx.opts, { op = "remove", id = "DEP-01" })

    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("removed", entry.outcome)
    assert.are.same({ reason = "legacy", expires = "2030-12-31", paths = { "src", "lib/*.lua" } }, entry.before)
    assert.is_nil(waivers.load_entries(fx.project)["DEP-01"])
    assert.are.same({ reason = "kept" }, waivers.load_entries(fx.project)["DEP-02"])
    assert.are.equal("waive", entry.inverse.op)

    local undo = one(fx.opts, entry.inverse)
    assert.is_true(undo.ok, vim.inspect(undo))
    assert.are.equal(before, read_raw(fx.file))
  end)

  it("the last waiver leaves an empty file, which is a file with no waivers", function()
    local fx = fixture()
    one(fx.opts, { op = "waive", id = "DEP-01", reason = "r" })

    one(fx.opts, { op = "remove", id = "DEP-01" })

    assert.are.equal("{}\n", read_raw(fx.file))
    assert.are.same({}, waivers.load_entries(fx.project))
  end)

  it("a waiver that is not there is not_found, in a project with no file as well", function()
    local fx = fixture()

    refused(one(fx.opts, { op = "remove", id = "DEP-01" }), "not_found")
    assert.is_nil(read_raw(fx.file))
  end)

  it("honours dry_run and if_match", function()
    local fx = fixture()
    one(fx.opts, { op = "waive", id = "DEP-01", reason = "r" })
    local bytes = read_raw(fx.file)

    local dry = one(fx.opts, { op = "remove", id = "DEP-01" }, { dry_run = true })
    refused(one(fx.opts, { op = "remove", id = "DEP-01", if_match = etag.of("x") }), "conflict")

    assert.are.equal("would_remove", dry.outcome)
    assert.are.equal("{}\n", dry.diff.after)
    assert.are.equal(bytes, read_raw(fx.file))
  end)
end)

describe("rules-ops/1 waivers: the request", function()
  it("one request may waive, renew and remove, each on the file the one before left", function()
    local fx = fixture()

    local doc = run(fx.opts, {
      { op = "waive", id = "DEP-01", reason = "r" },
      { op = "renew", id = "DEP-01", expires = "2031-01-01" },
      { op = "waive", id = "DEP-02", reason = "r2" },
      { op = "remove", id = "DEP-01" },
    }, { client_op_id = "c-9" })

    assert.is_true(doc.ok, vim.inspect(doc))
    assert.are.equal("c-9", doc.client_op_id)
    assert.are.same(
      { "waived", "renewed", "waived", "removed" },
      vim.tbl_map(function(r)
        return r.outcome
      end, doc.results)
    )
    assert.are.equal('{\n  "DEP-02": "r2"\n}\n', read_raw(fx.file))
  end)

  it("one that fails does not stop the others, and ok is false", function()
    local fx = fixture()

    local doc = run(fx.opts, {
      { op = "waive", id = "NOPE-1", reason = "r" },
      { op = "waive", id = "DEP-01", reason = "r" },
    })

    assert.is_false(doc.ok)
    assert.is_false(doc.results[1].ok)
    assert.is_true(doc.results[2].ok)
  end)

  it("an unknown field of an operation refuses the whole request", function()
    local fx = fixture()
    local doc, err = require("rules.ops").run({ ops = { { op = "waive", id = "DEP-01", reason = "r", until_ = "x" } } }, fx.opts)
    assert.is_nil(doc)
    assert.are.equal("invalid_argument", err.code)
    local doc2, err2 = require("rules.ops").run({ ops = { { op = "remove", id = "DEP-01", reason = "r" } } }, fx.opts)
    assert.is_nil(doc2)
    assert.are.equal("invalid_argument", err2.code)
  end)

  it("an engine date that is none is invalid_argument for the whole request", function()
    local fx = fixture()
    local opts = vim.tbl_extend("force", fx.opts, { today = "2030-02-30" })
    local doc, err = require("rules.ops").run({ ops = { { op = "waive", id = "DEP-01", reason = "r" } } }, opts)
    assert.is_nil(doc)
    assert.are.equal("invalid_argument", err.code)
  end)

  it("leaves nothing behind: no lock, no temporary file", function()
    local fx = fixture()

    one(fx.opts, { op = "waive", id = "DEP-01", reason = "r" })
    one(fx.opts, { op = "renew", id = "DEP-01", expires = "2031-01-01" })

    assert.are.same({ ".rules-waivers.json" }, listing(fx.project))
  end)

  it("does not touch the rulesets: no lock file there, no catalog made", function()
    local fx = fixture()
    local before = listing(fx.ruleset)

    local entry = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r" })

    assert.are.same(before, listing(fx.ruleset))
    assert.is_nil(entry.catalog)
  end)

  it("a lock held by someone else is locked and retryable, and names no path", function()
    local fx = fixture()
    write_raw(fx.project .. "/..rules-waivers.json.lock", tostring(vim.uv.os_getpid()) .. "\nheld")

    local entry = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r" })

    refused(entry, "locked")
    assert.is_true(entry.error.retryable)
    assert_no_path(entry.error.message, fx.project)
    assert.is_nil(entry.error.message:find("[/\\]"))
    assert.is_nil(read_raw(fx.file))
  end)

  it("is the waivers door of the api too: a flat request with project", function()
    local fx = fixture()
    local api = require("rules.api")
    local request = vim.json.encode({ ops = { { op = "waive", id = "DEP-01", reason = "r", project = fx.project } } })

    local text, code = api.call("ops", request, { rulesets = { fx.ruleset }, today = TODAY })

    assert.is_nil(code)
    assert.are.equal("waived", vim.json.decode(text).results[1].outcome)
    assert.are.same({ reason = "r" }, waivers.load_entries(fx.project)["DEP-01"])
  end)
end)

describe("rules-ops/1 waivers: the project", function()
  it("is the configured project by default", function()
    local fx = fixture()
    assert.is_true(one(fx.opts, { op = "waive", id = "DEP-01", reason = "r" }).ok)
    assert.is_not_nil(read_raw(fx.file))
  end)

  it("with none configured and none given it is invalid_argument", function()
    local fx = fixture()
    local opts = { rulesets = fx.opts.rulesets, today = TODAY }

    local entry = one(opts, { op = "waive", id = "DEP-01", reason = "r" })

    refused(entry, "invalid_argument")
    assert.matches("project", entry.error.message)
  end)

  it("with none configured, a given absolute folder is the project", function()
    local fx = fixture()
    local opts = { rulesets = fx.opts.rulesets, today = TODAY }

    local entry = one(opts, { op = "waive", id = "DEP-01", reason = "r", project = fx.project })

    assert.is_true(entry.ok, vim.inspect(entry))
    assert.is_not_nil(read_raw(fx.file))
  end)

  it("a relative project starts at the configured one; a folder in it is fine", function()
    local fx = fixture()
    vim.fn.mkdir(fx.project .. "/packages/app", "p")

    local entry = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", project = "packages/app" })

    assert.is_true(entry.ok, vim.inspect(entry))
    assert.is_not_nil(read_raw(fx.project .. "/packages/app/.rules-waivers.json"))
    assert.is_nil(read_raw(fx.file))
  end)

  it("a path that climbs with .. is refused, relative or absolute", function()
    local fx = fixture()
    vim.fn.mkdir(fx.project .. "/inner", "p")
    for _, project in ipairs({ "..", "../elsewhere", "inner/../..", fx.project .. "/inner/..", fx.project .. "/../x" }) do
      refused(one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", project = project }), "invalid_argument")
    end
    assert.is_nil(read_raw(fx.file))
  end)

  it("another folder than the configured project (or one inside it) is refused", function()
    local fx = fixture()
    local elsewhere = tmp_dir()

    local entry = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", project = elsewhere })

    refused(entry, "invalid_argument")
    assert.is_nil(read_raw(elsewhere .. "/.rules-waivers.json"))
    assert_no_path(entry.error.message, elsewhere, fx.project)
  end)

  it("a project that is not a folder is not_found", function()
    local fx = fixture()
    write_raw(fx.project .. "/afile", "x")

    refused(one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", project = "missing" }), "not_found")
    refused(one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", project = "afile" }), "not_found")
  end)

  it("the way the project is spelled does not matter: a trailing slash, a . segment", function()
    local fx = fixture()

    local a = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", project = fx.project .. "/" })
    local b = one(fx.opts, { op = "waive", id = "DEP-02", reason = "r", project = fx.project .. "/./" })

    assert.is_true(a.ok, vim.inspect(a))
    assert.is_true(b.ok, vim.inspect(b))
    assert.are.same({ "DEP-01", "DEP-02" }, vim.tbl_keys(waivers.load_entries(fx.project)))
  end)

  it("a folder inside a ruleset is refused, also when it is reached through a different spelling", function()
    local fx = fixture()
    local opts = { rulesets = fx.opts.rulesets, today = TODAY }

    local inside = one(opts, { op = "waive", id = "DEP-01", reason = "r", project = fx.ruleset .. "/_rules" })
    local same = one(opts, { op = "waive", id = "DEP-01", reason = "r", project = fx.ruleset .. "/" })
    local spelled = one(opts, { op = "waive", id = "DEP-01", reason = "r", project = fx.ruleset .. "/_rules/DEP/.." })

    refused(inside, "invalid_argument")
    refused(same, "invalid_argument")
    refused(spelled, "invalid_argument")
    assert.matches("ruleset", inside.error.message)
    assert.is_nil(read_raw(fx.ruleset .. "/.rules-waivers.json"))
  end)

  it("a ruleset folder that IS the configured project is allowed (a vault checks itself)", function()
    local fx = fixture()
    local opts = { rulesets = fx.opts.rulesets, project = fx.ruleset, today = TODAY }

    local entry = one(opts, { op = "waive", id = "DEP-01", reason = "r" })

    assert.is_true(entry.ok, vim.inspect(entry))
    assert.is_not_nil(read_raw(fx.ruleset .. "/.rules-waivers.json"))
  end)

  it("a project that holds the ruleset (the ruleset in its tree) is fine", function()
    local base = tmp_dir()
    local ruleset = base .. "/rules/Checklists"
    write_raw(ruleset .. "/_rules/DEP/DEP-01.md", rule_file("DEP-01"))
    local opts = { rulesets = { ruleset }, project = base, today = TODAY }

    local entry = one(opts, { op = "waive", id = "DEP-01", reason = "r" })

    assert.is_true(entry.ok, vim.inspect(entry))
    assert.is_not_nil(read_raw(base .. "/.rules-waivers.json"))
  end)

  it("compares by real path: a project named through a link is the configured one", function()
    local fx = fixture()
    local link = tmp_dir() .. "/link"
    local made = pcall(function()
      assert(vim.uv.fs_symlink(fx.project, link, { dir = true }))
    end)
    if not made then
      pending("this machine cannot make a symbolic link")
      return
    end

    local entry = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", project = link })

    assert.is_true(entry.ok, vim.inspect(entry))
    assert.is_not_nil(read_raw(fx.file))
  end)

  it("a message names no path of this machine", function()
    local fx = fixture()
    local lines = {}
    for _, project in ipairs({ "missing", "..", tmp_dir(), fx.ruleset }) do
      local entry = one(fx.opts, { op = "waive", id = "DEP-01", reason = "r", project = project })
      refused(entry, entry.error.code)
      lines[#lines + 1] = entry.error.message
    end
    local text = table.concat(lines, "\n")
    assert_no_path(text, fx.project, fx.ruleset, vim.fs.dirname(fx.project))
  end)
end)

describe("rules-ops/1 waivers: a file that cannot be used", function()
  for _, case in ipairs({
    { name = "is not JSON", text = "not json" },
    { name = "is a list", text = '["DEP-01"]' },
    { name = "has a bad date", text = '{"ERR-01": {"reason": "r", "expires": "2030-13-01"}}' },
    { name = "has an unknown key", text = '{"ERR-01": {"reason": "r", "until": "2030-12-01"}}' },
    { name = "is empty", text = "" },
  }) do
    it("waive, renew and remove refuse and leave a file that " .. case.name .. " as it is", function()
      local fx = fixture()
      write_raw(fx.file, case.text)

      for _, op in ipairs({
        { op = "waive", id = "DEP-01", reason = "r" },
        { op = "renew", id = "ERR-01", expires = "2031-01-01" },
        { op = "remove", id = "ERR-01" },
      }) do
        local entry = one(fx.opts, op)
        refused(entry, "invalid_argument")
        assert.matches("waivers file", entry.error.message)
        assert_no_path(entry.error.message, fx.project)
      end
      assert.are.equal(case.text, read_raw(fx.file))
    end)
  end

  it("a folder where the file belongs is refused", function()
    local fx = fixture()
    vim.fn.mkdir(fx.file, "p")

    refused(one(fx.opts, { op = "waive", id = "DEP-01", reason = "r" }), "invalid_argument")
  end)

  it("a link where the file belongs is forbidden: the write would replace the link", function()
    local fx = fixture()
    local target = tmp_dir() .. "/real.json"
    write_raw(target, "{}")
    local made = pcall(function()
      assert(vim.uv.fs_symlink(target, fx.file))
    end)
    if not made then
      pending("this machine cannot make a symbolic link")
      return
    end

    refused(one(fx.opts, { op = "waive", id = "DEP-01", reason = "r" }), "forbidden")
    assert.are.equal("{}", read_raw(target))
  end)
end)

describe("rules-ops/1 waivers: the file as the engine reads it", function()
  local api = require("rules.api")
  local BOM = "\239\187\191"

  ---@param target string
  ---@param link string
  ---@return boolean made
  local function symlink(target, link)
    return (pcall(function()
      assert(vim.uv.fs_symlink(target, link))
    end))
  end

  it("a file with a byte order mark is usable by the door and the document, as it is by the engine", function()
    local fx = fixture()
    write_raw(fx.file, BOM .. '{"ERR-01": "old form", "DEP-02": {"reason": "dated", "expires": "2031-01-01"}}')
    -- the engine reads it ...
    local entries, err = waivers.load_entries(fx.project)
    assert.is_nil(err)
    assert.are.same({ reason = "old form" }, entries["ERR-01"])

    -- ... so the document does ...
    local doc, code = vim.json.decode((api.call("waivers", nil, fx.opts))), nil
    assert.are.equal("rules.waivers", doc.kind, vim.inspect(doc))
    assert.are.same({ total = 2, expired = 0, unknown = 0 }, doc.counts)
    assert.are.equal(etag.of(read_raw(fx.file)), doc.etag, code)

    -- ... and so does the write door: waive, renew and remove all work, and the file comes out canonical (no mark)
    local waive = one(fx.opts, { op = "waive", id = "DEP-01", reason = "new" })
    assert.is_true(waive.ok, vim.inspect(waive))
    assert.are.equal(nil, read_raw(fx.file):find(BOM, 1, true))
    write_raw(fx.file, BOM .. read_raw(fx.file))
    local renew = one(fx.opts, { op = "renew", id = "DEP-02", expires = "2032-01-01" })
    assert.is_true(renew.ok, vim.inspect(renew))
    write_raw(fx.file, BOM .. read_raw(fx.file))
    local remove = one(fx.opts, { op = "remove", id = "ERR-01" })
    assert.is_true(remove.ok, vim.inspect(remove))
    local after = waivers.load_entries(fx.project)
    assert.are.same({ "DEP-01", "DEP-02" }, vim.fn.sort(vim.tbl_keys(after)))
  end)

  it("a link where the file belongs is read: the document lists it, only the write refuses", function()
    local fx = fixture()
    local target = tmp_dir() .. "/shared.json"
    write_raw(target, '{"DEP-01": {"reason": "shared by the monorepo", "expires": "2030-10-15"}}')
    if not symlink(target, fx.file) then
      pending("this machine cannot make a symbolic link")
      return
    end
    -- the engine follows the link ...
    local entries, err = waivers.load_entries(fx.project)
    assert.is_nil(err)
    assert.are.equal("shared by the monorepo", entries["DEP-01"].reason)

    -- ... so does the read-only document ...
    local text, code = api.call("waivers", nil, fx.opts)
    local doc = vim.json.decode(text)
    assert.is_nil(code, text)
    assert.are.equal("rules.waivers", doc.kind)
    assert.are.equal("DEP-01", doc.items[1].id)
    assert.is_true(doc.exists)
    assert.are.equal(etag.of(read_raw(target)), doc.etag)

    -- ... and a write still refuses, with the file the link points to untouched
    refused(one(fx.opts, { op = "renew", id = "DEP-01", expires = "2031-01-01" }), "forbidden")
    assert.are.equal('{"DEP-01": {"reason": "shared by the monorepo", "expires": "2030-10-15"}}', read_raw(target))
  end)

  it("a link that leads nowhere is a file that cannot be used, for the document too", function()
    local fx = fixture()
    if not symlink(tmp_dir() .. "/missing.json", fx.file) then
      pending("this machine cannot make a symbolic link")
      return
    end

    local doc, code = vim.json.decode((api.call("waivers", nil, fx.opts))), nil
    assert.are.equal("rules.error", doc.kind, code)
    assert.are.equal("invalid_argument", doc.code)
    assert_no_path(doc.message, fx.project)
  end)
end)

describe("rules-export/1 waivers", function()
  local api = require("rules.api")

  ---@param fx Spec.Fixture
  ---@param params? table
  ---@param opts? table
  ---@return table doc, string|nil code
  local function waivers_doc(fx, params, opts)
    local request = params and vim.json.encode({ params = params }) or nil
    local text, code = api.call("waivers", request, opts or fx.opts)
    return vim.json.decode(text), code
  end

  it("lists every waiver with expired and known, as of the day it is asked", function()
    local fx = fixture()
    write_raw(
      fx.file,
      [[{
        "DEP-01": "plain",
        "DEP-02": {"reason": "ran out", "expires": "2030-10-14"},
        "ERR-01": {"reason": "last day", "expires": "2030-10-15", "paths": ["src"]},
        "OLD-01": {"reason": "rule is gone", "expires": "2039-01-01"}
      }]]
    )

    local doc, code = waivers_doc(fx)

    assert.is_nil(code)
    assert.are.equal("rules.waivers", doc.kind)
    assert.are.equal(TODAY, doc.today)
    assert.are.equal(etag.of(read_raw(fx.file)), doc.etag)
    assert.is_true(doc.exists)
    assert.are.same({ total = 4, expired = 1, unknown = 1 }, doc.counts)
    assert.are.same({
      { expired = false, id = "DEP-01", known = true, reason = "plain" },
      { expired = true, expires = "2030-10-14", id = "DEP-02", known = true, reason = "ran out" },
      { expired = false, expires = "2030-10-15", id = "ERR-01", known = true, paths = { "src" }, reason = "last day" },
      { expired = false, expires = "2039-01-01", id = "OLD-01", known = false, reason = "rule is gone" },
    }, doc.items)
  end)

  it("expiry follows the day given, not the real one", function()
    local fx = fixture()
    write_raw(fx.file, '{"DEP-01": {"reason": "r", "expires": "2030-10-15"}}')

    local early = waivers_doc(fx, nil, vim.tbl_extend("force", fx.opts, { today = "2030-10-15" }))
    local late = waivers_doc(fx, nil, vim.tbl_extend("force", fx.opts, { today = "2030-10-16" }))

    assert.is_false(early.items[1].expired)
    assert.is_true(late.items[1].expired)
    assert.are_not.equal(early.digest, late.digest)
  end)

  it("a project with no file has no waivers and exists = false; the etag is that of an empty file", function()
    local fx = fixture()

    local doc = waivers_doc(fx)

    assert.is_false(doc.exists)
    assert.are.same({}, doc.items)
    assert.are.equal(etag.of(""), doc.etag)
  end)

  it("takes the project as a parameter, under the same rules as the operations", function()
    local fx = fixture()
    vim.fn.mkdir(fx.project .. "/sub", "p")
    write_raw(fx.project .. "/sub/.rules-waivers.json", '{"DEP-01": "in sub"}')

    local doc = waivers_doc(fx, { project = "sub" })
    local out, code = waivers_doc(fx, { project = tmp_dir() })

    assert.are.equal("in sub", doc.items[1].reason)
    assert.are.equal("rules.error", out.kind)
    assert.are.equal("invalid_argument", out.code)
    assert.is_not_nil(code)
  end)

  it("a file that cannot be used is an error document, never an empty list", function()
    local fx = fixture()
    write_raw(fx.file, '{"DEP-01": {"reason": "r", "expires": "tomorrow"}}')

    local doc, code = waivers_doc(fx)

    assert.is_not_nil(code)
    assert.are.equal("rules.error", doc.kind)
    assert.are.equal("invalid_argument", doc.code)
    assert.matches("waivers file", doc.message)
    assert_no_path(doc.message, fx.project)
  end)

  it("has no path of this machine, and is the same bytes twice", function()
    local fx = fixture()
    write_raw(fx.file, '{"DEP-01": {"reason": "r", "paths": ["src"]}}')
    local contract = require("rules.contract")
    local saved_clock = contract.clock
    contract.clock = function()
      return "2030-01-01T00:00:00Z"
    end

    local a = api.call("waivers", nil, fx.opts)
    local b = api.call("waivers", nil, fx.opts)
    contract.clock = saved_clock

    assert.are.equal(a, b)
    assert_no_path(a, fx.project, vim.fs.dirname(fx.project))
  end)

  it("an unknown parameter is refused, and hello lists the method and the operations", function()
    local fx = fixture()
    local bad = vim.json.decode((api.call("waivers", '{"params":{"folder":"x"}}', fx.opts)))
    local hello = vim.json.decode((api.call("hello", nil, fx.opts)))

    assert.are.equal("invalid_argument", bad.code)
    assert.is_true(vim.tbl_contains(hello.capabilities, "waivers"))
    assert.are.same({ "new", "set", "retire", "reinstate", "move", "waive", "renew", "remove" }, hello.ops)
  end)

  it("a waiver written by the door is in the document", function()
    local fx = fixture()
    one(fx.opts, { op = "waive", id = "DEP-02", reason = "via the door", expires = "2030-10-14" })

    local doc = waivers_doc(fx)

    assert.are.equal("DEP-02", doc.items[1].id)
    assert.is_true(doc.items[1].expired)
  end)
end)

describe("scripts/ruleset.lua check --waivers", function()
  local plugin_root = vim.fs.dirname(
    vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.api.nvim_get_runtime_file("lua/rules/contract.lua", false)[1])))
  )
  local script = plugin_root .. "/scripts/ruleset.lua"

  ---@param args string[]
  ---@return vim.SystemCompleted
  local function check(args)
    local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script, "check" }
    vim.list_extend(cmd, args)
    return vim.system(cmd, { text = true, env = { LIB_NVIM_DIR = vim.env.LIB_NVIM_DIR } }):wait(30000)
  end

  it("exits 1 on an expired waiver and 0 the day it is still valid; 1 on a file that cannot be used; 2 on wrong usage", function()
    if not vim.env.LIB_NVIM_DIR or vim.env.LIB_NVIM_DIR == "" then
      pending("LIB_NVIM_DIR is not set: the script cannot find lib.nvim")
      return
    end
    local fx = fixture()
    write_raw(fx.file, '{"DEP-01": {"reason": "legacy", "expires": "2030-10-15"}, "OLD-01": "gone"}')

    local valid = check({ "--waivers", "--today=2030-10-15", "--project=" .. fx.project, fx.ruleset })
    assert.are.equal(0, valid.code, valid.stdout .. valid.stderr)
    assert.matches("ok:", valid.stdout)
    assert.matches("OLD%-01 matches no loaded rule", valid.stdout)

    local expired = check({ "--waivers", "--today=2030-10-16", "--project=" .. fx.project, fx.ruleset })
    assert.are.equal(1, expired.code, expired.stdout .. expired.stderr)
    assert.matches("DEP%-01 ran out on 2030%-10%-15 %(legacy%)", expired.stdout)
    assert.matches("FAILED: 1 expired waiver", expired.stdout)

    -- without the flag the waivers are not looked at
    local plain = check({ "--project=" .. fx.project, fx.ruleset })
    assert.are.equal(0, plain.code, plain.stdout .. plain.stderr)

    write_raw(fx.file, "not json")
    local broken = check({ "--waivers", "--today=2030-10-15", "--project=" .. fx.project, fx.ruleset })
    assert.are.equal(1, broken.code, broken.stdout .. broken.stderr)
    assert.matches("FAILED: the waivers could not be read", broken.stdout)

    -- wrong usage: --waivers needs a project, --today needs --waivers
    assert.are.equal(2, check({ "--waivers", fx.ruleset }).code)
    assert.are.equal(2, check({ "--today=2030-10-15", "--project=" .. fx.project, fx.ruleset }).code)
  end)

  it("reads the waivers file through a link, and one with a byte order mark: the engine does", function()
    if not vim.env.LIB_NVIM_DIR or vim.env.LIB_NVIM_DIR == "" then
      pending("LIB_NVIM_DIR is not set: the script cannot find lib.nvim")
      return
    end
    local fx = fixture()
    local target = tmp_dir() .. "/shared.json"
    write_raw(target, "\239\187\191" .. '{"DEP-01": {"reason": "shared", "expires": "2030-10-15"}}')
    local made = pcall(function()
      assert(vim.uv.fs_symlink(target, fx.file))
    end)
    if not made then
      pending("this machine cannot make a symbolic link")
      return
    end

    local valid = check({ "--waivers", "--today=2030-10-15", "--project=" .. fx.project, fx.ruleset })
    assert.are.equal(0, valid.code, valid.stdout .. valid.stderr)
    assert.matches("ok:", valid.stdout)
    local expired = check({ "--waivers", "--today=2030-10-16", "--project=" .. fx.project, fx.ruleset })
    assert.are.equal(1, expired.code, expired.stdout .. expired.stderr)
    assert.matches("DEP%-01 ran out on 2030%-10%-15", expired.stdout)
  end)
end)
