---@module 'rules.report.review'
---@brief `:Rules review`: the proposals of an agent run, one at a time, to accept, waive or discard.
---@description
--- A scratch buffer with one block per proposal. What a proposal is stays in words, not in colour: the first word of a
--- block is `violation`, `compliant` or `unclear`, and `PROPOSED` marks all of them as what they are -- not a pass,
--- not a fail, not a waiver. Beside it nothing of the check results is shown or changed.
---
--- Keys act on the proposal under the cursor, and on that one only; there is no key for all of them, on purpose:
---
---   a  accept   writes the verdict (`rules.engine.verdicts`, the only door to `.rules-verdicts.json`)
---   w  waive    a violation the person lives with: asks for the reason, then `:Rules waive` does the rest
---   x  discard  forget the proposal, write nothing
---   <CR> open the first finding
---   q  close
---
--- `unclear` is not acceptable: it is the absence of an answer, and the keys say so. The person who accepts is
--- `vim.g.rules_by`, else the user name of the machine, else asked.

local agent = require("rules.agent")
local notify = require("rules.util.notify")

local M = {}

local BUF_NAME = "rules://review"

--- Text of the model (or of a file) as one line: `nvim_buf_set_lines` refuses a newline, and a control character
--- in a view is not what anyone meant to show.
---@param text any
---@return string
local function one_line(text)
  return (tostring(text):gsub("%c+", " "))
end

--- The lines of the view and which proposal each belongs to.
---@param proposals Rules.Agent.Proposal[]
---@return string[] lines
---@return table<integer, Rules.Agent.Proposal> owner  line number -> proposal
function M.render(proposals)
  local lines = {
    "rules.nvim review -- what an agent PROPOSED, not what was checked",
    "a accept   w waive (violation)   x discard   <CR> open the finding   q close      (one at a time; there is no accept-all)",
    "",
  }
  local owner = {}
  if #proposals == 0 then
    lines[#lines + 1] = "no proposals: run :Rules agent <ID> first"
    return lines, owner
  end
  for _, proposal in ipairs(proposals) do
    local result = proposal.result
    local head = ("PROPOSED %-9s %s"):format(result.status, proposal.rule.id)
    if proposal.rule.title and proposal.rule.title ~= "" then
      head = head .. " -- " .. one_line(proposal.rule.title)
    end
    local first = #lines + 1
    lines[#lines + 1] = head
    for _, finding in ipairs(result.findings) do
      lines[#lines + 1] = ("    %s:%d  %s"):format(one_line(finding.file), finding.line, one_line(finding.quote))
      if finding.why and finding.why ~= "" then
        lines[#lines + 1] = "        " .. one_line(finding.why)
      end
    end
    if result.status == "compliant" then
      lines[#lines + 1] = ("    looked at: %s"):format(one_line(table.concat(result.checked, ", ")))
      if #result.unchecked > 0 then
        lines[#lines + 1] = ("    NOT looked at (%d sent): %s"):format(
          #result.unchecked,
          one_line(table.concat(result.unchecked, ", "))
        )
      end
    end
    if result.status == "unclear" and result.reason then
      lines[#lines + 1] = "    " .. one_line(result.reason)
    end
    if #result.dropped > 0 then
      lines[#lines + 1] = ("    %d claim(s) of the model did not hold up against the files"):format(#result.dropped)
    end
    lines[#lines + 1] = ""
    for n = first, #lines do
      owner[n] = proposal
    end
  end
  return lines, owner
end

--- Who accepts: the person, never the proposal.
---@return string|nil
function M.by()
  local named = vim.g.rules_by
  if type(named) == "string" and vim.trim(named) ~= "" then
    return named
  end
  local user = vim.env.USERNAME or vim.env.USER
  if user and user ~= "" then
    return user
  end
  return nil
end

---@param root string
---@param proposal Rules.Agent.Proposal
---@param opts? { by?: string, model?: string }
---@return boolean ok
function M.accept(root, proposal, opts)
  opts = opts or {}
  local by = opts.by or M.by()
  if not by then
    notify.error("who accepts? set vim.g.rules_by to your name (the verdict records it)")
    return false
  end
  local ok, err = require("rules.engine.verdicts").accept(root, proposal.result, { by = by, model = proposal.model })
  if not ok then
    notify.error(("%s was not accepted: %s"):format(proposal.rule.id, err))
    return false
  end
  agent.drop(root, proposal.rule.id)
  notify.info(("%s accepted as %s by %s: %s"):format(proposal.rule.id, proposal.result.status, by, ".rules-verdicts.json"))
  return true
end

--- Waive the violation: asks for the reason, then the door of `:Rules waive` writes it.
---@param root string
---@param proposal Rules.Agent.Proposal
---@param reason? string  given by a caller that already asked (a spec); default: asks
---@param after? fun()
function M.waive(root, proposal, reason, after)
  if proposal.result.status ~= "violation" then
    notify.warn(("%s is %s: only a violation can be waived"):format(proposal.rule.id, proposal.result.status))
    return
  end
  local function write(text)
    if not text or vim.trim(text) == "" then
      notify.info("not waived: a waiver needs a reason")
      return
    end
    local result = require("rules.ui.cmd").run({ { op = "waive", id = proposal.rule.id, reason = text } }, false)
    if result.ok then
      agent.drop(root, proposal.rule.id)
      -- a waiver is applied to a failing check; this rule has none, so its result stays `manual`
      notify.warn(
        (
          "%s has no check: the waiver is recorded, but :Rules check still lists it as manual."
          .. " Accept (a) records the violation"
        ):format(proposal.rule.id)
      )
    end
    if after then
      after()
    end
  end
  if reason then
    write(reason)
    return
  end
  vim.ui.input({ prompt = ("Waive %s -- reason: "):format(proposal.rule.id) }, write)
end

---@param root string
---@param proposal Rules.Agent.Proposal
function M.discard(root, proposal)
  agent.drop(root, proposal.rule.id)
  notify.info(("%s discarded: nothing was written"):format(proposal.rule.id))
end

--- Open the review of the proposals of `root`.
---@param root? string
---@return integer buf
function M.open(root)
  root = root or vim.fn.getcwd()
  local buf = vim.fn.bufnr(BUF_NAME)
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, BUF_NAME)
  end
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "rules-review"

  ---@type table<integer, Rules.Agent.Proposal>
  local owner = {}

  local function refresh()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local lines
    lines, owner = M.render(agent.list(root))
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end

  local function current()
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local proposal = owner[line]
    if not proposal then
      notify.info("put the cursor on a proposal")
    end
    return proposal
  end

  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true, desc = "rules review: " .. desc })
  end
  map("a", function()
    local proposal = current()
    if proposal and M.accept(root, proposal) then
      refresh()
    end
  end, "accept the proposal under the cursor")
  map("w", function()
    local proposal = current()
    if proposal then
      M.waive(root, proposal, nil, refresh)
    end
  end, "waive the violation under the cursor")
  map("x", function()
    local proposal = current()
    if proposal then
      M.discard(root, proposal)
      refresh()
    end
  end, "discard the proposal under the cursor")
  map("<CR>", function()
    local proposal = current()
    local finding = proposal and proposal.result.findings[1]
    if finding then
      vim.cmd.edit(vim.fn.fnameescape(root .. "/" .. finding.file))
      pcall(vim.api.nvim_win_set_cursor, 0, { finding.line, 0 })
    end
  end, "open the first finding")
  map("q", function()
    vim.cmd.close()
  end, "close")

  refresh()
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

return M
