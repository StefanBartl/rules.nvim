local fswalk = require("rules.engine.fswalk")

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

---@param list string[]
---@param suffix string
---@return boolean
local function contains_suffix(list, suffix)
  for _, item in ipairs(list) do
    if item:sub(-#suffix) == suffix then
      return true
    end
  end
  return false
end

describe("rules.engine.fswalk.files", function()
  it("lists files recursively", function()
    local dir = tmp_dir()
    write_file(dir, "a.lua", { "x" })
    vim.fn.mkdir(dir .. "/sub", "p")
    write_file(dir .. "/sub", "b.lua", { "y" })

    local files = fswalk.files(dir)

    assert.is_true(contains_suffix(files, "/a.lua"))
    assert.is_true(contains_suffix(files, "/sub/b.lua"))
  end)

  it("returns '/'-separated paths even when root itself uses backslashes", function()
    local dir = tmp_dir()
    write_file(dir, "bad.lua", { "x" })

    local backslash_root = dir:gsub("/", "\\")
    local files = fswalk.files(backslash_root)

    assert.is_true(contains_suffix(files, "/bad.lua"))
    for _, item in ipairs(files) do
      assert.is_nil(item:find("\\", 1, true))
    end
  end)

  it("skips .git, .deps and .claude directories", function()
    local dir = tmp_dir()
    vim.fn.mkdir(dir .. "/.git", "p")
    write_file(dir .. "/.git", "config", { "x" })
    vim.fn.mkdir(dir .. "/.deps", "p")
    write_file(dir .. "/.deps", "vendored.lua", { "x" })
    -- .claude/worktrees/<name> is a second full checkout of this same repo
    -- (a running Claude Code session's own worktree) -- without skipping it,
    -- every finding in that checkout was counted a second time.
    vim.fn.mkdir(dir .. "/.claude/worktrees/some-session/lua", "p")
    write_file(dir .. "/.claude/worktrees/some-session/lua", "duplicate.lua", { "x" })
    write_file(dir, "real.lua", { "x" })

    local files = fswalk.files(dir)

    assert.is_false(contains_suffix(files, "/.git/config"))
    assert.is_false(contains_suffix(files, "/.deps/vendored.lua"))
    assert.is_false(contains_suffix(files, "/duplicate.lua"))
    assert.is_true(contains_suffix(files, "/real.lua"))
  end)

  it("lists a symlinked file -- a plain uv.fs_scandir_next type check can miss this", function()
    local uv = vim.uv or vim.loop
    local dir = tmp_dir()
    write_file(dir, "real.lua", { "x" })
    local ok = uv.fs_symlink(dir .. "/real.lua", dir .. "/link.lua")
    if not ok then
      pending("symlink creation not permitted on this machine")
      return
    end

    local files = fswalk.files(dir)

    assert.is_true(contains_suffix(files, "/link.lua"))
  end)
end)
