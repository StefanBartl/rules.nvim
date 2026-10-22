---@module 'rules.engine.agent.read'
---@brief Read one file for a request or for the check of an answer: a regular file, not a link, at most so big.
---@description
--- The agent modules read repository files that somebody else controls. In the editor that is `lib.nvim.fs.read_bounded`
--- (the type and size judged on the stat and again on the open descriptor, a FIFO cannot block it, a link is
--- refused). The desktop host runs the engine under the shim of `documentation.nvim`'s standalone build, whose `uv` has
--- no `fs_open`, `fs_fstat` or `fs_read`: there the file is checked with `lstat` (not a link, a regular file), opened
--- with `io.open` and measured before it is read. The two paths answer the same; the second has no protection against a
--- file swapped between the check and the open, which the first has.
---
--- A link is never read, and a file over the limit is not read at all.

local read_bounded = require("lib.nvim.fs.read_bounded")

local uv = vim.uv or vim.loop

local M = {}

--- Whether the editor's `uv` can do what `read_bounded` needs.
---@return boolean
local function has_libuv_files()
  return type(uv.fs_open) == "function"
    and type(uv.fs_fstat) == "function"
    and type(uv.fs_read) == "function"
    and type(uv.constants) == "table"
end

--- The content of the file, or nil and why.
---@param path string
---@param max_bytes integer
---@param portable? boolean  force the path without libuv (a spec; the host has it by itself)
---@return string|nil content
---@return string|nil err
function M.file(path, max_bytes, portable)
  if not portable and has_libuv_files() then
    return read_bounded(path, max_bytes, { follow_symlinks = false })
  end
  local stat = uv.fs_lstat(path)
  if not stat then
    return nil, "not found: " .. path
  end
  if stat.type ~= "file" then
    return nil, "not a regular file: " .. path
  end
  local fh = io.open(path, "rb")
  if not fh then
    return nil, "open failed: " .. path
  end
  local size = fh:seek("end")
  if not size or size > max_bytes then
    fh:close()
    return nil, ("too large (%s > %d bytes): %s"):format(tostring(size), max_bytes, path)
  end
  fh:seek("set", 0)
  local content = fh:read("*a")
  fh:close()
  if content == nil then
    return nil, "read failed: " .. path
  end
  return content, nil
end

return M
