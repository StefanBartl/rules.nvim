-- TESTS/vault_behind_spec.lua -- two machines make a rule in one family without a pull in between: the vault that lies behind
-- its upstream is told when a rule is made (`rules-ops/1` `new`, `:Rules new`, the form's question), never refused, and the
-- engine itself never pulls, fetches or commits.
--
-- The machines are real git repositories in a temporary folder (a bare "origin" and two clones, all on this disk: no
-- network). Paths are compared by real path, never by their spelling (macOS /var -> /private/var, Windows 8.3 names).
---@diagnostic disable: need-check-nil
local contract = require("rules.contract")
local ops = require("rules.ops")
local vault = require("rules.vault")
local write = require("rules.write")
local cmd = require("rules.ui.cmd")
local settings = require("rules.settings")

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
local function rule_text(id)
  return table.concat({
    "---",
    "id: " .. id,
    "severity: critical",
    "family: " .. id:match("^(%u+)"),
    "---",
    "",
    "#### `" .. id .. "` — a rule",
    "",
    "Text of " .. id .. ".",
    "",
  }, "\n")
end

---@param dir string
---@param ... string
---@return string stdout
local function git(dir, ...)
  local argv = { "git", "-c", "user.name=spec", "-c", "user.email=spec@example.invalid", "-c", "commit.gpgsign=false" }
  vim.list_extend(argv, { "-C", dir, ... })
  local done = vim.system(argv, { text = true }):wait(30000)
  assert(done.code == 0, ("git %s: %s"):format(table.concat({ ... }, " "), done.stderr or ""))
  return vim.trim(done.stdout or "")
end

---@param a string
---@param b string
---@return boolean
local function same_folder(a, b)
  return vim.fs.normalize(vim.uv.fs_realpath(a) or a) == vim.fs.normalize(vim.uv.fs_realpath(b) or b)
end

local have_git = vim.fn.executable("git") == 1

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return (path:gsub("\\", "/"))
end

---The two machines: `a` is the one the spec works on (DEP-01 and DEP-02 are pushed), `b` is another clone.
---@return { origin: string, a: string, b: string }
local function machines()
  local base = tmp_dir()
  local origin, a, b = base .. "/origin.git", base .. "/a", base .. "/b"
  vim.fn.mkdir(origin, "p")
  git(origin, "init", "-q", "--bare")
  git(origin, "symbolic-ref", "HEAD", "refs/heads/main")
  git(base, "clone", "-q", origin, "a")
  for _, id in ipairs({ "DEP-01", "DEP-02" }) do
    write_raw(("%s/rulesets/lua/_rules/DEP/%s.md"):format(a, id), rule_text(id))
  end
  git(a, "add", "-A")
  git(a, "commit", "-q", "-m", "two rules")
  git(a, "branch", "-M", "main")
  git(a, "push", "-q", "-u", "origin", "main")
  git(base, "clone", "-q", origin, "b")
  return { origin = origin, a = a, b = b }
end

---Another machine makes DEP-03 and pushes; `a` has fetched, so it knows (it has not pulled).
---@param m { origin: string, a: string, b: string }
local function other_machine_makes_dep03(m)
  write_raw(m.b .. "/rulesets/lua/_rules/DEP/DEP-03.md", rule_text("DEP-03"))
  git(m.b, "add", "-A")
  git(m.b, "commit", "-q", "-m", "DEP-03 from b")
  git(m.b, "push", "-q", "origin", "main")
  git(m.a, "fetch", "-q")
end

---@param opts table
---@param extra? table
---@return table entry
local function new_rule(opts, extra)
  local op = vim.tbl_extend("force", { op = "new", family = "DEP", title = "Fresh", severity = "critical" }, extra or {})
  local doc, err = ops.run({ ops = { op } }, opts)
  assert(doc, vim.inspect(err))
  return doc.results[1]
end

---A dry run of `new`: the entry, nothing written.
---@param opts table
---@return table entry
local function dry_new(opts)
  local op = { op = "new", family = "DEP", title = "T", severity = "critical" }
  local doc, err = ops.run({ dry_run = true, ops = { op } }, opts)
  assert(doc, vim.inspect(err))
  return doc.results[1]
end

---The machines once for the whole file, for the cases that only read or dry-run (a git setup costs a second or two):
---`a` is behind by DEP-03, which another machine made. A case that writes builds its own.
local shared
---@return { origin: string, a: string, b: string }
local function shared_behind()
  if not shared then
    shared = machines()
    other_machine_makes_dep03(shared)
  end
  return shared
end

---Machines that are up to date, once for the whole file, for the cases that only dry-run.
local clean
---@return { origin: string, a: string, b: string }
local function shared_clean()
  clean = clean or machines()
  return clean
end

describe("rules.vault.behind @spawn", function()
  if not have_git then
    it("needs git", function()
      pending("git is not installed")
    end)
    return
  end

  it("is silent for a folder that is no repository", function()
    assert.is_nil(vault.behind(tmp_dir()))
  end)

  it("is silent for a repository without an upstream", function()
    local dir = tmp_dir()
    git(dir, "init", "-q")
    write_raw(dir .. "/x", "x")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "x")
    assert.is_nil(vault.behind(dir))
  end)

  it("counts what a pull would bring, and knows only what the last fetch brought home", function()
    local m = machines()
    assert.are.equal(0, vault.behind(m.a))
    write_raw(m.b .. "/rulesets/lua/_rules/DEP/DEP-03.md", rule_text("DEP-03"))
    git(m.b, "add", "-A")
    git(m.b, "commit", "-q", "-m", "DEP-03 from b")
    git(m.b, "push", "-q", "origin", "main")
    -- the origin has it, this clone has not asked: no network, so nothing to say yet
    assert.are.equal(0, vault.behind(m.a))
    git(m.a, "fetch", "-q")
    assert.are.equal(1, vault.behind(m.a))
    git(m.a, "pull", "-q", "--ff-only")
    assert.are.equal(0, vault.behind(m.a))
  end)

  it("works from a folder below the top of the repository", function()
    assert.are.equal(1, vault.behind(shared_behind().a .. "/rulesets/lua"))
  end)

  it("asks git for the local refs only: read only, with a timeout, no fetch, no pull", function()
    local git_lib = require("lib.nvim.git")
    local original = git_lib.run
    local seen
    git_lib.run = function(args, opts)
      seen = { args = args, opts = opts }
      return { code = 0, stdout = "2\n", stderr = "" }
    end
    local ok, behind = pcall(vault.behind, "/somewhere")
    git_lib.run = original
    assert(ok, behind)
    assert.are.equal(2, behind)
    assert.are.same({ "rev-list", "--count", "HEAD..@{u}" }, seen.args)
    assert.are.equal("/somewhere", seen.opts.dir)
    assert.is_true(seen.opts.read_only)
    assert.is_true(seen.opts.no_lazy_fetch)
    assert.is_true(seen.opts.timeout_ms > 0 and seen.opts.timeout_ms <= 5000)
  end)

  it("is silent when git times out, fails, or answers with something else", function()
    local git_lib = require("lib.nvim.git")
    local original = git_lib.run
    for _, answer in ipairs({
      { code = 1, stdout = "", stderr = "fatal: no upstream configured" },
      { code = 0, stdout = "", timed_out = true },
      { code = 0, stdout = "not a number\n" },
    }) do
      git_lib.run = function()
        return answer
      end
      local ok, behind = pcall(vault.behind, "/somewhere")
      git_lib.run = original
      assert(ok, behind)
      assert.is_nil(behind, vim.inspect(answer))
    end
  end)

  it("is silent when git is not installed", function()
    local original = vim.fn.executable
    vim.fn.executable = function()
      return 0
    end
    local ok, behind = pcall(vault.behind, "/somewhere")
    vim.fn.executable = original
    assert(ok, behind)
    assert.is_nil(behind)
  end)
end)

