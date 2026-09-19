-- Several cases below monkey-patch `vim.fn.readfile` and `fswalk.files` at
-- runtime to simulate a read failure / count calls -- see NEW-42 in this
-- ecosystem's own rule catalog for the reasoning; confirmed firing via a live
-- lua_ls gegenprobe (2026-09-13), unlike a guessed-at suppression.
---@diagnostic disable: duplicate-set-field
local checks = require("rules.engine.checks")
local grep = require("rules.engine.checks.grep")
local file_exists = require("rules.engine.checks.file_exists")
local json_key = require("rules.engine.checks.json_key")
local lua_predicate = require("rules.engine.checks.lua_predicate")

--- A fresh empty temp directory.
---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

---@param dir string
---@param name string
---@param lines string[]
local function write_file(dir, name, lines)
  vim.fn.writefile(lines, dir .. "/" .. name)
end

--- The spelling a path under `dir` has once it has been through `fswalk` --
--- absolute and "/"-separated, which is `fswalk.files`' documented contract
--- and therefore the spelling of every `ctx` cache key and every finding's
--- `file`. `tmp_dir()` hands back whatever `vim.fn.tempname()` produces,
--- which on Windows is backslash-separated, so `dir .. "/" .. name` is a
--- *mixed*-separator third spelling that the engine never produces. Both
--- sides of a path comparison have to be resolved the same way -- exactly
--- what gate_spec.lua already does for `diff_files`' keys.
---@param dir string
---@param name string
---@return string
local function walked_path(dir, name)
  return vim.fs.normalize(dir) .. "/" .. name
end

