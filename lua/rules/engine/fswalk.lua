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
--- `.claude` is a git worktree's own workdir for a running Claude Code
--- session (`.claude/worktrees/<name>`) -- a second, full checkout of this
--- same repo. Without it here, a `grep` check walked every open worktree in
--- addition to the real tree, multiplying every finding once per session:
--- measured 2026-09-18, 81 of 134 grep-rule hits across the fleet were this
--- duplication, one repo alone reporting 68 SEC-01 findings where 17 were
--- real. A `:cnext` into one of the duplicates also lands in another
--- session's working tree, not this one's.
local SKIP_DIRS = { ".git", ".deps", ".claude" }

--- Every file under `root`, skipping VCS/dependency directories.
---
--- `collect_recursive` only ever appends "/"-joined suffixes onto whatever
--- `root` it was given verbatim (its own contract promises "absolute
--- paths", not a particular separator) -- on Windows a backslash-form
--- `root` (e.g. from `vim.fn.tempname()`/`vim.fn.getcwd()`) would otherwise
--- come back mixed-separator, breaking this module's own "/"-separated
--- promise below. Normalizing `root` here, once, before the walk keeps
--- that promise regardless of what separator style the caller's `root` used.
---@param root string
---@return string[] files  absolute paths, "/"-separated
function M.files(root)
  local normalized_root = root:gsub("\\", "/")
  return collect_recursive.files(normalized_root, {
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