describe("a rule made in a vault that lies behind its upstream @spawn", function()
  if not have_git then
    it("needs git", function()
      pending("git is not installed")
    end)
    return
  end

  before_each(function()
    contract.clear_cache()
  end)

  it("is made, and the entry warns: pull first, or another machine may make the same id", function()
    local m = machines()
    other_machine_makes_dep03(m)
    local head, upstream = git(m.a, "rev-parse", "HEAD"), git(m.a, "rev-parse", "@{u}")
    local entry = new_rule({ vault = m.a, today = "2026-10-15" })
    assert.is_true(entry.ok, vim.inspect(entry))
    assert.are.equal("created", entry.outcome)
    -- DEP-03 exists in the origin, not here: this machine gives it out again, which is the case the warning is for
    assert.are.equal("DEP-03", entry.id)
    assert.are.equal(1, #entry.warnings)
    assert.is_truthy(entry.warnings[1]:find("1 commit(s) behind its upstream", 1, true))
    assert.is_truthy(entry.warnings[1]:find("pull before you make a rule", 1, true))
    assert.is_truthy(read_raw(m.a .. "/rulesets/lua/_rules/DEP/DEP-03.md"))

    -- the engine pulled nothing, fetched nothing and committed nothing: the new file is the only change
    assert.are.equal(head, git(m.a, "rev-parse", "HEAD"))
    assert.are.equal(upstream, git(m.a, "rev-parse", "@{u}"))
    assert.are.equal(1, vault.behind(m.a), "still behind: nothing was pulled")
    local status = git(m.a, "status", "--porcelain")
    assert.is_truthy(status:find("DEP-03.md", 1, true))
    assert.are.equal(1, #vim.split(status, "\n", { plain = true }), status)
  end)

  it("is quiet once the vault is up to date, and the next id is a new one", function()
    local m = machines()
    other_machine_makes_dep03(m)
    git(m.a, "pull", "-q", "--ff-only")
    contract.clear_cache()
    local entry = new_rule({ vault = m.a, today = "2026-10-15" })
    assert.is_true(entry.ok)
    assert.is_nil(entry.warnings)
    assert.are.equal("DEP-04", entry.id)
  end)

  it("warns in a dry run too, writes nothing, and has the warning as a list in the document an app reads", function()
    local m = shared_behind()
    local entry = dry_new({ vault = m.a, today = "2026-10-15" })
    assert.are.equal("would_create", entry.outcome)
    assert.are.equal(1, #entry.warnings)
    assert.is_nil(read_raw(m.a .. "/rulesets/lua/_rules/DEP/DEP-03.md"))

    local text = require("rules.api").call(
      "ops",
      vim.json.encode({ dry_run = true, ops = { { op = "new", family = "DEP", title = "T", severity = "critical" } } }),
      { vault = m.a }
    )
    local decoded = vim.json.decode(text)
    assert.is_true(decoded.ok)
    assert.is_true(vim.islist(decoded.results[1].warnings))
    assert.is_truthy(text:find('"warnings":["the vault is 1 commit(s) behind', 1, true))
  end)

  it("is quiet when nothing is behind", function()
    local m = shared_clean()
    local entry = dry_new({ vault = m.a, today = "2026-10-15" })
    assert.are.equal("would_create", entry.outcome)
    assert.is_nil(entry.warnings)
  end)

  it("is quiet for a vault that is no repository, and for one without an upstream", function()
    local plain = tmp_dir()
    write_raw(plain .. "/rulesets/lua/_rules/DEP/DEP-01.md", rule_text("DEP-01"))
    local entry = dry_new({ vault = plain, today = "2026-10-15" })
    assert.are.equal("would_create", entry.outcome)
    assert.is_nil(entry.warnings)

    local local_only = tmp_dir()
    git(local_only, "init", "-q")
    write_raw(local_only .. "/rulesets/lua/_rules/DEP/DEP-01.md", rule_text("DEP-01"))
    git(local_only, "add", "-A")
    git(local_only, "commit", "-q", "-m", "x")
    entry = dry_new({ vault = local_only, today = "2026-10-15" })
    assert.are.equal("would_create", entry.outcome)
    assert.is_nil(entry.warnings)
  end)

  it("is quiet for a ruleset that is not in the vault, and without a vault", function()
    local m = shared_behind()
    local elsewhere = tmp_dir() .. "/Checklists"
    write_raw(elsewhere .. "/_rules/DEP/DEP-01.md", rule_text("DEP-01"))
    local entry = dry_new({ vault = m.a, rulesets = { elsewhere }, today = "2026-10-15" })
    assert.are.equal("would_create", entry.outcome)
    assert.is_nil(entry.warnings)

    local saved = vim.env.RULES_VAULT
    vim.env.RULES_VAULT = nil
    settings.reset()
    entry = dry_new({ rulesets = { elsewhere }, today = "2026-10-15" })
    vim.env.RULES_VAULT = saved
    settings.reset()
    assert.are.equal("would_create", entry.outcome)
    assert.is_nil(entry.warnings)
  end)

  it("finds the vault by its real path: a link to the vault is the same folder as the vault", function()
    local m = shared_behind()
    local link = tmp_dir() .. "/vault-link"
    local ok = vim.uv.fs_symlink(m.a, link, { dir = true, junction = true })
    if not ok then
      pending("a link cannot be made here")
      return
    end
    assert.is_true(same_folder(link, m.a))
    -- the vault by the link, the ruleset by its own path: one folder either way
    local entry = dry_new({ vault = link, rulesets = { m.a .. "/rulesets/lua" }, today = "2026-10-15" })
    assert.are.equal("would_create", entry.outcome)
    assert.are.equal(1, #entry.warnings)
  end)

  it("does not change what is refused: an invalid request is refused, without a warning", function()
    local m = shared_behind()
    local op = { op = "new", family = "DEP", title = "T", severity = "urgent" }
    local doc = assert(ops.run({ dry_run = true, ops = { op } }, { vault = m.a }))
    assert.is_false(doc.results[1].ok)
    assert.is_nil(doc.results[1].warnings)
  end)

  describe("in the editor", function()
    local saved_notify, notes

    ---@param needle string
    ---@param level? integer
    ---@return boolean
    local function told(needle, level)
      for _, note in ipairs(notes) do
        if note.text:find(needle, 1, true) and (level == nil or note.level == level) then
          return true
        end
      end
      return false
    end

    before_each(function()
      saved_notify = vim.notify
      notes = {}
      vim.notify = function(msg, level)
        notes[#notes + 1] = { text = tostring(msg), level = level }
      end
    end)

    ---@param vault_dir string
    local function editor_with(vault_dir)
      pcall(vim.api.nvim_del_user_command, "Rules")
      pcall(vim.api.nvim_del_user_command, "RulesVault")
      require("rules").setup({ vault = vault_dir })
      settings.reset()
      contract.clear_cache()
    end

    after_each(function()
      vim.notify = saved_notify
      pcall(vim.api.nvim_del_user_command, "Rules")
      pcall(vim.api.nvim_del_user_command, "RulesVault")
      require("rules.config").setup({})
      settings.reset()
    end)

    it(":Rules new tells the warning at the level of a warning, after the line that says what it did", function()
      editor_with(shared_behind().a)
      vim.cmd("Rules new DEP Fresh severity=critical --dry")
      assert.is_true(told("would create DEP-03", vim.log.levels.INFO))
      assert.is_true(told("commit(s) behind its upstream", vim.log.levels.WARN))
      local first, second
      for i, note in ipairs(notes) do
        if note.text:find("would create", 1, true) then
          first = i
        elseif note.text:find("behind its upstream", 1, true) then
          second = i
        end
      end
      assert.is_true(first < second)
    end)

    it(":Rules new says nothing about it when the vault is up to date", function()
      editor_with(shared_clean().a)
      vim.cmd("Rules new DEP Fresh severity=critical --dry")
      assert.is_true(told("would create DEP-03", vim.log.levels.INFO))
      assert.is_false(told("behind its upstream"))
    end)

    it("write.messages turns every warning of an entry into a warn message", function()
      local result = {
        ok = true,
        entries = { { ok = true, id = "DEP-09", outcome = "created", warnings = { "first", "second" } } },
      }
      local messages = write.messages(result, { { op = "new" } })
      assert.are.same({
        { level = "info", text = "created DEP-09" },
        { level = "warn", text = "first" },
        { level = "warn", text = "second" },
      }, messages)
    end)

    it("the question before the rule is made shows the warning, the file and the id", function()
      local text = cmd.preview_text(
        { family = "DEP", severity = "critical", title = "Fresh" },
        { id = "DEP-03", warnings = { "the vault is 1 commit(s) behind its upstream: pull first" } }
      )
      assert.is_truthy(text:find("Warning: the vault is 1 commit(s) behind its upstream: pull first", 1, true))
      assert.is_truthy(text:find("Back returns to the form", 1, true))
      local plain = cmd.preview_text({ family = "DEP", severity = "critical", title = "Fresh" }, { id = "DEP-03" })
      assert.is_nil(plain:find("Warning", 1, true))
    end)
  end)
end)
