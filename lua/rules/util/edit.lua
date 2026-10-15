---@module 'rules.util.edit'
---@brief Open a file or folder by its path, as one word, with nothing in it taken for a command-line special.
---@description
--- `:edit <path>` expands `%` (the current file) and `#` (the alternate file) in the path, so a vault folder called `a#b`
--- opened a different path, or none, depending on which buffers were around. The table form of `vim.cmd` with
--- `magic = { file = false }` hands the path over as it is: no `%`, no `#`, no wildcard, no backslash to undo.

local M = {}

---The arguments of a command that takes a path, as a table for `vim.cmd`: the path is one word, nothing in it is expanded.
---@param cmd string   the command: `edit`, a user command
---@param args string[]  its words; each reaches the command as one word
---@return table spec  for `vim.cmd(spec)`
function M.spec(cmd, args)
  return { cmd = cmd, args = args, magic = { file = false } }
end

---Open `path` in the current window (`:edit`).
---@param path string
---@return boolean ok
---@return string|nil err
function M.path(path)
  local ok, err = pcall(vim.cmd, M.spec("edit", { path }))
  if ok then
    return true, nil
  end
  return false, tostring(err)
end

return M
