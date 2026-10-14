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
  -- TESTS/vault_ci_spec.lua: the opt-in run against the real rulesets names its two folders in these variables.
  env_allow = { "RULES_REAL_LUA", "RULES_REAL_NATIVE" },
  -- Guards (docs/GUARDS.md of testing.nvim). The suite is clean for these, so they raise errors.
  guards = {
    fs = "error",
    scheduled_error = "error",
    prompt = "error",
    deprecation = "error",
    -- Warn only: TESTS/window_spec.lua closes the tabs that report.window.open creates, but not
    -- the report buffers behind them, so the state guard names 14 leaked buffers. A spec that
    -- leaks (not the plugin); the specs stay unchanged for now.
    -- (TESTS/usrcmds_write_spec.lua runs the real button dialog of lib.nvim, whose theme defines the Kit* highlight
    -- groups: the library's, not a leak of the plugin.)
    state = { mode = "warn", ignore_highlights = { "Kit" } },
    -- Spawn net on: every process a spec starts must be listed in guard_allow.spawn below.
    process_net = "error",
  },
  guard_allow = {
    -- gate_spec.lua builds throwaway git repositories (git init/add/commit/diff) in a temp
    -- directory to test the diff-scoped gate; git is the real tool the plugin integrates.
    -- contract_spec.lua runs scripts/rules.lua in a headless nvim to prove the exit codes of the
    -- command line (0 an answer, 1 an error document, 2 wrong usage).
    spawn = { "git", "nvim" },
  },
  -- gated: a failed conformance check makes `scripts/test.sh conformance` exit 1 (docs/CONFORMANCE.md of testing.nvim)
  conformance = {
    gate = true,
    waivers = {
      {
        check = "K15",
        rule = "NEW-08",
        file = "lua/rules/bindings",
        level = "warn",
        reason = "the plugin registers no keymaps or autocmds (user commands only); the files would be empty",
        expires = "2027-04-14",
      },
    },
  },
}
