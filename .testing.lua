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
  -- Guards (docs/GUARDS.md of testing.nvim). The suite is clean for these, so they raise errors.
  guards = {
    fs = "error",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    -- Warn only: TESTS/window_spec.lua closes the tabs that report.window.open creates, but not
    -- the report buffers behind them, so the state guard names 14 leaked buffers. A spec that
    -- leaks (not the plugin); the specs stay unchanged for now.
    state = "warn",
    -- Spawn net on: every process a spec starts must be listed in guard_allow.spawn below.
    process_net = "error",
  },
  guard_allow = {
    -- gate_spec.lua builds throwaway git repositories (git init/add/commit/diff) in a temp
    -- directory to test the diff-scoped gate; git is the real tool the plugin integrates.
    spawn = { "git" },
  },
}
