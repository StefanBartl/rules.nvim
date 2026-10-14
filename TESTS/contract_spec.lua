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
    assert.is_true(doc.read_only)
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
    assert.are.same({ "loaded" }, all.basis)
    local _, bad = call("next_id", { family = "A-B" }, opts)
    assert.are.equal("invalid_argument", bad)
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
    expect_golden("error", (api.call("rule", '{"params":{"id":"NOPE-1"}}', opts)))
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
      return
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
