---@module 'rules.ui.waiver_cmd'
---@brief The handlers of `:Rules waive`, `renew` and `unwaive` -- words in, one request to the door out.
---@description
--- The same thin layer as `rules.ui.cmd`: the command line is read (`rules.cmdline`, the words as typed), one operation of
--- `rules-ops/1` is built (`waive`, `renew`, `remove`) and handed to the door through `rules.write`, which looks after
--- the open buffers (the waivers file may be one) and tells the answer. Nothing of a waiver is checked here: a date
--- that is none, a path with `..`, a reason that says nothing, an id no rule has, a waiver that is there already or is
--- missing are what the door answers, word for word. A date in the past is not refused; the door answers with a warning
--- (the waiver is expired from the start) and the warning is shown.
---
---  - `waive`: `reason=` (required by the door), `expires=`, `paths=` (comma separated: `rules.cmdline.paths`)
---  - `renew`: `expires=` or `--no-expiry`, `reason=`; the door wants one of the two ways to say the last day
---  - `unwaive`: `dry_run` first, then the question (`--yes` skips it), then the write
---
--- The project is `--project=<dir>`, else that of the current buffer when it is one below the working directory, else the
--- working directory (`rules.ui.project`). `--dry`: everything is checked and told, nothing is written.
---
--- Not its job: the grammar (`rules.ui.routes`), the rules of a waiver (`rules.waiver_ops`, `rules.engine.waivers`).

local cmdline = require("rules.cmdline")
local notify = require("rules.util.notify")
local cmd = require("rules.ui.cmd")
local project = require("rules.ui.project")

local M = {}

---The words of the command line bound to their `key=` values. Says why and gives nothing when the line cannot be read.
---@param ctx table  composer context
---@param name string  the route
---@param keys string[]  the keys the verb takes; none: the verb takes nothing but the id
---@return table<string, string>|nil values
local function read(ctx, name, keys)
  local words, werr = cmd.words(ctx, require("rules.ui.routes").FLAGS[name])
  if not words then
    notify.error(tostring(werr))
    return nil
  end
  local bound, serr = cmdline.bind(words, keys, #keys > 0)
  if not bound then
    notify.error(tostring(serr))
    return nil
  end
  if #bound.lead > 0 then
    notify.error(("unexpected argument: %s"):format(cmdline.join(bound.lead)))
    return nil
  end
  return bound.values
end

---`:Rules waive <ID> reason=<text> [expires=YYYY-MM-DD] [paths=a,b] [--project=<dir>] [--dry]`
---@param ctx table
function M.waive(ctx)
  local values = read(ctx, "waive", cmdline.WAIVE_KEYS)
  if not values then
    return
  end
  ---@type table
  local op = {
    op = "waive",
    id = ctx.args.id,
    reason = values.reason,
    expires = values.expires,
    project = project.request(ctx.flags.project),
  }
  if values.paths ~= nil then
    op.paths = cmdline.paths(values.paths)
  end
  cmd.run({ op }, ctx.flags.dry)
end

---`:Rules renew <ID> [expires=YYYY-MM-DD | --no-expiry] [reason=<text>] [--project=<dir>] [--dry]`
---@param ctx table
function M.renew(ctx)
  local values = read(ctx, "renew", cmdline.RENEW_KEYS)
  if not values then
    return
  end
  ---@type table
  local op = {
    op = "renew",
    id = ctx.args.id,
    expires = values.expires,
    reason = values.reason,
    project = project.request(ctx.flags.project),
  }
  if ctx.flags["no-expiry"] then
    op.no_expiry = true
  end
  cmd.run({ op }, ctx.flags.dry)
end

---What the question shows of the waiver that goes: its values, from the answer of the dry run.
---@param entry table
---@return string
local function was(entry)
  local before = entry.before
  if type(before) ~= "table" then
    return ""
  end
  local lines = { "" }
  local function row(name, value)
    lines[#lines + 1] = ("  %-8s %s"):format(name, value)
  end
  row("reason", tostring(before.reason))
  row("expires", before.expires or "never")
  if type(before.paths) == "table" then
    row("paths", table.concat(before.paths, ", "))
  end
  return table.concat(lines, "\n")
end

---`:Rules unwaive <ID> [--project=<dir>] [--yes] [--dry]`
---@param ctx table
function M.unwaive(ctx)
  if not read(ctx, "unwaive", {}) then
    return
  end
  local id = ctx.args.id
  ---@type table
  local op = { op = "remove", id = id, project = project.request(ctx.flags.project) }
  cmd.ask_then_run(ctx, op, {
    question = function(entry)
      return ("Remove the waiver of %s from %s?\n%s\n\nThe findings it accepted flag again on the next check."):format(
        id,
        require("rules.write").waivers_file(op),
        was(entry)
      )
    end,
    yes_label = "remove",
    declined = ("the waiver of %s was not removed"):format(id),
    nobody = ("unwaive asks before it removes the waiver of %s, and there is nobody to ask: run it with --yes"):format(id),
  })
end

return M
