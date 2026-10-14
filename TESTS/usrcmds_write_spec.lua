-- TESTS/usrcmds_write_spec.lua -- `:Rules new`, `set`, `retire`, `move`, `list` and the form: a thin layer over `rules-ops/1`.
--
-- The commands are run as a user types them (`vim.cmd("Rules ...")`) against a fixture ruleset in a temporary folder.
-- A spec that asks a question answers it itself (`rules.ui.confirm.choose` is replaced); nothing opens a dialog.
---@diagnostic disable: need-check-nil
local contract = require("rules.contract")
local confirm = require("rules.ui.confirm")
local cmd = require("rules.ui.cmd")
local form = require("rules.form")
require("rules.ui.form")

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
---@param severity string
---@param title string
---@param body string
---@param block? string[]
---@return string
local function rule_file(id, severity, title, body, block)
  local out = { "---", "id: " .. id, "severity: " .. severity, "family: " .. id:match("^(%a+)%-"), "---", "" }
  out[#out + 1] = "#### `" .. id .. "` — " .. title
  out[#out + 1] = ""
  if block then
    out[#out + 1] = "```rule"
    vim.list_extend(out, block)
    out[#out + 1] = "```"
    out[#out + 1] = ""
  end
  out[#out + 1] = body
  out[#out + 1] = ""
  return table.concat(out, "\n")
end

local LAYOUT = table.concat({
  "---",
  "kind: layout",
  "output: regeln/DEP.md",
  "---",
  "# Dependencies",
  "",
  "## Core",
  "",
  "{{rule DEP-01}}",
  "",
  "## Extra",
  "",
  "{{rule DEP-02}}",
  "",
  "## Two Words",
  "",
}, "\n")

---The real path: a temporary folder may be reached through a link (macOS: /var -> /private/var, Windows: 8.3 names),
---and the editor names a buffer by one spelling, the test by the other.
---@param path string
---@return string
local function real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

---@param text string
---@param needle string
---@return integer
local function index_of(text, needle)
  local s = text:find(needle, 1, true)
  assert(s, ("%q is not in the text"):format(needle))
  return s
end

describe(":Rules new, set, retire, move, list", function()
  local root
  local origin, origin_win
  local saved_ignore
  local saved_uis = vim.api.nvim_list_uis
  local saved_print = _G.print
  -- the question is replaced per spec (below); this is the real one, put back afterwards
  local original_choose = confirm.choose
  local saved_notify = vim.notify
  local asked, answer
  local notes

  local function rule_path(id)
    return assert(contract.view(nil).abs[id])
  end

  local function layout_text()
    return read_raw(root .. "/_layouts/regeln/DEP.md")
  end

  ---@param text string
  ---@return boolean
  local function told(text)
    for _, note in ipairs(notes) do
      if note.text:find(text, 1, true) then
        return true
      end
    end
    return false
  end

  ---@param command string
  local function run(command)
    vim.cmd(command)
  end

  local function buffer_of(path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    return buf
  end

  before_each(function()
    origin = vim.api.nvim_get_current_buf()
    origin_win = vim.api.nvim_get_current_win()
    -- the rule files are Markdown: their FileType would load a syntax that defines highlight groups, which the
    -- state guard counts as a leak of the spec
    saved_ignore = vim.o.eventignore
    vim.o.eventignore = "FileType,Syntax"
    root = vim.fn.tempname() .. "/fixture/Checklists"
    write_raw(root .. "/_rules/DEP/DEP-01.md", rule_file("DEP-01", "recommended", "one", "Text of one."))
    write_raw(
      root .. "/_rules/DEP/DEP-02.md",
      rule_file("DEP-02", "critical", "two", "Text of two.", { 'check = { type = "grep", pattern = "foo" },' })
    )
    write_raw(root .. "/_layouts/regeln/DEP.md", LAYOUT)
    pcall(vim.api.nvim_del_user_command, "Rules")
    require("rules").setup({ rulesets = { root } })
    contract.clear_cache()
    require("rules.ui.candidates").reset()

    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { text = tostring(msg), level = level }
    end
    asked, answer = {}, 2
    confirm.choose = function(question, choices, cb)
      asked[#asked + 1] = { question = question, choices = choices }
      cb(answer)
    end
    cmd.form_open = nil
  end)

  after_each(function()
    vim.notify = saved_notify
    _G.print = saved_print
    vim.api.nvim_list_uis = saved_uis
    cmd.form_open = nil
    confirm.choose = original_choose
    vim.o.eventignore = saved_ignore
    -- the window of the spec stays (the guard counts a replaced window as a leak): the form's and the quickfix
    -- window are closed
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
    vim.fn.setqflist({}, "f")
    pcall(vim.api.nvim_del_user_command, "Rules")
  end)

  describe("new", function()
    it("makes the rule at the next free id, places it, opens it and tells it", function()
      run("Rules new DEP Fresh rule here severity=critical text=Some prose here --after=DEP-01")
      local path = root .. "/_rules/DEP/DEP-03.md"
      local text = assert(read_raw(path))
      assert.is_truthy(text:find("severity: critical", 1, true))
      assert.is_truthy(text:find("Fresh rule here", 1, true))
      assert.is_truthy(text:find("Some prose here", 1, true))
      local layout = layout_text()
      assert.is_true(index_of(layout, "{{rule DEP-01}}") < index_of(layout, "{{rule DEP-03}}"))
      assert.is_true(index_of(layout, "{{rule DEP-03}}") < index_of(layout, "## Extra"))
      assert.are.equal(real(path), real(vim.api.nvim_buf_get_name(0)))
      assert.is_true(told("created DEP-03 in regeln/DEP.md"))
      assert.are.same({}, asked)
    end)

    it("--dry checks everything and writes nothing", function()
      run("Rules new DEP Fresh rule severity=critical --dry")
      assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-03.md"))
      assert.is_true(told("would create DEP-03"))
    end)

    it("tells the refusal of the engine word for word", function()
      run("Rules new DEP Fresh rule severity=urgent")
      assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-03.md"))
      assert.is_true(told("severity must be one of critical, recommended, nice-to-have"))
    end)

    it("opens the form, filled in with what was given, when a required part is missing", function()
      local seen
      cmd.form_open = function(opts)
        seen = opts
      end
      run("Rules new DEP Fresh rule --to=regeln/DEP.md#Core")
      assert.are.equal("DEP", seen.family)
      assert.are.equal("Fresh rule", seen.title)
      assert.is_nil(seen.severity)
      assert.are.equal("regeln/DEP.md#Core", seen.place)
      assert.are.same({ "DEP" }, seen.families)
      assert.are.same({ "regeln/DEP.md" }, seen.layouts)
      assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-03.md"))

      run("Rules new DEP severity=critical text=Some prose --after=DEP-02")
      assert.are.equal("critical", seen.severity)
      assert.are.equal("Some prose", seen.text)
      assert.is_nil(seen.title)
      assert.are.equal("after DEP-02", seen.place)

      run("Rules new")
      assert.is_nil(seen.family)
      assert.are.equal("", seen.place)
    end)

    it("does not open the form for --dry, which needs everything", function()
      local opened = false
      cmd.form_open = function()
        opened = true
      end
      run("Rules new DEP --dry")
      assert.is_false(opened)
      assert.is_true(told("--dry needs the family, a title and severity="))
    end)

    it("reads a place of its own: one of --to, --after, --before", function()
      run("Rules new DEP Fresh severity=critical --after=DEP-01 --before=DEP-02")
      assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-03.md"))
      assert.is_true(told("give one place"))
    end)
  end)

  -- Everything here goes through the real command (`vim.cmd`): Neovim cuts the line, the composer takes the flags and
  -- the declared `key=` words out, the handler reads what is left.
  describe("the command line", function()
    ---@param id string
    ---@return table
    local function rule_of(id)
      return assert(contract.view(nil).full[id])
    end

    describe("key= words stand anywhere", function()
      it("binds the family and the title right when a key= word stands before the family", function()
        run("Rules new text=Hello DEP Wrong title severity=critical")
        local rule = rule_of("DEP-03")
        assert.is_truthy(rule.title:find("Wrong title", 1, true))
        assert.is_nil(rule.title:find("DEP Wrong", 1, true))
        assert.are.equal("Hello", rule.text)
        assert.are.equal("critical", rule.severity)
        assert.are.equal("DEP", rule.family)
      end)

      it("takes severity= before the family into the rule, and opens no form for it", function()
        local opened = false
        cmd.form_open = function()
          opened = true
        end
        run("Rules new severity=critical DEP Add check")
        assert.is_false(opened)
        local rule = rule_of("DEP-03")
        assert.are.equal("critical", rule.severity)
        assert.is_truthy(rule.title:find("Add check", 1, true))
        assert.is_nil(rule.title:find("DEP Add", 1, true))
      end)

      it("fills the form with the family, the title and the key= words wherever they stood", function()
        local seen
        cmd.form_open = function(opts)
          seen = opts
        end
        run("Rules new severity=critical DEP")
        assert.are.equal("DEP", seen.family)
        assert.are.equal("critical", seen.severity)
        assert.is_nil(seen.title)
        run("Rules new text=Hello DEP Fresh title")
        assert.are.equal("DEP", seen.family)
        assert.are.equal("Fresh title", seen.title)
        assert.are.equal("Hello", seen.text)
        assert.is_nil(seen.severity)
        run("Rules new severity=critical")
        assert.is_nil(seen.family)
        assert.is_nil(seen.title)
        assert.are.equal("critical", seen.severity)
      end)

      it("binds the id of set and retire right when a key= word stands before it", function()
        run("Rules set severity=critical DEP-01 title=New title")
        local rule = rule_of("DEP-01")
        assert.are.equal("critical", rule.severity)
        assert.is_truthy(rule.title:find("New title", 1, true))
        assert.is_true(told("changed DEP-01"))
        run("Rules retire reason=cleaned DEP-01 --yes")
        local retired = assert(read_raw(root .. "/_retired/DEP/DEP-01.md"))
        assert.is_truthy(retired:find("reason: cleaned", 1, true))
      end)

      it("still reads the value of a key= word after the id over several words", function()
        run("Rules set DEP-01 title=A title over words severity=nice-to-have text=and some text")
        local rule = rule_of("DEP-01")
        assert.is_truthy(rule.title:find("A title over words", 1, true))
        assert.are.equal("and some text", rule.text)
        assert.are.equal("nice-to-have", rule.severity)
      end)
    end)

    describe("values come out as typed", function()
      it("keeps a run of blanks in a JSON value", function()
        run('Rules set DEP-02 check={"type":"grep","pattern":"a  b"}')
        assert.are.equal("a  b", rule_of("DEP-02").check.pattern)
      end)

      it("keeps a run of blanks between the words of a text", function()
        run("Rules set DEP-01 text=one  two   three")
        assert.are.equal("one  two   three", rule_of("DEP-01").text)
      end)

      it("keeps every backslash of a value, also before a blank and in pairs", function()
        run("Rules set DEP-01 text=C:\\Users\\x\\ end")
        assert.are.equal("C:\\Users\\x\\ end", rule_of("DEP-01").text)
        run("Rules set DEP-01 text=a\\\\b and \\\\ c")
        assert.are.equal("a\\\\b and \\\\ c", rule_of("DEP-01").text)
      end)

      it("keeps the backslash in a check as well", function()
        run('Rules set DEP-02 check={"type":"grep","pattern":"a\\\\.b"}')
        assert.are.equal("a\\.b", rule_of("DEP-02").check.pattern)
      end)

      it("keeps a run of blanks in the title of a new rule", function()
        run("Rules new DEP Two  blanks severity=critical")
        assert.is_truthy(rule_of("DEP-03").title:find("Two  blanks", 1, true))
      end)
    end)

    describe("a word that starts with two dashes", function()
      it("is a flag, as it always was", function()
        local before = read_raw(rule_path("DEP-01"))
        run("Rules set DEP-01 text=run with --dry")
        assert.are.equal(before, read_raw(rule_path("DEP-01")))
        assert.is_true(told("would change DEP-01"))
      end)

      it("is a word of the value after a bare --, which ends the flags", function()
        run("Rules set DEP-01 text=run with -- --dry now")
        assert.are.equal("run with --dry now", rule_of("DEP-01").text)
        assert.is_true(told("changed DEP-01"))
        assert.is_false(told("would change"))
      end)

      it("keeps the flags that stand before the --", function()
        local before = read_raw(rule_path("DEP-01"))
        run("Rules set DEP-01 text=run -- --with --dry --dry")
        assert.is_true(told("changed DEP-01"))
        run("Rules set DEP-01 --dry text=run -- --with")
        assert.is_true(told("would change DEP-01"))
        assert.are_not.equal(before, read_raw(rule_path("DEP-01")))
        assert.are.equal("run --with --dry --dry", rule_of("DEP-01").text)
      end)

      it("takes a word with two dashes into a new title after the --", function()
        run("Rules new DEP Use -- --fast severity=critical")
        assert.is_truthy(rule_of("DEP-03").title:find("Use --fast", 1, true))
      end)
    end)
  end)

  describe("the family of new", function()
    ---@return string[]
    local function made_ids()
      contract.clear_cache()
      local out = {}
      for _, rule in ipairs(contract.view(nil).rules) do
        out[#out + 1] = rule.id
      end
      table.sort(out)
      return out
    end

    before_each(function()
      -- a session with a screen: the question can be asked
      vim.api.nvim_list_uis = function()
        return { {} }
      end
    end)

    it("refuses a mistyped title that was read as a family, and writes nothing", function()
      local opened = false
      cmd.form_open = function()
        opened = true
      end
      run("Rules new Fix the bug severity=critical")
      assert.is_true(told("invalid_argument: family must be 1 to 12 uppercase letters A-Z"))
      assert.are.same({ "DEP-01", "DEP-02" }, made_ids())
      -- not even a form: it would open on a family that no submit could pass
      run("Rules new Fix the bug")
      assert.is_false(opened)
      assert.are.same({}, asked)
    end)

    it("refuses a lowercase or mixed-case family, and says what the door says", function()
      for _, family in ipairs({ "dep", "Dep", "DEp" }) do
        notes = {}
        run(("Rules new %s Title severity=critical"):format(family))
        assert.is_true(told("invalid_argument: family " .. require("rules.ops").family_error(family)), family)
      end
      assert.are.same({ "DEP-01", "DEP-02" }, made_ids())
    end)

    it("asks first about a family no rule has yet, and makes the rule on Yes", function()
      answer = 2
      run("Rules new NEWF Brand new severity=critical")
      assert.are.equal(1, #asked)
      assert.is_truthy(asked[1].question:find("New family NEWF", 1, true))
      assert.is_truthy(asked[1].question:find("NEWF-01", 1, true))
      assert.are.same({ "No", "Yes, make it" }, asked[1].choices)
      assert.are.same({ "DEP-01", "DEP-02", "NEWF-01" }, made_ids())
      assert.is_true(told("created NEWF-01"))
    end)

    it("makes nothing on No or when the question is dismissed", function()
      answer = 1
      run("Rules new NEWF Brand new severity=critical")
      assert.are.equal(1, #asked)
      assert.is_true(told("NEWF-01 was not made"))
      answer = nil
      run("Rules new NEWF Brand new severity=critical")
      assert.are.equal(2, #asked)
      assert.are.same({ "DEP-01", "DEP-02" }, made_ids())
    end)

    it("--yes makes the rule without asking, --dry asks nothing and writes nothing", function()
      run("Rules new NEWF Brand new severity=critical --dry")
      assert.is_true(told("would create NEWF-01"))
      assert.are.same({ "DEP-01", "DEP-02" }, made_ids())
      run("Rules new NEWF Brand new severity=critical --yes")
      assert.are.same({}, asked)
      assert.are.same({ "DEP-01", "DEP-02", "NEWF-01" }, made_ids())
    end)

    it("does not ask about a family a rule has, loaded or retired, nor about a rule the door would refuse", function()
      run("Rules new DEP Fresh severity=critical")
      assert.are.same({}, asked)
      run("Rules retire DEP-01 --yes")
      run("Rules retire DEP-02 --yes")
      run("Rules retire DEP-03 --yes")
      assert.are.same({}, made_ids())
      asked = {}
      -- the family has only retired rules now: it is not a new one
      run("Rules new DEP Again severity=critical")
      assert.are.same({}, asked)
      assert.are.same({ "DEP-04" }, made_ids())
      notes = {}
      run("Rules new NEWF Brand new severity=urgent")
      assert.are.same({}, asked)
      assert.is_true(told("severity must be one of"))
    end)

    it("needs --yes where there is nobody to ask", function()
      vim.api.nvim_list_uis = saved_uis
      run("Rules new NEWF Brand new severity=critical")
      assert.are.same({}, asked)
      assert.is_true(told("is a new family"))
      assert.is_true(told("run it with --yes"))
      assert.are.same({ "DEP-01", "DEP-02" }, made_ids())
    end)
  end)

  describe("the form", function()
    ---@return integer buf
    local function open_form(command)
      run(command)
      local buf = vim.api.nvim_get_current_buf()
      assert.are.equal("markdown", vim.bo[buf].filetype)
      assert.is_truthy(vim.api.nvim_buf_get_name(buf):find("rules://rule-new", 1, true))
      return buf
    end

    ---@param buf integer
    ---@param prefix string
    ---@param line string
    local function set_line(buf, prefix, line)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      for i, l in ipairs(lines) do
        if l:sub(1, #prefix) == prefix then
          vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { line })
          return
        end
      end
      error("no line starting with " .. prefix)
    end

    ---Press a buffer-local normal-mode key of the form (as Neovim spells the lhs: `<C-S>`, `<Space>`).
    ---@param buf integer
    ---@param lhs string
    local function press(buf, lhs)
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if vim.keycode(map.lhs) == vim.keycode(lhs) then
          map.callback()
          return
        end
      end
      error(("the form has no key %s"):format(lhs))
    end

    ---@param buf integer
    local function submit(buf)
      vim.api.nvim_set_current_buf(buf)
      press(buf, "<C-S>")
    end

    ---@param buf integer
    ---@return string
    local function form_text(buf)
      return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end

    it("checks, shows what would be made, asks, and only then writes", function()
      local buf = open_form("Rules new DEP")
      set_line(buf, "Title:", "Title: Made in the form")
      set_line(buf, "Place:", "Place: regeln/DEP.md#Two Words")
      set_line(buf, "- [ ] nice-to-have", "- [x] nice-to-have")
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      vim.list_extend(lines, { "Prose line one.", "", "Prose line two." })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      submit(buf)

      assert.are.equal(1, #asked)
      local question = asked[1].question
      assert.is_truthy(question:find("DEP-03", 1, true))
      assert.is_truthy(question:find("nice-to-have", 1, true))
      assert.is_truthy(question:find("Made in the form", 1, true))
      assert.is_truthy(question:find("regeln/DEP.md", 1, true))
      assert.is_truthy(question:find("3 line(s)", 1, true))
      assert.are.same({ "Back to the form", "Create the rule" }, asked[1].choices)

      local text = assert(read_raw(root .. "/_rules/DEP/DEP-03.md"))
      assert.is_truthy(text:find("severity: nice-to-have", 1, true))
      assert.is_truthy(text:find("Prose line one.\n\nProse line two.", 1, true))
      assert.is_true(index_of(layout_text(), "{{rule DEP-03}}") > index_of(layout_text(), "## Two Words"))
      assert.is_false(vim.api.nvim_buf_is_valid(buf))
      assert.are.equal(real(root .. "/_rules/DEP/DEP-03.md"), real(vim.api.nvim_buf_get_name(0)))
      assert.is_true(told("created DEP-03 in regeln/DEP.md"))
    end)

    it("runs through the real <C-s> of insert mode and the real dialog, with keys", function()
      -- nothing is replaced: the key map of the form, `rules.ui.confirm.choose` and the button dialog of the kit
      confirm.choose = original_choose
      local kit = require("lib.nvim.ui.kit.confirm")
      local buf = open_form("Rules new DEP")
      set_line(buf, "Title:", "Title: Made with the keys")
      set_line(buf, "- [ ] recommended", "- [x] recommended")
      vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      -- a (to the end of the line, in insert mode), then the key the form maps in both modes
      vim.api.nvim_feedkeys(vim.keycode("A<C-s>"), "x", false)
      assert.is_true(kit.is_open(), "the question was not asked")
      assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-03.md"))
      -- the dialog starts on the harmless button ("Back to the form"): one step to the right is "Create the rule"
      assert.are.equal(1, kit.current_focus())
      vim.api.nvim_feedkeys("l", "x", false)
      assert.are.equal(2, kit.current_focus())
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
      assert.is_false(kit.is_open())
      local text = assert(read_raw(root .. "/_rules/DEP/DEP-03.md"))
      assert.is_truthy(text:find("severity: recommended", 1, true))
      assert.is_truthy(text:find("Made with the keys", 1, true))
      assert.is_true(told("created DEP-03"))
    end)

    it("writes nothing when the real dialog is answered with Esc", function()
      confirm.choose = original_choose
      local kit = require("lib.nvim.ui.kit.confirm")
      local buf = open_form("Rules new DEP")
      set_line(buf, "Title:", "Title: Never made")
      set_line(buf, "- [ ] critical", "- [x] critical")
      vim.api.nvim_set_current_win(vim.fn.bufwinid(buf))
      vim.api.nvim_feedkeys(vim.keycode("A<C-s>"), "x", false)
      assert.is_true(kit.is_open())
      vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
      assert.is_false(kit.is_open())
      assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-03.md"))
      assert.is_true(vim.api.nvim_buf_is_valid(buf))
    end)

    it("shows a new family in the question, and no such line for a family that is there", function()
      local form_buf = open_form("Rules new NEWF")
      set_line(form_buf, "Title:", "Title: Made in the form")
      set_line(form_buf, "- [ ] critical", "- [x] critical")
      submit(form_buf)
      assert.are.equal(1, #asked)
      assert.is_truthy(asked[1].question:find("NEWF (NEW: no rule of any ruleset has it yet)", 1, true))
      assert.is_true(told("created NEWF-01"))

      local known = open_form("Rules new DEP")
      set_line(known, "Title:", "Title: Known family")
      set_line(known, "- [ ] critical", "- [x] critical")
      submit(known)
      assert.are.equal(2, #asked)
      assert.is_nil(asked[2].question:find("NEW:", 1, true))
    end)

    it("refuses a family that is not uppercase letters in the form, before anything is asked", function()
      local buf = open_form("Rules new")
      set_line(buf, "Family:", "Family: Fix")
      set_line(buf, "Title:", "Title: the bug")
      set_line(buf, "- [ ] critical", "- [x] critical")
      submit(buf)
      assert.is_truthy(form_text(buf):find("Family must be 1 to 12 uppercase letters A-Z", 1, true))
      assert.are.same({}, asked)
    end)

    it("fills the form with what the command line gave", function()
      local buf = open_form("Rules new DEP severity=recommended text=Given prose --after=DEP-01")
      local parsed = form.parse(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.are.equal("DEP", parsed.family)
      assert.are.equal("", parsed.title)
      assert.are.equal("after DEP-01", parsed.place)
      assert.are.same({ "recommended" }, parsed.ticks)
      assert.are.equal("Given prose", parsed.text)
    end)

    it("says up front what is missing and neither asks nor writes", function()
      local buf = open_form("Rules new")
      submit(buf)
      local text = form_text(buf)
      assert.is_truthy(text:find("! The form was not submitted:", 1, true))
      assert.is_truthy(text:find("Family is required", 1, true))
      assert.is_truthy(text:find("Title is required", 1, true))
      assert.is_truthy(text:find("severity: tick one", 1, true))
      assert.are.same({}, asked)
      assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-03.md"))
      -- a second submit replaces the report instead of piling up another
      submit(buf)
      assert.are.equal(1, select(2, form_text(buf):gsub("The form was not submitted", "")))
    end)

    it("shows a refusal of the engine in the form, which stays open with everything typed", function()
      local buf = open_form("Rules new DEP Title here text=# a heading ends the rule")
      set_line(buf, "- [ ] critical", "- [x] critical")
      submit(buf)
      assert.is_true(vim.api.nvim_buf_is_valid(buf))
      local text = form_text(buf)
      assert.is_truthy(text:find("! The form was not submitted:", 1, true))
      assert.is_truthy(text:find("invalid_argument", 1, true))
      assert.is_truthy(text:find("Title here", 1, true))
      assert.are.same({}, asked)
      assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-03.md"))
    end)

    it("writes nothing when the question is answered with Back or dismissed", function()
      local buf = open_form("Rules new DEP Title here")
      set_line(buf, "- [ ] critical", "- [x] critical")
      for _, reply in ipairs({ 1, vim.NIL }) do
        answer = reply ~= vim.NIL and reply or nil
        submit(buf)
        assert.is_nil(read_raw(root .. "/_rules/DEP/DEP-03.md"))
        assert.is_true(vim.api.nvim_buf_is_valid(buf))
      end
      assert.are.equal(2, #asked)
    end)

    it("cancels with q: at once when nothing was typed, after a question when something was", function()
      local buf = open_form("Rules new DEP")
      press(buf, "q")
      assert.is_false(vim.api.nvim_buf_is_valid(buf))
      assert.are.same({}, asked)
      assert.is_true(told("rule not created"))

      buf = open_form("Rules new DEP")
      set_line(buf, "Title:", "Title: typed")
      answer = 1
      press(buf, "q")
      assert.is_true(vim.api.nvim_buf_is_valid(buf))
      assert.are.equal(1, #asked)
      answer = 2
      press(buf, "q")
      assert.is_false(vim.api.nvim_buf_is_valid(buf))
    end)

    it("ticks one severity with <Space>, and leaves <Space> alone elsewhere", function()
      local buf = open_form("Rules new DEP")
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local at
      for i, l in ipairs(lines) do
        if l == "- [ ] recommended" then
          at = i
        end
      end
      vim.api.nvim_win_set_cursor(0, { at, 0 })
      press(buf, "<Space>")
      assert.is_true(vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "- [x] recommended"))
      assert.is_true(require("rules.ui.form").toggle_here(buf))
      assert.is_false(vim.tbl_contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "- [x] recommended"))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      assert.is_false(require("rules.ui.form").toggle_here(buf))
    end)
  end)

  describe("set", function()
    it("changes the file, and reloads the unmodified buffer of it", function()
      local buf = buffer_of(rule_path("DEP-01"))
      run("Rules set DEP-01 severity=critical")
      assert.is_truthy(read_raw(rule_path("DEP-01")):find("severity: critical", 1, true))
      assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("severity: critical", 1, true))
      assert.is_false(vim.bo[buf].modified)
      assert.is_true(told("changed DEP-01"))
      assert.is_true(told("reloaded"))
    end)

    it("reports a conflict, and keeps the buffer, when the buffer has unsaved changes", function()
      local buf = buffer_of(rule_path("DEP-01"))
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved" })
      run("Rules set DEP-01 severity=critical")
      assert.is_truthy(read_raw(rule_path("DEP-01")):find("severity: critical", 1, true))
      assert.are.equal("unsaved", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
      assert.is_true(vim.bo[buf].modified)
      assert.is_true(told("unsaved changes"))
      local conflict
      for _, note in ipairs(notes) do
        if note.text:find("unsaved changes", 1, true) then
          conflict = note
        end
      end
      assert.are.equal(vim.log.levels.WARN, conflict.level)
    end)

    it("--dry writes nothing and shows the diff", function()
      local before = read_raw(rule_path("DEP-01"))
      run("Rules set DEP-01 severity=critical --dry")
      assert.are.equal(before, read_raw(rule_path("DEP-01")))
      assert.is_true(told("+severity: critical"))
    end)

    it("takes a value with spaces and several keys", function()
      run("Rules set DEP-01 title=A new title here text=Other prose for it severity=nice-to-have")
      local rule = contract.view(nil).full["DEP-01"]
      assert.is_truthy(rule.title:find("A new title here", 1, true))
      assert.are.equal("Other prose for it", rule.text)
      assert.are.equal("nice-to-have", rule.severity)
    end)

    it("sets the check from a JSON object and removes it with nothing after the =", function()
      run('Rules set DEP-02 check={"type":"grep","pattern":"bar"}')
      assert.are.equal("bar", contract.view(nil).full["DEP-02"].check.pattern)
      run("Rules set DEP-02 check=")
      assert.is_nil(contract.view(nil).full["DEP-02"].check)
    end)

    it("leaves the check line byte for byte where only the agent is set, as the command says it does", function()
      local line = 'check = { type = "grep", pattern = "foo" },'
      assert.is_truthy(read_raw(rule_path("DEP-02")):find(line, 1, true))
      run('Rules set DEP-02 agent={"question":"Is it so?"}')
      local text = read_raw(rule_path("DEP-02"))
      assert.is_truthy(text:find(line, 1, true))
      assert.is_truthy(text:find("agent = ", 1, true))
      run("Rules set DEP-02 agent=")
      assert.is_truthy(read_raw(rule_path("DEP-02")):find(line, 1, true))
      assert.is_nil(read_raw(rule_path("DEP-02")):find("agent = ", 1, true))
    end)

    it("tells what is wrong with the line, and what the engine refuses, word for word", function()
      run("Rules set DEP-01")
      assert.is_true(told("nothing to set"))
      run("Rules set DEP-01 colour=red")
      assert.is_true(told("unknown field 'colour'"))
      run("Rules set DEP-01 severity=urgent")
      assert.is_true(told("severity must be one of"))
      run("Rules set DEP-01 check=grep")
      assert.is_true(told("check= takes a JSON object"))
      run("Rules set NOPE-01 severity=critical")
      assert.is_true(told("not_found"))
    end)
  end)

  it("tells it, and raises nothing, when no ruleset is configured", function()
    pcall(vim.api.nvim_del_user_command, "Rules")
    require("rules").setup({ rulesets = {} })
    contract.clear_cache()
    run("Rules set DEP-01 severity=critical")
    run("Rules new DEP Fresh severity=critical")
    run("Rules move DEP-01 --after=DEP-02")
    run("Rules list")
    local count = 0
    for _, note in ipairs(notes) do
      if note.text:find("no ruleset is configured", 1, true) then
        count = count + 1
      end
    end
    assert.is_true(count >= 3, vim.inspect(notes))
  end)

  describe("retire", function()
    ---@return boolean
    local function retired()
      return read_raw(root .. "/_retired/DEP/DEP-01.md") ~= nil
    end

    before_each(function()
      -- a session with a screen: the question can be asked
      vim.api.nvim_list_uis = function()
        return { {} }
      end
    end)

    it("asks first, with No as the answer the dialog starts on, and does nothing on No", function()
      answer = 1
      run("Rules retire DEP-01")
      assert.are.equal(1, #asked)
      assert.are.same({ "No", "Yes, retire" }, asked[1].choices)
      assert.is_truthy(asked[1].question:find("Retire DEP-01?", 1, true))
      assert.is_false(retired())
      assert.is_truthy(read_raw(rule_path("DEP-01")))
      assert.is_true(told("DEP-01 was not retired"))
    end)

    it("moves the file to _retired and out of the layout on Yes", function()
      run("Rules retire DEP-01 --by=DEP-02 reason=not needed any more")
      assert.is_true(retired())
      local text = read_raw(root .. "/_retired/DEP/DEP-01.md")
      assert.is_truthy(text:find("replaced_by: DEP-02", 1, true))
      assert.is_truthy(text:find("reason: not needed any more", 1, true))
      assert.is_nil(layout_text():find("{{rule DEP-01}}", 1, true))
      assert.is_true(told("retired DEP-01"))
      assert.is_truthy(asked[1].question:find("Replaced by DEP-02", 1, true))
    end)

    it("--yes retires without asking", function()
      run("Rules retire DEP-01 --yes")
      assert.is_true(retired())
      assert.are.same({}, asked)
    end)

    it("does not ask about a rule the engine would refuse", function()
      run("Rules retire NOPE-01")
      assert.are.same({}, asked)
      assert.is_true(told("not_found"))
      run("Rules retire DEP-01 --by=GHOST-01")
      assert.are.same({}, asked)
      assert.is_false(retired())
      assert.is_true(told("not_found"))
    end)

    it("--dry says what would happen, asks nothing and moves nothing", function()
      run("Rules retire DEP-01 --dry")
      assert.are.same({}, asked)
      assert.is_false(retired())
      assert.is_true(told("would retire DEP-01"))
    end)

    it("refuses, without a screen to ask on, to retire without --yes", function()
      vim.api.nvim_list_uis = saved_uis
      run("Rules retire DEP-01")
      assert.are.same({}, asked)
      assert.is_false(retired())
      assert.is_true(told("run it with --yes"))
    end)

    it("names the buffer of the retired file and leaves it open", function()
      local buf = buffer_of(rule_path("DEP-01"))
      run("Rules retire DEP-01 --yes")
      assert.is_true(vim.api.nvim_buf_is_valid(buf))
      assert.is_true(told("no longer there"))
    end)
  end)

  describe("move", function()
    it("moves the rule into a section of the layout", function()
      run("Rules move DEP-02 --to=regeln/DEP.md#Core")
      local layout = layout_text()
      assert.is_true(index_of(layout, "{{rule DEP-02}}") < index_of(layout, "## Extra"))
      assert.is_true(told("moved DEP-02 to regeln/DEP.md"))
    end)

    it("takes a section with a blank in it when the blank is escaped", function()
      run("Rules move DEP-02 --to=regeln/DEP.md#Two\\ Words")
      assert.is_true(index_of(layout_text(), "{{rule DEP-02}}") > index_of(layout_text(), "## Two Words"))
    end)

    it("puts the rule at the start of the section with --first", function()
      run("Rules move DEP-02 --to=regeln/DEP.md#Core --first")
      local layout = layout_text()
      assert.is_true(index_of(layout, "{{rule DEP-02}}") < index_of(layout, "{{rule DEP-01}}"))
    end)

    it("moves after or before another rule", function()
      run("Rules move DEP-02 --before=DEP-01")
      assert.is_true(index_of(layout_text(), "{{rule DEP-02}}") < index_of(layout_text(), "{{rule DEP-01}}"))
      run("Rules move DEP-02 --after=DEP-01")
      assert.is_true(index_of(layout_text(), "{{rule DEP-02}}") > index_of(layout_text(), "{{rule DEP-01}}"))
    end)

    it("--dry changes nothing", function()
      local before = layout_text()
      run("Rules move DEP-02 --to=regeln/DEP.md#Core --dry")
      assert.are.equal(before, layout_text())
      assert.is_true(told("would move DEP-02"))
    end)

    it("needs exactly one place, and tells a word it cannot use", function()
      local before = layout_text()
      run("Rules move DEP-02")
      assert.is_true(told("needs a place"))
      run("Rules move DEP-02 --after=DEP-01 --before=DEP-01")
      assert.is_true(told("give one place"))
      run("Rules move DEP-02 --to=regeln/DEP.md#Two Words")
      assert.is_true(told("unexpected argument: Words"))
      assert.is_true(told("backslash"))
      run("Rules move DEP-02 --first --after=DEP-01")
      assert.is_true(told("--first goes with"))
      assert.are.equal(before, layout_text())
    end)

    it("tells what the engine says about a layout that is not there", function()
      run("Rules move DEP-02 --to=regeln/NOPE.md#Core")
      assert.is_true(told("invalid_argument"))
    end)
  end)

  describe("list", function()
    it("puts the rules in the quickfix list, each at its source line", function()
      run("Rules list --family=DEP")
      local items = vim.fn.getqflist()
      assert.are.equal(2, #items)
      assert.is_truthy(items[1].text:find("DEP-01 [recommended] one", 1, true))
      assert.is_truthy(items[2].text:find("DEP-02 [critical] two", 1, true))
      assert.are.equal(real(rule_path("DEP-01")), real(vim.api.nvim_buf_get_name(items[1].bufnr)))
      assert.are.equal("rules list", vim.fn.getqflist({ title = 1 }).title)
    end)

    it("narrows by family and by severity", function()
      run("Rules list --severity=critical")
      local items = vim.fn.getqflist()
      assert.are.equal(1, #items)
      assert.is_truthy(items[1].text:find("DEP-02", 1, true))
    end)

    it("says when no rule matches, and tells the engine's refusal of a severity", function()
      run("Rules list --family=ZZZ")
      assert.is_true(told("no rule matches"))
      run("Rules list --severity=urgent")
      assert.is_true(told("severity must be one of"))
    end)

    it("--format=json prints the document of the machine contract", function()
      local printed = {}
      ---@diagnostic disable-next-line: duplicate-set-field
      _G.print = function(...)
        printed[#printed + 1] = table.concat(vim.tbl_map(tostring, { ... }), " ")
      end
      run("Rules list --family=DEP --format=json")
      _G.print = saved_print
      local doc = vim.json.decode(printed[1])
      assert.are.equal("rules.list", doc.kind)
      assert.are.equal(2, doc.total)
    end)
  end)

  describe("completion", function()
    ---@param line string
    ---@return string[]
    local function complete(line)
      return vim.fn.getcompletion(line, "cmdline")
    end

    it("offers the new verbs", function()
      local verbs = complete("Rules ")
      for _, verb in ipairs({ "new", "set", "retire", "move", "list", "show" }) do
        assert.is_true(vim.tbl_contains(verbs, verb), verb)
      end
    end)

    it("offers families, then the keys and their severities", function()
      assert.is_true(vim.tbl_contains(complete("Rules new "), "DEP"))
      assert.is_true(vim.tbl_contains(complete("Rules new DEP "), "severity="))
      assert.are.same(
        { "severity=critical", "severity=recommended", "severity=nice-to-have" },
        vim.tbl_filter(function(c)
          return c:find("^severity=")
        end, complete("Rules new DEP severity="))
      )
    end)

    it("offers ids, live: a rule that was just made is there", function()
      assert.are.same({ "DEP-01", "DEP-02" }, complete("Rules set DEP-0"))
      run("Rules new DEP Fresh severity=critical")
      assert.are.same({ "DEP-01", "DEP-02", "DEP-03" }, complete("Rules set DEP-0"))
      assert.are.same({ "--by=DEP-01", "--by=DEP-02", "--by=DEP-03" }, complete("Rules retire DEP-01 --by=DEP"))
      assert.are.same({ "DEP-01", "DEP-02", "DEP-03" }, complete("Rules show DEP"))
    end)

    it("offers the layouts, then the sections of a layout with a blank escaped", function()
      assert.are.same({ "--to=regeln/DEP.md" }, complete("Rules move DEP-01 --to=regeln"))
      local sections = complete("Rules move DEP-01 --to=regeln/DEP.md#")
      assert.is_true(vim.tbl_contains(sections, "--to=regeln/DEP.md#Core"))
      assert.is_true(vim.tbl_contains(sections, "--to=regeln/DEP.md#Two\\ Words"))
      assert.are.same({ "--to=regeln/DEP.md#Two\\ Words" }, complete("Rules move DEP-01 --to=regeln/DEP.md#Two"))
    end)

    it("offers the severities of a list", function()
      assert.are.same(
        { "--severity=critical", "--severity=recommended", "--severity=nice-to-have" },
        complete("Rules list --severity=")
      )
    end)

    it("is empty, not an error, where no ruleset is configured", function()
      pcall(vim.api.nvim_del_user_command, "Rules")
      require("rules").setup({ rulesets = {} })
      contract.clear_cache()
      assert.is_false(vim.tbl_contains(complete("Rules set "), "DEP-01"))
      assert.is_true(vim.tbl_contains(complete("Rules set "), "severity="))
      assert.are.same({}, complete("Rules move DEP-01 --to="))
      assert.is_false(vim.tbl_contains(complete("Rules new "), "DEP"))
    end)
  end)
end)
