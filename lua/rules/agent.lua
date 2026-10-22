---@module 'rules.agent'
---@brief `:Rules agent`: give the manual rules of a project to a model through ai.nvim and keep its answers as proposals.
---@description
--- The editor side of the agent run. The engine does the thinking (`engine/agent/plan` bundles the rules, `request`
--- writes the text, `validate` checks the answer against the tree, `verdicts` keeps what a person accepted); this
--- module is the glue: it picks the rules, decides where the request may go, says so, asks, sends one request at a
--- time and files the answers as proposals for `:Rules review`.
---
--- **Where it goes.** The transport is `ai.nvim`'s `ask`, a soft dependency: without it the command says so (no
--- second transport lives here). The backend is named with `backend=`, else the first of `agent.backends`, else
--- `ollama`. `agent.backends` is the allow-list of the project: empty means local only (`M.LOCAL`), a non-empty list
--- allows exactly those. A backend outside it is refused before anything is built. Every run prints the backend, the
--- model, the number of requests, files and an estimate of the tokens before anything leaves, and asks, unless
--- `yes` is given; with nobody to ask and no `yes` it refuses.
---
--- **What comes back.** A proposal is never a result of the check: it is kept in `M.proposals` (per project, for the
--- session), shown by `:Rules review`, and only an accept there writes a verdict. The raw answers are cached
--- (`engine/agent/cache`) by the request that earned them, so the same rule against the same files and model is not
--- asked twice.

local notify = require("rules.util.notify")
local settings = require("rules.settings")
local loader = require("rules.engine.loader")
local plan_lib = require("rules.engine.agent.plan")
local request_lib = require("rules.engine.agent.request")
local validate = require("rules.engine.agent.validate")
local cache = require("rules.engine.agent.cache")

local M = {}

--- Backends that run on this machine; the only ones allowed when `agent.backends` is empty.
M.LOCAL = { ollama = true, loomai = true }
M.DEFAULT_BACKEND = "ollama"

--- Replaces `require("ai").ask` (a spec, or a host with its own transport). `opts.ask` of a run wins over it.
---@type (fun(req: table, cb: fun(ok: boolean, res: any)))|nil
M.transport = nil
--- Replaces the folder of the answer cache (a spec). `opts.cache_dir` of a run wins over it.
---@type string|nil
M.cache_dir = nil

---@class Rules.Agent.Proposal
---@field rule Rules.ParsedRule
---@field result Rules.Agent.Result
---@field provider? string
---@field model? string
---@field batch? string

--- The proposals of this session: project root -> rule id -> proposal.
---@type table<string, table<string, Rules.Agent.Proposal>>
M.proposals = {}

---@class Rules.Agent.RunOpts
---@field root? string  the project; default the working directory
---@field id? string  one rule
---@field family? string  every manual rule of a family (needs `manual`)
---@field manual? boolean
---@field dry_run? boolean  plan and describe, send nothing
---@field yes? boolean  do not ask before sending
---@field backend? string
---@field model? string
---@field ask? fun(req: table, cb: fun(ok: boolean, res: any))  the transport; default `require("ai").ask`
---@field confirm? fun(question: string, cb: fun(accepted: boolean))  the question before sending; default the dialog
---@field cache_dir? string  default `cache.dir()`
---@field done? fun(summary: Rules.Agent.Summary)

---@class Rules.Agent.Summary
---@field ok boolean  the run went as far as it was asked to
---@field sent integer  requests sent
---@field cached integer  requests answered from the cache
---@field proposals integer  rules that now have a proposal (violation, compliant)
---@field unclear integer  rules whose answer was unclear
---@field manual string[]  ids that stay on the worklist, not sent
---@field errors string[]
---@field lines? string[]  `dry_run`: what would be sent
---@field declined? boolean

