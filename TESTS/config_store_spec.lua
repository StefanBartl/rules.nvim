-- TESTS/config_store_spec.lua -- `config.get()` comes from lib.lua.config.new; it must equal what the merge functions of
-- `rules.config.merge` (which `rules.settings.resolve` still stacks its layers with) give over the defaults.

local config = require("rules.config")
local merge = require("rules.config.merge")
local DEFAULTS = require("rules.config.DEFAULTS")

---What `setup()` computed before the store: each named key merged over the defaults with the merge functions.
---@param explicit table
---@return table
local function expected(explicit)
  local state = vim.deepcopy(DEFAULTS)
  for key, value in pairs(explicit) do
    if key == "agent" then
      state.agent = merge.agent(DEFAULTS.agent, value)
    elseif key == "gates" then
      state.gates = merge.gates(DEFAULTS.gates, value)
    elseif key == "keys" then
      state.keys = merge.keys(DEFAULTS.keys, value)
    else
      state[key] = vim.deepcopy(value)
    end
  end
  return state
end

describe("rules.config store", function()
  local samples = {
    {},
    { rulesets = { "/a", "/b" } },
    { gates = { release = { "REL" }, quick = { "A", "B" } } },
    { vault = "/some/vault", lua_predicates = false, trust = { "/t" } },
    { agent = { batch_size = 3, deny = { "secret/**" } } },
    { agent = { backends = { "local" }, models = { "m1", "m2" }, deny = {} } },
    {
      agent = {
        scopes = { LUA = { include = { "lua/**" } }, DOC = { include = { "docs/**", "*.md" } } },
        max_context_bytes = 1000,
      },
    },
    { keys = { form = { submit = "<C-x>", help = false } } },
    { keys = { form = { toggle = { "<Space>", "x" }, cancel = "<Esc>" } } },
    {
      rulesets = { "@vault/lua" },
      gates = { g = { "X" } },
      agent = { scopes = { A = { include = { "a" } } }, batch_size = 1 },
      keys = { form = { accept = false } },
      vault = "/v",
    },
  }

  for index, opts in ipairs(samples) do
    it(("sample %d: get() is the defaults with the merge functions applied"):format(index), function()
      config.setup(opts)
      assert.are.same(expected(opts), config.get())
      assert.are.same(opts, config.explicit(), "explicit() holds exactly what setup() named")
    end)
  end

  it("shares no table with DEFAULTS", function()
    config.setup({ gates = { g = { "X" } } })
    local cfg = config.get()
    assert.is_true(cfg.agent ~= DEFAULTS.agent)
    assert.is_true(cfg.agent.scopes ~= DEFAULTS.agent.scopes)
    assert.is_true(cfg.keys.form ~= DEFAULTS.keys.form)
    assert.is_true(cfg.rulesets ~= DEFAULTS.rulesets)
  end)

  it("a second setup() starts from the defaults again (nothing carries over)", function()
    config.setup({ agent = { batch_size = 2 }, gates = { g = { "X" } }, keys = { form = { help = false } } })
    config.setup({ rulesets = { "/a" } })
    assert.are.equal(8, config.get().agent.batch_size)
    assert.are.same({}, config.get().gates)
    assert.are.equal("g?", config.get().keys.form.help)
  end)

  it("an empty list in agent clears the default one, a name in gates adds to none", function()
    config.setup({ agent = { deny = {} }, gates = {} })
    assert.are.same({}, config.get().agent.deny)
    assert.are.same({}, config.get().gates)
  end)

  it("setup() with nothing is the defaults", function()
    config.setup()
    assert.are.same(DEFAULTS, config.get())
  end)
end)
