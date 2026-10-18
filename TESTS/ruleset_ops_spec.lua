-- TESTS/ruleset_ops_spec.lua -- `create_ruleset`, `archive_ruleset`, `restore_ruleset` of `rules-ops/1`: the vault changes, a
-- ruleset is moved to the archive and never deleted, the `rulesets` list of the vault's `.rules.json` is edited as text,
-- and the inverse brings every byte back.
---@diagnostic disable: need-check-nil
local ops = require("rules.ops")
local contract = require("rules.contract")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return (path:gsub("\\", "/"))
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

---@param path string
---@return boolean
local function exists(path)
  return (vim.uv or vim.loop).fs_stat(path) ~= nil
end

local RULE = "---\nid: DEP-01\nseverity: critical\nfamily: DEP\n---\n\n#### `DEP-01` — Pin it\n\nPin the version.\n"

---A vault with the rulesets `names`, each with a rule of its own family, and a `.rules.json` text (or none).
---@param names string[]
---@param rules_json string|nil
---@return string root
local function make_vault(names, rules_json)
  local root = tmp_dir()
  for _, name in ipairs(names) do
    write_raw(
      ("%s/rulesets/%s/_rules/DEP/%s-01.md"):format(root, name, name:upper()),
      (RULE:gsub("DEP%-01", name:upper() .. "-01"))
    )
  end
  if rules_json then
    write_raw(root .. "/.rules.json", rules_json)
  end
  return root
end

---@param root string
---@param op table
---@param dry? boolean
---@return table entry
---@return table doc
local function run(root, op, dry)
  local doc, err = ops.run({ ops = { op }, dry_run = dry or false }, { vault = root })
  assert(doc, vim.inspect(err))
  return doc.results[1], doc
end

---A request the door refuses as a whole (no vault, no ruleset, a vault file it cannot read): no entries, an error.
---@param root string
---@param op table
---@return table err
local function refused(root, op)
  local doc, err = ops.run({ ops = { op } }, { vault = root })
  assert.is_nil(doc)
  return err
end