--- The proposals of a project, sorted by rule id.
---@param root string
---@return Rules.Agent.Proposal[]
function M.list(root)
  local out = {}
  for _, proposal in pairs(M.proposals[root] or {}) do
    out[#out + 1] = proposal
  end
  table.sort(out, function(a, b)
    return a.rule.id < b.rule.id
  end)
  return out
end

--- Forget one proposal (accepted, waived or discarded).
---@param root string
---@param id string
function M.drop(root, id)
  if M.proposals[root] then
    M.proposals[root][id] = nil
  end
end

---@param root string
---@param proposal Rules.Agent.Proposal
local function keep(root, proposal)
  M.proposals[root] = M.proposals[root] or {}
  M.proposals[root][proposal.rule.id] = proposal
end

--- Where a request may go: the backend and the model, or why not.
---@param agent Rules.AgentOpts  the merged `agent` settings
---@param opts { backend?: string, model?: string }
---@return { provider: string, model: string|nil, is_local: boolean }|nil destination
---@return string|nil err
function M.destination(agent, opts)
  local backends = agent.backends or {}
  local provider = opts.backend or backends[1] or M.DEFAULT_BACKEND
  if #backends > 0 then
    if not vim.tbl_contains(backends, provider) then
      return nil,
        ("backend %q is not in agent.backends (%s): add it there to allow it"):format(provider, table.concat(backends, ", "))
    end
  elseif not M.LOCAL[provider] then
    return nil,
      ("backend %q is not local, and agent.backends is empty (local only): add it to agent.backends to allow it"):format(provider)
  end
  local model = opts.model or (agent.models or {})[1]
  return { provider = provider, model = model, is_local = M.LOCAL[provider] == true }, nil
end

--- The manual rules a run is about.
---@param rules Rules.ParsedRule[]
---@param opts Rules.Agent.RunOpts
---@return Rules.ParsedRule[]|nil selected
---@return string|nil err
local function select_rules(rules, opts)
  if opts.id then
    for _, rule in ipairs(rules) do
      if rule.id == opts.id then
        if rule.check ~= nil then
          return nil, ("%s has a check: the agent answers the manual rules, a check answers this one"):format(rule.id)
        end
        return { rule }, nil
      end
    end
    return nil, ("no loaded rule with id %q"):format(opts.id)
  end
  if opts.family then
    if not opts.manual then
      return nil, ":Rules agent --family=<PREFIX> needs --manual: the agent answers the rules without a check"
    end
    local runner = require("rules.engine.runner")
    local out = {}
    for _, rule in ipairs(rules) do
      if rule.check == nil and runner.family_of(rule.id) == opts.family then
        out[#out + 1] = rule
      end
    end
    if #out == 0 then
      return nil, ("family %q has no manual rule loaded"):format(opts.family)
    end
    return out, nil
  end
  return nil, ":Rules agent needs a rule id or --family=<PREFIX> --manual"
end

---@param plan Rules.Agent.Plan
---@param requests table<string, Rules.Agent.Request>
---@param dest { provider: string, model: string|nil, is_local: boolean }
---@return string[] lines
local function describe(plan, requests, dest)
  local lines = {}
  local files, tokens, requests_n = 0, 0, 0
  for _, batch in ipairs(plan.batches) do
    local req = requests[batch.id]
    if req then
      requests_n = requests_n + 1
      files = files + #req.sent
      tokens = tokens + req.tokens
      local ids = {}
      for _, entry in ipairs(batch.rules) do
        ids[#ids + 1] = entry.rule.id
      end
      lines[#lines + 1] = ("  %s: %d rule(s) (%s), %d file(s), %d bytes, ~%d tokens"):format(
        batch.id,
        #batch.rules,
        table.concat(ids, ", "),
        #req.sent,
        req.chars,
        req.tokens
      )
      if #req.unreadable > 0 then
        lines[#lines + 1] = ("      not readable, left out: %s"):format(table.concat(req.unreadable, ", "))
      end
    end
  end
  for _, skipped in ipairs(plan.skipped) do
    lines[#lines + 1] = ("  not sent: %s stays %s (%s)"):format(skipped.rule.id, skipped.status, skipped.reason)
  end
  if #plan.denied > 0 then
    lines[#lines + 1] = ("  never sent (deny list): %s"):format(table.concat(plan.denied, ", "))
  end
  table.insert(
    lines,
    1,
    ("%d request(s), %d file(s), ~%d tokens, to %s (%s)%s"):format(
      requests_n,
      files,
      tokens,
      dest.provider,
      dest.model or "the backend's default model",
      dest.is_local and ", runs on this machine" or ", NOT local: the file content leaves this machine"
    )
  )
  return lines
end

---@param text string
---@param summary Rules.Agent.Summary
local function fail(text, summary)
  notify.error(text)
  summary.ok = false
  summary.errors[#summary.errors + 1] = text
end

---@param transport fun(req: table, cb: fun(ok: boolean, res: any))
---@param batch Rules.Agent.Batch
---@param req Rules.Agent.Request
---@param dest { provider: string, model: string|nil }
---@param cb fun(ok: boolean, text_or_err: string, from_cache: boolean)
---@param cache_dir string
local function answer_of(transport, batch, req, dest, cb, cache_dir)
  local key = cache.key(req, dest.provider, dest.model)
  local hit = cache.get(cache_dir, key)
  if hit then
    cb(true, hit.text, true)
    return
  end
  transport({
    system = req.system,
    prompt = req.prompt,
    provider = dest.provider,
    model = dest.model,
    bulk = { label = "rules.nvim agent", max_chars = req.chars + 2000, concurrency = 1 },
  }, function(ok, res)
    if not ok then
      local message = type(res) == "table" and (res.message or vim.inspect(res)) or tostring(res)
      cb(false, ("%s: %s"):format(batch.id, message), false)
      return
    end
    local text = type(res) == "table" and res.text or nil
    if type(text) ~= "string" then
      cb(false, ("%s: the backend answered without text"):format(batch.id), false)
      return
    end
    cache.put(cache_dir, key, { text = text, provider = dest.provider, model = dest.model, date = os.date("%Y-%m-%d") })
    cb(true, text, false)
  end)
end

--- Run the agent over the manual rules named in `opts`.
---@param opts Rules.Agent.RunOpts
---@return nil
function M.run(opts)
  local root = opts.root or vim.fn.getcwd()
  ---@type Rules.Agent.Summary
  local summary = { ok = true, sent = 0, cached = 0, proposals = 0, unclear = 0, manual = {}, errors = {} }
  local function finish()
    if opts.done then
      opts.done(summary)
    end
  end

  local res = settings.resolve({ project = root })
  settings.notify(res)
  local settings_err = settings.error_text(res, false)
  if settings_err then
    fail(settings_err, summary)
    return finish()
  end
  local rules, load_errors = loader.load(res.rulesets)
  for _, err in ipairs(load_errors) do
    notify.warn(err)
  end
  local selected, select_err = select_rules(rules, opts)
  if not selected then
    fail(select_err --[[@as string]], summary)
    return finish()
  end

  local dest, dest_err = M.destination(res.agent, opts)
  if not dest then
    fail(dest_err --[[@as string]], summary)
    return finish()
  end

  local plan = plan_lib.plan(selected, root, { agent = res.agent })
  local requests = {}
  local unreadable_batches = {}
  for _, batch in ipairs(plan.batches) do
    local req, build_err = request_lib.build(batch, root)
    if req then
      requests[batch.id] = req
    else
      unreadable_batches[batch.id] = build_err
    end
  end
  for _, skipped in ipairs(plan.skipped) do
    if skipped.status == "unclear" then
      keep(root, {
        rule = skipped.rule,
        result = {
          rule_id = skipped.rule.id,
          status = "unclear",
          proposed = true,
          verified = false,
          findings = {},
          checked = {},
          unchecked = {},
          dropped = {},
          reason = skipped.reason,
        },
      })
      summary.unclear = summary.unclear + 1
    else
      summary.manual[#summary.manual + 1] = skipped.rule.id
    end
  end

  local lines = describe(plan, requests, dest)
  if opts.dry_run then
    summary.lines = lines
    notify.info("dry run, nothing is sent:\n" .. table.concat(lines, "\n"))
    return finish()
  end
  if next(requests) == nil then
    for _, message in pairs(unreadable_batches) do
      notify.warn(message)
    end
    notify.info("nothing to send:\n" .. table.concat(lines, "\n"))
    return finish()
  end

  local transport = opts.ask or M.transport
  if not transport then
    local ok, ai = pcall(require, "ai")
    if not ok or type(ai.ask) ~= "function" then
      fail(
        "no transport for :Rules agent: ai.nvim is not installed (or has no ask); nothing was sent."
          .. " Install ai.nvim, the other :Rules commands do not need it",
        summary
      )
      return finish()
    end
    transport = ai.ask
  end

  local question = "Send to the model?\n\n" .. table.concat(lines, "\n")
  local function go()
    local cache_dir = opts.cache_dir or M.cache_dir or cache.dir()
    local index = 0
    local function step()
      index = index + 1
      local batch = plan.batches[index]
      if not batch then
        notify.info(
          ("agent: %d request(s) sent, %d from the cache, %d proposal(s), %d unclear. :Rules review to look at them"):format(
            summary.sent,
            summary.cached,
            summary.proposals,
            summary.unclear
          )
        )
        return finish()
      end
      local req = requests[batch.id]
      if not req then
        step()
        return
      end
      answer_of(transport, batch, req, dest, function(ok, text, from_cache)
        if not ok then
          summary.ok = false
          summary.errors[#summary.errors + 1] = text
          notify.error(text)
          for _, entry in ipairs(batch.rules) do
            summary.unclear = summary.unclear + 1
            keep(root, {
              rule = entry.rule,
              batch = batch.id,
              result = {
                rule_id = entry.rule.id,
                status = "unclear",
                proposed = true,
                verified = false,
                findings = {},
                checked = {},
                unchecked = {},
                dropped = {},
                reason = "the request failed: " .. text,
              },
            })
          end
          step()
          return
        end
        if from_cache then
          summary.cached = summary.cached + 1
        else
          summary.sent = summary.sent + 1
        end
        for _, entry in ipairs(batch.rules) do
          local result = validate.validate(entry.rule, text, root, { sent = req.sent })
          keep(root, { rule = entry.rule, result = result, provider = dest.provider, model = dest.model, batch = batch.id })
          if result.status == "unclear" then
            summary.unclear = summary.unclear + 1
          else
            summary.proposals = summary.proposals + 1
          end
        end
        step()
      end, cache_dir)
    end
    step()
  end

  notify.info("agent: " .. lines[1])
  if opts.yes then
    go()
    return
  end
  local confirm = opts.confirm
  if not confirm then
    if #vim.api.nvim_list_uis() == 0 then
      fail(
        "the agent asks before it sends, and there is nobody to ask: run it with --yes (the destination is shown first)",
        summary
      )
      return finish()
    end
    confirm = function(q, cb)
      require("rules.ui.confirm").yesno(q, "send", cb)
    end
  end
  confirm(question, function(accepted)
    if not accepted then
      summary.declined = true
      notify.info("agent: nothing was sent")
      return finish()
    end
    go()
  end)
end

return M
