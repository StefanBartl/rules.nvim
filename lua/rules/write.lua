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

---The operations that write the waivers file of a PROJECT, which lies outside every ruleset.
local WAIVER_OPS = { waive = true, renew = true, remove = true }

---What a write may change on disk, for the buffers to be looked after: the rulesets, and the waivers file of the project
---of each waiver operation (resolved by the door's own function, so the file is the one it writes; a project it
---refuses has no file, and the door says why).
---@param op_list table[]
---@param copts Rules.Contract.Opts
---@return string[]
local function written_roots(op_list, copts)
  local rulesets = contract.rulesets(copts)
  local roots = vim.list_slice(rulesets, 1, #rulesets)
  for _, op in ipairs(op_list) do
    if WAIVER_OPS[op.op] then
      local dir = require("rules.waiver_ops").resolve_project(op.project, copts, rulesets)
      if dir then
        roots[#roots + 1] = require("rules.engine.waivers").path(dir)
      end
    end
  end
  return roots
end

---Run operations through the door.
---@param op_list table[]  operations of `rules-ops/1` (`{ op = "set", id = ..., patch = ... }`)
---@param opts? Rules.WriteOpts
---@return Rules.WriteResult
function M.run(op_list, opts)
  opts = opts or {}
  local snaps
  if not opts.dry then
    snaps = buffers.snapshot(written_roots(op_list, opts.contract or contract.editor_opts()))
  end
  local doc, err = ops.run({ ops = op_list, dry_run = opts.dry == true }, opts.contract or contract.editor_opts())
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

---The diff of a dry run, cut to `MAX_DIFF_LINES`, put behind a line of text.
---@param text string
---@param entry table
---@return string
local function with_diff(text, entry)
  local diff = entry.diff and entry.diff.before and entry.diff.after and unified(entry.diff.before, entry.diff.after)
  if not diff then
    return text
  end
  local lines = vim.split(diff, "\n", { plain = true })
  if #lines > M.MAX_DIFF_LINES then
    local more = #lines - M.MAX_DIFF_LINES
    lines = vim.list_slice(lines, 1, M.MAX_DIFF_LINES)
    lines[#lines + 1] = ("... %d more line(s)"):format(more)
  end
  return text .. "\n" .. table.concat(lines, "\n")
end

---Where a waiver operation wrote: the waivers file of its project, as the request named the project (the working
---directory's when it named none).
---@param op table
---@return string
local function waivers_file(op)
  local file = require("rules.engine.waivers").FILE
  local project = type(op.project) == "string" and op.project:gsub("[/\\]+$", "") or ""
  if project == "" or project == "." then
    return file
  end
  return project .. "/" .. file
end

M.waivers_file = waivers_file

---The last day of a waiver operation, as told.
---@param op table
---@return string
local function through(op)
  if op.no_expiry then
    return " (no expiry)"
  end
  return type(op.expires) == "string" and (" through " .. op.expires) or ""
end

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
    text = with_diff(("would change %s"):format(id), entry)
  elseif outcome == "waived" then
    text = ("waived %s%s in %s"):format(id, through(op), waivers_file(op))
  elseif outcome == "would_waive" then
    text = with_diff(("would waive %s%s in %s"):format(id, through(op), waivers_file(op)), entry)
  elseif outcome == "renewed" then
    text = ("renewed the waiver of %s%s in %s"):format(id, through(op), waivers_file(op))
  elseif outcome == "would_renew" then
    text = with_diff(("would renew the waiver of %s%s in %s"):format(id, through(op), waivers_file(op)), entry)
  elseif outcome == "removed" then
    text = ("removed the waiver of %s from %s"):format(id, waivers_file(op))
  elseif outcome == "would_remove" then
    text = with_diff(("would remove the waiver of %s from %s"):format(id, waivers_file(op)), entry)
  elseif outcome == "unchanged" then
    text = ("%s is unchanged"):format(id)
  elseif outcome == "retired" then
    text = ("retired %s"):format(id)
  elseif outcome == "would_retire" then
    text = ("would retire %s"):format(id)
  elseif outcome == "reinstated" then
    text = ("reinstated %s%s"):format(id, placed)
  elseif outcome == "would_reinstate" then
    text = ("would reinstate %s%s"):format(id, placed)
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
    -- told after the line that says what was made, at a level a person notices: the rule IS made
    for _, warning in ipairs(entry.warnings or {}) do
      out[#out + 1] = { level = "warn", text = warning }
    end
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
      -- the file that is gone is the rule's (retire) or the retired copy of it (reinstate)
      local why = "retired"
      for _, op in ipairs(op_list) do
        if op.op == "reinstate" then
          why = "reinstated"
        end
      end
      out[#out + 1] = {
        level = "warn",
        text = ("%s is no longer there (%s): the buffer was left open"):format(shown(report.gone), why),
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
