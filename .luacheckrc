-- luacheck configuration for rules.nvim
std = "luajit"
globals = { "vim" }
max_line_length = 130

-- TESTS/ uses plenary's busted-compatible globals (describe/it/before_each/
-- assert.*), which luacheck's built-in busted std does not match here since
-- it only matches lowercase spec/test/tests directories, not `TESTS/`.
files["TESTS/"] = {
  std = "+busted",
}
