local plan_lib = require("rules.engine.agent.plan")

---@param id string
---@param extra? table
---@return table
local function rule(id, extra)
  return vim.tbl_extend("force", {
    id = id,
    severity = "recommended",
    title = id .. " title",
    text = "",
    source_file = "x.md",
    source_line = 1,
  }, extra or {})
end

--- A plan over a fake tree: `files` is `{ path = bytes }`.
---@param rules table[]
---@param files table<string, integer>
---@param agent? table
---@return table
local function plan_of(rules, files, agent)
  local list = vim.tbl_keys(files)
  return plan_lib.plan(rules, "/nowhere", {
    agent = agent,
    files = list,
    size = function(path)
      return files[path]
    end,
  })
end

---@param batch table
---@return string[]
local function ids_of(batch)
  local out = {}
  for _, entry in ipairs(batch.rules) do
    out[#out + 1] = entry.rule.id
  end
  return out
end

describe("rules.engine.agent.plan scope", function()
  it("leaves a rule with a check alone", function()
    local plan = plan_of({ rule("A-01", { check = { type = "file_exists", path = "x" } }) }, { ["a.lua"] = 1 }, {
      scopes = { A = { include = { "*.lua" } } },
    })

    assert.are.same({}, plan.batches)
    assert.are.same({}, plan.skipped)
  end)

  it("keeps a manual rule with no scope on the worklist and says why", function()
    local plan = plan_of({ rule("A-01") }, { ["a.lua"] = 1 })

    assert.are.same({}, plan.batches)
    assert.are.equal(1, #plan.skipped)
    assert.are.equal("manual", plan.skipped[1].status)
    assert.are.equal("no scope to look in", plan.skipped[1].reason)
  end)

  it("takes the scope of the family when the rule has none", function()
    local plan = plan_of({ rule("A-01") }, { ["a.lua"] = 1, ["b.txt"] = 1 }, {
      scopes = { A = { include = { "*.lua" } } },
    })

    assert.are.equal(1, #plan.batches)
    assert.are.same({ "a.lua" }, plan.batches[1].files)
    assert.are.equal("family", plan.batches[1].rules[1].source)
  end)

  it("prefers the scope of the rule over the one of its family", function()
    local plan = plan_of({ rule("A-01", { agent = { include = { "*.txt" } } }) }, { ["a.lua"] = 1, ["b.txt"] = 1 }, {
      scopes = { A = { include = { "*.lua" } } },
    })

    assert.are.same({ "b.txt" }, plan.batches[1].files)
    assert.are.equal("rule", plan.batches[1].rules[1].source)
  end)

  it("does not use the scope of another family", function()
    local plan = plan_of({ rule("B-01") }, { ["a.lua"] = 1 }, { scopes = { A = { include = { "*.lua" } } } })

    assert.are.equal("no scope to look in", plan.skipped[1].reason)
  end)

  it("keeps a rule whose scope matches no file on the worklist", function()
    local plan = plan_of({ rule("A-01") }, { ["a.lua"] = 1 }, { scopes = { A = { include = { "*.go" } } } })

    assert.are.same({}, plan.batches)
    assert.are.equal("manual", plan.skipped[1].status)
    assert.are.equal("scope matches no file", plan.skipped[1].reason)
  end)
end)

describe("rules.engine.agent.plan batches", function()
  local scopes = { A = { include = { "*.lua" } }, B = { include = { "*.lua" } }, C = { include = { "*.md" } } }

  it("puts rules that look at the same files into one request", function()
    local plan = plan_of({ rule("B-01"), rule("A-02"), rule("A-01") }, { ["a.lua"] = 1, ["b.md"] = 1 }, {
      scopes = scopes,
    })

    assert.are.equal(1, #plan.batches)
    assert.are.same({ "A-01", "A-02", "B-01" }, ids_of(plan.batches[1]))
  end)

  it("gives rules with different files separate requests", function()
    local plan = plan_of({ rule("A-01"), rule("C-01") }, { ["a.lua"] = 1, ["b.md"] = 1 }, { scopes = scopes })

    assert.are.equal(2, #plan.batches)
    assert.are.same({ "a.lua" }, plan.batches[1].files)
    assert.are.same({ "b.md" }, plan.batches[2].files)
    assert.are.equal("b1", plan.batches[1].id)
    assert.are.equal("b2", plan.batches[2].id)
  end)

  it("cuts a group at batch_size, 8 by default", function()
    local rules = {}
    for n = 1, 10 do
      rules[#rules + 1] = rule(("A-%02d"):format(n))
    end

    local plan = plan_of(rules, { ["a.lua"] = 1 }, { scopes = scopes })

    assert.are.equal(2, #plan.batches)
    assert.are.equal(8, #plan.batches[1].rules)
    assert.are.equal(2, #plan.batches[2].rules)
    assert.are.same({ "a.lua" }, plan.batches[2].files)
  end)

  it("takes batch_size from the config", function()
    local plan = plan_of({ rule("A-01"), rule("A-02"), rule("A-03") }, { ["a.lua"] = 1 }, {
      scopes = scopes,
      batch_size = 2,
    })

    assert.are.equal(2, #plan.batches)
    assert.are.equal(2, #plan.batches[1].rules)
  end)

  it("lists the files sorted, so that the same tree always gives the same plan", function()
    local plan = plan_of({ rule("A-01") }, { ["z.lua"] = 1, ["a.lua"] = 1, ["m.lua"] = 1 }, { scopes = scopes })

    assert.are.same({ "a.lua", "m.lua", "z.lua" }, plan.batches[1].files)
    assert.are.equal(3, plan.batches[1].bytes)
  end)
end)

describe("rules.engine.agent.plan size", function()
  it("does not cut a scope down quietly: the rule becomes unclear", function()
    local plan = plan_of({ rule("A-01") }, { ["a.lua"] = 40000, ["b.lua"] = 30000 }, {
      scopes = { A = { include = { "*.lua" } } },
    })

    assert.are.same({}, plan.batches)
    assert.are.equal("unclear", plan.skipped[1].status)
    assert.is_truthy(plan.skipped[1].reason:find("context exceeds limit", 1, true))
  end)

  it("takes the limit from the config, and allows exactly the limit", function()
    local files = { ["a.lua"] = 100 }
    local scopes = { A = { include = { "*.lua" } } }

    assert.are.equal(1, #plan_of({ rule("A-01") }, files, { scopes = scopes, max_context_bytes = 100 }).batches)
    assert.are.equal("unclear", plan_of({ rule("A-01") }, files, { scopes = scopes, max_context_bytes = 99 }).skipped[1].status)
  end)

  it("judges each rule by its own files, not by the run", function()
    local plan = plan_of({ rule("A-01"), rule("B-01", { agent = { include = { "big.txt" } } }) }, {
      ["a.lua"] = 10,
      ["big.txt"] = 70000,
    }, { scopes = { A = { include = { "*.lua" } } } })

    assert.are.equal(1, #plan.batches)
    assert.are.same({ "A-01" }, ids_of(plan.batches[1]))
    assert.are.equal("B-01", plan.skipped[1].rule.id)
  end)

  it("caps the file list at the max_files of the rule and says so", function()
    local plan = plan_of({ rule("A-01", { agent = { include = { "*.lua" }, max_files = 2 } }) }, {
      ["a.lua"] = 1,
      ["b.lua"] = 1,
      ["c.lua"] = 1,
    })

    assert.are.same({ "a.lua", "b.lua" }, plan.batches[1].files)
    assert.are.same({ total = 3, kept = 2 }, plan.batches[1].rules[1].truncated)
  end)

  it("does not mark a rule truncated when the files fit", function()
    local plan = plan_of({ rule("A-01", { agent = { include = { "*.lua" }, max_files = 5 } }) }, { ["a.lua"] = 1 })

    assert.is_nil(plan.batches[1].rules[1].truncated)
  end)
end)

describe("rules.engine.agent.plan deny", function()
  local scopes = { A = { include = { "**" } } }

  it("never sends environment files or keys, with no configuration at all", function()
    local files = {
      ["a.lua"] = 1,
      [".env"] = 1,
      [".env.local"] = 1,
      ["config/.env"] = 1,
      ["keys/server.pem"] = 1,
      ["deploy/id_rsa"] = 1,
      ["deploy/id_rsa.pub"] = 1,
      ["x.key"] = 1,
    }

    local plan = plan_of({ rule("A-01") }, files, { scopes = scopes })

    assert.are.same({ "a.lua" }, plan.batches[1].files)
    assert.are.same(
      { ".env", ".env.local", "config/.env", "deploy/id_rsa", "deploy/id_rsa.pub", "keys/server.pem", "x.key" },
      plan.denied
    )
  end)

  it("adds the deny globs of the config, a glob without a slash at any depth", function()
    local plan = plan_of({ rule("A-01") }, { ["a.lua"] = 1, ["x/notes.private"] = 1 }, {
      scopes = scopes,
      deny = { "*.private" },
    })

    assert.are.same({ "a.lua" }, plan.batches[1].files)
  end)

  it("reads a glob with a slash from the root, and a directory denies everything below it", function()
    local files = { ["a.lua"] = 1, ["secrets/a.txt"] = 1, ["secrets/deep/b.txt"] = 1, ["lib/secrets/c.txt"] = 1 }

    local plan = plan_of({ rule("A-01") }, files, { scopes = scopes, deny = { "secrets" } })
    local by_slash = plan_of({ rule("A-01") }, files, { scopes = scopes, deny = { "secrets/**" } })

    assert.are.same({ "a.lua", "lib/secrets/c.txt" }, by_slash.batches[1].files)
    -- no slash: any file or directory of that name, at any depth
    assert.are.same({ "a.lua" }, plan.batches[1].files)
  end)

  it("cannot be switched off by the config", function()
    local plan = plan_of({ rule("A-01") }, { ["a.lua"] = 1, [".env"] = 1 }, { scopes = scopes, deny = {} })

    assert.are.same({ "a.lua" }, plan.batches[1].files)
  end)

  it("keeps a rule whose scope only reaches denied files on the worklist", function()
    local plan = plan_of({ rule("A-01") }, { [".env"] = 1 }, { scopes = scopes })

    assert.are.same({}, plan.batches)
    assert.are.equal("manual", plan.skipped[1].status)
    assert.is_truthy(plan.skipped[1].reason:find("1 denied", 1, true))
  end)

  it("does not count a denied file against the size limit", function()
    local plan = plan_of({ rule("A-01") }, { ["a.lua"] = 10, [".env"] = 90000 }, { scopes = scopes })

    assert.are.equal(1, #plan.batches)
    assert.are.equal(10, plan.batches[1].bytes)
  end)
end)

describe("rules.engine.agent.plan on a real tree", function()
  it("walks the root, skips what the walk skips, and reads sizes from the disk", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/lua", "p")
    vim.fn.mkdir(dir .. "/.git", "p")
    vim.fn.writefile({ "abc" }, dir .. "/lua/a.lua")
    vim.fn.writefile({ "abc" }, dir .. "/.git/config")
    vim.fn.writefile({ "SECRET=1" }, dir .. "/.env")

    local plan = plan_lib.plan({ rule("A-01") }, dir, { agent = { scopes = { A = { include = { "**" } } } } })

    assert.are.same({ "lua/a.lua" }, plan.batches[1].files)
    assert.are.equal(4, plan.batches[1].bytes)
    assert.are.same({ ".env" }, plan.denied)
  end)
end)

describe("rules.engine.agent.plan deny edge cases", function()
  local scopes = { A = { include = { "**" } } }

  it("ignores case: KEY.PEM and .ENV are the same files on NTFS and APFS", function()
    local plan = plan_of({ rule("A-01") }, { ["a.lua"] = 1, ["KEY.PEM"] = 1, [".ENV"] = 1, ["x/ID_RSA"] = 1 }, {
      scopes = scopes,
      deny = { "*.PRIVATE" },
    })

    assert.are.same({ "a.lua" }, plan.batches[1].files)
  end)

  it("never sends a symbolic link, whatever its name", function()
    local plan = plan_lib.plan({ rule("A-01") }, "/nowhere", {
      agent = { scopes = scopes },
      files = { "a.lua", "docs/notes.txt" },
      size = function()
        return 1
      end,
      is_link = function(path)
        return path == "docs/notes.txt"
      end,
    })

    assert.are.same({ "a.lua" }, plan.batches[1].files)
    assert.are.same({ "docs/notes.txt" }, plan.denied)
  end)

  it("finds a real symbolic link on the disk", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "KEY" }, dir .. "/target.dat")
    vim.fn.writefile({ "x" }, dir .. "/a.lua")
    local linked = vim.uv.fs_symlink(dir .. "/target.dat", dir .. "/notes.txt")
    if not linked then
      pending("symlink creation not permitted on this machine")
      return
    end

    local plan = plan_lib.plan({ rule("A-01") }, dir, { agent = { scopes = scopes } })

    assert.is_false(vim.tbl_contains(plan.batches[1].files, "notes.txt"))
    assert.is_true(vim.tbl_contains(plan.denied, "notes.txt"))
  end)

  it("does not reorder the list of files it was given", function()
    local given = { "z.lua", "a.lua" }

    plan_lib.plan({ rule("A-01") }, "/nowhere", {
      agent = { scopes = scopes },
      files = given,
      size = function()
        return 1
      end,
    })

    assert.are.same({ "z.lua", "a.lua" }, given)
  end)

  it("treats a batch_size below 1 as 1 instead of failing", function()
    local plan = plan_of({ rule("A-01"), rule("A-02") }, { ["a.lua"] = 1 }, { scopes = scopes, batch_size = 0 })

    assert.are.equal(2, #plan.batches)
  end)

  it("names the source of the files on each rule of a batch", function()
    local plan = plan_of({ rule("A-01", { agent = { include = { "*.lua" } } }), rule("A-02") }, { ["a.lua"] = 1 }, {
      scopes = { A = { include = { "*.lua" } } },
    })

    assert.are.equal(1, #plan.batches)
    assert.are.equal("rule", plan.batches[1].rules[1].source)
    assert.are.equal("family", plan.batches[1].rules[2].source)
  end)
end)
