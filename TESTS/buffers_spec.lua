-- TESTS/buffers_spec.lua -- the open buffers of a ruleset around a write: reload what changed, report what cannot be.
---@diagnostic disable: need-check-nil
local buffers = require("rules.buffers")

---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param buf integer
---@return string
local function text_of(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

describe("rules.buffers", function()
  local root, file, outside

  local origin

  -- a loaded buffer without a window: nothing to show, no syntax to load, no empty buffer left behind
  ---@param path string
  ---@return integer buf
  local function open(path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    return buf
  end

  -- the rule files are Markdown: their FileType would load a syntax that defines highlight groups, which the
  -- state guard counts as a leak of the spec
  local saved_ignore

  before_each(function()
    saved_ignore = vim.o.eventignore
    vim.o.eventignore = "FileType,Syntax"
    origin = vim.api.nvim_get_current_buf()
    root = vim.fn.tempname() .. "/Checklists"
    file = root .. "/_rules/DEP/DEP-01.md"
    write_raw(file, "one\n")
    outside = vim.fn.tempname() .. "/other.md"
    write_raw(outside, "outside\n")
  end)

  after_each(function()
    vim.o.eventignore = saved_ignore
    vim.api.nvim_set_current_buf(origin)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if buf ~= origin then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end)

  it("reloads an unmodified buffer whose file changed", function()
    local buf = open(file)
    local snaps = buffers.snapshot({ root })
    write_raw(file, "two\n")
    local report = buffers.refresh(snaps)
    assert.are.equal(1, #report.reloaded)
    assert.are.equal("two", text_of(buf))
    assert.is_false(vim.bo[buf].modified)
    assert.are.same({}, report.conflicts)
  end)

  it("reloads the buffer in the window that shows it", function()
    local buf = open(file)
    vim.api.nvim_win_set_buf(0, buf)
    assert.are_not.equal(-1, vim.fn.bufwinid(buf))
    local snaps = buffers.snapshot({ root })
    write_raw(file, "two\n")
    assert.are.equal(1, #buffers.refresh(snaps).reloaded)
    assert.are.equal("two", text_of(buf))
  end)

  it("reloads a hidden buffer too (it has no window)", function()
    local buf = open(file)
    assert.are.equal(-1, vim.fn.bufwinid(buf))
    local snaps = buffers.snapshot({ root })
    write_raw(file, "two\n")
    local report = buffers.refresh(snaps)
    assert.are.equal(1, #report.reloaded)
    assert.are.equal("two", text_of(buf))
  end)

  it("leaves a buffer with unsaved changes as it is and names it as a conflict", function()
    local buf = open(file)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my edit" })
    local snaps = buffers.snapshot({ root })
    write_raw(file, "two\n")
    local report = buffers.refresh(snaps)
    assert.are.equal(1, #report.conflicts)
    assert.are.same({}, report.reloaded)
    assert.are.equal("my edit", text_of(buf))
    assert.is_true(vim.bo[buf].modified)
  end)

  it("says nothing about a file the write did not change, not even in a modified buffer", function()
    local buf = open(file)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "my edit" })
    local snaps = buffers.snapshot({ root })
    local report = buffers.refresh(snaps)
    assert.are.same({ reloaded = {}, conflicts = {}, gone = {}, stale = {} }, report)
    assert.are.equal("my edit", text_of(buf))
  end)

  it("names a file that is gone (a retired rule) and leaves its buffer", function()
    local buf = open(file)
    local snaps = buffers.snapshot({ root })
    assert.is_true(os.remove(file))
    local report = buffers.refresh(snaps)
    assert.are.equal(1, #report.gone)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
    assert.are.equal("one", text_of(buf))
  end)

  it("does not look at a buffer outside the ruleset", function()
    local buf = open(outside)
    local snaps = buffers.snapshot({ root })
    assert.are.same({}, snaps)
    write_raw(outside, "changed\n")
    local report = buffers.refresh(snaps)
    assert.are.same({}, report.reloaded)
    assert.are.equal("outside", text_of(buf))
  end)

  it("does not take a folder with the same start as the ruleset for a part of it", function()
    local sibling = root .. "-two/_rules/DEP/DEP-09.md"
    write_raw(sibling, "nine\n")
    open(sibling)
    assert.are.same({}, buffers.snapshot({ root }))
  end)

  it("names a buffer it could not reload as stale (an autocmd vetoes the read)", function()
    local buf = open(file)
    local snaps = buffers.snapshot({ root })
    write_raw(file, "two\n")
    local veto = vim.api.nvim_create_autocmd("BufReadPre", {
      callback = function()
        error("vetoed")
      end,
    })
    local report = buffers.refresh(snaps)
    vim.api.nvim_del_autocmd(veto)
    assert.are.equal(1, #report.stale)
    assert.are.same({}, report.reloaded)
    assert.is_true(vim.api.nvim_buf_is_valid(buf))
  end)

  it("takes a ruleset that is one file", function()
    local buf = open(file)
    local snaps = buffers.snapshot({ file })
    write_raw(file, "two\n")
    assert.are.equal(1, #buffers.refresh(snaps).reloaded)
    assert.are.equal("two", text_of(buf))
  end)
end)
