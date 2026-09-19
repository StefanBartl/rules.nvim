---@module 'rules.engine.checks.errline'
---@brief Collapse a `lib.lua.error.safe_call` failure message into the
--- single line a `Rules.Finding.text` field needs.
---@description
--- `safe_call`'s failure `.message` is a full `debug.traceback()` string --
--- the error text followed by `"\nstack traceback:\n\t..."`. Every check
--- impl that embeds `.message` straight into a `Finding.text` was handing
--- `report/buffer.lua` a multi-line string; that module folds each finding
--- into exactly one report line and passes the whole batch to
--- `nvim_buf_set_lines`, which throws `'replacement string' item contains
--- newlines` on ANY line containing an embedded `\n` -- so the report
--- render itself crashed instead of showing the friendly per-rule error the
--- catch was meant to produce (see `waivers.lua`'s own newline rejection
--- for the same constraint on the read side). `debug.traceback()` always
--- puts the actual error message on its first line; the remaining lines are
--- the call stack, useful in `:messages` but not inside one report line.

local M = {}

---@param message string  a `safe_call` failure's `.message` (may be multi-line)
---@return string  just the first line, safe to embed in a Finding.text
function M.first_line(message)
  return message:match("^[^\n]*") or message
end

return M
