-- TESTS/usrcmds_help_spec.lua -- every flag and positional argument of `:Rules` has a line in the
-- option float.
--
-- lib.nvim's help float (the option cheatsheet on the command line) shows one line per
-- `--flag` / `key=`, taken from the `desc` of its spec, and one for the next positional argument,
-- taken from its `desc` or from the text of its type (`RULES_GATE`, `RULES_ID`). This pins that
-- nothing of the verb ships without one, and that the lines stay what the float expects: one short
-- line, no trailing full stop.

describe(":Rules option float", function()
  local composer = require("lib.nvim.bindings.usercmd.composer")
  local entries = require("lib.nvim.bindings.usercmd.composer.help.entries")

  before_each(function()
    pcall(vim.api.nvim_del_user_command, "Rules")
    require("rules.bindings.usrcmds").setup()
  end)

  after_each(function()
    pcall(vim.api.nvim_del_user_command, "Rules")
  end)

  it("leaves no flag without a description", function()
    local missing = {}
    for _, m in ipairs(composer.help.undocumented("Rules")) do
      missing[#missing + 1] = ("%s %s %s"):format(m.route, m.kind, m.name)
    end
    assert.are.equal("", table.concat(missing, ", "))
  end)

  it("leaves no positional argument without a description", function()
    local missing = {}
    for _, m in ipairs(composer.help.undocumented("Rules", { args = true })) do
      missing[#missing + 1] = ("%s %s %s"):format(m.route, m.kind, m.name)
    end
    assert.are.equal("", table.concat(missing, ", "))
  end)

  it("keeps the type texts of the positional arguments to one short line", function()
    local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")
    for _, name in ipairs({ "RULES_GATE", "RULES_ID" }) do
      local text = argtypes.get(name).desc or ""
      assert.is_true(text ~= "", name .. " shows a text")
      assert.is_nil(text:find("\n", 1, true), name .. " is one line")
      assert.is_true(#text <= 80, name .. " stays short")
      assert.is_nil(text:find("%.$"), name .. " has no trailing full stop")
    end
  end)

  it("keeps every description to one short line without a trailing full stop", function()
    local handle = composer.registry().Rules
    assert.is_not_nil(handle)
    local seen = 0
    for _, route in ipairs(handle:spec().routes or {}) do
      for _, flag in ipairs(route.flags or {}) do
        seen = seen + 1
        local text = entries.flag_desc(route, flag) or ""
        local what = ("--%s of %s"):format(flag.name, table.concat(route.path, " "))
        assert.is_true(text ~= "", what .. " shows a text")
        assert.is_nil(text:find("\n", 1, true), what .. " is one line")
        assert.is_true(#text <= 80, what .. " stays short")
        assert.is_nil(text:find("%.$"), what .. " has no trailing full stop")
      end
    end
    assert.is_true(seen > 0, "the routes' flags were actually walked")
  end)
end)
