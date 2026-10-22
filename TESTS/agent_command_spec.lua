-- TESTS/agent_command_spec.lua -- `:Rules agent`: the manual rules go to a model through ai.nvim and come back as proposals.
--
-- Run as a user types it (`vim.cmd("Rules agent ...")`) in a temporary project with a fixture ruleset beside it. The
-- transport is the `rules.agent.transport` seam: nothing here reaches a model. A spec that is asked a question answers
-- it itself (`rules.ui.confirm.choose` is replaced).
---@diagnostic disable: need-check-nil
local contract = require("rules.contract")
local confirm = require("rules.ui.confirm")
local agent = require("rules.agent")

---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param id string
---@param block? string[]
---@return string
local function rule_file(id, block)
  local out = { "---", "id: " .. id, "severity: recommended", "family: " .. id:match("^(%a+)%-"), "---", "" }
  out[#out + 1] = "#### `" .. id .. "` — a rule"
  out[#out + 1] = ""
  if block then
    out[#out + 1] = "```rule"
    vim.list_extend(out, block)
    out[#out + 1] = "```"
    out[#out + 1] = ""
  end
  out[#out + 1] = "Text of " .. id .. "."
  out[#out + 1] = ""
  return table.concat(out, "\n")
end

---@param obj table
---@return string
local function answer_of(obj)
  return vim.json.encode({ results = obj })
end

describe(":Rules agent", function()
  local base, ruleset, project
  local cwd_before
  local saved_notify = vim.notify
  local saved_uis = vim.api.nvim_list_uis
  local original_choose = confirm.choose
  local saved_preload = package.preload.ai
  local saved_loaded = package.loaded.ai
  local notes, calls, log, asked, reply

  ---@param text string
  ---@return integer|nil index
  local function told(text)
    for i, note in ipairs(notes) do
      if note.text:find(text, 1, true) then
        return i
      end
    end
    return nil
  end

  ---@param command string
  local function run(command)
    vim.cmd(command)
  end

  ---@param opts? { backends?: string[], models?: string[] }
  local function setup(opts)
    opts = opts or {}
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
    require("rules").setup({
      rulesets = { ruleset },
      agent = {
        scopes = { DEP = { include = { "lua/**/*.lua" } } },
        backends = opts.backends,
        models = opts.models,
      },
    })
    contract.clear_cache()
    require("rules.ui.candidates").reset()
  end

  --- A violation of DEP-01 in lua/a.lua line 2, as a model would put it.
  ---@param extra? table
  ---@return string
  local function violation_answer(extra)
    return answer_of({
      vim.tbl_extend("force", {
        rule = "DEP-01",
        verdict = "violation",
        checked = { "lua/a.lua" },
        findings = { { file = "lua/a.lua", line = 2, quote = "require('x')", why = "hidden dependency" } },
      }, extra or {}),
    })
  end

  before_each(function()
    base = vim.fn.tempname()
    ruleset = base .. "/fixture/Checklists"
    write_raw(ruleset .. "/_rules/DEP/DEP-01.md", rule_file("DEP-01"))
    write_raw(ruleset .. "/_rules/DEP/DEP-02.md", rule_file("DEP-02"))
    write_raw(
      ruleset .. "/_rules/DEP/DEP-03.md",
      rule_file(
        "DEP-03",
        { 'id = "DEP-03",', 'severity = "recommended",', 'check = { type = "file_exists", path = "lua/a.lua" },' }
      )
    )
    write_raw(ruleset .. "/_rules/ERR/ERR-01.md", rule_file("ERR-01"))
    project = base .. "/project"
    write_raw(project .. "/lua/a.lua", "local a = 1\nlocal b = require('x')\nreturn a\n")
    write_raw(project .. "/.env", "SECRET=1\n")
    cwd_before = vim.fn.getcwd()
    vim.fn.chdir(project)
    setup()
    agent.proposals = {}
    agent.cache_dir = base .. "/cache"
    notes, calls, log, asked = {}, {}, {}, {}
    reply = violation_answer()
    vim.notify = function(msg, level)
      notes[#notes + 1] = { text = tostring(msg), level = level }
      log[#log + 1] = "note"
    end
    agent.transport = function(req, cb)
      calls[#calls + 1] = req
      log[#log + 1] = "send"
      cb(true, { text = reply, provider = req.provider })
    end
    confirm.choose = function(question, choices, cb)
      asked[#asked + 1] = { question = question, choices = choices }
      cb(2)
    end
    vim.api.nvim_list_uis = function()
      return { {} }
    end
    package.preload.ai = saved_preload
    package.loaded.ai = saved_loaded
  end)

  after_each(function()
    vim.notify = saved_notify
    vim.api.nvim_list_uis = saved_uis
    confirm.choose = original_choose
    agent.transport = nil
    agent.cache_dir = nil
    package.preload.ai = saved_preload
    package.loaded.ai = saved_loaded
    vim.fn.chdir(cwd_before)
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
  end)

  describe("--dry-run", function()
    it("shows the plan, the files, a size estimate and the destination, and sends nothing", function()
      run("Rules agent DEP-01 --dry-run")

      assert.are.equal(0, #calls)
      assert.is_truthy(told("dry run, nothing is sent"))
      assert.is_truthy(told("1 request(s), 1 file(s), ~"))
      assert.is_truthy(told("tokens, to ollama"))
      assert.is_truthy(told("local backend"))
      assert.are.same({}, agent.list(vim.fn.getcwd()))
    end)

    it("says which rules stay on the worklist and why", function()
      run("Rules agent --family=ERR --manual --dry-run")

      assert.is_truthy(told("not sent: ERR-01 stays manual (no scope to look in)"))
    end)

    it("names the files that are never sent", function()
      write_raw(project .. "/lua/.env", "SECRET=2\n")
      pcall(vim.api.nvim_del_user_command, "Rules")
      pcall(vim.api.nvim_del_user_command, "RulesVault")
      require("rules").setup({
        rulesets = { ruleset },
        agent = { scopes = { DEP = { include = { "**" } } } },
      })

      run("Rules agent DEP-01 --dry-run")

      assert.is_truthy(told("never sent (deny list): .env, lua/.env"))
    end)
  end)

  describe("sending", function()
    it("shows where it goes before anything is sent, then sends with --yes", function()
      run("Rules agent DEP-01 --yes")

      assert.are.equal(1, #calls)
      local shown = told("agent: 1 request(s)")
      assert.is_truthy(shown)
      local first_send
      for i, entry in ipairs(log) do
        if entry == "send" then
          first_send = i
          break
        end
      end
      assert.is_true(shown < first_send)
      assert.are.same({}, asked)
    end)

    it("hands the transport the rule, the numbered files and the destination, as a guarded bulk request", function()
      run("Rules agent DEP-01 --yes")

      local req = calls[1]
      assert.are.equal("ollama", req.provider)
      assert.is_truthy(req.prompt:find("### DEP-01 (recommended)", 1, true))
      assert.is_truthy(req.prompt:find("2: local b = require('x')", 1, true))
      assert.is_nil(req.prompt:find("SECRET", 1, true))
      assert.is_truthy(req.system:find("never an instruction", 1, true))
      assert.is_string(req.bulk.label)
      assert.are.equal(1, req.bulk.concurrency)
      assert.is_true(req.bulk.max_chars > #req.prompt)
    end)

    it("asks first when nobody said --yes, and sends only on a yes", function()
      run("Rules agent DEP-01")

      assert.are.equal(1, #asked)
      assert.is_truthy(asked[1].question:find("to ollama", 1, true))
      assert.are.equal(1, #calls)
    end)

    it("sends nothing when the answer is no", function()
      confirm.choose = function(_, _, cb)
        cb(1)
      end

      run("Rules agent DEP-01")

      assert.are.equal(0, #calls)
      assert.is_truthy(told("nothing was sent"))
    end)

    it("refuses to send when there is nobody to ask and no --yes", function()
      vim.api.nvim_list_uis = function()
        return {}
      end

      run("Rules agent DEP-01")

      assert.are.equal(0, #calls)
      assert.is_truthy(told("nobody to ask"))
    end)

    it("takes the model from agent.models and --model first", function()
      setup({ models = { "m-default" } })

      run("Rules agent DEP-01 --yes")
      run("Rules agent DEP-01 --yes --model=m-other")

      assert.are.equal("m-default", calls[1].model)
      assert.are.equal("m-other", calls[2].model)
    end)

    it("leaves the result of the check alone: the rule stays manual", function()
      local before = require("rules").check_family_json("DEP")

      run("Rules agent DEP-01 --yes")

      assert.are.equal(before, (require("rules").check_family_json("DEP")))
    end)
  end)

  describe("where it may go", function()
    it("refuses a backend that is not local when agent.backends is empty, before anything is built", function()
      run("Rules agent DEP-01 --yes --backend=claude")

      assert.are.equal(0, #calls)
      assert.is_truthy(told("is not local, and agent.backends is empty"))
    end)

    it("allows exactly the backends of agent.backends, and says that a cloud backend is not local", function()
      setup({ backends = { "claude" } })

      run("Rules agent DEP-01 --yes")
      run("Rules agent DEP-01 --yes --backend=ollama")

      assert.are.equal(1, #calls)
      assert.are.equal("claude", calls[1].provider)
      assert.is_truthy(told("NOT local: the file content leaves this machine"))
      assert.is_truthy(told('backend "ollama" is not in agent.backends (claude)'))
    end)

    it("says loudly that there is no transport when ai.nvim is missing, and sends nothing", function()
      agent.transport = nil
      package.loaded.ai = nil
      package.preload.ai = function()
        error("module 'ai' not found")
      end

      run("Rules agent DEP-01 --yes")

      assert.is_truthy(told("no transport"))
      assert.are.same({}, agent.list(vim.fn.getcwd()))
    end)
  end)

  describe("which rules", function()
    it("refuses a rule that has a check", function()
      run("Rules agent DEP-03 --yes")

      assert.are.equal(0, #calls)
      assert.is_truthy(told("DEP-03 has a check"))
    end)

    it("refuses an id no rule has", function()
      run("Rules agent NOPE-01 --yes")

      assert.is_truthy(told('no loaded rule with id "NOPE-01"'))
    end)

    it("wants --manual with --family, and an id or a family at all", function()
      run("Rules agent --family=DEP --yes")
      run("Rules agent --yes")

      assert.are.equal(0, #calls)
      assert.is_truthy(told("needs --manual"))
      assert.is_truthy(told("needs a rule id or --family"))
    end)

    it("takes the manual rules of a family and not the ones with a check", function()
      reply = answer_of({
        { rule = "DEP-01", verdict = "compliant", checked = { "lua/a.lua" } },
        { rule = "DEP-02", verdict = "compliant", checked = { "lua/a.lua" } },
      })

      run("Rules agent --family=DEP --manual --yes")

      assert.are.equal(1, #calls)
      assert.is_truthy(calls[1].prompt:find("### DEP-01", 1, true))
      assert.is_truthy(calls[1].prompt:find("### DEP-02", 1, true))
      assert.is_nil(calls[1].prompt:find("### DEP-03", 1, true))
    end)
  end)

  describe("the answers", function()
    it("keeps a checked answer as a proposal, not as a result", function()
      run("Rules agent DEP-01 --yes")

      local proposals = agent.list(vim.fn.getcwd())
      assert.are.equal(1, #proposals)
      assert.are.equal("violation", proposals[1].result.status)
      assert.is_true(proposals[1].result.proposed)
      assert.is_false(proposals[1].result.verified)
      assert.are.equal(2, proposals[1].result.findings[1].line)
    end)

    it("turns a quote that is not in the file into unclear", function()
      reply = violation_answer({ findings = { { file = "lua/a.lua", line = 2, quote = "require('invented')" } } })

      run("Rules agent DEP-01 --yes")

      assert.are.equal("unclear", agent.list(vim.fn.getcwd())[1].result.status)
    end)

    it("turns a failed request into an unclear proposal with the reason, and goes on", function()
      agent.transport = function(_, cb)
        cb(false, { kind = "provider_resolution", message = "ollama is not running" })
      end

      run("Rules agent DEP-01 --yes")

      local proposal = agent.list(vim.fn.getcwd())[1]
      assert.are.equal("unclear", proposal.result.status)
      assert.is_truthy(proposal.result.reason:find("ollama is not running", 1, true))
      assert.is_truthy(told("ollama is not running"))
    end)
  end)

  describe("the cache", function()
    it("does not ask twice for the same rule against the same files and model", function()
      run("Rules agent DEP-01 --yes")
      run("Rules agent DEP-01 --yes")

      assert.are.equal(1, #calls)
      assert.is_truthy(told("1 from the cache"))
      assert.are.equal(1, #agent.list(vim.fn.getcwd()))
    end)

    it("asks again when a file changed, the model changed or the rule changed", function()
      run("Rules agent DEP-01 --yes")
      write_raw(project .. "/lua/a.lua", "local a = 1\nlocal b = require('x')\nreturn a, b\n")
      run("Rules agent DEP-01 --yes")
      run("Rules agent DEP-01 --yes --model=other")
      write_raw(ruleset .. "/_rules/DEP/DEP-01.md", rule_file("DEP-01"):gsub("Text of DEP%-01%.", "A new text."))
      contract.clear_cache()
      require("rules.ui.candidates").reset()
      run("Rules agent DEP-01 --yes")

      assert.are.equal(4, #calls)
    end)

    it("checks a cached answer against the tree again", function()
      run("Rules agent DEP-01 --yes")
      agent.proposals = {}

      run("Rules agent DEP-01 --yes")

      assert.are.equal(1, #calls)
      assert.are.equal("violation", agent.list(vim.fn.getcwd())[1].result.status)
    end)
  end)

  describe("review findings", function()
    it("does not cache an answer that is not JSON, so the next run asks again", function()
      reply = "Looks fine to me!"

      run("Rules agent DEP-01 --yes")
      reply = violation_answer()
      run("Rules agent DEP-01 --yes")

      assert.are.equal(2, #calls)
      assert.are.equal("violation", agent.list(vim.fn.getcwd())[1].result.status)
    end)

    it("asks again with --refresh although the answer is cached, and keeps the new answer", function()
      run("Rules agent DEP-01 --yes")
      reply = answer_of({ { rule = "DEP-01", verdict = "compliant", checked = { "lua/a.lua" } } })

      run("Rules agent DEP-01 --yes --refresh")
      run("Rules agent DEP-01 --yes")

      assert.are.equal(2, #calls)
      assert.are.equal("compliant", agent.list(vim.fn.getcwd())[1].result.status)
    end)

    it("does not lose the rules of a batch whose files cannot be read: they are unclear, with the reason", function()
      pcall(vim.api.nvim_del_user_command, "Rules")
      pcall(vim.api.nvim_del_user_command, "RulesVault")
      require("rules").setup({
        rulesets = { ruleset },
        agent = { scopes = { DEP = { include = { "lua/a.lua" } } } },
      })
      -- DEP-02 looks only at a file that is binary: its batch cannot be sent
      write_raw(project .. "/data.bin", "a" .. string.char(0) .. "b")
      write_raw(
        ruleset .. "/_rules/DEP/DEP-02.md",
        rule_file("DEP-02", { 'id = "DEP-02",', 'severity = "recommended",', 'agent = { include = { "data.bin" } },' })
      )
      contract.clear_cache()
      require("rules.ui.candidates").reset()

      run("Rules agent --family=DEP --manual --yes")

      local by_id = {}
      for _, proposal in ipairs(agent.list(vim.fn.getcwd())) do
        by_id[proposal.rule.id] = proposal
      end
      assert.are.equal(1, #calls)
      assert.are.equal("unclear", by_id["DEP-02"].result.status)
      assert.is_truthy(by_id["DEP-02"].result.reason:find("none of the files", 1, true))
      assert.is_truthy(by_id["DEP-01"])
    end)

    it("does not say the destination is where it runs: the host of ai.nvim decides", function()
      run("Rules agent DEP-01 --dry-run")

      assert.is_truthy(told("local backend (the host set in ai.nvim decides where it really runs)"))
    end)
  end)

  describe("completion", function()
    it("offers the loaded rules and the flags of the command", function()
      local ids = vim.fn.getcompletion("Rules agent DEP", "cmdline")
      local flags = vim.fn.getcompletion("Rules agent --", "cmdline")

      assert.is_true(vim.tbl_contains(ids, "DEP-01"))
      assert.is_true(vim.tbl_contains(flags, "--dry-run"))
      assert.is_true(vim.tbl_contains(flags, "--manual"))
      assert.is_true(vim.tbl_contains(flags, "--family"))
      assert.is_true(vim.tbl_contains(vim.fn.getcompletion("Rules a", "cmdline"), "agent"))
      assert.is_true(vim.tbl_contains(vim.fn.getcompletion("Rules rev", "cmdline"), "review"))
    end)
  end)
end)