describe("rules.engine.checks (dispatch)", function()
  it("ERR-01: a check impl that throws reports an error, not a crash, and names the check type", function()
    -- A malformed Lua pattern is the realistic real-world trigger (an
    -- unescaped `(`/`[`/trailing `%` in a ruleset-authored `grep` rule) --
    -- `string.find` throws on it rather than returning an error value.
    local dir = tmp_dir()
    write_file(dir, "a.lua", { "local x = 1" })

    local status, findings = checks.run({ type = "grep", pattern = "(" }, dir)

    assert.are.equal("error", status)
    assert.are.equal(1, #findings)
    assert.matches("grep check crashed", findings[1].text)
    -- `status.message` is a multi-line `debug.traceback()` string; a raw
    -- embed would crash `report/buffer.lua`'s `nvim_buf_set_lines` call on
    -- render (`'replacement string' item contains newlines`).
    assert.is_nil(findings[1].text:find("\n", 1, true))
  end)
end)

describe("rules.engine.checks.grep", function()
  it("passes when the pattern occurs nowhere", function()
    local dir = tmp_dir()
    write_file(dir, "a.lua", { "local x = 1" })

    local status, findings = grep.run({ type = "grep", pattern = "vim%.loop%." }, dir)

    assert.are.equal("pass", status)
    assert.are.equal(0, #findings)
  end)

  it("fails and reports file:line when the pattern occurs", function()
    local dir = tmp_dir()
    write_file(dir, "a.lua", { "local x = 1", "vim.loop.new_timer()" })

    local status, findings = grep.run({ type = "grep", pattern = "vim%.loop%." }, dir)

    assert.are.equal("fail", status)
    assert.are.equal(1, #findings)
    assert.are.equal(2, findings[1].line)
  end)

  it("suppresses a hit whose line also matches `unless`", function()
    local dir = tmp_dir()
    write_file(dir, "a.lua", { "local uv = vim.uv or vim.loop" })

    local status = grep.run({
      type = "grep",
      pattern = "vim%.loop%.?",
      unless = "vim%.uv or vim%.loop",
    }, dir)

    assert.are.equal("pass", status)
  end)

  it("only scans files matching `include`", function()
    local dir = tmp_dir()
    write_file(dir, "a.txt", { "vim.loop.new_timer()" })

    local status = grep.run({ type = "grep", pattern = "vim%.loop%." }, dir)

    assert.are.equal("pass", status) -- default include is "%.lua$", so a.txt is skipped
  end)

  it("`excludes` skips a whole file even though it matches `include`", function()
    local dir = tmp_dir()
    vim.fn.mkdir(dir .. "/TESTS", "p")
    write_file(dir .. "/TESTS", "checks_spec.lua", { "os.execute('rm -rf tmp')" })
    write_file(dir, "real.lua", { "local x = 1" })

    local status, findings = grep.run({
      type = "grep",
      pattern = "os%.execute%(",
      excludes = { "/TESTS/" },
    }, dir)

    assert.are.equal("pass", status)
    assert.are.equal(0, #findings)
  end)

  it("`excludes` does not touch a file that does not match any of them", function()
    local dir = tmp_dir()
    vim.fn.mkdir(dir .. "/TESTS", "p")
    write_file(dir .. "/TESTS", "fixture.lua", { "os.execute('rm -rf tmp')" })
    write_file(dir, "real.lua", { "os.execute('rm -rf tmp')" })

    local status, findings = grep.run({
      type = "grep",
      pattern = "os%.execute%(",
      excludes = { "/TESTS/" },
    }, dir)

    assert.are.equal("fail", status)
    assert.are.equal(1, #findings)
    assert.is_true(findings[1].file:find("real%.lua$") ~= nil)
  end)

  it("fails (not a silent skip) when a matching file cannot be read", function()
    local dir = tmp_dir()
    write_file(dir, "a.lua", { "irrelevant content" })

    local original_readfile = vim.fn.readfile
    vim.fn.readfile = function(path)
      if path:match("a%.lua$") then
        error("EACCES: permission denied")
      end
      return original_readfile(path)
    end

    local ok, status, findings = pcall(grep.run, { type = "grep", pattern = "irrelevant" }, dir)
    vim.fn.readfile = original_readfile

    assert.is_true(ok)
    assert.are.equal("fail", status)
    assert.are.equal(1, #findings)
    assert.matches("could not read file", findings[1].text)
    -- Same crash class as checks/init.lua's ERR-01 test above: the caught
    -- error's `.message` is a multi-line traceback.
    assert.is_nil(findings[1].text:find("\n", 1, true))
  end)

  it("reuses a shared ctx's file listing across two calls instead of re-walking", function()
    local dir = tmp_dir()
    write_file(dir, "a.lua", { "x" })

    local fswalk = require("rules.engine.fswalk")
    local calls = 0
    local original_files = fswalk.files
    fswalk.files = function(...)
      calls = calls + 1
      return original_files(...)
    end

    local ctx = {}
    grep.run({ type = "grep", pattern = "x" }, dir, ctx)
    grep.run({ type = "grep", pattern = "y" }, dir, ctx)
    fswalk.files = original_files

    assert.are.equal(1, calls)
  end)

  it("without a shared ctx, each call walks independently", function()
    local dir = tmp_dir()
    write_file(dir, "a.lua", { "x" })

    local fswalk = require("rules.engine.fswalk")
    local calls = 0
    local original_files = fswalk.files
    fswalk.files = function(...)
      calls = calls + 1
      return original_files(...)
    end

    grep.run({ type = "grep", pattern = "x" }, dir)
    grep.run({ type = "grep", pattern = "y" }, dir)
    fswalk.files = original_files

    assert.are.equal(2, calls)
  end)

  it("ERR-60: caches no read error for a file that reads successfully, not a truthy garbage value", function()
    -- Regression for `ok and nil or err` -- `nil` is itself falsy, so that
    -- ternary shape silently ignores `ok` and always takes the error
    -- branch. A Lua table can't actually store a `nil` value under a key
    -- (assigning `nil` deletes it), so the broken version would have left
    -- `file_errors[file]` set to the *stringified readfile result* instead
    -- (`tostring(lines)`, a `"table: 0x..."` string) -- truthy garbage,
    -- not absent and not nil.
    local dir = tmp_dir()
    local file = walked_path(dir, "a.lua")
    write_file(dir, "a.lua", { "x" })

    local ctx = {}
    grep.run({ type = "grep", pattern = "x" }, dir, ctx)

    assert.is_not_nil(ctx.file_contents[file])
    assert.is_nil(ctx.file_errors[file])
  end)

  it("`patterns` matches any of several calls (DEP-04's two deprecated names)", function()
    local dir = tmp_dir()
    write_file(dir, "a.lua", { "nvim_out_write('x')" })

    local status, findings = grep.run({
      type = "grep",
      patterns = { "nvim_err_writeln%(", "nvim_out_write%(" },
    }, dir)

    assert.are.equal("fail", status)
    assert.are.equal(1, #findings)
  end)
end)

describe("rules.engine.checks.file_exists", function()
  it("file_exists passes when the file is there", function()
    local dir = tmp_dir()
    write_file(dir, "README.md", { "hello" })

    local status = file_exists.run({ type = "file_exists", path = "README.md" }, dir)

    assert.are.equal("pass", status)
  end)

  it("file_exists fails when the file is missing", function()
    local dir = tmp_dir()

    local status, findings = file_exists.run({ type = "file_exists", path = "LICENSE" }, dir)

    assert.are.equal("fail", status)
    assert.are.equal(1, #findings)
  end)

  it("file_absent fails when the file is present", function()
    local dir = tmp_dir()
    write_file(dir, ".luarc.json", { "{}" })

    local status = file_exists.run({ type = "file_absent", path = ".luarc.json" }, dir)

    assert.are.equal("fail", status)
  end)

  it("file_absent passes when the file is missing", function()
    local dir = tmp_dir()

    local status = file_exists.run({ type = "file_absent", path = "nope" }, dir)

    assert.are.equal("pass", status)
  end)

  it("file_exists with `paths` passes when any one candidate is present", function()
    local dir = tmp_dir()
    write_file(dir, ".stylua.toml", { "" })

    local status = file_exists.run({ type = "file_exists", paths = { "stylua.toml", ".stylua.toml" } }, dir)

    assert.are.equal("pass", status)
  end)

  it("file_exists with `paths` fails only when NONE of the candidates are present", function()
    local dir = tmp_dir()

    local status, findings = file_exists.run({ type = "file_exists", paths = { "stylua.toml", ".stylua.toml" } }, dir)

    assert.are.equal("fail", status)
    assert.are.equal(1, #findings)
  end)

  it("errors loudly, not a silent pass, when neither `path` nor `paths` is set", function()
    -- Regression: a typo'd field name (`Path` instead of `path`) used to
    -- crash (root .. "/" .. nil), loud and visible. The `paths` refactor
    -- made `candidates` default to `{}` for the same typo, which turned
    -- file_absent's "nothing found" branch into a silent, wrong "pass" --
    -- indistinguishable from a rule that genuinely found the forbidden file
    -- absent. Worst on exactly the rule shape ("this file must never
    -- exist") where a silently vacuous check does the most damage.
    local dir = tmp_dir()

    local status, findings = file_exists.run({ type = "file_absent", Path = ".env" }, dir)
    assert.are.equal("error", status)
    assert.are.equal(1, #findings)

    local status2, findings2 = file_exists.run({ type = "file_exists" }, dir)
    assert.are.equal("error", status2)
    assert.are.equal(1, #findings2)
  end)

  it("PRIN-25: errors loudly on a wrong-typed `path` instead of throwing", function()
    local dir = tmp_dir()

    local status, findings = file_exists.run({ type = "file_exists", path = true }, dir)

    assert.are.equal("error", status)
    assert.are.equal(1, #findings)
  end)
end)

describe("rules.engine.checks.json_key", function()
  it("passes when the file is missing entirely", function()
    local dir = tmp_dir()

    local status = json_key.run({ type = "json_key_absent", path = ".luarc.json", key = "workspace.library" }, dir)

    assert.are.equal("pass", status)
  end)

  it("passes when the key is genuinely absent", function()
    local dir = tmp_dir()
    write_file(dir, ".luarc.json", { '{ "diagnostics.globals": ["vim"] }' })

    local status = json_key.run({ type = "json_key_absent", path = ".luarc.json", key = "workspace.library" }, dir)

    assert.are.equal("pass", status)
  end)

  it("fails when the dotted key is set", function()
    local dir = tmp_dir()
    write_file(dir, ".luarc.json", { '{ "workspace": { "library": ["foo"] } }' })

    local status = json_key.run({ type = "json_key_absent", path = ".luarc.json", key = "workspace.library" }, dir)

    assert.are.equal("fail", status)
  end)

  it("fails loudly on unparseable JSON rather than silently passing", function()
    local dir = tmp_dir()
    write_file(dir, ".luarc.json", { "{ not json" })

    local status = json_key.run({ type = "json_key_absent", path = ".luarc.json", key = "workspace.library" }, dir)

    assert.are.equal("fail", status)
  end)

  it("PRIN-25: errors loudly when `path` or `key` is missing/wrong-typed instead of throwing", function()
    local dir = tmp_dir()

    local status, findings = json_key.run({ type = "json_key_absent", key = "workspace.library" }, dir)
    assert.are.equal("error", status)
    assert.are.equal(1, #findings)

    local status2, findings2 = json_key.run({ type = "json_key_absent", path = ".luarc.json" }, dir)
    assert.are.equal("error", status2)
    assert.are.equal(1, #findings2)
  end)

  it("ERR-01: reports an error, not a crash, when readfile throws after filereadable passed", function()
    local dir = tmp_dir()
    write_file(dir, ".luarc.json", { "{}" })

    local original_readfile = vim.fn.readfile
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.readfile = function()
      error("E484: Can't open file")
    end

    local ok, status, findings =
      pcall(json_key.run, { type = "json_key_absent", path = ".luarc.json", key = "workspace.library" }, dir)
    vim.fn.readfile = original_readfile

    assert.is_true(ok)
    assert.are.equal("error", status)
    assert.matches("could not read file", findings[1].text)
    -- Same crash class as checks/init.lua's ERR-01 test above: the caught
    -- error's `.message` is a multi-line traceback.
    assert.is_nil(findings[1].text:find("\n", 1, true))
  end)
end)

describe("rules.engine.checks.lua_predicate", function()
  it("passes when fn returns true", function()
    local status = lua_predicate.run({
      type = "lua_predicate",
      fn = function()
        return true
      end,
    }, "/tmp")

    assert.are.equal("pass", status)
  end)

  it("fails with the returned findings when fn returns false", function()
    local status, findings = lua_predicate.run({
      type = "lua_predicate",
      fn = function()
        return false, { { file = "x", line = 1, text = "nope" } }
      end,
    }, "/tmp")

    assert.are.equal("fail", status)
    assert.are.equal(1, #findings)
  end)

  it("reports an error, not a crash, when fn throws", function()
    local status, findings = lua_predicate.run({
      type = "lua_predicate",
      fn = function()
        error("boom")
      end,
    }, "/tmp")

    assert.are.equal("error", status)
    assert.matches("boom", findings[1].text)
    -- Same crash class as checks/init.lua's ERR-01 test above: the caught
    -- error's `.message` is a multi-line traceback.
    assert.is_nil(findings[1].text:find("\n", 1, true))
  end)

  it("ERR-02: reports an error, not a malformed finding, when fn's findings lack a `line`", function()
    local status, findings = lua_predicate.run({
      type = "lua_predicate",
      fn = function()
        return false, { { file = "x", text = "nope" } }
      end,
    }, "/tmp")

    assert.are.equal("error", status)
    assert.matches("malformed finding", findings[1].text)
  end)
end)
