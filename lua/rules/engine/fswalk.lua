---@module 'rules.engine.fswalk'
---@brief Recursive file listing used by the `grep` check.
---@description
--- Thin wrapper around `lib.nvim.fs.collect_recursive` (REL-31: reusable
--- filesystem-walk logic belongs in `lib.nvim`, not reimplemented here) --
--- it already handles a case this module's own previous hand-rolled
--- `uv.fs_scandir` walk did not: a symlinked directory is listed but never
--- recursed into (an ancestor-pointing symlink would otherwise recurse
--- forever), and a symlink is classified via `fs_stat`/`fs_lstat` rather
--- than trusting `fs_scandir_next`'s not-always-reliable type hint -- the
--- previous walk here only branched on `"directory"`/`"file"`, so a
--- symlink reported as neither (common on filesystems without dirent
--- `d_type` support) was silently invisible to every `grep` check, no
--- error, no warning.

local collect_recursive = require("lib.nvim.fs.collect_recursive")

local M = {}

---@type string[]
local SKIP_DIRS = { ".git", ".deps" }

--- Every file under `root`, skipping VCS/dependency directories.
---@param root string
---@return string[] files  absolute paths, "/"-separated
function M.files(root)
  return collect_recursive.files(root, {
    ignore = function(abs_path, is_dir)
      if not is_dir then
        return false
      end
      local name = vim.fs.basename(abs_path)
      return vim.tbl_contains(SKIP_DIRS, name)
    end,
  })
end

return M
