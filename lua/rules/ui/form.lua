---@module 'rules.ui.form'
---@brief The buffer, the keys and the help of the `:Rules new` form -- a thin UI over `rules.form`.
---@description
--- Opens the form text (`rules.form.template`) in a scratch Markdown buffer and binds the keys. All the rules
--- (parsing, checking what is required, the one tick of the severity) are in `rules.form`; what is done with a
--- checked request (`on_submit`) is the caller's, so a refusal of the engine leaves the form open with everything
--- typed.
---
--- Keys (buffer-local, listed by `g?`):
---  - `<Space>` / `<CR>` on a severity bullet: tick / untick it (anywhere else the key is what it always is)
---  - `<C-s>` (normal and insert): check the form and submit it
---  - `q` (normal) / `<C-q>`: cancel, nothing is created (asks first when something was typed)
---  - `g?`: help
---
--- Not its job: the form rules (`rules.form`), the questions and the write (`rules.ui.cmd`).

local form = require("rules.form")

local M = {}

---The text of `g?`.
---@return string[]
function M.help_lines()
  return {
    "Rule form",
    "",
    "<Space> / <CR>   tick or untick the severity under the cursor (one tick)",
    "<C-s>            check the form, then create the rule",
    "q / <C-q>        cancel, nothing is created (asks first when you typed something)",
    "g?               this help",
    "",
    "Family, Title and a severity are required. Place is optional: after <ID>, before <ID>, <file>#<section>, <file>.",
    "Everything below '## text' is the prose of the rule.",
    "Lines starting with ! are the report of the last submit; they go away on the next one.",
  }
end

---@param buf integer
---@return string[]
local function buf_lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

---Tick or untick the severity bullet under the cursor.
---@param buf integer
---@return boolean handled  `false` when the cursor is not on a severity bullet
function M.toggle_here(buf)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local wanted = form.toggle(buf_lines(buf), lnum)
  if not wanted then
    return false
  end
  set_lines(buf, wanted)
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  return true
end

---Put the report at the top of the form, in place of an earlier one.
---@param buf integer
---@param errors string[]
function M.show_errors(buf, errors)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local report = form.error_lines(errors)
  vim.list_extend(report, form.strip_errors(buf_lines(buf)))
  set_lines(buf, report)
  -- the window of the form, not "the current one": a refusal of the engine is told after a question was asked
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  end
end

---Parse and check the form of `buf`; what is wrong is written into the buffer.
---@param buf integer
---@return table|nil op  one `new` operation
function M.read(buf)
  local lines = form.strip_errors(buf_lines(buf))
  set_lines(buf, lines)
  local op, errors = form.validate(form.parse(lines))
  if not op then
    M.show_errors(buf, errors)
    return nil
  end
  return op
end

---Close the form buffer (and its window when it is not the last one).
---@param buf integer
function M.close(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if #vim.api.nvim_list_wins() > 1 then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

---@class Rules.FormOpenOpts: Rules.FormOpts
---@field on_submit fun(op: table, buf: integer)  the checked request (one `new` operation)
---@field on_cancel? fun()

---Open the form.
---@param opts Rules.FormOpenOpts
---@return integer buf
function M.open(opts)
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = "markdown"
  -- a second form must still get a name: the first one may be open
  if not pcall(vim.api.nvim_buf_set_name, buf, "rules://rule-new") then
    pcall(vim.api.nvim_buf_set_name, buf, ("rules://rule-new/%d"):format(buf))
  end
  local baseline = form.template(opts)
  set_lines(buf, baseline)
  -- 'modified' is never set on a `nofile` buffer, so what the user typed is found by comparing with the template
  local function typed_something()
    return not vim.deep_equal(form.strip_errors(buf_lines(buf)), baseline)
  end

  local function map(modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  local function toggle_or(key)
    return function()
      if not M.toggle_here(buf) then
        vim.api.nvim_feedkeys(vim.keycode(key), "n", false)
      end
    end
  end
  map("n", "<Space>", toggle_or("<Space>"), "Rule form: tick/untick")
  map("n", "<CR>", toggle_or("<CR>"), "Rule form: tick/untick")

  map({ "n", "i" }, "<C-s>", function()
    vim.cmd("stopinsert")
    local op = M.read(buf)
    if op then
      opts.on_submit(op, buf)
    end
  end, "Rule form: submit")

  local function leave()
    M.close(buf)
    if opts.on_cancel then
      opts.on_cancel()
    end
  end
  local function cancel()
    if not (vim.api.nvim_buf_is_valid(buf) and typed_something()) then
      leave()
      return
    end
    require("rules.ui.confirm").yesno("Discard what you typed in the rule form?", "discard", function(yes)
      if yes then
        leave()
      end
    end)
  end
  map("n", "q", cancel, "Rule form: cancel")
  map({ "n", "i" }, "<C-q>", cancel, "Rule form: cancel")
  map("n", "g?", function()
    require("rules.util.notify").info(table.concat(M.help_lines(), "\n"))
  end, "Rule form: help")

  -- start on the first free text line
  for i, line in ipairs(buf_lines(buf)) do
    if line:match("^Family:%s*$") or line:match("^Title:%s*$") then
      vim.api.nvim_win_set_cursor(0, { i, #line })
      break
    end
  end
  return buf
end

return M
