-- TESTS/contract_spec.lua -- `rules-export/1`: the documents, the one door (`rules.api`), the host, the command line.
---@diagnostic disable: need-check-nil
local api = require("rules.api")
local contract = require("rules.contract")
local env = require("rules.env")

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

local DOCUMENT = table.concat({
  "# Dependencies",
  "",
  "### `DEP-01` — one",
  "",
  "```rule",
  'id = "DEP-01",',
  'severity = "recommended",',
  'check = { type = "grep", pattern = "foo" },',
  "```",
  "",
  "Text of one.",
  "",
  "### `DEP-09` — nine",
  "",
  "```rule",
  'id = "DEP-09",',
  'severity = "critical",',
  "```",
  "",
  "Text of nine.",
  "",
}, "\n")

local RULE_FILE = table.concat({
  "---",
  "id: ERR-100",
  "severity: nice-to-have",
  "family: ERR",
  "---",
  "",
  "#### `ERR-100` — a rule of its own",
  "",
  "Prose of the rule.",
  "",
}, "\n")

local FUNCTION_RULE = table.concat({
  "### `LUA-01` — function check",
  "",
  "```rule",
  'id = "LUA-01",',
  'severity = "critical",',
  'check = { type = "lua_predicate", predicate = function() return true end },',
  "```",
  "",
  "Text.",
  "",
}, "\n")

---@return string root, table opts
local function fixture()
  local root = tmp_dir() .. "/fixture/Checklists"
  write_raw(root .. "/DEP.md", DOCUMENT)
  write_raw(root .. "/_rules/ERR/ERR-100.md", RULE_FILE)
  write_raw(root .. "/LUA.md", FUNCTION_RULE)
  return root, { rulesets = { root }, gates = { release = { "DEP", "NOPE" } } }
end

---@param method string
---@param params table|nil
---@param opts table
---@return table doc, string|nil code
local function call(method, params, opts)
  local request = params and vim.json.encode({ params = params }) or nil
  local text, code = api.call(method, request, opts)
  return vim.json.decode(text), code
end

