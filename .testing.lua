-- .testing.lua -- configuration of testing.nvim for this project.
-- Every key is optional; the keys are documented in testing.nvim's docs/CONFIG.md. Loading this
-- file executes it (same trust as running the specs).
return {
  -- Lua module root of the project.
  plugin = "rules",
  -- Dependencies (directory names) put on the runtimepath: $<NAME>_DIR, .deps/<name>, ../<name>,
  -- stdpath('data')/lazy/<name>.
  deps = { "lib.nvim" },
  -- One nvim per spec file, started from a -c command (v:vim_did_enter is 0): nothing leaks
  -- between spec files.
  isolated = "file",
  host = "c",
}
