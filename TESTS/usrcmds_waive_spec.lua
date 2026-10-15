-- TESTS/usrcmds_waive_spec.lua -- `:Rules waive`, `renew`, `unwaive`: a thin layer over `waive`, `renew` and `remove` of
-- `rules-ops/1` -- the words of the command line, the project, the question, the open buffers of the waivers file, the
-- completion.
--
-- The commands are run as a user types them (`vim.cmd("Rules ...")`) in a temporary project; the ruleset is a fixture
-- beside it. The clock is the `waivers.clock` seam and every date is in 2030 or later: nothing here depends on the real
-- day. A spec that asks a question answers it itself (`rules.ui.confirm.choose` is replaced).
---@diagnostic disable: need-check-nil
local contract = require("rules.contract")
local confirm = require("rules.ui.confirm")
local waivers = require("rules.engine.waivers")
local project_of = require("rules.ui.project")

local TODAY = "2030-06-15"

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
local function rule_file(id)
  return table.concat({
    "---",
    "id: " .. id,
    "severity: recommended",
    "family: " .. id:match("^(%a+)%-"),
    "---",
    "",
    "#### `" .. id .. "` — a rule",
    "",
    "Text of " .. id .. ".",
    "",
  }, "\n")
end

---The real path: a temporary folder may be reached through a link (macOS: /var -> /private/var, Windows: 8.3 names).
---@param path string
---@return string
local function real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