describe("rules.api", function()
  local saved_clock, saved_engine
  before_each(function()
    saved_clock, saved_engine = contract.clock, contract.engine_info
    contract.clock = function()
      return "2026-01-01T00:00:00Z"
    end
    contract.engine_info = function()
      return { version = "0.1.0", git = "test", nvim = "test" }
    end
  end)
  after_each(function()
    contract.clock, contract.engine_info = saved_clock, saved_engine
  end)

  it("hello names the schema, the methods and the limits, and reads no rule", function()
    local doc, code = call("hello", nil, { rulesets = {} })
    assert.is_nil(code)
    assert.are.equal("rules.hello", doc.kind)
    assert.are.equal("rules.nvim", doc.plugin)
    assert.are.equal(1, doc.schema)
    assert.are.same({ 1 }, doc.schemas)
    assert.is_false(doc.read_only)
    assert.is_true(vim.tbl_contains(doc.capabilities, "next_id"))
    assert.are.same({ "critical", "recommended", "nice-to-have" }, doc.enums.severity)
  end)

  it("snapshot counts families, rules, sources and gates", function()
    local root, opts = fixture()
    local doc, code = call("snapshot", nil, opts)
    assert.is_nil(code)
    assert.are.equal("rules.snapshot", doc.kind)
    assert.are.same({ rules = 4, families = 3, files = 3 }, doc.counts)
    local fam = {}
    for _, f in ipairs(doc.families) do
      fam[f.family] = f
    end
    assert.are.equal(2, fam.DEP.count)
    assert.are.equal(1, fam.DEP.critical)
    assert.are.equal(1, fam.DEP.recommended)
    assert.are.equal(1, fam.DEP.with_check)
    assert.are.equal(1, fam.ERR.nice_to_have)
    assert.are.equal(1, #doc.gates)
    assert.are.equal("release", doc.gates[1].name)
    assert.are.equal(2, doc.gates[1].rules)
    assert.are.same({ "NOPE" }, doc.gates[1].unknown)
    assert.is_truthy(doc.rev:match("^rev:%x+$"))
    assert.is_truthy(doc.digest:match("^sha256:%x+$"))
    assert.are.equal(vim.fs.basename(root), doc.source.id)
  end)

  it("keeps no path of this machine in any document", function()
    local root, opts = fixture()
    for _, method in ipairs({ "snapshot", "sources", "list" }) do
      local text = api.call(method, nil, opts)
      assert.is_nil(text:lower():find(vim.fs.normalize(root):lower(), 1, true), method)
      assert.is_nil(text:find("\\\\", 1, true), method)
    end
  end)

  it("answers the same bytes for the same source and a new digest when a file changes", function()
    local root, opts = fixture()
    local first = api.call("snapshot", nil, opts)
    local second = api.call("snapshot", nil, opts)
    assert.are.equal(first, second)
    write_raw(root .. "/_rules/ERR/ERR-100.md", RULE_FILE .. "More.\n")
    local third = api.call("snapshot", nil, opts)
    assert.are_not.equal(first, third)
  end)

  it("lists in id order, pages, and filters by family and severity", function()
    local _, opts = fixture()
    local all = call("list", nil, opts)
    local ids = {}
    for _, r in ipairs(all.items) do
      ids[#ids + 1] = r.id
    end
    assert.are.same({ "DEP-01", "DEP-09", "ERR-100", "LUA-01" }, ids)
    assert.are.equal(4, all.total)

    local page = call("list", { limit = 2, offset = 1 }, opts)
    assert.are.equal(4, page.total)
    assert.are.equal("DEP-09", page.items[1].id)
    assert.are.equal(2, #page.items)

    local dep = call("list", { family = "DEP" }, opts)
    assert.are.equal(2, dep.total)
    local crit = call("list", { severity = "critical" }, opts)
    assert.are.equal(2, crit.total)
  end)

  it("refuses a bad limit, offset and severity as invalid_argument", function()
    local _, opts = fixture()
    for _, params in ipairs({ { limit = 0 }, { limit = 501 }, { offset = -1 }, { severity = "huge" } }) do
      local doc, code = call("list", params, opts)
      assert.are.equal("invalid_argument", code)
      assert.are.equal("rules.error", doc.kind)
    end
  end)

  it("rule gives the text, the check, and the etag with its scope", function()
    local _, opts = fixture()
    local doc = call("rule", { id = "DEP-01" }, opts)
    assert.are.equal("rules.rule", doc.kind)
    assert.are.equal("Text of one.", doc.rule.text)
    assert.are.equal("grep", doc.rule.check.type)
    assert.are.equal("file", doc.rule.etag_scope)
    assert.is_true(doc.rule.editable)

    local own = call("rule", { id = "ERR-100" }, opts)
    assert.are.equal("rule", own.rule.etag_scope)
    assert.are.equal("Prose of the rule.", own.rule.text)
    assert.is_truthy(own.rule.etag:match("^sha256:%x+$"))
    assert.are_not.equal(doc.rule.etag, own.rule.etag)
  end)

  it("sends a check with a function without it and marks the rule not editable", function()
    local _, opts = fixture()
    local doc = call("rule", { id = "LUA-01" }, opts)
    assert.is_false(doc.rule.editable)
    assert.are.equal("lua_predicate", doc.rule.check.type)
    assert.is_nil(doc.rule.check.predicate)
  end)

  it("answers an unknown id as not_found and a missing id as invalid_argument", function()
    local _, opts = fixture()
    local doc, code = call("rule", { id = "NOPE-01" }, opts)
    assert.are.equal("not_found", code)
    assert.are.equal("not_found", doc.code)
    local _, missing = call("rule", {}, opts)
    assert.are.equal("invalid_argument", missing)
  end)

  it("next_id counts over the loaded rules, keeps the width, and starts a new family at 01", function()
    local _, opts = fixture()
    local dep = call("next_id", { family = "DEP" }, opts)
    assert.are.equal("DEP-10", dep.items[1].next)
    assert.are.equal(9, dep.items[1].highest)
    local err = call("next_id", { family = "ERR" }, opts)
    assert.are.equal("ERR-101", err.items[1].next)
    local fresh = call("next_id", { family = "NEW" }, opts)
    assert.are.equal("NEW-01", fresh.items[1].next)
    local all = call("next_id", nil, opts)
    assert.are.equal(3, #all.items)
    assert.are.same({ "loaded", "retired" }, all.basis)
    local _, bad = call("next_id", { family = "A-B" }, opts)
    assert.are.equal("invalid_argument", bad)
  end)

  it("next_id and the load errors agree on which ids are taken, retired ones included", function()
    local function text(id)
      return ("---\nid: %s\nseverity: critical\nfamily: AAA\n---\n\n#### `%s`\n\nText.\n"):format(id, id)
    end
    local root = tmp_dir() .. "/fixture/Checklists"
    write_raw(root .. "/_rules/AAA/AAA-05.md", text("AAA-05"))
    -- the two machines: a retired AAA-05 beside the live one; the next id is AAA-06 and the check says "taken"
    write_raw(root .. "/_retired/AAA/AAA-05.md", text("AAA-05"))
    local view = assert(contract.view({ rulesets = { root } }))
    assert.are.equal("AAA-06", contract.next_free(view, "AAA"))
    assert.are.equal(1, #view.load_errors, vim.inspect(view.load_errors))
    assert.matches("duplicate rule id AAA-05", view.load_errors[1], 1, true)
    assert.matches("Checklists/_retired/AAA/AAA-05.md (retired)", view.load_errors[1], 1, true)
    assert.is_nil(view.load_errors[1]:find(root, 1, true), "no path of this machine in a document")
    assert.are.same(
      { "AAA-05" },
      vim.tbl_map(function(entry)
        return entry.id
      end, view.retired)
    )

    -- a retired file that says another id than its name takes both: the next id passes both
    local other = tmp_dir() .. "/fixture/Checklists"
    write_raw(other .. "/_retired/AAA/AAA-02.md", text("AAA-09"))
    local view2 = assert(contract.view({ rulesets = { other } }))
    assert.are.equal("AAA-10", contract.next_free(view2, "AAA"))
    assert.are.equal(1, #view2.load_errors, vim.inspect(view2.load_errors))
    assert.matches("named for AAA-02 but its frontmatter says `id: AAA-09`", view2.load_errors[1], 1, true)
  end)

  it("next_id takes an id of any length: the next one is exact, `highest` is held at 2^53 - 1", function()
    local root = tmp_dir() .. "/fixture/Checklists"
    for _, id in ipairs({ "BIG-99999999999999999", "HUGE-123456789012345678901", "HUGE-007" }) do
      local family = id:match("^(%a+)")
      write_raw(
        ("%s/_rules/%s/%s.md"):format(root, family, id),
        ("---\nid: %s\nseverity: nice-to-have\nfamily: %s\n---\n\n#### `%s` — big\n\nText.\n"):format(id, family, id)
      )
    end
    local doc, code = call("next_id", nil, { rulesets = { root } })
    assert.is_nil(code, vim.inspect(doc))
    assert.are.equal("rules.next_id", doc.kind)
    local by_family = {}
    for _, item in ipairs(doc.items) do
      by_family[item.family] = item
    end
    assert.are.equal("BIG-100000000000000000", by_family.BIG.next)
    assert.are.equal(9007199254740991, by_family.BIG.highest)
    assert.are.equal("HUGE-123456789012345678902", by_family.HUGE.next)
    assert.are.equal(2, by_family.HUGE.count)
    local one, one_code = call("next_id", { family = "BIG" }, { rulesets = { root } })
    assert.is_nil(one_code)
    assert.are.equal("BIG-100000000000000000", one.items[1].next)
    assert.are.equal("BIG-100000000000000000", contract.next_free(assert(contract.view({ rulesets = { root } })), "BIG"))
  end)

  it("next_id never gives an id longer than an id may be: the family has no `next` once none is left", function()
    local root = tmp_dir() .. "/fixture/Checklists"
    -- FIT-1 and 95 zeros is exactly 100 bytes; BIG-<96 nines> is 100 bytes already, one past it would be 103
    for _, id in ipairs({ "FIT-" .. ("9"):rep(95), "BIG-" .. ("9"):rep(96) }) do
      local family = id:match("^(%a+)")
      assert.is_true(#id <= 100)
      write_raw(
        ("%s/_rules/%s/%s.md"):format(root, family, id),
        ("---\nid: %s\nseverity: nice-to-have\nfamily: %s\n---\n\n#### `%s` — big\n\nText.\n"):format(id, family, id)
      )
    end
    local doc, code = call("next_id", nil, { rulesets = { root } })
    assert.is_nil(code, vim.inspect(doc))
    local by_family = {}
    for _, item in ipairs(doc.items) do
      by_family[item.family] = item
    end
    assert.are.equal(2, #doc.items, vim.inspect(doc.items))
    assert.are.equal("FIT-1" .. ("0"):rep(95), by_family.FIT.next)
    assert.are.equal(100, #by_family.FIT.next)
    assert.is_nil(by_family.BIG.next, "the id after BIG-99...9 would be longer than an id may be")
    assert.are.equal(1, by_family.BIG.count)
    assert.is_nil(contract.next_free(assert(contract.view({ rulesets = { root } })), "BIG"))
  end)

  it("sources lists the files with an etag each", function()
    local _, opts = fixture()
    local doc = call("sources", nil, opts)
    assert.are.equal(3, #doc.items)
    for _, item in ipairs(doc.items) do
      assert.is_truthy(item.etag:match("^sha256:%x+$"))
      assert.is_true(item.rules >= 1)
    end
  end)

  it("tells a duplicate id in load_errors, with both sources named by their ruleset", function()
    local a, b = tmp_dir() .. "/one/Checklists", tmp_dir() .. "/two/Checklists"
    write_raw(a .. "/x.md", DOCUMENT)
    write_raw(b .. "/y.md", DOCUMENT)
    local doc = call("snapshot", nil, { rulesets = { a, b } })
    assert.is_true(#doc.load_errors >= 1)
    local message = doc.load_errors[1]
    assert.is_truthy(message:find("duplicate rule id", 1, true))
    assert.is_nil(message:find(vim.fs.normalize(a), 1, true))
    -- both rulesets are called `Checklists`: the folder above tells them apart
    assert.is_truthy(message:find("one/Checklists/x.md", 1, true))
    assert.is_truthy(message:find("two/Checklists/y.md", 1, true))
  end)

  it("names a ruleset by its own folder, never by a folder above it that is not needed", function()
    local root, opts = fixture()
    local doc = call("sources", nil, opts)
    for _, item in ipairs(doc.items) do
      assert.is_truthy(item.path:find("^Checklists/"), item.path)
    end
    assert.is_nil(api.call("snapshot", nil, opts):find("fixture/", 1, true))
    assert.are.equal("Checklists", vim.fs.basename(root))
  end)

  it("tells two rulesets with the same folder and the same folder above apart by a number", function()
    local a, b = tmp_dir() .. "/fixture/Checklists", tmp_dir() .. "/fixture/Checklists"
    write_raw(a .. "/x.md", DOCUMENT)
    write_raw(b .. "/y.md", DOCUMENT)
    local _, names = contract.rulesets({ rulesets = { a, b } })
    assert.are.equal("fixture/Checklists", names[vim.fs.normalize(a)])
    assert.are.equal("fixture/Checklists#2", names[vim.fs.normalize(b)])

    local doc = call("snapshot", nil, { rulesets = { a, b } })
    local message = doc.load_errors[1]
    assert.is_truthy(message:find("fixture/Checklists/x.md", 1, true), message)
    assert.is_truthy(message:find("fixture/Checklists#2/y.md", 1, true), message)
    assert.is_nil(message:find(vim.fs.normalize(a), 1, true))
  end)

  it("counts a ruleset listed twice, or spelled another way, once", function()
    local root, opts = fixture()
    opts.rulesets = { root, root .. "/", root .. "/./" }
    local paths, names = contract.rulesets(opts)
    -- compared by the real path: a runner's temp folder may be spelled with an 8.3 short name
    assert.are.equal(1, #paths)
    assert.are.equal(vim.uv.fs_realpath(root), vim.uv.fs_realpath(paths[1]))
    assert.are.equal("Checklists", names[paths[1]])

    local doc = call("snapshot", nil, opts)
    assert.are.same({}, doc.load_errors)
    assert.are.equal(3, doc.counts.files)
    local sources = call("sources", nil, opts)
    for _, item in ipairs(sources.items) do
      assert.is_truthy(item.path:find("^Checklists/"), item.path)
    end
  end)

  it("counts a ruleset spelled in another case once where the file system does not tell the cases apart", function()
    if vim.fn.has("win32") == 0 and vim.fn.has("mac") == 0 then
      pending("the file system tells the cases apart")
    end
    local root, opts = fixture()
    opts.rulesets = { root, root:upper() }
    local paths, names = contract.rulesets(opts)
    assert.are.equal(1, #paths)
    assert.are.equal("Checklists", names[paths[1]])
    assert.are.same({}, call("snapshot", nil, opts).load_errors)
  end)

  it("keeps the scan while no file changed and takes the new one when a file did", function()
    local root, opts = fixture()
    local old = os.time() - 3600
    local function age_all()
      for _, path in ipairs(vim.fn.globpath(root, "**/*.md", false, true)) do
        vim.uv.fs_utime(path, old, old)
      end
    end
    age_all()
    contract.clear_cache()
    local first = assert(contract.view(opts))
    assert.are.equal(first, (contract.view(opts)))

    write_raw(root .. "/_rules/ERR/ERR-100.md", RULE_FILE .. "More prose.\n")
    age_all()
    local second = assert(contract.view(opts))
    assert.are_not.equal(first, second)
    assert.are.equal("More prose.", second.full["ERR-100"].text:match("More prose%."))
  end)

  it("does not keep a scan of files that changed a moment ago", function()
    local _, opts = fixture()
    contract.clear_cache()
    local first = assert(contract.view(opts))
    local second = assert(contract.view(opts))
    assert.are_not.equal(first, second)
  end)

  it("answers a request with an unknown parameter, a higher schema, or no ruleset with an error document", function()
    local _, opts = fixture()
    local doc, code = call("list", { colour = "red" }, opts)
    assert.are.equal("invalid_argument", code)
    assert.are.equal("rules.error", doc.kind)

    local text, c2 = api.call("snapshot", '{"schema":2}', opts)
    assert.are.equal("unsupported_schema", c2)
    assert.are.equal("rules.error", vim.json.decode(text).kind)

    local none, c3 = call("snapshot", nil, { rulesets = {} })
    assert.are.equal("not_found", c3)
    assert.are.equal("rules.error", none.kind)

    local _, c4 = call("nope", nil, opts)
    assert.is_not_nil(c4)
  end)

  it("never throws, whatever the request", function()
    local _, opts = fixture()
    for _, request in ipairs({ "", "not json", "[]", "null", '{"params":[]}', '{"params":{"id":5}}' }) do
      local ok, text = pcall(api.call, "rule", request, opts)
      assert.is_true(ok, request)
      assert.is_string(text)
    end
  end)
end)

describe("rules-export/1 golden files", function()
  local saved_clock, saved_engine
  before_each(function()
    saved_clock, saved_engine = contract.clock, contract.engine_info
    contract.clock = function()
      return "2026-01-01T00:00:00Z"
    end
    contract.engine_info = function()
      return { version = "0.1.0", git = "golden", nvim = "golden" }
    end
  end)
  after_each(function()
    contract.clock, contract.engine_info = saved_clock, saved_engine
  end)

  local plugin_root = vim.fs.dirname(
    vim.fs.dirname(
      vim.fs.dirname(
        vim.fs.normalize(vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("lua/rules/contract.lua", false)[1], ":p"))
      )
    )
  )
  local dir = plugin_root .. "/schemas/rules-export/1/golden"

  ---@param name string
  ---@param text string
  local function expect_golden(name, text)
    local path = dir .. "/" .. name .. ".json"
    if vim.env.RULES_UPDATE_GOLDEN == "1" or vim.uv.fs_stat(dir .. "/.update") then
      write_raw(path, text .. "\n")
    end
    local f = assert(
      io.open(path, "rb"),
      "missing golden file " .. path .. " (create schemas/rules-export/1/golden/.update and rerun to write it)"
    )
    local want = f:read("*a")
    f:close()
    assert.are.equal(want, text .. "\n", name)
  end

  it("match the documents the engine writes", function()
    local _, opts = fixture()
    expect_golden("hello", (api.call("hello", nil, opts)))
    expect_golden("snapshot", (api.call("snapshot", nil, opts)))
    expect_golden("list", (api.call("list", '{"params":{"limit":2}}', opts)))
    expect_golden("rule", (api.call("rule", '{"params":{"id":"DEP-01"}}', opts)))
    expect_golden("next_id", (api.call("next_id", '{"params":{"family":"DEP"}}', opts)))
    expect_golden("sources", (api.call("sources", nil, opts)))
    expect_golden("rulesets", (api.call("rulesets", nil, opts)))
    expect_golden("error", (api.call("rule", '{"params":{"id":"NOPE-1"}}', opts)))
    local request =
      '{"client_op_id":"c-1","dry_run":true,"ops":[{"op":"new","family":"DEP","title":"golden","severity":"critical"}]}'
    expect_golden("result", (api.call("ops", request, opts)))
  end)

  it("match the waivers document and a waive dry run (a project with a waivers file, a fixed day)", function()
    local root, opts = fixture()
    local project = tmp_dir()
    write_raw(
      project .. "/.rules-waivers.json",
      table.concat({
        '{"DEP-01": "plain", "OLD-01": "gone",',
        ' "DEP-09": {"reason": "ran out", "expires": "2025-12-31", "paths": ["src", "docs/**/*.md"]}}',
      })
    )
    opts = vim.tbl_extend("force", opts, { rulesets = { root }, project = project, today = "2026-01-01" })
    expect_golden("waivers", (api.call("waivers", nil, opts)))
    local request = '{"client_op_id":"c-2","dry_run":true,"ops":[{"op":"renew","id":"DEP-09","expires":"2026-12-31"}]}'
    expect_golden("result_renew", (api.call("ops", request, opts)))
  end)
end)

describe("rules.host", function()
  it("answers a request line with the document the api gives, on one line", function()
    local host = require("rules.host")
    local reply = host.handle("7\thello\t")
    assert.is_truthy(reply)
    local id, text = reply:match("^(%d+)\t(.*)$")
    assert.are.equal("7", id)
    assert.are.equal("rules.hello", vim.json.decode(text).kind)
    assert.is_nil(text:find("\n", 1, true))
  end)

  it("skips a line that is no request", function()
    assert.is_nil(require("rules.host").handle("garbage"))
  end)

  it("reads the rulesets from $RULES_RULESETS and the gates from $RULES_GATES", function()
    local root = fixture()
    local saved_sets, saved_gates = vim.env.RULES_RULESETS, vim.env.RULES_GATES
    vim.env.RULES_RULESETS = root
    vim.env.RULES_GATES = "release=DEP,NOPE"
    local ok, reply = pcall(require("rules.host").handle, "3\tsnapshot\t")
    vim.env.RULES_RULESETS, vim.env.RULES_GATES = saved_sets, saved_gates
    assert.is_true(ok, reply)
    local doc = vim.json.decode(reply:match("^3\t(.*)$"))
    assert.are.equal("rules.snapshot", doc.kind)
    assert.are.equal(4, doc.counts.rules)
    assert.are.equal("release", doc.gates[1].name)
    assert.are.same({ "NOPE" }, doc.gates[1].unknown)
  end)
end)

describe("scripts/rules.lua", function()
  local script = vim.fs.dirname(
    vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("lua/rules/contract.lua", false)[1], ":p")))
  )
  script = vim.fs.dirname(script) .. "/scripts/rules.lua"

  ---@param args string[]
  ---@return vim.SystemCompleted
  local function run(args)
    local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script }
    vim.list_extend(cmd, args)
    return vim.system(cmd, { text = true, env = { LIB_NVIM_DIR = vim.env.LIB_NVIM_DIR } }):wait(20000)
  end

  it("answers 0 for a document, 1 for an error document and 2 for wrong usage", function()
    if not vim.env.LIB_NVIM_DIR or vim.env.LIB_NVIM_DIR == "" then
      pending("LIB_NVIM_DIR is not set: the script cannot find lib.nvim")
    end
    local root = fixture()
    local ok = run({ "call", "rule", '--params={"id":"DEP-01"}', "--ruleset=" .. root })
    assert.are.equal(0, ok.code)
    assert.are.equal("rules.rule", vim.json.decode(ok.stdout).kind)

    local missing = run({ "call", "rule", '--params={"id":"NOPE-01"}', "--ruleset=" .. root })
    assert.are.equal(1, missing.code)
    assert.are.equal("not_found", vim.json.decode(missing.stdout).code)

    local list = run({ "list", "--format=json", "--family=DEP", "--ruleset=" .. root })
    assert.are.equal(0, list.code)
    assert.are.equal(2, vim.json.decode(list.stdout).total)

    assert.are.equal(2, run({ "frobnicate" }).code)
    assert.are.equal(2, run({ "list" }).code)
    assert.are.equal(2, run({ "call", "hello", "--colour=red" }).code)
    assert.are.equal(2, run({ "list", "--format=json", "--limit=ten", "--ruleset=" .. root }).code)

    -- a number no JSON carries, or no whole number: an error document, not a crash
    for _, flag in ipairs({ "--limit=inf", "--limit=nan", "--limit=-inf", "--offset=inf", "--limit=2.5" }) do
      local bad = run({ "list", "--format=json", flag, "--ruleset=" .. root })
      assert.are.equal(1, bad.code, flag .. " " .. bad.stderr)
      local doc = vim.json.decode(bad.stdout)
      assert.are.equal("rules.error", doc.kind, flag)
      assert.are.equal("invalid_argument", doc.code, flag)
    end
    local page = run({ "list", "--format=json", "--limit=1", "--offset=1", "--ruleset=" .. root })
    assert.are.equal(0, page.code)
    assert.are.equal(1, #vim.json.decode(page.stdout).items)

    -- the write door: the fields of the request are its own, not under `params`
    local dry = run({
      "call",
      "ops",
      '--params={"dry_run":true,"ops":[{"op":"new","family":"DEP","title":"t","severity":"critical"}]}',
      "--ruleset=" .. root,
    })
    assert.are.equal(0, dry.code, dry.stdout)
    local result = vim.json.decode(dry.stdout)
    assert.are.equal("rules.result", result.kind)
    assert.are.equal("would_create", result.results[1].outcome)
  end)
end)

describe("rules.env", function()
  it("splits paths on ; and on : but not on a drive colon", function()
    assert.are.same({ "C:/a", "D:\\b", "/c" }, env.split_paths("C:/a;D:\\b:/c"))
  end)

  it("parses gates", function()
    assert.are.same({ release = { "REL", "DEP" }, review = { "ERR" } }, env.parse_gates("release=REL,DEP;review=ERR"))
    assert.are.same({}, env.parse_gates("garbage"))
  end)
end)

describe("rules.contract.locate", function()
  local function rule_file(path, id, title)
    write_raw(
      path,
      table.concat({
        "# x",
        "",
        "### `" .. id .. "` — " .. title,
        "",
        "```rule",
        'id = "' .. id .. '",',
        'severity = "recommended",',
        "```",
        "",
        "text",
        "",
      }, "\n")
    )
  end

  ---Three rulesets: two called `Checklists` (so a name needs the folder above) and a third that clashes with the
  ---second as well (`#2`), all outside any vault; plus a folder of the same name that is not loaded.
  local function layout()
    local base = vim.fs.normalize(tmp_dir())
    local one, two = base .. "/one/Checklists", base .. "/two/Checklists"
    rule_file(one .. "/a.md", "AAA-01", "first")
    rule_file(two .. "/b.md", "BBB-01", "second")
    rule_file(base .. "/three/two/Checklists/c.md", "CCC-01", "third")
    -- a folder that is not configured but has a name a document will use
    rule_file(base .. "/vault/rulesets/one/Checklists/a.md", "ZZZ-01", "not loaded")
    return base, { one, two, base .. "/three/two/Checklists" }
  end

  it("names the file and the ruleset, whatever name the document gives the ruleset", function()
    local base, sets = layout()
    local opts = { rulesets = sets }
    for id, want in pairs({
      ["AAA-01"] = { file = base .. "/one/Checklists/a.md", root = sets[1] },
      ["BBB-01"] = { file = base .. "/two/Checklists/b.md", root = sets[2] },
      ["CCC-01"] = { file = base .. "/three/two/Checklists/c.md", root = sets[3] },
    }) do
      local found, err = contract.locate(id, opts)
      assert.is_nil(err)
      assert.are.equal(vim.fs.normalize(vim.fn.fnamemodify(want.file, ":p")), found.file, id)
      assert.are.equal(vim.fs.normalize(vim.fn.fnamemodify(want.root, ":p")):gsub("/+$", ""), found.root, id)
    end
    -- the documents name the three rulesets differently, none by its place: this is what a client cannot invert
    local sources = {}
    for _, id in ipairs({ "AAA-01", "BBB-01", "CCC-01" }) do
      sources[#sources + 1] = contract.rule(id, opts).rule.source
    end
    assert.are.same({ "one/Checklists/a.md", "two/Checklists/b.md", "two/Checklists#2/c.md" }, sources)
    for _, source in ipairs(sources) do
      assert.is_nil(source:match("^%a:") or source:match("^/"), "a path of this machine in a document")
    end
  end)

  it("knows nothing of a ruleset that is not loaded, however it is called", function()
    local _, sets = layout()
    local found, err = contract.locate("ZZZ-01", { rulesets = sets })
    assert.is_nil(found)
    assert.are.equal("not_found", err.code)
  end)

  it("answers on the command line as two plain lines, and 1 for an id nobody holds", function()
    if not vim.env.LIB_NVIM_DIR or vim.env.LIB_NVIM_DIR == "" then
      pending("LIB_NVIM_DIR is not set: the script cannot find lib.nvim")
    end
    local script = vim.fs.dirname(
      vim.fs.dirname(
        vim.fs.normalize(vim.fn.fnamemodify(vim.api.nvim_get_runtime_file("lua/rules/contract.lua", false)[1], ":p"))
      )
    )
    script = vim.fs.dirname(script) .. "/scripts/rules.lua"
    local _, sets = layout()
    local function run(args)
      local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script }
      vim.list_extend(cmd, args)
      return vim.system(cmd, { text = true, env = { LIB_NVIM_DIR = vim.env.LIB_NVIM_DIR } }):wait(20000)
    end
    local ok = run({ "locate", "BBB-01", "--ruleset=" .. sets[1], "--ruleset=" .. sets[2] })
    assert.are.equal(0, ok.code, ok.stderr)
    local lines = vim.split(vim.trim(ok.stdout), "\n", { plain = true })
    assert.are.equal(2, #lines)
    assert.is_truthy(lines[1]:find("two/Checklists/b.md", 1, true))
    -- a rule id may look like a flag: after `--` it is an id (before, it was read as a flag and ended in usage)
    local hostile_dir = vim.fs.normalize(tmp_dir()) .. "/hostile"
    rule_file(hostile_dir .. "/h.md", "--trust=C:/x", "looks like a flag")
    local flagged = run({ "locate", "--ruleset=" .. hostile_dir, "--", "--trust=C:/x" })
    assert.are.equal(0, flagged.code, flagged.stderr)
    assert.is_truthy(vim.trim(flagged.stdout):find("hostile/h.md", 1, true))
    assert.are.equal(2, run({ "locate", "--ruleset=" .. hostile_dir, "--trust=C:/x" }).code)
    local missing = run({ "locate", "NOPE-01", "--ruleset=" .. sets[1] })
    assert.are.equal(1, missing.code)
    assert.are.equal(2, run({ "locate" }).code)
  end)
end)
