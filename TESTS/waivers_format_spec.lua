-- TESTS/waivers_format_spec.lua -- the object form of `.rules-waivers.json` (reason, expires, paths), the expiry, the paths,
-- and what the run and the report make of them. The old map `{ "ID": "reason" }` is in TESTS/waivers_spec.lua.
--
-- Nothing here depends on the real date: the clock is `opts.today` or the `waivers.clock` seam.
---@diagnostic disable: need-check-nil
local waivers = require("rules.engine.waivers")
local runner = require("rules.engine.runner")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

---@param dir string
---@param text string
local function put(dir, text)
  local f = assert(io.open(dir .. "/.rules-waivers.json", "wb"))
  f:write(text)
  f:close()
end

---@param path string
---@param text string
local function write_file(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

describe("rules.engine.waivers.valid_date", function()
  it("takes a real calendar date, YYYY-MM-DD", function()
    for _, date in ipairs({ "2030-10-15", "2028-02-29", "2000-02-29", "2030-12-31", "0001-01-01" }) do
      assert.is_true(waivers.valid_date(date), date)
    end
  end)

  it("refuses a day the calendar does not have", function()
    for _, date in ipairs({ "2031-02-29", "1900-02-29", "2030-04-31", "2030-13-01", "2030-00-10", "2030-10-00", "0000-01-01" }) do
      assert.is_false(waivers.valid_date(date), date)
    end
  end)

  it("refuses any other spelling: no time, no time zone, no short fields, no other type", function()
    for _, date in ipairs({
      "2030-10-15T00:00:00Z",
      "2030-10-15T00:00",
      "2030-10-15Z",
      "2030-10-15+02:00",
      "2030-1-5",
      "26-10-15",
      "2026/10/15",
      " 2030-10-15",
      "2030-10-15 ",
      "20261015",
      "",
    }) do
      assert.is_false(waivers.valid_date(date), date)
    end
    assert.is_false(waivers.valid_date(20261015))
    assert.is_false(waivers.valid_date(nil))
    assert.is_false(waivers.valid_date(vim.NIL))
  end)
end)

describe("rules.engine.waivers clock", function()
  local saved
  before_each(function()
    saved = waivers.clock
  end)
  after_each(function()
    waivers.clock = saved
  end)

  it("today() is the clock, unless a date is given", function()
    waivers.clock = function()
      return "2031-03-04"
    end
    assert.are.equal("2031-03-04", (waivers.today(nil)))
    assert.are.equal("2030-10-15", (waivers.today("2030-10-15")))
  end)

  it("a date that is none is an error, not the clock", function()
    local today, err = waivers.today("2030-02-30")
    assert.is_nil(today)
    assert.matches("YYYY%-MM%-DD", err)
  end)

  it("the real clock answers a valid date", function()
    assert.is_true(waivers.valid_date(saved()))
  end)

  it("a waiver is valid through its last day and expired the day after", function()
    local entry = { reason = "r", expires = "2030-10-15" }
    assert.is_false(waivers.is_expired(entry, "2030-10-14"))
    assert.is_false(waivers.is_expired(entry, "2030-10-15"))
    assert.is_true(waivers.is_expired(entry, "2030-10-16"))
    assert.is_true(waivers.is_expired(entry, "2031-01-01"))
    assert.is_false(waivers.is_expired({ reason = "r" }, "2099-12-31"))
  end)

  it("expired() lists the ids that ran out, sorted", function()
    local entries = {
      ["B-02"] = { reason = "r", expires = "2030-01-01" },
      ["A-01"] = { reason = "r", expires = "2030-02-01" },
      ["C-03"] = { reason = "r", expires = "2030-10-15" },
      ["D-04"] = { reason = "r" },
    }
    assert.are.same({ "A-01", "B-02" }, waivers.expired(entries, "2030-10-15"))
  end)
end)

describe("rules.engine.waivers.load_entries: the object form", function()
  it("reads the old map and the object form side by side", function()
    local dir = tmp_dir()
    put(
      dir,
      [[{
        "DEP-01": "old form",
        "DEP-02": { "reason": "new form" },
        "DEP-03": { "reason": "dated", "expires": "2030-12-31" },
        "DEP-04": { "reason": "scoped", "paths": ["src", "docs/**/*.md"] },
        "DEP-05": { "reason": "both", "expires": "2031-02-28", "paths": ["lib/"] }
      }]]
    )

    local entries, err = waivers.load_entries(dir)

    assert.is_nil(err)
    assert.are.same({ reason = "old form" }, entries["DEP-01"])
    assert.are.same({ reason = "new form" }, entries["DEP-02"])
    assert.are.same({ reason = "dated", expires = "2030-12-31" }, entries["DEP-03"])
    assert.are.same({ reason = "scoped", paths = { "src", "docs/**/*.md" } }, entries["DEP-04"])
    assert.are.same({ reason = "both", expires = "2031-02-28", paths = { "lib/" } }, entries["DEP-05"])
  end)

  it("load() keeps its shape for existing callers: the reason text of every entry", function()
    local dir = tmp_dir()
    put(dir, '{"DEP-01": "old form", "DEP-03": {"reason": "dated", "expires": "2030-12-31"}}')

    local reasons, err = waivers.load(dir)

    assert.is_nil(err)
    assert.are.same({ ["DEP-01"] = "old form", ["DEP-03"] = "dated" }, reasons)
  end)

  -- every one of these is a file that exists and cannot be used: an error, never "no waivers"
  local BAD = {
    { name = "an unknown key", json = '{"DEP-01": {"reason": "r", "expiry": "2030-12-31"}}', match = "unknown key" },
    { name = "no reason", json = '{"DEP-01": {"expires": "2030-12-31"}}', match = "needs a reason" },
    { name = "an empty reason", json = '{"DEP-01": {"reason": "   "}}', match = "says something" },
    { name = "a reason that is no text", json = '{"DEP-01": {"reason": 5}}', match = "must be a text" },
    { name = "a multi-line reason", json = '{"DEP-01": {"reason": "a\\nb"}}', match = "newline" },
    { name = "a too long reason", json = '{"DEP-01": {"reason": "' .. string.rep("x", 501) .. '"}}', match = "exceeds" },
    {
      name = "a date with a time",
      json = '{"DEP-01": {"reason": "r", "expires": "2030-12-31T10:00:00"}}',
      match = "YYYY%-MM%-DD",
    },
    { name = "a date with a time zone", json = '{"DEP-01": {"reason": "r", "expires": "2030-12-31Z"}}', match = "YYYY%-MM%-DD" },
    { name = "a day the calendar lacks", json = '{"DEP-01": {"reason": "r", "expires": "2031-02-29"}}', match = "YYYY%-MM%-DD" },
    { name = "a date that is a number", json = '{"DEP-01": {"reason": "r", "expires": 20261231}}', match = "YYYY%-MM%-DD" },
    { name = "a date that is null", json = '{"DEP-01": {"reason": "r", "expires": null}}', match = "YYYY%-MM%-DD" },
    { name = "paths that is a text", json = '{"DEP-01": {"reason": "r", "paths": "src"}}', match = "list of text" },
    { name = "paths that is empty", json = '{"DEP-01": {"reason": "r", "paths": []}}', match = "must not be empty" },
    { name = "a path with ..", json = '{"DEP-01": {"reason": "r", "paths": ["src/../etc"]}}', match = "%.%." },
    { name = "a path that is ..", json = '{"DEP-01": {"reason": "r", "paths": [".."]}}', match = "%.%." },
    { name = "an absolute path", json = '{"DEP-01": {"reason": "r", "paths": ["/etc"]}}', match = "relative" },
    { name = "a drive path", json = '{"DEP-01": {"reason": "r", "paths": ["C:/x"]}}', match = "relative" },
    { name = "a home path", json = '{"DEP-01": {"reason": "r", "paths": ["~/x"]}}', match = "relative" },
    { name = "a backslash", json = '{"DEP-01": {"reason": "r", "paths": ["src\\\\a"]}}', match = "backslash" },
    { name = "an empty path", json = '{"DEP-01": {"reason": "r", "paths": [""]}}', match = "non%-empty" },
    { name = "a ./ path", json = '{"DEP-01": {"reason": "r", "paths": ["./src"]}}', match = "segment" },
    { name = "a // path", json = '{"DEP-01": {"reason": "r", "paths": ["src//a"]}}', match = "segment" },
    { name = "a path that is no text", json = '{"DEP-01": {"reason": "r", "paths": [5]}}', match = "non%-empty text" },
    { name = "a broken glob", json = '{"DEP-01": {"reason": "r", "paths": ["src/{a,b"]}}', match = "glob" },
    { name = "the same path twice", json = '{"DEP-01": {"reason": "r", "paths": ["src", "src/"]}}', match = "twice" },
    {
      name = "too many paths",
      json = '{"DEP-01": {"reason": "r", "paths": ["' .. table.concat(
        vim.tbl_map(function(i)
          return "p" .. i
        end, vim.fn.range(1, 51)),
        '","'
      ) .. '"]}}',
      match = "more than",
    },
    { name = "a waiver that is a list", json = '{"DEP-01": ["r"]}', match = "reason text or an object" },
    { name = "a waiver that is null", json = '{"DEP-01": null}', match = "reason text or an object" },
    { name = "a waiver that is a number", json = '{"DEP-01": 3}', match = "reason text or an object" },
  }

  for _, case in ipairs(BAD) do
    it("is an error for " .. case.name, function()
      local dir = tmp_dir()
      put(dir, case.json)

      local entries, err = waivers.load_entries(dir)

      assert.are.same({}, entries)
      assert.is_not_nil(err, case.name)
      assert.matches(case.match, err)
      -- the old loader says the same: nothing is silently dropped
      local reasons, err2 = waivers.load(dir)
      assert.are.same({}, reasons)
      assert.is_not_nil(err2)
    end)
  end

  it("takes a date on the last day of a leap year and a path with a glob and a trailing slash", function()
    local dir = tmp_dir()
    put(dir, '{"DEP-01": {"reason": "r", "expires": "2028-02-29", "paths": ["src/", "**/*.{md,txt}", "a[bc]/x"]}}')

    local entries, err = waivers.load_entries(dir)

    assert.is_nil(err)
    assert.are.equal("2028-02-29", entries["DEP-01"].expires)
  end)

  it("a waivers file that is a folder is an error, not 'no waivers'", function()
    local dir = tmp_dir()
    vim.fn.mkdir(dir .. "/.rules-waivers.json", "p")

    local entries, err = waivers.load_entries(dir)

    assert.are.same({}, entries)
    assert.is_not_nil(err)
  end)

  it("an empty file is an error, not 'no waivers'", function()
    local dir = tmp_dir()
    put(dir, "")

    local _, err = waivers.load_entries(dir)

    assert.is_not_nil(err)
    assert.matches("could not parse", err)
  end)

  it("keeps the caps: more than 500 entries of the object form", function()
    local parts = {}
    for i = 1, 501 do
      parts[#parts + 1] = ('"DEP-%d": {"reason": "r"}'):format(i)
    end
    local dir = tmp_dir()
    put(dir, "{" .. table.concat(parts, ",") .. "}")

    local _, err = waivers.load_entries(dir)

    assert.matches("more than", err)
  end)

  it("a rule id with a control character is an error", function()
    local dir = tmp_dir()
    put(dir, '{"DEP\\u0001-01": "r"}')

    local _, err = waivers.load_entries(dir)

    assert.is_not_nil(err)
  end)
end)

describe("rules.engine.waivers.encode", function()
  it("writes sorted keys, two spaces, LF and a final newline; a reason alone stays the short form", function()
    local text = waivers.encode({
      ["DEP-02"] = { reason = "b", expires = "2030-12-31", paths = { "src", "docs" } },
      ["DEP-01"] = { reason = "a" },
    })

    assert.are.equal(
      table.concat({
        "{",
        '  "DEP-01": "a",',
        '  "DEP-02": {',
        '    "expires": "2030-12-31",',
        '    "paths": [',
        '      "src",',
        '      "docs"',
        "    ],",
        '    "reason": "b"',
        "  }",
        "}",
        "",
      }, "\n"),
      text
    )
    assert.is_nil(text:find("\r", 1, true))
  end)

  it("an empty set is {} and a newline", function()
    assert.are.equal("{}\n", waivers.encode({}))
  end)

  it("reads back as what was written", function()
    local entries = {
      ["DEP-01"] = { reason = 'with "quotes" and a / slash and ünïcode' },
      ["DEP-02"] = { reason = "b", expires = "2030-12-31", paths = { "src" } },
    }
    local back, err = waivers.parse(waivers.encode(entries), "x")
    assert.is_nil(err)
    assert.are.same(entries, back)
  end)
end)

describe("rules.engine.waivers.path_matches", function()
  it("a plain name is that file or the folder with that name, nothing that merely starts like it", function()
    assert.is_true(waivers.path_matches({ "src" }, "src/a.lua"))
    assert.is_true(waivers.path_matches({ "src" }, "src/deep/a.lua"))
    assert.is_true(waivers.path_matches({ "src/a.lua" }, "src/a.lua"))
    assert.is_true(waivers.path_matches({ "src/" }, "src/a.lua"))
    assert.is_false(waivers.path_matches({ "src" }, "srcx/a.lua"))
    assert.is_false(waivers.path_matches({ "src" }, "other/src/a.lua"))
    assert.is_false(waivers.path_matches({ "src/a.lua" }, "src/a.luax"))
  end)

  it("a glob is matched on the whole path: * stays in a folder, ** goes down", function()
    assert.is_true(waivers.path_matches({ "*.md" }, "README.md"))
    assert.is_false(waivers.path_matches({ "*.md" }, "docs/README.md"))
    assert.is_true(waivers.path_matches({ "**/*.md" }, "docs/a/README.md"))
    assert.is_true(waivers.path_matches({ "**/*.md" }, "README.md"))
    assert.is_true(waivers.path_matches({ "docs/**" }, "docs/a/b.txt"))
    assert.is_true(waivers.path_matches({ "src/*.{lua,txt}" }, "src/a.txt"))
    assert.is_false(waivers.path_matches({ "src/*.{lua,txt}" }, "src/a.md"))
    assert.is_true(waivers.path_matches({ "lib?" }, "libs/a.lua"))
  end)

  it("any of several paths", function()
    assert.is_true(waivers.path_matches({ "docs", "src/*.lua" }, "src/a.lua"))
    assert.is_false(waivers.path_matches({ "docs", "src/*.lua" }, "test/a.lua"))
  end)
end)

describe("rules.engine.waivers.relativizer", function()
  it("tells a file's place in the project, whatever way the root and the file are spelled", function()
    local root = tmp_dir()
    write_file(root .. "/src/a.lua", "x")
    local rel = waivers.relativizer(root)

    assert.are.equal("src/a.lua", rel(root .. "/src/a.lua"))
    assert.are.equal("src/a.lua", rel(root .. "/src/./a.lua"))
    assert.are.equal("src/a.lua", rel(root .. "/other/../src/a.lua"))
    assert.are.equal("src/a.lua", waivers.relativizer(root .. "/")(root .. "/src/a.lua"))
    assert.are.equal("src/a.lua", waivers.relativizer(root .. "/src/..")(root .. "/src/a.lua"))
  end)

  it("a file that is not there yet (a missing file the check names) is placed by its folder", function()
    local root = tmp_dir()
    local rel = waivers.relativizer(root)
    assert.are.equal("missing/x.lua", rel(root .. "/missing/x.lua"))
  end)

  it("the root itself, a sibling folder with the same start and a file elsewhere are not inside", function()
    local root = tmp_dir()
    local sibling = root .. "-sibling"
    write_file(sibling .. "/a.lua", "x")
    local rel = waivers.relativizer(root)

    assert.is_nil(rel(root))
    assert.is_nil(rel(sibling .. "/a.lua"))
    assert.is_nil(rel(vim.fn.tempname()))
  end)

  it("compares by real path: a root reached through a link is the same project", function()
    local real = tmp_dir()
    write_file(real .. "/src/a.lua", "x")
    local link = tmp_dir() .. "/link"
    local made = pcall(function()
      assert(vim.uv.fs_symlink(real, link, { dir = true }))
    end)
    if not made then
      pending("this machine cannot make a symbolic link")
      return
    end

    assert.are.equal("src/a.lua", waivers.relativizer(link)(real .. "/src/a.lua"))
    assert.are.equal("src/a.lua", waivers.relativizer(real)(link .. "/src/a.lua"))
  end)
end)

describe("rules.engine.runner with expiring and path-limited waivers", function()
  local rules = {
    { id = "DEP-01", severity = "recommended", check = { type = "grep", pattern = "vim%.loop%." } },
    { id = "DEP-09", severity = "critical", check = { type = "grep", pattern = "not%.there" } },
  }

  ---@return string root
  local function project()
    local root = tmp_dir()
    write_file(root .. "/src/a.lua", "vim.loop.new_timer()\n")
    write_file(root .. "/docs/b.lua", "vim.loop.hrtime()\n")
    return root
  end

  ---@param results Rules.Result[]
  ---@param id string
  ---@return Rules.Result
  local function find(results, id)
    return vim.tbl_filter(function(r)
      return r.rule.id == id
    end, results)[1]
  end

  it("a waiver on its last day still waives", function()
    local root = project()
    local w = { ["DEP-01"] = { reason = "tracked", expires = "2030-10-15" } }

    local res = find(runner.check_family(rules, "DEP", root, w, { today = "2030-10-15" }), "DEP-01")

    assert.are.equal("waived", res.status)
    assert.are.equal("tracked", res.waiver_reason)
    assert.are.equal("2030-10-15", res.waiver_expires)
    assert.is_nil(res.expired_waiver)
    assert.are.equal(2, #res.findings)
  end)

  it("the day after, it is expired: the finding flags again and the result says when and why", function()
    local root = project()
    local w = { ["DEP-01"] = { reason = "tracked", expires = "2030-10-15" } }

    local res = find(runner.check_family(rules, "DEP", root, w, { today = "2030-10-16" }), "DEP-01")

    assert.are.equal("fail", res.status)
    assert.are.equal(2, #res.findings)
    assert.are.same({ reason = "tracked", expires = "2030-10-15" }, res.expired_waiver)
    assert.is_nil(res.waiver_reason)
  end)

  it("an expired waiver of a rule that passes is told too: it is a waiver to renew or remove", function()
    local root = project()
    local w = { ["DEP-09"] = { reason = "old", expires = "2030-01-01" } }

    local res = find(runner.check_family(rules, "DEP", root, w, { today = "2030-10-16" }), "DEP-09")

    assert.are.equal("pass", res.status)
    assert.are.equal("2030-01-01", res.expired_waiver.expires)
  end)

  it("takes the date from the clock when the run is given none", function()
    local root = project()
    local w = { ["DEP-01"] = { reason = "tracked", expires = "2030-10-15" } }
    local saved = waivers.clock
    waivers.clock = function()
      return "2030-10-16"
    end
    local results = runner.check_family(rules, "DEP", root, w)
    waivers.clock = saved

    assert.are.equal("fail", find(results, "DEP-01").status)
  end)

  it("a waiver with no expiry never runs out", function()
    local root = project()

    local res =
      find(runner.check_family(rules, "DEP", root, { ["DEP-01"] = { reason = "r" } }, { today = "2099-01-01" }), "DEP-01")

    assert.are.equal("waived", res.status)
  end)

  it("paths: a waiver covering every finding waives the rule", function()
    local root = project()
    local w = { ["DEP-01"] = { reason = "r", paths = { "src", "docs/*.lua" } } }

    local res = find(runner.check_family(rules, "DEP", root, w, { today = "2030-10-15" }), "DEP-01")

    assert.are.equal("waived", res.status)
    assert.are.same({ "src", "docs/*.lua" }, res.waiver_paths)
  end)

  it("paths: a finding outside them still flags, the ones inside are counted as waived", function()
    local root = project()
    local w = { ["DEP-01"] = { reason = "legacy", paths = { "src" } } }

    local res = find(runner.check_family(rules, "DEP", root, w, { today = "2030-10-15" }), "DEP-01")

    assert.are.equal("fail", res.status)
    assert.are.equal(1, #res.findings)
    assert.matches("docs", res.findings[1].file)
    assert.are.equal(1, res.partial_waiver.suppressed)
    assert.are.equal("legacy", res.partial_waiver.reason)
  end)

  it("paths: no finding inside them leaves the rule failing as it is", function()
    local root = project()
    local w = { ["DEP-01"] = { reason = "legacy", paths = { "vendor" } } }

    local res = find(runner.check_family(rules, "DEP", root, w, { today = "2030-10-15" }), "DEP-01")

    assert.are.equal("fail", res.status)
    assert.are.equal(2, #res.findings)
    assert.is_nil(res.partial_waiver)
  end)

  it("paths: a finding that is no file (an errored check names the root) is never inside them", function()
    local root = project()
    local broken = { { id = "DEP-05", severity = "critical", check = { type = "nope" } } }
    local w = { ["DEP-05"] = { reason = "legacy", paths = { "src" } } }

    local res = runner.check_family(broken, "DEP", root, w, { today = "2030-10-15" })[1]

    assert.are.equal("error", res.status)
  end)

  it("paths are relative to the project root, not to where the run starts", function()
    local root = project()
    local w = { ["DEP-01"] = { reason = "r", paths = { "src", "docs" } } }
    local saved = vim.fn.getcwd()
    vim.cmd.cd(vim.fn.fnameescape(root .. "/src"))
    local results = runner.check_family(rules, "DEP", root, w, { today = "2030-10-15" })
    vim.cmd.cd(vim.fn.fnameescape(saved))

    assert.are.equal("waived", find(results, "DEP-01").status)
  end)

  it("a waiver in the old string form behaves as before: no expiry, every path", function()
    local root = project()

    local res = find(runner.check_family(rules, "DEP", root, { ["DEP-01"] = "tracked" }, { today = "2099-01-01" }), "DEP-01")

    assert.are.equal("waived", res.status)
    assert.are.equal("tracked", res.waiver_reason)
    assert.is_nil(res.waiver_expires)
    assert.is_nil(res.waiver_paths)
  end)
end)

describe("rules.report.buffer with waivers", function()
  local buffer = require("rules.report.buffer")
  local rule = { id = "DEP-01", severity = "recommended", source_file = "x.md", source_line = 1 }

  it("a waived rule shows its reason, its last day and its paths", function()
    local lines = buffer.render({
      {
        rule = rule,
        status = "waived",
        findings = { { file = "a", line = 1, text = "t" } },
        waiver_reason = "legacy",
        waiver_expires = "2030-12-31",
        waiver_paths = { "src", "docs" },
      },
    })

    assert.are.equal("⚪ DEP-01 -- waived (legacy, until 2030-12-31, only in src, docs): 1 finding(s) suppressed", lines[3])
  end)

  it("a waived rule without expiry or paths reads as it always did", function()
    local lines = buffer.render({
      { rule = rule, status = "waived", findings = { { file = "a", line = 1, text = "t" } }, waiver_reason = "legacy" },
    })

    assert.are.equal("⚪ DEP-01 -- waived (legacy): 1 finding(s) suppressed", lines[3])
  end)

  it("an expired waiver is said under the rule, with its date and reason", function()
    local lines = buffer.render({
      {
        rule = rule,
        status = "fail",
        findings = { { file = "a.lua", line = 3, text = "t" } },
        expired_waiver = { reason = "legacy", expires = "2030-09-01" },
      },
    })

    assert.are.equal("🟡 DEP-01 -- 1 finding(s)", lines[3])
    assert.are.equal("      a.lua:3: t", lines[4])
    assert.are.equal("      waiver expired on 2030-09-01 (legacy): renew it or remove it", lines[5])
  end)

  it("an expired waiver of a passing rule is said too", function()
    local lines = buffer.render({
      { rule = rule, status = "pass", findings = {}, expired_waiver = { reason = "legacy", expires = "2030-09-01" } },
    })

    assert.are.equal("🟡 DEP-01 -- ok", lines[3])
    assert.matches("waiver expired on 2030%-09%-01 %(legacy%)", lines[4])
  end)

  it("a waiver that covered some findings by path says how many", function()
    local lines = buffer.render({
      {
        rule = rule,
        status = "fail",
        findings = { { file = "b.lua", line = 1, text = "t" } },
        partial_waiver = { reason = "legacy", paths = { "src" }, suppressed = 4 },
      },
    })

    assert.are.equal("      4 more finding(s) waived in src (legacy)", lines[5])
  end)
end)

describe("rules.report.json with waivers", function()
  local json = require("rules.report.json")
  local rule = { id = "DEP-01", severity = "critical" }

  it("carries the expiry, the paths, the partial and the expired waiver", function()
    local entries = json.to_entries({
      {
        rule = rule,
        status = "waived",
        findings = {},
        waiver_reason = "r",
        waiver_expires = "2030-12-31",
        waiver_paths = { "src" },
      },
      { rule = rule, status = "fail", findings = {}, expired_waiver = { reason = "r", expires = "2030-01-01" } },
      { rule = rule, status = "fail", findings = {}, partial_waiver = { reason = "r", paths = { "src" }, suppressed = 2 } },
    })

    assert.are.equal("2030-12-31", entries[1].waiver_expires)
    assert.are.same({ "src" }, entries[1].waiver_paths)
    assert.are.equal("2030-01-01", entries[2].expired_waiver.expires)
    assert.are.equal(2, entries[3].partial_waiver.suppressed)
  end)

  it("an expired waiver on a critical rule that fails keeps the exit code at 1", function()
    local results = {
      { rule = rule, status = "fail", findings = {}, expired_waiver = { reason = "r", expires = "2030-01-01" } },
    }
    assert.are.equal(1, json.exit_code(results))
  end)
end)

describe("a diff-scoped gate", function()
  local gate = require("rules.engine.gate")

  it("keeps what a failing result says about its waiver when findings stay", function()
    local file = vim.fs.normalize(vim.fn.fnamemodify(tmp_dir() .. "/a.lua", ":p"))
    local results = {
      {
        rule = { id = "DEP-01" },
        status = "fail",
        findings = { { file = file, line = 1, text = "t" } },
        expired_waiver = { reason = "r", expires = "2030-01-01" },
      },
    }

    local scoped = gate.scope_to_diff(results, { [file] = true })

    assert.are.equal("fail", scoped[1].status)
    assert.are.equal("2030-01-01", scoped[1].expired_waiver.expires)
  end)

  it("keeps the note of an expired waiver on a rule the diff leaves passing", function()
    local results = {
      {
        rule = { id = "DEP-01" },
        status = "fail",
        findings = { { file = "elsewhere.lua", line = 1, text = "t" } },
        expired_waiver = { reason = "r", expires = "2030-01-01" },
      },
    }

    local scoped = gate.scope_to_diff(results, {})

    assert.are.equal("pass", scoped[1].status)
    assert.are.equal("2030-01-01", scoped[1].expired_waiver.expires)
  end)
end)