describe(":Rules waive, renew, unwaive", function()
  local base, ruleset, project, file
  local cwd_before
  local origin, origin_win
  local saved_ignore, saved_clock
  local saved_uis = vim.api.nvim_list_uis
  local saved_notify = vim.notify
  local original_choose = confirm.choose
  local asked, answer
  local notes

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

  ---@param text string
  ---@return integer|nil level
  local function level_of(text)
    for _, note in ipairs(notes) do
      if note.text:find(text, 1, true) then
        return note.level
      end
    end
    return nil
  end

  ---@param command string
  local function run(command)
    vim.cmd(command)
  end

  ---@param dir? string
  ---@return Rules.WaiverEntries
  local function entries(dir)
    local loaded, err = waivers.load_entries(dir or project)
    assert.is_nil(err)
    return loaded
  end

  ---@param tbl table
  local function seed(tbl)
    write_raw(file, vim.json.encode(tbl))
  end

  ---@param path string
  ---@return integer
  local function buffer_of(path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    return buf
  end

  ---@param line string
  ---@return string[]
  local function complete(line)
    return vim.fn.getcompletion(line, "cmdline")
  end

  ---The ids a line offers: the key= words and flags it offers beside them are left out.
  ---@param line string
  ---@return string[]
  local function ids(line)
    return vim.tbl_filter(function(word)
      return not word:find("=", 1, true) and word:sub(1, 1) ~= "-"
    end, complete(line))
  end

  ---A buffer for a file of the project (a real file, so its folder is a folder).
  ---@param path string
  ---@return integer
  local function open_file(path)
    write_raw(path, "x\n")
    local buf = buffer_of(path)
    vim.api.nvim_set_current_buf(buf)
    return buf
  end

  before_each(function()
    origin = vim.api.nvim_get_current_buf()
    origin_win = vim.api.nvim_get_current_win()
    saved_ignore = vim.o.eventignore
    vim.o.eventignore = "FileType,Syntax"
    base = vim.fn.tempname()
    ruleset = base .. "/fixture/Checklists"
    write_raw(ruleset .. "/_rules/DEP/DEP-01.md", rule_file("DEP-01"))
    write_raw(ruleset .. "/_rules/DEP/DEP-02.md", rule_file("DEP-02"))
    write_raw(ruleset .. "/_rules/ERR/ERR-01.md", rule_file("ERR-01"))
    project = base .. "/project"
    file = project .. "/.rules-waivers.json"
    vim.fn.mkdir(project, "p")
    cwd_before = vim.fn.getcwd()
    vim.fn.chdir(project)
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
    require("rules").setup({ rulesets = { ruleset } })
    contract.clear_cache()
    require("rules.ui.candidates").reset()
    saved_clock = waivers.clock
    waivers.clock = function()
      return TODAY
    end
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { text = tostring(msg), level = level }
    end
    asked, answer = {}, 2
    confirm.choose = function(question, choices, cb)
      asked[#asked + 1] = { question = question, choices = choices }
      cb(answer)
    end
  end)

  after_each(function()
    vim.notify = saved_notify
    vim.api.nvim_list_uis = saved_uis
    confirm.choose = original_choose
    waivers.clock = saved_clock
    vim.o.eventignore = saved_ignore
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
    vim.fn.chdir(cwd_before)
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
  end)

  describe("waive", function()
    it("writes the waiver with a reason, a last day and the paths, and tells it", function()
      run("Rules waive DEP-01 reason=legacy code, ticket 12 expires=2030-12-31 paths=src/legacy,docs/**/*.md")
      assert.are.same({
        ["DEP-01"] = { reason = "legacy code, ticket 12", expires = "2030-12-31", paths = { "src/legacy", "docs/**/*.md" } },
      }, entries())
      assert.is_true(told("waived DEP-01 through 2030-12-31 in .rules-waivers.json"))
      assert.are.same({}, asked)
    end)

    it("takes a reason of only a reason in the short form, and the keys in any order", function()
      run("Rules waive expires=2031-01-01 DEP-02 reason=fixture strings")
      assert.are.same({ ["DEP-02"] = { reason = "fixture strings", expires = "2031-01-01" } }, entries())
      run("Rules waive ERR-01 reason=just because")
      assert.are.same({ reason = "just because" }, entries()["ERR-01"])
      assert.is_truthy(read_raw(file):find('"ERR-01": "just because"', 1, true))
    end)

    it("keeps a value as typed: blanks, backslashes, % and #", function()
      run([[Rules waive DEP-01 reason=C:\Users\x\ end  two  blanks, 100% #done]])
      assert.are.equal([[C:\Users\x\ end  two  blanks, 100% #done]], entries()["DEP-01"].reason)
    end)

    it("splits paths= at the commas, not at the commas of a glob, and keeps a blank inside a path", function()
      run("Rules waive DEP-01 reason=r paths=docs/**/*.{md,txt}, my dir/100%/a#b.lua,src/")
      assert.are.same({ "docs/**/*.{md,txt}", "my dir/100%/a#b.lua", "src/" }, entries()["DEP-01"].paths)
    end)

    it("ends the flags at a bare -- where it stands for that, as set does", function()
      run("Rules waive DEP-01 -- reason=run with --dry now")
      assert.are.equal("run with --dry now", entries()["DEP-01"].reason)
    end)

    it("--dry checks everything, writes nothing and shows the file that would be written", function()
      run("Rules waive DEP-01 reason=later expires=2030-12-31 --dry")
      assert.is_nil(read_raw(file))
      assert.is_true(told("would waive DEP-01 through 2030-12-31 in .rules-waivers.json"))
      assert.is_true(told('+  "DEP-01": {'))
    end)

    it("tells what the door refuses word for word", function()
      run("Rules waive GHOST-01 reason=r")
      assert.is_true(told("invalid_argument: no loaded rule has the id GHOST-01"))
      notes = {}
      run("Rules waive DEP-01")
      assert.is_true(told("invalid_argument: waive needs id and reason"))
      notes = {}
      run("Rules waive DEP-01 reason=")
      assert.is_true(told("needs a reason that says something"))
      notes = {}
      run("Rules waive DEP-01 reason=r expires=2030-02-30")
      assert.is_true(told("expires for DEP-01 must be a calendar date"))
      notes = {}
      run("Rules waive DEP-01 reason=r paths=../outside")
      assert.is_true(told("paths for DEP-01: a path must not contain .."))
      notes = {}
      run("Rules waive DEP-01 reason=r paths=a,,b")
      assert.is_true(told("a path must be a non-empty text"))
      notes = {}
      run("Rules waive DEP-01 reason=r paths=")
      assert.is_true(told("paths must not be empty"))
      notes = {}
      run([[Rules waive DEP-01 reason=r paths=src\legacy]])
      assert.is_true(told("a path uses /"))
      assert.is_nil(read_raw(file))
    end)

    it("refuses a waiver that is there already, in the door's words, and leaves the file", function()
      run("Rules waive DEP-01 reason=first")
      local before = read_raw(file)
      notes = {}
      run("Rules waive DEP-01 reason=second")
      assert.is_true(told("DEP-01 is waived already: renew it"))
      assert.are.equal(before, read_raw(file))
    end)

    it("shows a date in the past as a warning: the waiver is written and expired", function()
      run("Rules waive DEP-01 reason=old expires=2029-01-01")
      assert.are.equal("2029-01-01", entries()["DEP-01"].expires)
      assert.is_true(told("expires is before today (" .. TODAY .. ")"))
      assert.are.equal(vim.log.levels.WARN, level_of("expires is before today"))
      assert.are.equal(vim.log.levels.INFO, level_of("waived DEP-01"))
    end)

    it("refuses a word that is no key=value, and an unknown key, before the door", function()
      run("Rules waive DEP-01 expire=2030-01-01 reason=r")
      assert.is_true(told("unknown field 'expire'"))
      notes = {}
      run("Rules waive DEP-01 reason=r reason=again")
      assert.is_true(told("'reason' given twice"))
      assert.is_nil(read_raw(file))
    end)
  end)

  describe("renew", function()
    before_each(function()
      seed({
        ["DEP-01"] = { reason = "legacy", expires = "2030-01-01", paths = { "src/legacy" } },
        ["DEP-02"] = "no expiry",
      })
    end)

    it("gives the waiver a new last day and keeps its reason and paths", function()
      run("Rules renew DEP-01 expires=2031-03-04")
      assert.are.same({ reason = "legacy", expires = "2031-03-04", paths = { "src/legacy" } }, entries()["DEP-01"])
      assert.is_true(told("renewed the waiver of DEP-01 through 2031-03-04 in .rules-waivers.json"))
    end)

    it("--no-expiry takes the last day away, reason= changes the reason", function()
      run("Rules renew DEP-01 --no-expiry reason=now permanent, ticket 9")
      assert.are.same({ reason = "now permanent, ticket 9", paths = { "src/legacy" } }, entries()["DEP-01"])
      assert.is_true(told("(no expiry)"))
    end)

    it("gives a waiver that has no last day one", function()
      run("Rules renew DEP-02 expires=2032-02-02")
      assert.are.same({ reason = "no expiry", expires = "2032-02-02" }, entries()["DEP-02"])
    end)

    it("--dry writes nothing", function()
      local before = read_raw(file)
      run("Rules renew DEP-01 expires=2031-03-04 --dry")
      assert.are.equal(before, read_raw(file))
      assert.is_true(told("would renew the waiver of DEP-01 through 2031-03-04"))
    end)

    it("tells what the door refuses word for word", function()
      run("Rules renew DEP-01")
      assert.is_true(told("invalid_argument: renew needs expires"))
      notes = {}
      run("Rules renew DEP-01 expires=2031-03-04 --no-expiry")
      assert.is_true(told("invalid_argument: renew needs expires"))
      notes = {}
      run("Rules renew ERR-01 expires=2031-03-04")
      assert.is_true(told("not_found: no waiver for ERR-01"))
      notes = {}
      run("Rules renew DEP-01 expires=soon")
      assert.is_true(told("invalid_argument: expires must be a calendar date"))
      notes = {}
      run("Rules renew DEP-01 expires=2031-03-04 reason=")
      assert.is_true(told("reason must say something"))
      assert.are.equal("2030-01-01", entries()["DEP-01"].expires)
    end)

    it("says it when nothing changes", function()
      run("Rules renew DEP-01 expires=2030-01-01")
      assert.is_true(told("DEP-01 is unchanged"))
    end)

    it("shows a date in the past as a warning", function()
      run("Rules renew DEP-01 expires=2029-12-31")
      assert.are.equal("2029-12-31", entries()["DEP-01"].expires)
      assert.are.equal(vim.log.levels.WARN, level_of("expires is before today"))
    end)
  end)

  describe("unwaive", function()
    before_each(function()
      -- a session with a screen: the question can be asked
      vim.api.nvim_list_uis = function()
        return { {} }
      end
      seed({ ["DEP-01"] = { reason = "legacy code", expires = "2030-01-01", paths = { "src/a", "src/b" } }, ["DEP-02"] = "keep" })
    end)

    it("asks first, showing the waiver, with No as the answer the dialog starts on, and does nothing on No", function()
      answer = 1
      run("Rules unwaive DEP-01")
      assert.are.equal(1, #asked)
      assert.are.same({ "No", "Yes, remove" }, asked[1].choices)
      local question = asked[1].question
      assert.is_truthy(question:find("Remove the waiver of DEP-01 from .rules-waivers.json?", 1, true))
      assert.is_truthy(question:find("legacy code", 1, true))
      assert.is_truthy(question:find("2030-01-01", 1, true))
      assert.is_truthy(question:find("src/a, src/b", 1, true))
      assert.is_not_nil(entries()["DEP-01"])
      assert.is_true(told("the waiver of DEP-01 was not removed"))
      -- a question that was dismissed is no answer either
      answer = nil
      run("Rules unwaive DEP-01")
      assert.is_not_nil(entries()["DEP-01"])
    end)

    it("removes the waiver on Yes and leaves the others", function()
      run("Rules unwaive DEP-01")
      assert.are.same({ ["DEP-02"] = { reason = "keep" } }, entries())
      assert.is_true(told("removed the waiver of DEP-01 from .rules-waivers.json"))
    end)

    it("--yes removes without asking", function()
      run("Rules unwaive DEP-02 --yes")
      assert.are.same({}, asked)
      assert.is_nil(entries()["DEP-02"])
    end)

    it("--dry says what would happen, asks nothing and removes nothing", function()
      local before = read_raw(file)
      run("Rules unwaive DEP-01 --dry")
      assert.are.same({}, asked)
      assert.are.equal(before, read_raw(file))
      assert.is_true(told("would remove the waiver of DEP-01 from .rules-waivers.json"))
    end)

    it("does not ask about a waiver the door would refuse", function()
      run("Rules unwaive ERR-01")
      assert.are.same({}, asked)
      assert.is_true(told("not_found: no waiver for ERR-01"))
    end)

    it("needs --yes where there is nobody to ask", function()
      vim.api.nvim_list_uis = saved_uis
      run("Rules unwaive DEP-01")
      assert.are.same({}, asked)
      assert.is_not_nil(entries()["DEP-01"])
      assert.is_true(told("run it with --yes"))
    end)

    it("refuses a word it cannot use", function()
      run("Rules unwaive DEP-01 reason=x --yes")
      assert.is_true(told("unexpected argument: reason=x"))
      assert.is_not_nil(entries()["DEP-01"])
    end)
  end)

  describe("the open buffer of the waivers file", function()
    before_each(function()
      seed({ ["DEP-02"] = "keep" })
    end)

    it("is reloaded when it has no unsaved changes", function()
      local buf = buffer_of(file)
      run("Rules waive DEP-01 reason=fresh")
      assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find('"DEP-01": "fresh"', 1, true))
      assert.is_false(vim.bo[buf].modified)
      assert.is_true(told("reloaded"))
      run("Rules renew DEP-01 expires=2031-01-01")
      assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("2031-01-01", 1, true))
      run("Rules unwaive DEP-01 --yes")
      assert.is_nil(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("DEP-01", 1, true))
    end)

    it("is reported as a conflict, and left as it is, when it has unsaved changes", function()
      local buf = buffer_of(file)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "{ my edit" })
      run("Rules waive DEP-01 reason=fresh")
      assert.is_truthy(read_raw(file):find('"DEP-01": "fresh"', 1, true))
      assert.are.same({ "{ my edit" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.is_true(vim.bo[buf].modified)
      assert.is_true(told("has unsaved changes and the file changed on disk"))
      assert.is_true(told(".rules-waivers.json"))
    end)

    it("is not made when it is not open, and nothing is said about buffers", function()
      assert.are.equal(-1, vim.fn.bufnr(file))
      run("Rules waive DEP-01 reason=fresh")
      assert.are.equal(-1, vim.fn.bufnr(file))
      assert.is_false(told("reloaded"))
      assert.is_false(told("unsaved"))
    end)

    it("is not touched by a --dry run, nor by a run the door refuses", function()
      local buf = buffer_of(file)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "{ my edit" })
      run("Rules waive DEP-01 reason=fresh --dry")
      run("Rules waive GHOST-01 reason=fresh")
      assert.are.same({ "{ my edit" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.is_false(told("unsaved"))
    end)

    it("is found by its real path, also in a project below the working directory", function()
      write_raw(project .. "/pkgs/a/.rules.json", "{}")
      local sub_file = project .. "/pkgs/a/.rules-waivers.json"
      write_raw(sub_file, "{}\n")
      local waivers_buf = buffer_of(sub_file)
      open_file(project .. "/pkgs/a/src/x.lua")
      run("Rules waive DEP-01 reason=sub")
      assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(waivers_buf, 0, -1, false), "\n"):find("DEP-01", 1, true))
    end)
  end)

  describe("the project", function()
    it("is the working directory without a file of a project of its own", function()
      open_file(project .. "/src/deep/x.lua")
      run("Rules waive DEP-01 reason=r")
      assert.are.equal("r", entries()["DEP-01"].reason)
      assert.is_true(told("waived DEP-01 in .rules-waivers.json"))
      -- a buffer without a file, and one that is no file
      vim.cmd("enew")
      run("Rules waive DEP-02 reason=r")
      assert.is_not_nil(entries()["DEP-02"])
      vim.cmd("enew")
      vim.bo.buftype = "nofile"
      run("Rules waive ERR-01 reason=r")
      assert.is_not_nil(entries()["ERR-01"])
    end)

    it("is the folder of the buffer's file with a .rules.json, a waivers file or a .git below the cwd", function()
      write_raw(project .. "/pkgs/a/.rules.json", "{}")
      open_file(project .. "/pkgs/a/src/x.lua")
      run("Rules waive DEP-01 reason=in a")
      assert.are.equal("in a", entries(project .. "/pkgs/a")["DEP-01"].reason)
      assert.are.same({}, entries())
      assert.is_true(told("waived DEP-01 in pkgs/a/.rules-waivers.json"))

      write_raw(project .. "/pkgs/b/.rules-waivers.json", "{}\n")
      open_file(project .. "/pkgs/b/x.lua")
      run("Rules waive DEP-01 reason=in b")
      assert.are.equal("in b", entries(project .. "/pkgs/b")["DEP-01"].reason)

      vim.fn.mkdir(project .. "/pkgs/c/.git", "p")
      open_file(project .. "/pkgs/c/lib/x.lua")
      run("Rules waive DEP-01 reason=in c")
      assert.are.equal("in c", entries(project .. "/pkgs/c")["DEP-01"].reason)
      assert.are.same({}, entries())
    end)

    it("is the nearest folder that has a marker, and the project of renew and unwaive as well", function()
      write_raw(project .. "/pkgs/a/.rules.json", "{}")
      write_raw(project .. "/pkgs/a/inner/.rules-waivers.json", '{"DEP-01": "inner"}\n')
      open_file(project .. "/pkgs/a/inner/src/x.lua")
      run("Rules renew DEP-01 expires=2031-01-01")
      assert.are.equal("2031-01-01", entries(project .. "/pkgs/a/inner")["DEP-01"].expires)
      run("Rules unwaive DEP-01 --yes")
      assert.is_nil(entries(project .. "/pkgs/a/inner")["DEP-01"])
      assert.is_false(told("not_found"))
    end)

    it("is never a folder above the working directory, nor one beside it", function()
      -- a repository around the working directory, and one beside it
      vim.fn.mkdir(base .. "/.git", "p")
      open_file(project .. "/src/x.lua")
      run("Rules waive DEP-01 reason=r")
      assert.are.equal("r", entries()["DEP-01"].reason)
      assert.is_nil(read_raw(base .. "/.rules-waivers.json"))

      vim.fn.mkdir(base .. "/other/.git", "p")
      open_file(base .. "/other/x.lua")
      run("Rules waive DEP-02 reason=r")
      assert.is_not_nil(entries()["DEP-02"])
      assert.is_nil(read_raw(base .. "/other/.rules-waivers.json"))
    end)

    it("--project= names it, relative to the working directory, also when the buffer is in another one", function()
      write_raw(project .. "/pkgs/a/.rules.json", "{}")
      open_file(project .. "/pkgs/a/x.lua")
      vim.fn.mkdir(project .. "/pkgs/b", "p")
      run("Rules waive DEP-01 reason=r --project=pkgs/b")
      assert.are.equal("r", entries(project .. "/pkgs/b")["DEP-01"].reason)
      assert.are.same({}, entries(project .. "/pkgs/a"))
      assert.is_true(told("waived DEP-01 in pkgs/b/.rules-waivers.json"))
      run("Rules renew DEP-01 expires=2031-01-01 --project=pkgs/b")
      assert.are.equal("2031-01-01", entries(project .. "/pkgs/b")["DEP-01"].expires)
      run("Rules unwaive DEP-01 --project=pkgs/b --yes")
      assert.is_nil(entries(project .. "/pkgs/b")["DEP-01"])
      -- the working directory itself
      run("Rules waive DEP-02 reason=top --project=.")
      assert.are.equal("top", entries()["DEP-02"].reason)
    end)

    it("--project= takes a blank as \\ and keeps % and # as typed", function()
      vim.fn.mkdir(project .. "/p gs 100%#x", "p")
      run([[Rules waive DEP-01 reason=r --project=p\ gs\ 100%#x]])
      assert.are.equal("r", entries(project .. "/p gs 100%#x")["DEP-01"].reason)
    end)

    it("--project= outside the working directory is the door's refusal, and nothing is written", function()
      vim.fn.mkdir(base .. "/elsewhere", "p")
      run("Rules waive DEP-01 reason=r --project=" .. base .. "/elsewhere")
      assert.is_true(told("project must be the configured project or a folder inside it"))
      assert.is_nil(read_raw(base .. "/elsewhere/.rules-waivers.json"))
      notes = {}
      run("Rules waive DEP-01 reason=r --project=missing")
      assert.is_true(told("the project is not a folder that exists"))
      notes = {}
      run("Rules waive DEP-01 reason=r --project=../project")
      assert.is_true(told("project must not contain .."))
    end)

    describe("of_buffer", function()
      it("is nil for a file outside the working directory and for the working directory", function()
        write_raw(base .. "/other/.rules.json", "{}")
        local buf = open_file(base .. "/other/x.lua")
        assert.is_nil(project_of.of_buffer(buf))
        write_raw(project .. "/.rules.json", "{}")
        buf = open_file(project .. "/x.lua")
        assert.is_nil(project_of.of_buffer(buf))
      end)

      it("is the folder relative to the working directory, spelled as the file system spells it", function()
        write_raw(project .. "/Pkgs/a/.rules.json", "{}")
        local buf = open_file(project .. "/Pkgs/a/x.lua")
        assert.are.equal("Pkgs/a", project_of.of_buffer(buf, real(project)))
        assert.are.equal("Pkgs/a", project_of.of_buffer(buf))
      end)

      it("lets an explicit --project= win over the buffer", function()
        assert.are.equal("given", project_of.request("given", 0))
      end)
    end)
  end)

  describe("completion", function()
    before_each(function()
      seed({ ["DEP-01"] = "one", ["ERR-01"] = "two", ["GHOST-01"] = "a waiver for an id nobody loads" })
    end)

    it("waive offers the ids of the loaded rules", function()
      assert.are.same({ "DEP-01", "DEP-02" }, complete("Rules waive DEP-"))
      assert.is_true(vim.tbl_contains(complete("Rules waive "), "ERR-01"))
    end)

    it("renew and unwaive offer the ids that have a waiver, and only those", function()
      assert.are.same({ "DEP-01", "ERR-01", "GHOST-01" }, ids("Rules renew "))
      assert.are.same({ "DEP-01" }, ids("Rules unwaive D"))
      assert.are.same({ "GHOST-01" }, ids("Rules unwaive G"))
    end)

    it("reads the file on every <Tab>: a waiver made a moment ago is offered, one removed is not", function()
      assert.are.same({}, ids("Rules renew DEP-02"))
      run("Rules waive DEP-02 reason=r")
      assert.are.same({ "DEP-02" }, ids("Rules renew DEP-02"))
      run("Rules unwaive DEP-02 --yes")
      assert.are.same({}, ids("Rules unwaive DEP-02"))
      -- and one written by someone else
      seed({ ["DEP-02"] = "by hand" })
      assert.are.same({ "DEP-02" }, ids("Rules renew DEP-02"))
    end)

    it("offers the ids of the project of the buffer, and of --project= when the line names one", function()
      write_raw(project .. "/pkgs/a/.rules.json", "{}")
      write_raw(project .. "/pkgs/a/.rules-waivers.json", '{"DEP-02": "in a"}\n')
      open_file(project .. "/pkgs/a/x.lua")
      assert.are.same({ "DEP-02" }, ids("Rules renew "))
      assert.are.same({ "DEP-01", "ERR-01", "GHOST-01" }, ids("Rules renew --project=. "))
      vim.cmd("enew")
      assert.are.same({ "DEP-02" }, ids("Rules unwaive --project=pkgs/a "))
    end)

    it("offers nothing, and no error, for a file that cannot be used or a project the door refuses", function()
      write_raw(file, "this is not json")
      assert.are.same({}, ids("Rules renew "))
      seed({ ["DEP-01"] = "one" })
      assert.are.same({}, ids("Rules renew --project=missing "))
      assert.are.same({}, ids("Rules renew --project=../project "))
    end)

    it("--project= offers the folders, a blank in a name written with a backslash before it", function()
      vim.fn.mkdir(project .. "/pkgs/a", "p")
      vim.fn.mkdir(project .. "/pkgs/b c", "p")
      -- the editor ends a folder with the separator of the system
      local sep = vim.fn.has("win32") == 1 and "\\" or "/"
      local got = complete("Rules waive DEP-01 --project=pkgs/")
      table.sort(got)
      assert.are.same({ "--project=pkgs" .. sep .. "a" .. sep, "--project=pkgs" .. sep .. "b\\ c" .. sep }, got)
      -- and what it offers is read back as the folder it names
      local typed = got[2]:gsub("^%-%-project=", "")
      assert.are.equal("pkgs" .. sep .. "b c" .. sep, require("rules.cmdline").unescape(typed))
    end)

    it("expires= has no completion", function()
      assert.are.same({}, complete("Rules waive DEP-01 expires="))
      assert.are.same({}, complete("Rules renew DEP-01 expires=20"))
    end)

    it("names today in the help of expires=, as of the moment the help is read", function()
      local composer = require("lib.nvim.bindings.usercmd.composer")
      local seen = {}
      for _, route in ipairs(composer.registry().Rules:spec().routes) do
        if route.path[1] == "waive" or route.path[1] == "renew" then
          for _, kv in ipairs(route.kv) do
            if kv.key == "expires" then
              seen[#seen + 1] = kv
            end
          end
        end
      end
      assert.are.equal(2, #seen)
      for _, kv in ipairs(seen) do
        assert.is_truthy(kv.desc:find("today is " .. TODAY, 1, true))
        assert.is_true(#kv.desc <= 80)
        waivers.clock = function()
          return "2031-02-03"
        end
        assert.is_truthy(kv.desc:find("today is 2031-02-03", 1, true))
        waivers.clock = function()
          return TODAY
        end
      end
    end)
  end)
end)
