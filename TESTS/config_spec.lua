local config = require("rules.config")

describe("rules.config.setup", function()
  it("accepts a valid rulesets list and gates table", function()
    config.setup({ rulesets = { "/a", "/b" }, gates = { release = { "REL" } } })

    assert.are.same({ "/a", "/b" }, config.get().rulesets)
    assert.are.same({ release = { "REL" } }, config.get().gates)
  end)

  it("ERR-22: a non-table setup() argument degrades to defaults instead of crashing on pairs()", function()
    config.setup({ rulesets = { "/a" } }) -- establish a known non-default state first

    for _, bad in ipairs({ "not-a-table", 5, true, false }) do
      local ok = pcall(config.setup, bad)
      assert.is_true(ok, ("setup(%s) must not raise"):format(tostring(bad)))
      assert.are.same({}, config.get().rulesets) -- DEFAULTS.rulesets
      assert.are.same({}, config.get().gates) -- DEFAULTS.gates
      config.setup({ rulesets = { "/a" } }) -- reset for the next iteration
    end
  end)

  it("ERR-22: an invalid rulesets value degrades to the default instead of propagating", function()
    config.setup({ rulesets = { "/a" } }) -- establish a known non-default state first
    config.setup({ rulesets = "not-a-list" })

    assert.are.same({}, config.get().rulesets) -- DEFAULTS.rulesets
  end)

  it("ERR-22: a rulesets list with a non-string entry degrades to the default", function()
    config.setup({ rulesets = { "/a" } })
    config.setup({ rulesets = { "/a", 5 } })

    assert.are.same({}, config.get().rulesets)
  end)

  it("ERR-22: an invalid gates value degrades to the default instead of propagating", function()
    config.setup({ gates = { release = { "REL" } } })
    config.setup({ gates = "not-a-table" })

    assert.are.same({}, config.get().gates) -- DEFAULTS.gates
  end)

  it("ERR-22: a gates entry whose family list has a non-string entry degrades to the default", function()
    config.setup({ gates = { release = { "REL" } } })
    config.setup({ gates = { release = { "REL", 5 } } })

    assert.are.same({}, config.get().gates)
  end)

  it("leaves an unrelated valid key untouched when the other key is invalid", function()
    config.setup({ rulesets = { "/a" }, gates = "not-a-table" })

    assert.are.same({ "/a" }, config.get().rulesets)
    assert.are.same({}, config.get().gates)
  end)

  it("ERR-50: warns with a did-you-mean hint on a typo'd top-level key, instead of silently dropping it", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    local original_notify = vim.notify
    local messages = {}
    vim.notify = function(msg, _)
      messages[#messages + 1] = msg
    end

    config.setup({ ruleset = { "/a" } }) -- typo: "ruleset", not "rulesets"
    vim.notify = original_notify

    assert.are.same({}, config.get().rulesets) -- the typo'd value never lands
    assert.is_true(#messages > 0)
    assert.matches("ruleset", messages[#messages])
    assert.matches("did you mean rulesets", messages[#messages])
  end)

  describe("keys.form", function()
    local DEFAULT_FORM = {
      toggle = "<Space>",
      accept = "<CR>",
      submit = "<C-s>",
      close = "q",
      cancel = "<C-q>",
      help = "g?",
    }

    ---@param opts any
    ---@return string[] messages
    local function setup_with(opts)
      local original_notify = vim.notify
      local messages = {}
      vim.notify = function(msg, _)
        messages[#messages + 1] = tostring(msg)
      end
      local ok, err = pcall(config.setup, opts)
      vim.notify = original_notify
      assert(ok, err)
      return messages
    end

    ---@param messages string[]
    ---@param needle string
    ---@return boolean
    local function mentions(messages, needle)
      for _, message in ipairs(messages) do
        if message:find(needle, 1, true) then
          return true
        end
      end
      return false
    end

    after_each(function()
      config.setup({})
    end)

    it("keeps the default keys when nothing is set, and warns about nothing", function()
      assert.are.equal(0, #setup_with({}))
      assert.are.same(DEFAULT_FORM, config.get().keys.form)
      assert.are.equal(0, #setup_with({ keys = {} }))
      assert.are.same(DEFAULT_FORM, config.get().keys.form)
      assert.are.equal(0, #setup_with({ keys = { form = {} } }))
      assert.are.same(DEFAULT_FORM, config.get().keys.form)
    end)

    it("changes the actions that are named, a key, a list of keys or false, and leaves the others", function()
      local messages = setup_with({ keys = { form = { submit = "<C-g>", toggle = { "x", "<Tab>" }, help = false } } })
      assert.are.equal(0, #messages)
      local form = config.get().keys.form
      assert.are.equal("<C-g>", form.submit)
      assert.are.same({ "x", "<Tab>" }, form.toggle)
      assert.is_false(form.help)
      assert.are.equal("<CR>", form.accept)
      assert.are.equal("q", form.close)
      assert.are.equal("<C-q>", form.cancel)
      -- the next setup() starts from the defaults again
      setup_with({ keys = { form = { close = "Q" } } })
      assert.are.same(vim.tbl_extend("force", DEFAULT_FORM, { close = "Q" }), config.get().keys.form)
    end)

    it("ERR-50: warns, naming the key, about an action or a group this plugin does not have", function()
      local messages = setup_with({ keys = { form = { sumbit = "<C-g>", frobnicate = "x" }, menu = {} } })
      assert.is_true(mentions(messages, "keys.form.sumbit (did you mean submit?)"))
      assert.is_true(mentions(messages, "keys.form.frobnicate"))
      assert.is_true(mentions(messages, "keys.menu"))
      -- nothing was bound to nothing: the defaults stand
      assert.are.same(DEFAULT_FORM, config.get().keys.form)
    end)

    it("ERR-22: a wrong value is dropped with its dotted key, the right ones next to it stay", function()
      local bad = { 5, true, "", {}, { "a", 5 }, { "" }, { a = "b" } }
      for _, value in ipairs(bad) do
        local messages = setup_with({ keys = { form = { submit = value, close = "Q" } } })
        assert.is_true(mentions(messages, "keys.form.submit"), vim.inspect(value) .. ": " .. vim.inspect(messages))
        assert.is_true(mentions(messages, "falling back to default"))
        assert.are.equal("<C-s>", config.get().keys.form.submit, vim.inspect(value))
        assert.are.equal("Q", config.get().keys.form.close)
      end
    end)

    it("ERR-22: a keys or keys.form that is no table is told and ignored", function()
      for _, opts in ipairs({ { keys = "x" }, { keys = 5 }, { keys = { form = "x" } }, { keys = { form = { "q" } } } }) do
        local messages = setup_with(opts)
        assert.is_true(#messages > 0, vim.inspect(opts))
        assert.are.same(DEFAULT_FORM, config.get().keys.form, vim.inspect(opts))
      end
    end)

    it("warns when two actions are on the same key, in every spelling of it, and keeps what was set", function()
      local messages = setup_with({ keys = { form = { submit = "<Space>" } } })
      assert.are.equal(1, #messages)
      assert.is_true(mentions(messages, "keys.form"))
      assert.is_true(mentions(messages, "toggle, submit share the key <Space>"))
      assert.are.equal("<Space>", config.get().keys.form.submit)

      messages = setup_with({ keys = { form = { help = { "x", "<C-S>" } } } })
      assert.is_true(mentions(messages, "submit, help share the key <C-s>"))

      -- the same key twice in the list of one action is no conflict; a key switched off is none either
      assert.are.equal(0, #setup_with({ keys = { form = { help = { "?", "?" } } } }))
      assert.are.equal(0, #setup_with({ keys = { form = { toggle = false, accept = false, submit = "<Space>" } } }))
    end)
  end)

  it("ERR-50: does not warn for the two known top-level keys", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    local original_notify = vim.notify
    local messages = {}
    vim.notify = function(msg, _)
      messages[#messages + 1] = msg
    end

    config.setup({ rulesets = { "/a" }, gates = { release = { "REL" } } })
    vim.notify = original_notify

    assert.are.equal(0, #messages)
  end)
end)
