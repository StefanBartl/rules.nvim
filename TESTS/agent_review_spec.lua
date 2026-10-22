-- TESTS/agent_review_spec.lua -- `:Rules review`: the proposals of an agent run, to accept, waive or discard one at a time.
--
-- The view is opened with the command a user types; the keys are the ones the buffer maps (called as a key would call
-- them). Proposals are put in by a run of `:Rules agent` over the `rules.agent.transport` seam: no model is asked.
---@diagnostic disable: need-check-nil
local contract = require("rules.contract")
local confirm = require("rules.ui.confirm")
local agent = require("rules.agent")
local verdicts = require("rules.engine.verdicts")
local waivers = require("rules.engine.waivers")
local review = require("rules.report.review")

---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
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

describe(":Rules review", function()
  local base, ruleset, project, root
  local origin, origin_win
  local cwd_before
  local saved_notify = vim.notify
  local saved_uis = vim.api.nvim_list_uis
  local saved_clock = waivers.clock
  local saved_by, saved_user, saved_username = vim.g.rules_by, vim.env.USER, vim.env.USERNAME
  local original_choose = confirm.choose
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

  --- What the model answers, per rule.
  local answers = {
    ["DEP-01"] = {
      rule = "DEP-01",
      verdict = "violation",
      checked = { "lua/a.lua" },
      findings = { { file = "lua/a.lua", line = 2, quote = "require('x')", why = "hidden dependency" } },
    },
    ["DEP-02"] = { rule = "DEP-02", verdict = "compliant", checked = { "lua/a.lua" } },
    ["ERR-01"] = { rule = "ERR-01", verdict = "unclear", reason = "needs the build config" },
  }

  ---@param family string
  local function ask_family(family)
    agent.transport = function(_, cb)
      cb(true, { text = vim.json.encode({ results = vim.tbl_values(answers) }) })
    end
    agent.run({ family = family, manual = true, yes = true, root = root })
  end

  ---@return integer buf
  local function open()
    vim.cmd("Rules review")
    return vim.api.nvim_get_current_buf()
  end

  ---@param buf integer
  ---@param needle string
  ---@return integer|nil line
  local function line_of(buf, needle)
    for i, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if text:find(needle, 1, true) then
        return i
      end
    end
    return nil
  end

  ---Press a key of the review buffer with the cursor on `needle`.
  ---@param buf integer
  ---@param key string
  ---@param needle string
  local function press(buf, key, needle)
    local line = assert(line_of(buf, needle), "no line with " .. needle)
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    local map = vim.api.nvim_buf_call(buf, function()
      return vim.fn.maparg(key, "n", false, true)
    end)
    assert(map.callback, "the review buffer maps no " .. key)
    map.callback()
  end

  before_each(function()
    origin = vim.api.nvim_get_current_buf()
    origin_win = vim.api.nvim_get_current_win()
    base = vim.fn.tempname()
    ruleset = base .. "/fixture/Checklists"
    for _, id in ipairs({ "DEP-01", "DEP-02", "ERR-01" }) do
      write_raw(ruleset .. "/_rules/" .. id:match("^(%a+)") .. "/" .. id .. ".md", rule_file(id))
    end
    project = base .. "/project"
    write_raw(project .. "/lua/a.lua", "local a = 1\nlocal b = require('x')\nreturn a\n")
    cwd_before = vim.fn.getcwd()
    vim.fn.chdir(project)
    root = vim.fn.getcwd()
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
    require("rules").setup({
      rulesets = { ruleset },
      agent = { scopes = { DEP = { include = { "lua/**/*.lua" } }, ERR = { include = { "lua/**/*.lua" } } } },
    })
    contract.clear_cache()
    require("rules.ui.candidates").reset()
    agent.proposals = {}
    agent.cache_dir = base .. "/cache"
    vim.g.rules_by = "Stefan"
    waivers.clock = function()
      return "2030-06-15"
    end
    notes = {}
    vim.notify = function(msg, level)
      notes[#notes + 1] = { text = tostring(msg), level = level }
    end
    vim.api.nvim_list_uis = function()
      return { {} }
    end
  end)

  after_each(function()
    vim.notify = saved_notify
    vim.api.nvim_list_uis = saved_uis
    waivers.clock = saved_clock
    confirm.choose = original_choose
    agent.transport = nil
    agent.cache_dir = nil
    vim.g.rules_by, vim.env.USER, vim.env.USERNAME = saved_by, saved_user, saved_username
    vim.fn.chdir(cwd_before)
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
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
  end)

  describe("the view", function()
    it("says there is nothing to look at before an agent run", function()
      local buf = open()

      assert.is_truthy(line_of(buf, "no proposals: run :Rules agent <ID> first"))
    end)

    it("shows every proposal as PROPOSED, with its status in words, apart from the check results", function()
      ask_family("DEP")
      ask_family("ERR")

      local buf = open()

      assert.is_truthy(line_of(buf, "what an agent PROPOSED, not what was checked"))
      assert.is_truthy(line_of(buf, "PROPOSED violation DEP-01"))
      assert.is_truthy(line_of(buf, "PROPOSED compliant DEP-02"))
      assert.is_truthy(line_of(buf, "PROPOSED unclear   ERR-01"))
      assert.is_truthy(line_of(buf, "lua/a.lua:2  require('x')"))
      assert.is_truthy(line_of(buf, "hidden dependency"))
      assert.is_truthy(line_of(buf, "needs the build config"))
    end)

    it("says which sent files a compliant answer did not look at", function()
      write_raw(project .. "/lua/b.lua", "return 1\n")
      ask_family("DEP")

      local buf = open()

      assert.is_truthy(line_of(buf, "looked at: lua/a.lua"))
      assert.is_truthy(line_of(buf, "NOT looked at (1 sent): lua/b.lua"))
    end)

    it("maps no key for accepting all of them", function()
      ask_family("DEP")

      local buf = open()

      for _, key in ipairs({ "A", "W", "ga", "<C-a>" }) do
        local map = vim.api.nvim_buf_call(buf, function()
          return vim.fn.maparg(key, "n", false, true)
        end)
        assert.is_nil(map.callback, key)
      end
      assert.is_truthy(line_of(buf, "there is no accept-all"))
    end)
  end)

  describe("accept", function()
    it("writes the verdict of the proposal under the cursor, as the person, and takes it off the list", function()
      ask_family("DEP")
      local buf = open()

      press(buf, "a", "PROPOSED violation DEP-01")

      local loaded, err = verdicts.load(root)
      assert.is_nil(err)
      assert.are.equal("violation", loaded["DEP-01"].verdict)
      assert.are.equal("Stefan", loaded["DEP-01"].by)
      assert.are.equal("violation", loaded["DEP-01"].from_proposal.status)
      assert.are.same({ { file = "lua/a.lua", line = 2 } }, loaded["DEP-01"].evidence)
      assert.is_nil(loaded["DEP-02"])
      assert.is_nil(line_of(buf, "PROPOSED violation DEP-01"))
      assert.is_truthy(line_of(buf, "PROPOSED compliant DEP-02"))
    end)

    it("does not accept an unclear proposal", function()
      ask_family("ERR")
      local buf = open()

      press(buf, "a", "PROPOSED unclear   ERR-01")

      assert.are.equal(0, vim.fn.filereadable(verdicts.path(root)))
      assert.is_truthy(told("was not accepted"))
      assert.is_truthy(line_of(buf, "PROPOSED unclear   ERR-01"))
    end)

    it("asks who accepts when nobody is named, and writes nothing", function()
      vim.g.rules_by, vim.env.USER, vim.env.USERNAME = nil, nil, nil
      ask_family("DEP")
      local buf = open()

      press(buf, "a", "PROPOSED violation DEP-01")

      assert.are.equal(0, vim.fn.filereadable(verdicts.path(root)))
      assert.is_truthy(told("who accepts?"))
    end)

    it("accepts one proposal per key press, never the rest", function()
      ask_family("DEP")
      local buf = open()

      press(buf, "a", "PROPOSED compliant DEP-02")

      local loaded = verdicts.load(root)
      assert.are.same({ "DEP-02" }, vim.tbl_keys(loaded))
    end)
  end)

  describe("waive", function()
    it("waives the violation with the reason, through the door of :Rules waive", function()
      ask_family("DEP")
      local buf = open()
      local original_input = vim.ui.input
      vim.ui.input = function(_, cb)
        cb("known, ticket 7")
      end

      press(buf, "w", "PROPOSED violation DEP-01")
      vim.ui.input = original_input

      local entries = waivers.load_entries(root)
      assert.are.equal("known, ticket 7", entries["DEP-01"].reason)
      assert.is_nil(line_of(buf, "PROPOSED violation DEP-01"))
      assert.are.equal(0, vim.fn.filereadable(verdicts.path(root)))
    end)

    it("writes nothing without a reason", function()
      ask_family("DEP")
      local buf = open()
      local original_input = vim.ui.input
      vim.ui.input = function(_, cb)
        cb("   ")
      end

      press(buf, "w", "PROPOSED violation DEP-01")
      vim.ui.input = original_input

      assert.are.same({}, waivers.load_entries(root))
      assert.is_truthy(line_of(buf, "PROPOSED violation DEP-01"))
    end)

    it("refuses to waive what is not a violation", function()
      ask_family("DEP")
      local buf = open()

      press(buf, "w", "PROPOSED compliant DEP-02")

      assert.are.same({}, waivers.load_entries(root))
      assert.is_truthy(told("only a violation can be waived"))
    end)
  end)

  describe("discard", function()
    it("forgets the proposal and writes nothing", function()
      ask_family("DEP")
      local buf = open()

      press(buf, "x", "PROPOSED violation DEP-01")

      assert.is_nil(line_of(buf, "PROPOSED violation DEP-01"))
      assert.are.equal(0, vim.fn.filereadable(verdicts.path(root)))
      assert.are.same({}, waivers.load_entries(root))
    end)
  end)

  describe("without ai.nvim", function()
    it("leaves the review working: the view does not need a transport", function()
      ask_family("DEP")
      agent.transport = nil
      local saved_loaded, saved_preload = package.loaded.ai, package.preload.ai
      package.loaded.ai = nil
      package.preload.ai = function()
        error("module 'ai' not found")
      end

      local buf = open()
      package.loaded.ai, package.preload.ai = saved_loaded, saved_preload

      assert.is_truthy(line_of(buf, "PROPOSED violation DEP-01"))
    end)
  end)

  it("renders without a window: what a host shows", function()
    ask_family("DEP")

    local lines, owner = review.render(agent.list(root))

    assert.is_true(#lines > 3)
    assert.are.equal("DEP-01", owner[4].rule.id)
  end)
end)
