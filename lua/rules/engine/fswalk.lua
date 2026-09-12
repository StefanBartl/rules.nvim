---@module 'rules.engine.fswalk'
---@brief Recursive file listing used by the `grep` check.
---@description
--- `vim.uv` with a `vim.loop` fallback for Neovim < 0.10 -- the very fallback
--- `DEP-01` asks every plugin in this collection to keep, dogfooded here.

local M = {}

---@type string[]
local SKIP_DIRS = { ".git", ".deps" }

--- Every file under `root`, skipping VCS/dependency directories.
---@param root string
---@return string[] files  absolute paths, "/"-separated
function M.files(root)
  local uv = vim.uv or vim.loop
  local out = {}

  local function walk(dir)
    local fs = uv.fs_scandir(dir)
    if not fs then
      return
    end
    while true do
      local name, typ = uv.fs_scandir_next(fs)
      if not name then
        break
      end
      local full = dir .. "/" .. name
      if typ == "directory" then
        if not vim.tbl_contains(SKIP_DIRS, name) then
          walk(full)
        end
      elseif typ == "file" then
        out[#out + 1] = full
      end
    end
  end

  walk(root)
  return out
end

return M
