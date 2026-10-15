-- TESTS/form_keys_spec.lua -- the keys of the `:Rules new` form follow `setup({ keys = { form = ... } })`.
--
-- The form buffer is opened by `rules.ui.form.open` with a plain `on_submit` of the spec (no ruleset, no engine): what is
-- checked is the buffer-local key map (`nvim_buf_get_keymap`), what a key does, and the two texts that name the keys (the
-- hint under the title and `g?`). The unit specs of the option itself are in `config_spec.lua`.
---@diagnostic disable: need-check-nil
local config = require("rules.config")
local ui = require("rules.ui.form")
local confirm = require("rules.ui.confirm")
-- the form reads the severities from the door: load it before the guards look
require("rules.contract")
require("rules.ops")

describe("the keys of the :Rules new form", function()
  local origin, origin_win
  local saved_ignore
  local saved_notify = vim.notify
  local original_choose = confirm.choose
  local notes, submitted

  ---@param opts? table
  ---@return integer buf
  local function open(opts)
    return ui.open(vim.tbl_extend("force", {
      families = { "DEP" },
      on_submit = function(op)
        submitted[#submitted + 1] = op
      end,
    }, opts or {}))
  end

  ---The buffer-local maps of a mode by their keycodes (`<C-s>` and `<C-S>` are one).
  ---@param buf integer
  ---@param mode string
  ---@return table<string, table>
  local function maps(buf, mode)
    local out = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
      out[vim.keycode(map.lhs)] = map
    end
    return out
  end

  ---@param buf integer
  ---@param mode string
  ---@param lhs string
  ---@return boolean
  local function bound(buf, mode, lhs)
    return maps(buf, mode)[vim.keycode(lhs)] ~= nil
  end

  ---@param buf integer
  ---@param mode string
  ---@param lhs string
  local function press(buf, mode, lhs)
    local map = assert(maps(buf, mode)[vim.keycode(lhs)], ("the form has no key %s in mode %s"):format(lhs, mode))
    map.callback()
  end

  ---@param buf integer
  ---@return string
  local function text(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end

  ---@param needle string
  ---@return boolean
  local function told(needle)
    for _, note in ipairs(notes) do
      if note:find(needle, 1, true) then
        return true
      end
    end
    return false
  end

  before_each(function()
    origin = vim.api.nvim_get_current_buf()
    origin_win = vim.api.nvim_get_current_win()
    saved_ignore = vim.o.eventignore
    vim.o.eventignore = "FileType,Syntax"
    notes, submitted = {}, {}
    vim.notify = function(msg)
      notes[#notes + 1] = tostring(msg)
    end
    config.setup({})
  end)

  after_each(function()
    vim.notify = saved_notify
    confirm.choose = original_choose
    vim.o.eventignore = saved_ignore
    config.setup({})
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= origin_win then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    vim.api.nvim_set_current_win(origin_win)
    vim.api.nvim_set_current_buf(origin)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if buf ~= origin then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end)

  it("binds the default keys when nothing is set, in the modes it always did", function()
    local buf = open()
    for _, lhs in ipairs({ "<Space>", "<CR>", "<C-s>", "q", "<C-q>", "g?" }) do
      assert.is_true(bound(buf, "n", lhs), lhs .. " in normal mode")
    end
    assert.is_true(bound(buf, "i", "<C-s>"))
    assert.is_true(bound(buf, "i", "<C-q>"))
    assert.is_false(bound(buf, "i", "<Space>"))
    assert.is_false(bound(buf, "i", "q"))
    assert.is_false(bound(buf, "i", "g?"))
    assert.is_truthy(text(buf):find("<!-- <Space>/<CR> tick, <C-s> check and create, q cancel, g? help -->", 1, true))
  end)

  it("binds the keys that setup() names, and not the defaults they replace", function()
    config.setup({
      keys = { form = { toggle = "x", accept = "<Tab>", submit = "<C-g>", close = "Q", cancel = "<M-q>", help = "?" } },
    })
    local buf = open()
    for _, lhs in ipairs({ "x", "<Tab>", "<C-g>", "Q", "<M-q>", "?" }) do
      assert.is_true(bound(buf, "n", lhs), lhs .. " in normal mode")
    end
    assert.is_true(bound(buf, "i", "<C-g>"))
    assert.is_true(bound(buf, "i", "<M-q>"))
    for _, lhs in ipairs({ "<Space>", "<CR>", "<C-s>", "q", "<C-q>", "g?" }) do
      assert.is_false(bound(buf, "n", lhs), lhs .. " is not a key of the form any more")
    end
    assert.is_false(bound(buf, "i", "<C-s>"))
    assert.is_false(bound(buf, "i", "<C-q>"))
  end)

  it("does what the key says: the new keys tick, submit, cancel and help", function()
    config.setup({ keys = { form = { toggle = "x", submit = "<C-g>", close = "Q", help = "?" } } })
    local buf = open({ title = "A title", severity = "critical" })
    vim.api.nvim_set_current_buf(buf)

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, line in ipairs(lines) do
      if line == "- [ ] recommended" then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
      end
    end
    press(buf, "n", "x")
    assert.is_true(vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "- [x] recommended"))

    press(buf, "n", "?")
    assert.is_true(told("Rule form"))

    press(buf, "n", "<C-g>")
    assert.are.equal(0, #submitted, "family is missing: the form was not submitted")
    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      require("rules.form").template({ family = "DEP", title = "A title", severity = "critical" })
    )
    press(buf, "i", "<C-g>")
    assert.are.equal(1, #submitted)
    assert.are.equal("DEP", submitted[1].family)

    -- something was typed: the question is asked first (answered Yes here), then the form closes
    local asked = 0
    confirm.choose = function(_, _, cb)
      asked = asked + 1
      cb(2)
    end
    press(buf, "n", "Q")
    assert.are.equal(1, asked)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))

    -- nothing typed: it closes at once
    local fresh = open()
    press(fresh, "n", "Q")
    assert.are.equal(1, asked)
    assert.is_false(vim.api.nvim_buf_is_valid(fresh))
  end)

  it("binds every key of a list, each one working", function()
    config.setup({ keys = { form = { toggle = { "x", "y" }, help = { "?", "<F1>" } } } })
    local buf = open({ severity = "critical" })
    for _, lhs in ipairs({ "x", "y" }) do
      assert.is_true(bound(buf, "n", lhs))
    end
    local at
    for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line == "- [ ] recommended" then
        at = i
      end
    end
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { at, 0 })
    press(buf, "n", "y")
    assert.is_true(vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "- [x] recommended"))
    notes = {}
    press(buf, "n", "<F1>")
    assert.is_true(told("Rule form"))
    -- the default <Space> is not a key of the form any more
    assert.is_false(bound(buf, "n", "<Space>"))
  end)

  it("binds nothing for an action that is false, and the other actions are not touched", function()
    config.setup({ keys = { form = { submit = false, cancel = false } } })
    local buf = open()
    assert.is_false(bound(buf, "n", "<C-s>"))
    assert.is_false(bound(buf, "i", "<C-s>"))
    assert.is_false(bound(buf, "n", "<C-q>"))
    assert.is_false(bound(buf, "i", "<C-q>"))
    for _, lhs in ipairs({ "<Space>", "<CR>", "q", "g?" }) do
      assert.is_true(bound(buf, "n", lhs), lhs)
    end
    -- the hint leaves out what has no key
    assert.is_truthy(text(buf):find("<!-- <Space>/<CR> tick, q cancel, g? help -->", 1, true))
    assert.is_nil(text(buf):find("check and create", 1, true))

    config.setup({ keys = { form = { toggle = false, accept = false, close = false, cancel = false, help = false } } })
    local bare = open()
    -- only the submit key is left in the buffer
    assert.is_true(bound(bare, "n", "<C-s>"))
    assert.is_false(bound(bare, "n", "<Space>"))
    assert.is_false(bound(bare, "n", "q"))
    assert.is_false(bound(bare, "n", "g?"))
  end)

  describe("the help and the hint", function()
    it("show the keys that are bound", function()
      config.setup({ keys = { form = { toggle = "x", accept = false, submit = { "<C-g>", "<F5>" }, close = "Q", help = "?" } } })
      local lines = ui.help_lines()
      local all = table.concat(lines, "\n")
      assert.is_truthy(all:find("x ", 1, true))
      assert.is_truthy(all:find("<C-g> / <F5>", 1, true))
      assert.is_truthy(all:find("Q / <C-q>", 1, true))
      assert.is_truthy(all:find("?   ", 1, true))
      assert.is_nil(all:find("<Space>", 1, true))
      assert.is_nil(all:find("<CR>", 1, true))
      assert.is_nil(all:find("g?", 1, true))
      assert.is_nil(all:find("<C-s>", 1, true))

      local buf = open()
      assert.is_truthy(text(buf):find("<!-- x tick, <C-g>/<F5> check and create, Q cancel, ? help -->", 1, true))
      -- `g?` of the form says the same
      press(buf, "n", "?")
      assert.is_true(told("<C-g> / <F5>"))
    end)

    it("name an action without a key with a dash, not with the default key", function()
      config.setup({ keys = { form = { help = false, close = false, cancel = false } } })
      local lines = ui.help_lines()
      local row = lines[6]
      assert.are.equal("-", vim.trim(row):match("^(%S+)"), vim.inspect(lines))
      assert.is_truthy(row:find("this help", 1, true))
      assert.is_truthy(lines[5]:find("^%-%s+cancel"))
    end)

    it("are the default texts with the default keys", function()
      local lines = ui.help_lines()
      assert.is_truthy(lines[3]:find("^<Space> / <CR>%s+tick or untick"))
      assert.is_truthy(lines[4]:find("^<C%-s>%s+check the form"))
      assert.is_truthy(lines[5]:find("^q / <C%-q>%s+cancel"))
      assert.is_truthy(lines[6]:find("^g%?%s+this help"))
      assert.are.equal(require("rules.form").DEFAULT_HINT, ui.key_hint())
    end)
  end)

  it("warns at setup() when two actions share a key, and the form still opens with what was set", function()
    config.setup({ keys = { form = { help = "<C-s>" } } })
    assert.is_true(told("submit, help share the key <C-s>"))
    local buf = open()
    assert.is_true(bound(buf, "n", "<C-s>"))
    -- the later of the two (help is bound last) is the one that works
    assert.are.equal("Rule form: help", maps(buf, "n")[vim.keycode("<C-s>")].desc)
  end)
end)