---@param root string
---@return string[]
local function ruleset_names(root)
  contract.clear_cache()
  local out = {}
  for _, folder in ipairs(require("rules.vault").rulesets({ vault = root })) do
    out[#out + 1] = vim.fs.basename(folder)
  end
  return out
end

describe("create_ruleset", function()
  it("makes the folders and the placeholders, and the vault offers the ruleset", function()
    local root = make_vault({ "alpha" })
    local entry = run(root, { op = "create_ruleset", name = "beta" })
    assert.is_true(entry.ok)
    assert.are.equal("beta", entry.ruleset)
    assert.are.equal("created", entry.outcome)
    assert.is_true(exists(root .. "/rulesets/beta/_rules/.gitkeep"))
    assert.is_true(exists(root .. "/rulesets/beta/_layouts/.gitkeep"))
    assert.are.same({ "alpha", "beta" }, ruleset_names(root))
    assert.are.same({ op = "archive_ruleset", name = "beta" }, entry.inverse)
    assert.is_nil(entry.id)
  end)

  it("answers a dry run and writes nothing", function()
    local root = make_vault({ "alpha" })
    local entry = run(root, { op = "create_ruleset", name = "beta" }, true)
    assert.is_true(entry.ok)
    assert.are.equal("would_create", entry.outcome)
    assert.is_false(exists(root .. "/rulesets/beta"))
  end)

  it("refuses a name that is taken, in any letter case, and a name that is not one", function()
    local root = make_vault({ "alpha" })
    for _, name in ipairs({ "alpha", "ALPHA" }) do
      local entry = run(root, { op = "create_ruleset", name = name })
      assert.is_false(entry.ok)
      assert.are.equal("conflict", entry.error.code)
    end
    for _, name in ipairs({ "", "a/b", "..", "a b", "-x", "CON", "x." }) do
      local entry = run(root, { op = "create_ruleset", name = name })
      assert.is_false(entry.ok, name)
      assert.are.equal("invalid_argument", entry.error.code)
    end
    assert.are.same({ "alpha" }, ruleset_names(root))
  end)

  it("needs a name and a vault", function()
    local root = make_vault({ "alpha" })
    local entry = run(root, { op = "create_ruleset" })
    assert.are.equal("invalid_argument", entry.error.code)
    local none = tmp_dir() .. "/nope"
    refused(none, { op = "create_ruleset", name = "beta" })
    assert.is_false(exists(none .. "/rulesets"))
  end)

  it("adds the ruleset to the list of .rules.json and leaves the rest of the file as it was", function()
    local before = '{\n  "gates": {},\n  "rulesets": ["rulesets/alpha"],\n  "note": "keep me"\n}\n'
    local root = make_vault({ "alpha" }, before)
    local entry = run(root, { op = "create_ruleset", name = "beta" })
    assert.is_true(entry.ok)
    assert.are.equal(
      '{\n  "gates": {},\n  "rulesets": ["rulesets/alpha", "rulesets/beta"],\n  "note": "keep me"\n}\n',
      read_raw(root .. "/.rules.json")
    )
    assert.are.same({ "alpha", "beta" }, ruleset_names(root))
  end)

  it("adds to a one-line list, and leaves a file without a list alone", function()
    local root = make_vault({ "alpha" }, '{"rulesets": ["rulesets/alpha"]}')
    local entry = run(root, { op = "create_ruleset", name = "beta" })
    assert.is_true(entry.ok)
    assert.are.equal('{"rulesets": ["rulesets/alpha", "rulesets/beta"]}', read_raw(root .. "/.rules.json"))
    local free = make_vault({ "alpha" }, '{"gates": {}}')
    assert.is_true(run(free, { op = "create_ruleset", name = "beta" }).ok)
    assert.are.equal('{"gates": {}}', read_raw(free .. "/.rules.json"))
  end)

  it("refuses a .rules.json it cannot read before it makes anything", function()
    local root = make_vault({ "alpha" }, "{ not json")
    refused(root, { op = "create_ruleset", name = "beta" })
    assert.is_false(exists(root .. "/rulesets/beta"))
  end)
end)

describe("archive_ruleset and restore_ruleset", function()
  it("moves the ruleset to the archive and back, byte for byte", function()
    local root = make_vault({ "alpha", "beta" })
    local file = root .. "/rulesets/beta/_rules/DEP/BETA-01.md"
    local text = read_raw(file)
    local entry = run(root, { op = "archive_ruleset", name = "beta" })
    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("archived", entry.outcome)
    assert.is_false(exists(root .. "/rulesets/beta"))
    assert.are.equal(text, read_raw(root .. "/archive/rulesets/beta/_rules/DEP/BETA-01.md"))
    assert.are.same({ "alpha" }, ruleset_names(root))
    assert.are.same({ op = "restore_ruleset", name = "beta" }, entry.inverse)
    local back = run(root, entry.inverse)
    assert.is_true(back.ok, vim.inspect(back))
    assert.are.equal(text, read_raw(file))
    assert.is_false(exists(root .. "/archive/rulesets/beta"))
    assert.are.same({ "archive_ruleset" }, { back.inverse.op })
    assert.are.same({ "alpha", "beta" }, ruleset_names(root))
  end)

  it("never deletes: the archive keeps every file", function()
    local root = make_vault({ "alpha", "beta" })
    write_raw(root .. "/rulesets/beta/_layouts/doc.md", "layout\n")
    write_raw(root .. "/rulesets/beta/notes.txt", "notes\n")
    run(root, { op = "archive_ruleset", name = "beta" })
    assert.are.equal("layout\n", read_raw(root .. "/archive/rulesets/beta/_layouts/doc.md"))
    assert.are.equal("notes\n", read_raw(root .. "/archive/rulesets/beta/notes.txt"))
  end)

  it("answers a dry run and moves nothing", function()
    local root = make_vault({ "alpha", "beta" })
    local entry = run(root, { op = "archive_ruleset", name = "beta" }, true)
    assert.is_true(entry.ok)
    assert.are.equal("would_archive", entry.outcome)
    assert.is_true(exists(root .. "/rulesets/beta"))
    assert.is_false(exists(root .. "/archive"))
  end)

  it("does not archive the last ruleset, one that is not there, or into an archive that has the name", function()
    local solo = make_vault({ "alpha" })
    local last = run(solo, { op = "archive_ruleset", name = "alpha" })
    assert.are.equal("invalid_argument", last.error.code)
    assert.is_true(exists(solo .. "/rulesets/alpha"))
    local root = make_vault({ "alpha", "beta" })
    assert.are.equal("not_found", run(root, { op = "archive_ruleset", name = "gamma" }).error.code)
    write_raw(root .. "/archive/rulesets/beta/old.txt", "old\n")
    local taken = run(root, { op = "archive_ruleset", name = "beta" })
    assert.are.equal("conflict", taken.error.code)
    assert.is_true(exists(root .. "/rulesets/beta"))
    assert.are.equal("old\n", read_raw(root .. "/archive/rulesets/beta/old.txt"))
  end)

  it("refuses to restore a name that is in use or not archived", function()
    local root = make_vault({ "alpha", "beta" })
    assert.are.equal("not_found", run(root, { op = "restore_ruleset", name = "beta" }).error.code)
    run(root, { op = "archive_ruleset", name = "beta" })
    write_raw(root .. "/rulesets/beta/_rules/.gitkeep", "")
    assert.are.equal("conflict", run(root, { op = "restore_ruleset", name = "beta" }).error.code)
    assert.is_true(exists(root .. "/archive/rulesets/beta"))
  end)

  it("edits the list of .rules.json and the inverse puts it back as it was", function()
    local cases = {
      '{"rulesets": ["rulesets/alpha", "rulesets/beta"], "gates": {}}',
      '{"rulesets": ["rulesets/beta", "rulesets/alpha"], "gates": {}}',
      '{\n  "rulesets": [\n    "rulesets/alpha",\n    "@vault/beta",\n    "rulesets/gamma"\n  ],\n  "gates": {}\n}\n',
    }
    for index, before in ipairs(cases) do
      local root = make_vault({ "alpha", "beta", "gamma" }, before)
      local entry = run(root, { op = "archive_ruleset", name = "beta" })
      assert.is_true(entry.ok, ("case %d: %s"):format(index, vim.inspect(entry)))
      local after = read_raw(root .. "/.rules.json")
      assert.is_nil(after:find("beta", 1, true), after)
      assert.is_not_nil(after:find('"gates": {}', 1, true), after)
      assert.are.same(index == 3 and { "alpha", "gamma" } or { "alpha" }, ruleset_names(root))
      local back = run(root, entry.inverse)
      assert.is_true(back.ok, vim.inspect(back))
      assert.is_not_nil(read_raw(root .. "/.rules.json"):find("beta", 1, true))
      assert.is_not_nil(vim.tbl_contains(ruleset_names(root), "beta"))
    end
  end)

  it("refuses before it moves when .rules.json cannot be used", function()
    local root = make_vault({ "alpha", "beta" }, "{ not json")
    refused(root, { op = "archive_ruleset", name = "beta" })
    assert.is_true(exists(root .. "/rulesets/beta"))
    assert.is_false(exists(root .. "/archive"))
  end)

  it("leaves the lock file behind never", function()
    local root = make_vault({ "alpha", "beta" })
    run(root, { op = "archive_ruleset", name = "beta" })
    run(root, { op = "restore_ruleset", name = "beta" })
    for _, name in ipairs(vim.fn.readdir(root)) do
      assert.is_nil(name:find("lock", 1, true), name)
    end
  end)
end)

describe("the operations in the door", function()
  it("are in the list of hello", function()
    local hello = contract.hello()
    for _, name in ipairs({ "create_ruleset", "archive_ruleset", "restore_ruleset" }) do
      assert.is_true(vim.tbl_contains(hello.ops, name), name)
    end
  end)

  it("take a request with other operations in it, one entry for each", function()
    local root = make_vault({ "alpha" })
    local doc = ops.run({
      ops = { { op = "create_ruleset", name = "beta" }, { op = "archive_ruleset", name = "beta" } },
    }, { vault = root })
    assert.are.equal(2, #doc.results)
    assert.is_true(doc.results[1].ok)
    assert.is_true(doc.results[2].ok)
  end)

  it("refuse a field they do not know", function()
    local root = make_vault({ "alpha" })
    local doc = ops.run({ ops = { { op = "create_ruleset", name = "beta", path = "C:/x" } } }, { vault = root })
    assert.is_nil(doc)
    assert.is_false(exists(root .. "/rulesets/beta"))
  end)
end)
