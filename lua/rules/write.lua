---@module 'rules.write'
---@brief The editor's one way to write: a request to `rules-ops/1`, the open buffers looked after, the answer told.
---@description
--- A thin layer, no write logic of its own: `run` hands the operations to the door (`rules.ops`, the same one an app
--- or an agent uses), and around a real write it remembers the open buffers of the ruleset and looks at them after
--- (`rules.buffers`): an unmodified buffer of a file that changed is reloaded, one with unsaved changes is reported
--- as a conflict. `messages` turns the answer (one entry per operation) into lines for the user.
---
--- `opts.dry` is the door's `dry_run`: everything is checked, nothing is written, no buffer is touched.
---
--- Not its job: what an operation does (`rules.ops`), the commands and the form (`rules.ui.cmd`).

local ops = require("rules.ops")
local contract = require("rules.contract")
local buffers = require("rules.buffers")
local notify = require("rules.util.notify")

local M = {}

---@class Rules.WriteOpts
---@field dry? boolean  `dry_run`: write nothing
---@field contract? Rules.Contract.Opts  `{ rulesets?, gates?, today? }`; default: `setup()`

---@class Rules.WriteResult
---@field ok boolean                    the request was answered and every entry is ok
---@field doc table|nil                 the `rules.result` document
---@field err table|nil                 the error of the contract when there is no document
---@field entries table[]               one per operation, in order
---@field buffers Rules.BufferReport|nil  what happened to the open buffers (a real write only)

---Run operations through the door.
---@param op_list table[]  operations of `rules-ops/1` (`{ op = "set", id = ..., patch = ... }`)
---@param opts? Rules.WriteOpts
---@return Rules.WriteResult
function M.run(op_list, opts)
  opts = opts or {}
  local snaps
  if not opts.dry then
    snaps = buffers.snapshot((contract.rulesets(opts.contract)))
  end
  local doc, err = ops.run({ ops = op_list, dry_run = opts.dry == true }, opts.contract)
  if not doc then
    return { ok = false, err = err, entries = {} }
  end
  ---@type Rules.WriteResult
  local result = { ok = doc.ok == true, doc = doc, entries = doc.results or {} }
  if snaps then
    result.buffers = buffers.refresh(snaps)
  end
  return result
end

---A unified diff of two texts, a few lines of context; `nil` where the editor cannot make one.
---@param before string
---@param after string
---@return string|nil
local function unified(before, after)
  local differ = (vim.text and vim.text.diff) or vim.diff
  local ok, out = pcall(differ, before, after, { result_type = "unified", ctxlen = 1 })
  if ok and type(out) == "string" and out ~= "" then
    return (out:gsub("\n+$", ""))
  end
  return nil
end

---The most lines of a diff that are shown in a message.
M.MAX_DIFF_LINES = 20

---@param entry table
---@param op table
---@return "info"|"warn"|"error" level
---@return string text
local function describe(entry, op)
  if not entry.ok then
    local err = entry.error or {}
    return "error", ("%s: %s"):format(err.code or "error", err.message or "the operation failed")
  end
  local id = entry.id or op.id or "?"
  local outcome = entry.outcome
  local layout = entry.placed and entry.placed.layout
  local placed = layout and (" in %s"):format(layout) or ""
  local text
  if outcome == "created" then
    text = ("created %s%s"):format(id, placed)
  elseif outcome == "would_create" then
    text = ("would create %s%s"):format(id, placed)
  elseif outcome == "changed" then
    text = ("changed %s"):format(id)
  elseif outcome == "would_change" then
    text = ("would change %s"):format(id)
    local diff = entry.diff and entry.diff.before and entry.diff.after and unified(entry.diff.before, entry.diff.after)
    if diff then
      local lines = vim.split(diff, "\n", { plain = true })
      if #lines > M.MAX_DIFF_LINES then
        local more = #lines - M.MAX_DIFF_LINES
        lines = vim.list_slice(lines, 1, M.MAX_DIFF_LINES)
        lines[#lines + 1] = ("... %d more line(s)"):format(more)
      end
      text = text .. "\n" .. table.concat(lines, "\n")
    end
  elseif outcome == "unchanged" then
    text = ("%s is unchanged"):format(id)
  elseif outcome == "retired" then
    text = ("retired %s"):format(id)
  elseif outcome == "would_retire" then
    text = ("would retire %s"):format(id)
  elseif outcome == "moved" then
    text = ("moved %s%s"):format(id, layout and (" to %s"):format(layout) or "")
  elseif outcome == "would_move" then
    text = ("would move %s"):format(id)
  else
    text = ("%s: %s"):format(id, tostring(outcome or "ok"))
  end
  return "info", text
end

---@param names string[]
---@return string
local function shown(names)
  local out = {}
  for i, name in ipairs(names) do
    out[i] = vim.fn.fnamemodify(name, ":~")
  end
  return table.concat(out, ", ")
end

---The lines to tell the user about a result: one per operation, then what happened to the buffers and to the
---generated documents.
---@param result Rules.WriteResult
---@param op_list table[]  the operations that were run (an entry is told with its operation)
---@return { level: "info"|"warn"|"error", text: string }[]
function M.messages(result, op_list)
  local out = {}
  if result.err then
    out[1] = { level = "error", text = ("%s: %s"):format(result.err.code or "error", result.err.message or "failed") }
    return out
  end
  for i, entry in ipairs(result.entries) do
    local level, text = describe(entry, op_list[i] or {})
    out[#out + 1] = { level = level, text = text }
    local catalog = entry.catalog
    if catalog and (catalog.errors or 0) > 0 then
      out[#out + 1] = {
        level = "warn",
        text = ("%d generated document(s) could not be made: run :Rules catalog"):format(catalog.errors),
      }
    end
  end
  local report = result.buffers
  if report then
    if #report.reloaded > 0 then
      out[#out + 1] = { level = "info", text = "reloaded " .. shown(report.reloaded) }
    end
    if #report.conflicts > 0 then
      out[#out + 1] = {
        level = "warn",
        text = (
          "%s has unsaved changes and the file changed on disk: the buffer was left as it is"
          .. " (:edit! takes the file's version, :write! the buffer's)"
        ):format(shown(report.conflicts)),
      }
    end
    if #report.gone > 0 then
      out[#out + 1] = {
        level = "warn",
        text = ("%s is no longer there (retired): the buffer was left open"):format(shown(report.gone)),
      }
    end
    if #report.stale > 0 then
      out[#out + 1] = {
        level = "warn",
        text = (
          "%s changed on disk and could not be reloaded: the buffer shows the old text and is set modified and"
          .. " readonly, so :w cannot put it over the new file (:edit! reads the file again)"
        ):format(shown(report.stale)),
      }
    end
  end
  return out
end

---Tell the user about a result.
---@param result Rules.WriteResult
---@param op_list table[]
function M.say(result, op_list)
  for _, message in ipairs(M.messages(result, op_list)) do
    notify[message.level](message.text)
  end
end

return M
