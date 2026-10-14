-- TESTS/vault_cmd_spec.lua -- `:RulesVault open|clipboard|link|find|grep|tree|cdx`: which ruleset, rule id or family a
-- word means, where each verb sends it, the one "no vault" notice, the completion and the option float.
--
-- The commands are run as a user types them (`vim.cmd("RulesVault ...")`) against a vault in a temporary folder. The
-- clipboard, the explorer, the picker, the list to pick from and the window of the tree are the seams of
-- `rules.ui.vault_cmd`: a spec reads what went through them, nothing opens.
---@diagnostic disable: need-check-nil
local config = require("rules.config")
local settings = require("rules.settings")
local contract = require("rules.contract")
local cmd = require("rules.ui.vault_cmd")
local ops = require("rules.vault_ops")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return path
end

---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---The real path, `/`-separated: a temporary folder may be reached through a link (macOS /var, Windows 8.3 names) and
---the editor names a buffer by one spelling, the test by the other.
---@param path string
---@return string
local function real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

---@param id string
---@param severity string
---@param title string
---@return string
local function rule_file(id, severity, title)
  return table.concat({
    "---",
    "id: " .. id,
    "severity: " .. severity,
    "family: " .. id:match("^(%a+)%-"),
    "---",
    "",
    "#### `" .. id .. "` — " .. title,
    "",
    "Text of " .. id .. ".",
    "",
  }, "\n")
end

local RETIRED = table.concat({
  "---",
  "id: DEP-03",
  "retired: 2026-01-01",
  "replaced_by: DEP-06",
  "reason: superseded",
  "---",
  "",
  "#### `DEP-03` — old",
  "",
}, "\n")

local LAYOUT = table.concat({
  "---",
  "kind: layout",
  "output: Dependencies.md",
  "---",
  "# Dependencies",
  "",
  "{{rule DEP-01}}",
  "",
  "{{rule DEP-06}}",
  "",
}, "\n")

---A vault with two rulesets: `lua` (family DEP: DEP-01, DEP-06, the retired DEP-03; a layout and its generated
---document) and `native` (family ERR).
---@return string vault, string lua, string native
local function make_vault()
  local vault = tmp_dir() .. "/rules-vault"
  local lua, native = vault .. "/rulesets/lua", vault .. "/rulesets/native"
  write_raw(lua .. "/_rules/DEP/DEP-01.md", rule_file("DEP-01", "recommended", "one"))
  write_raw(lua .. "/_rules/DEP/DEP-06.md", rule_file("DEP-06", "critical", "six"))
  write_raw(lua .. "/_retired/DEP/DEP-03.md", RETIRED)
  write_raw(lua .. "/_layouts/Dependencies.md", LAYOUT)
  write_raw(native .. "/_rules/ERR/ERR-100.md", rule_file("ERR-100", "nice-to-have", "err"))
  write_raw(native .. "/_rules/ERR/ERR-101.md", rule_file("ERR-101", "critical", "err two"))
  local _, errors = require("rules.engine.catalog").build(lua)
  assert(#errors == 0, vim.inspect(errors))
  return vault, lua, native
end

local ENV = { "RULES_VAULT", "RULES_PROJECT", "RULES_RULESETS", "RULES_GATES" }

describe(":RulesVault", function()
  local saved_env, saved_notify, saved_uis, saved_ignore
  local origin, origin_win
  local notes, copied, explored, picked, dispatched, shown
  local select_answer
  local vault, lua, native

  ---@param needle string
  ---@param level? integer
  ---@return boolean
  local function told(needle, level)
    for _, note in ipairs(notes) do
      if note.text:find(needle, 1, true) and (level == nil or note.level == level) then
        return true
      end
    end
    return false
  end

  ---@param line string
  local function run(line)
    vim.cmd(line)
  end

  ---@param name string
  ---@return string[]
  local function complete(line)
    return vim.fn.getcompletion(line, "cmdline")
  end

  local function reset_state()
    notes, copied, explored, picked, dispatched, shown = {}, {}, {}, {}, {}, {}
  end

  before_each(function()
    saved_env = {}
    for _, name in ipairs(ENV) do
      saved_env[name] = vim.env[name]
      vim.env[name] = nil
    end
    saved_notify, saved_uis, saved_ignore = vim.notify, vim.api.nvim_list_uis, vim.o.eventignore
    origin, origin_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    -- the rule files are Markdown: their FileType would load a syntax that defines highlight groups, which the state
    -- guard counts as a leak of the spec
    vim.o.eventignore = "FileType,Syntax"
    vault, lua, native = make_vault()
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
    config.setup({ vault = vault })
    settings.reset()
    require("rules").setup({ vault = vault })
    contract.clear_cache()
    require("rules.ui.candidates").reset()
    reset_state()
    vim.notify = function(msg, level)
      notes[#notes + 1] = { text = tostring(msg), level = level }
    end
    select_answer = 1
    cmd.copy = function(text)
      copied[#copied + 1] = text
      return true
    end
    cmd.select = function(items, opts, cb)
      picked[#picked + 1] = { items = items, prompt = opts.prompt }
      cb(items[select_answer], select_answer)
    end
    cmd.explorer_open = function(dir)
      explored[#explored + 1] = dir
    end
    cmd.show = function(lines)
      shown[#shown + 1] = lines
    end
    cmd.pickers_backend = function()
      return {
        dispatch = function(action, source, engine)
          dispatched[#dispatched + 1] = { action = action, source = source, engine = engine }
        end,
      }, { name = "fake" }
    end
  end)

  after_each(function()
    vim.notify, vim.api.nvim_list_uis, vim.o.eventignore = saved_notify, saved_uis, saved_ignore
    for _, name in ipairs(ENV) do
      vim.env[name] = saved_env[name]
    end
    cmd.copy, cmd.select, cmd.explorer_open, cmd.pickers_backend, cmd.show = nil, nil, nil, nil, nil
    ops.CASE_BLIND = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if win ~= origin_win then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    pcall(vim.api.nvim_set_current_win, origin_win)
    pcall(vim.api.nvim_set_current_buf, origin)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if buf ~= origin then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    config.setup({})
    settings.reset()
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
  end)

  describe("without a vault", function()
    before_each(function()
      config.setup({})
      settings.reset()
      require("rules").setup({})
    end)

    it("every verb but create says so once, and does nothing else", function()
      for _, verb in ipairs({ "open", "clipboard", "link", "find", "grep", "tree", "cdx" }) do
        reset_state()
        run("RulesVault " .. verb .. " DEP-06")
        assert.are.equal(1, #notes, verb)
        assert.is_true(told("no vault is configured", vim.log.levels.WARN), verb)
        assert.is_true(told(":RulesVault create <dir>"), verb)
        assert.are.same({}, copied, verb)
        assert.are.same({}, explored, verb)
        assert.are.same({}, dispatched, verb)
        assert.are.same({}, shown, verb)
        assert.are.same({}, picked, verb)
        assert.are.equal(origin, vim.api.nvim_get_current_buf(), verb)
      end
    end)

    it("reports the missing vault and not a stray word, and not the word either", function()
      run("RulesVault open lua rules extra words")
      assert.are.equal(1, #notes)
      assert.is_true(told("no vault is configured"))
      assert.is_false(told("unexpected argument"))
      assert.is_false(told("neither a ruleset"))
    end)

    it("the bare command says it too", function()
      run("RulesVault")
      assert.is_true(told("no vault is configured"))
    end)

    it("is no vault for rules.vault.is_none, and a named vault that is not there is something else", function()
      local _, message = require("rules.vault").root({ project = tmp_dir() })
      assert.is_true(require("rules.vault").is_none(message))
      vim.env.RULES_VAULT = tmp_dir() .. "/gone"
      local _, broken = require("rules.vault").root({ project = tmp_dir() })
      assert.is_false(require("rules.vault").is_none(broken))
    end)
  end)

  describe("a vault that is named but not a folder", function()
    it("is an error with the place it was named, from every verb", function()
      vim.env.RULES_VAULT = tmp_dir() .. "/gone"
      config.setup({})
      settings.reset()
      require("rules").setup({})
      for _, verb in ipairs({ "open", "tree", "cdx" }) do
        reset_state()
        run("RulesVault " .. verb .. " DEP-06")
        assert.are.equal(1, #notes, verb)
        assert.is_true(told("$RULES_VAULT: the vault is not a folder", vim.log.levels.ERROR), verb)
        assert.is_false(told("no vault is configured"), verb)
        assert.are.same({}, copied, verb)
      end
    end)

    it("names setup() when that is where it was named", function()
      config.setup({ vault = tmp_dir() .. "/gone" })
      settings.reset()
      run("RulesVault open DEP-06")
      assert.is_true(told("setup({ vault = ... }): the vault is not a folder", vim.log.levels.ERROR))
    end)
  end)

  describe("which word means what", function()
    ---@return Rules.Vault.Ctx
    local function context()
      local ctx, kind, message = ops.context()
      assert(ctx, tostring(kind) .. ": " .. tostring(message))
      return ctx
    end

    it("the rulesets of the vault are its roots, named by their folders", function()
      local ctx = context()
      assert.are.same({ "lua", "native" }, ops.ruleset_names(ctx))
      assert.are.equal(real(lua), real(ctx.rulesets[1].dir))
      assert.are.equal(real(vault), real(ctx.root))
    end)

    it("reads the rules of the vault's rulesets and not of whatever setup() loads", function()
      local other = tmp_dir() .. "/other"
      write_raw(other .. "/_rules/ZZZ/ZZZ-01.md", rule_file("ZZZ-01", "critical", "elsewhere"))
      config.setup({ vault = vault, rulesets = { other } })
      settings.reset()
      contract.clear_cache()
      local target, err = ops.resolve(context(), "DEP-06")
      assert.is_nil(err)
      assert.are.equal("id", target.kind)
      local missing = ops.resolve(context(), "ZZZ-01")
      assert.is_nil(missing)
    end)

    it("a ruleset, a rule id, a family and a part each have one reading", function()
      local ctx = context()
      local ruleset = ops.resolve(ctx, "lua")
      assert.are.equal("ruleset", ruleset.kind)
      assert.are.equal("rules", ruleset.part)
      assert.is_false(ruleset.part_given)
      local id = ops.resolve(ctx, "DEP-06")
      assert.are.equal("id", id.kind)
      assert.are.equal("DEP-06", id.entry.id)
      assert.is_false(id.entry.retired)
      local family = ops.resolve(ctx, "DEP")
      assert.are.equal("family", family.kind)
      assert.are.equal(3, #family.entries)
      local part = ops.resolve(ctx, "layouts")
      assert.are.equal("none", part.kind)
      assert.are.equal("layouts", part.part)
      assert.is_true(part.part_given)
      local both = ops.resolve(ctx, "native", "all")
      assert.are.equal("ruleset", both.kind)
      assert.are.equal("all", both.part)
    end)

    it("a retired rule is still a rule id, marked retired", function()
      local target = ops.resolve(context(), "DEP-03")
      assert.are.equal("id", target.kind)
      assert.is_true(target.entry.retired)
      assert.are.equal("DEP-06", target.entry.replaced_by)
      assert.are.equal(real(lua .. "/_retired/DEP/DEP-03.md"), real(target.entry.file))
    end)

    it("a single word that is a part and a ruleset name means the ruleset", function()
      local named = tmp_dir() .. "/rules-vault"
      write_raw(named .. "/rulesets/all/_rules/ALL/ALL-01.md", rule_file("ALL-01", "critical", "x"))
      write_raw(named .. "/rulesets/lua/_rules/DEP/DEP-01.md", rule_file("DEP-01", "critical", "x"))
      vim.env.RULES_VAULT = named
      config.setup({})
      settings.reset()
      local ctx = context()
      local target = ops.resolve(ctx, "all")
      assert.are.equal("ruleset", target.kind)
      assert.are.equal("all", target.name)
      assert.are.equal("rules", target.part)
      local with_part = ops.resolve(ctx, "all", "all")
      assert.are.equal("ruleset", with_part.kind)
      assert.are.equal("all", with_part.part)
      local alone = ops.resolve(ctx, "layouts")
      assert.are.equal("none", alone.kind)
    end)

    it("an unknown word is an error that lists the rulesets and suggests the case it has", function()
      local ctx = context()
      local target, err = ops.resolve(ctx, "DEP-99")
      assert.is_nil(target)
      assert.is_truthy(err:find("'DEP-99' is neither a ruleset (lua, native), a rule id nor a family", 1, true))
      local _, hint = ops.resolve(ctx, "dep-06")
      assert.is_truthy(hint:find("did you mean DEP-06?", 1, true))
      local _, family_hint = ops.resolve(ctx, "dep")
      assert.is_truthy(family_hint:find("did you mean DEP?", 1, true))
    end)

    it("an unknown part is an error, and a rule id or a family takes none", function()
      local ctx = context()
      local _, err = ops.resolve(ctx, "lua", "nope")
      assert.is_truthy(err:find("unknown part 'nope' (expected rules|layouts|catalogs|all)", 1, true))
      local _, with_id = ops.resolve(ctx, "DEP-06", "layouts")
      assert.is_truthy(with_id:find("goes with a ruleset, not with the rule id DEP-06", 1, true))
      local _, with_family = ops.resolve(ctx, "DEP", "all")
      assert.is_truthy(with_family:find("goes with a ruleset, not with the family DEP", 1, true))
    end)

    it("is told by the command, once", function()
      run("RulesVault open nope")
      assert.are.equal(1, #notes)
      assert.is_true(told("'nope' is neither a ruleset", vim.log.levels.ERROR))
      assert.are.equal(origin, vim.api.nvim_get_current_buf())
      -- a part that is none is refused by the grammar before a handler runs
      reset_state()
      pcall(vim.cmd, "RulesVault clipboard lua sideways")
      vim.wait(50)
      assert.are.same({}, copied)
    end)

    it("names a ruleset in the case it has only where the file system does not tell the cases apart", function()
      ops.CASE_BLIND = true
      assert.are.equal("lua", ops.resolve(context(), "LUA").name)
      ops.CASE_BLIND = false
      local target, err = ops.resolve(context(), "LUA")
      assert.is_nil(target)
      assert.is_truthy(err:find("did you mean lua?", 1, true))
    end)

    it("settles a word-less target: the ruleset of the buffer, else the only one, else a pick", function()
      -- the buffer lies in native
      vim.cmd({ cmd = "edit", args = { native .. "/_rules/ERR/ERR-100.md" } })
      run("RulesVault clipboard")
      assert.are.equal(1, #copied)
      assert.is_truthy(real(copied[1]):find(real(native) .. "/_rules", 1, true))
      assert.are.same({}, picked)

      -- a buffer that is nowhere in the vault: two rulesets, so a pick (the first is taken by the seam)
      reset_state()
      vim.cmd({ cmd = "enew" })
      select_answer = 2
      run("RulesVault clipboard")
      assert.are.equal(1, #picked)
      assert.are.same({ "lua", "native" }, picked[1].items)
      assert.are.equal("Ruleset> ", picked[1].prompt)
      assert.is_truthy(real(copied[1]):find(real(native) .. "/_rules", 1, true))
    end)

    it("takes the only ruleset without asking, and asks for none when the vault has none", function()
      local single = tmp_dir() .. "/rules-vault"
      write_raw(single .. "/rulesets/solo/_rules/DEP/DEP-01.md", rule_file("DEP-01", "critical", "x"))
      vim.env.RULES_VAULT = single
      config.setup({})
      settings.reset()
      vim.cmd({ cmd = "enew" })
      run("RulesVault clipboard")
      assert.are.same({}, picked)
      assert.is_truthy(real(copied[1]):find(real(single) .. "/rulesets/solo/_rules", 1, true))

      local empty = tmp_dir() .. "/rules-vault"
      vim.fn.mkdir(empty .. "/rulesets", "p")
      vim.env.RULES_VAULT = empty
      settings.reset()
      reset_state()
      run("RulesVault clipboard")
      assert.is_true(told("The vault has no ruleset yet", vim.log.levels.WARN))
      assert.are.same({}, copied)
    end)

    it("says which rulesets to name when several fit and nobody can be asked", function()
      cmd.select = nil
      vim.cmd({ cmd = "enew" })
      run("RulesVault clipboard")
      assert.is_true(told("Name one: lua, native", vim.log.levels.ERROR))
      assert.are.same({}, copied)
    end)
  end)

  describe("paths are compared by real path", function()
    it("a file reached through a link is in its ruleset", function()
      local link = tmp_dir() .. "/link-to-lua"
      local ok = pcall(function()
        assert((vim.uv or vim.loop).fs_symlink(lua, link, { dir = true, junction = true }))
      end)
      if not ok then
        pending("no link can be made here")
        return
      end
      local ctx = assert(ops.context())
      local through = link .. "/_rules/DEP/DEP-01.md"
      assert.is_true(ops.same_path(link, lua))
      assert.are.equal("lua", ops.ruleset_of_path(ctx, through).name)
      assert.is_false(ops.same_path(link, native))
      vim.cmd({ cmd = "edit", args = { through } })
      run("RulesVault clipboard")
      assert.is_truthy(real(copied[1]):find(real(lua) .. "/_rules", 1, true))
    end)

    it("the case of a path counts only where the file system ignores it", function()
      -- neither path exists: they are compared by their spelling, folded or not
      ops.CASE_BLIND = true
      assert.is_true(ops.same_path(lua .. "/X", lua .. "/x"))
      assert.are.equal("lua", ops.fold("Lua"))
      ops.CASE_BLIND = false
      assert.is_false(ops.same_path(lua .. "/X", lua .. "/x"))
      assert.is_true(ops.same_path(lua .. "/x", lua .. "/x"))
      assert.are.equal("Lua", ops.fold("Lua"))
    end)
  end)

  describe("open", function()
    it("opens the file of a rule id, at its heading", function()
      run("RulesVault open DEP-06")
      assert.are.equal(real(lua .. "/_rules/DEP/DEP-06.md"), real(vim.api.nvim_buf_get_name(0)))
      assert.is_true(vim.api.nvim_win_get_cursor(0)[1] > 1)
      assert.are.same({}, explored)
    end)

    it("opens the file of a retired rule id", function()
      run("RulesVault open DEP-03")
      assert.are.equal(real(lua .. "/_retired/DEP/DEP-03.md"), real(vim.api.nvim_buf_get_name(0)))
    end)

    it("opens the folder of a family in the explorer, not a file", function()
      run("RulesVault open ERR")
      assert.are.equal(1, #explored)
      assert.are.equal(real(native .. "/_rules/ERR"), real(explored[1]))
      assert.are.equal(origin, vim.api.nvim_get_current_buf())
    end)

    it("opens the parts of a ruleset: rules (the default), layouts, all", function()
      run("RulesVault open lua")
      assert.are.equal(real(lua .. "/_rules"), real(explored[1]))
      run("RulesVault open lua layouts")
      assert.are.equal(real(lua .. "/_layouts"), real(explored[2]))
      run("RulesVault open native all")
      assert.are.equal(real(native), real(explored[3]))
    end)

    it("opens the generated document of the catalogs part in a buffer", function()
      run("RulesVault open lua catalogs")
      assert.are.equal(real(lua .. "/Dependencies.md"), real(vim.api.nvim_buf_get_name(0)))
      assert.are.same({}, explored)
    end)

    it("says what is missing instead of opening a folder that is not there", function()
      run("RulesVault open native layouts")
      assert.is_true(told("native has no layouts folder yet", vim.log.levels.WARN))
      assert.are.same({}, explored)
      reset_state()
      run("RulesVault open native catalogs")
      assert.is_true(told("native has no generated document yet", vim.log.levels.WARN))
    end)

    it("falls back to the ruleset folder for a ruleset that keeps its rules in documents", function()
      local docs = tmp_dir() .. "/rules-vault"
      write_raw(
        docs .. "/rulesets/book/DEP.md",
        table.concat({
          "# Dependencies",
          "",
          "### `DEP-01` — one",
          "",
          "```rule",
          'id = "DEP-01",',
          'severity = "recommended",',
          "```",
          "",
          "Text.",
          "",
        }, "\n")
      )
      vim.env.RULES_VAULT = docs
      config.setup({})
      settings.reset()
      run("RulesVault open book")
      assert.are.equal(real(docs .. "/rulesets/book"), real(explored[1]))
      run("RulesVault open DEP-01")
      assert.are.equal(real(docs .. "/rulesets/book/DEP.md"), real(vim.api.nvim_buf_get_name(0)))
      reset_state()
      run("RulesVault open DEP")
      assert.are.equal(real(docs .. "/rulesets/book/DEP.md"), real(vim.api.nvim_buf_get_name(0)))
    end)

    it("lets you pick when a family has its folder in several rulesets", function()
      write_raw(native .. "/_rules/DEP/DEP-50.md", rule_file("DEP-50", "critical", "in native too"))
      contract.clear_cache()
      select_answer = 2
      run("RulesVault open DEP")
      assert.are.equal(1, #picked)
      assert.are.equal(2, #picked[1].items)
      assert.are.equal(real(native .. "/_rules/DEP"), real(explored[1]))
    end)

    it("reports a word after the arguments of the verb", function()
      run("RulesVault open lua rules extra")
      assert.is_true(told("unexpected argument: extra", vim.log.levels.ERROR))
      assert.are.same({}, explored)
    end)
  end)

  describe("clipboard", function()
    it("copies the absolute path of a rule file, with forward slashes", function()
      run("RulesVault clipboard DEP-06")
      assert.are.equal(1, #copied)
      assert.are.equal(real(lua .. "/_rules/DEP/DEP-06.md"), real(copied[1]))
      assert.is_nil(copied[1]:find("\\", 1, true))
      assert.is_true(told("Copied " .. copied[1], vim.log.levels.INFO))
    end)

    it("copies the folder of a family and of a part", function()
      run("RulesVault clipboard DEP")
      assert.are.equal(real(lua .. "/_rules/DEP"), real(copied[1]))
      run("RulesVault clipboard native layouts")
      assert.are.equal(1, #copied)
      assert.is_true(told("native has no layouts folder yet"))
      run("RulesVault clipboard lua all")
      assert.are.equal(real(lua), real(copied[2]))
    end)

    it("--rel writes the path relative to the folder of the current file", function()
      vim.cmd({ cmd = "edit", args = { lua .. "/_rules/DEP/DEP-01.md" } })
      run("RulesVault clipboard DEP-06 --rel")
      assert.are.equal("DEP-06.md", copied[1])
      run("RulesVault clipboard ERR-100 --rel")
      assert.are.equal("../../../native/_rules/ERR/ERR-100.md", copied[2])
      run("RulesVault clipboard lua catalogs --rel")
      assert.are.equal("../../Dependencies.md", copied[3])
    end)

    it("--link copies [ID](path), the path wrapped in <> when it holds a blank", function()
      run("RulesVault clipboard DEP-06 --link")
      local shown_path = copied[1]:match("^%[DEP%-06%]%((.-)%)$")
      assert.is_truthy(shown_path, copied[1])
      assert.are.equal(real(lua .. "/_rules/DEP/DEP-06.md"), real(shown_path))
      vim.cmd({ cmd = "edit", args = { lua .. "/_rules/DEP/DEP-01.md" } })
      run("RulesVault clipboard DEP-06 --link --rel")
      assert.are.equal("[DEP-06](DEP-06.md)", copied[2])
      assert.are.equal("[a b](<x y/z.md>)", ops.markdown_link("a b", "x y/z.md"))
      assert.are.equal("[a](<f(1).md>)", ops.markdown_link("a", "f(1).md"))
    end)

    it("copies one line per file for the generated documents", function()
      write_raw(
        lua .. "/_layouts/Other.md",
        table.concat({ "---", "kind: layout", "output: docs/Other.md", "---", "# Other", "", "{{rule DEP-01}}", "" }, "\n")
      )
      assert(#select(2, require("rules.engine.catalog").build(lua)) == 0)
      run("RulesVault clipboard lua catalogs")
      local lines = vim.split(copied[1], "\n", { plain = true })
      assert.are.equal(2, #lines)
      assert.are.equal(real(lua .. "/Dependencies.md"), real(lines[1]))
      assert.are.equal(real(lua .. "/docs/Other.md"), real(lines[2]))
    end)

    it("tells a clipboard that cannot be written", function()
      cmd.copy = function()
        return false
      end
      run("RulesVault clipboard DEP-06")
      assert.is_true(told("Could not write to the clipboard", vim.log.levels.ERROR))
    end)
  end)

  describe("link", function()
    ---@param lines string[]
    ---@return integer buf
    local function scratch(lines)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(buf)
      return buf
    end

    it("puts a Markdown link to the rule at the cursor, relative to the current file", function()
      local doc = tmp_dir() .. "/notes/finding.md"
      write_raw(doc, "See: \n")
      vim.cmd({ cmd = "edit", args = { doc } })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      run("RulesVault link DEP-06")
      local line = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
      local target = line:match("^%[DEP%-06%]%((.-)%)See: $")
      assert.is_truthy(target, line)
      assert.are.equal(real(lua .. "/_rules/DEP/DEP-06.md"), real(vim.fs.dirname(doc) .. "/" .. target))
      assert.is_nil(target:find("\\", 1, true))
      assert.are.same({}, copied)
    end)

    it("labels a family by its name and a part by its ruleset and part", function()
      scratch({ "" })
      run("RulesVault link ERR")
      assert.is_truthy(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:match("^%[ERR%]%("))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "" })
      run("RulesVault link lua layouts")
      assert.is_truthy(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:match("^%[lua layouts%]%("))
    end)

    it("falls back to the clipboard in a buffer that cannot take text", function()
      local buf = scratch({ "" })
      vim.bo[buf].modifiable = false
      run("RulesVault link DEP-06")
      assert.are.equal(1, #copied)
      assert.is_truthy(copied[1]:match("^%[DEP%-06%]%("))
      assert.is_true(told("is in the + register instead", vim.log.levels.WARN))
    end)
  end)

  describe("find and grep", function()
    it("root the picker at the ruleset of a part", function()
      run("RulesVault find lua")
      run("RulesVault grep lua layouts")
      assert.are.equal(2, #dispatched)
      assert.are.equal("files", dispatched[1].action)
      assert.are.equal(real(lua .. "/_rules"), real(dispatched[1].source.roots[1]))
      assert.are.equal("lua> ", dispatched[1].source.prompt)
      assert.is_nil(dispatched[1].source.query)
      assert.are.equal("grep", dispatched[2].action)
      assert.are.equal(real(lua .. "/_layouts"), real(dispatched[2].source.roots[1]))
      assert.are.equal("fake", dispatched[2].engine.name)
    end)

    it("search the whole ruleset of a rule id for the id", function()
      run("RulesVault grep ERR-101")
      assert.are.equal(1, #dispatched)
      assert.are.equal(real(native), real(dispatched[1].source.roots[1]))
      assert.are.equal("ERR-101", dispatched[1].source.query)
      assert.are.equal("ERR-101> ", dispatched[1].source.prompt)
    end)

    it("search the folder of a family", function()
      run("RulesVault find DEP")
      assert.are.equal(real(lua .. "/_rules/DEP"), real(dispatched[1].source.roots[1]))
    end)

    it("refuse the catalogs, which are files and not a folder", function()
      run("RulesVault find lua catalogs")
      assert.is_true(told("catalogs are generated documents", vim.log.levels.WARN))
      assert.are.same({}, dispatched)
    end)

    it("open the folder in the explorer where pickers.nvim is not there", function()
      cmd.pickers_backend = function()
        return nil, nil
      end
      run("RulesVault grep lua all")
      assert.is_true(told("pickers.nvim is not available", vim.log.levels.WARN))
      assert.are.same({}, dispatched)
      assert.are.equal(real(lua), real(explored[1]))
    end)

    it("ask pickers.nvim itself without the seam, and do not fail where it is not installed", function()
      if pcall(require, "pickers.command") then
        pending("pickers.nvim is installed: it would open a picker")
        return
      end
      cmd.pickers_backend = nil
      run("RulesVault find lua")
      assert.is_true(told("pickers.nvim is not available", vim.log.levels.WARN))
      assert.are.equal(real(lua .. "/_rules"), real(explored[1]))
    end)
  end)

  describe("tree", function()
    it("shows a ruleset family by family, the retired rules marked, with counts", function()
      run("RulesVault tree lua")
      assert.are.equal(1, #shown)
      assert.are.same({
        "lua  2 rules, 1 retired, 1 family",
        "└─ DEP  2 rules, 1 retired",
        "   ├─ DEP-01  [recommended]  one",
        "   ├─ DEP-03  [retired]  -> DEP-06",
        "   └─ DEP-06  [critical]  six",
      }, shown[1])
    end)

    it("shows the families of another ruleset with their own counts", function()
      run("RulesVault tree native")
      assert.are.same({
        "native  2 rules, 1 family",
        "└─ ERR  2 rules",
        "   ├─ ERR-100  [nice-to-have]  err",
        "   └─ ERR-101  [critical]  err two",
      }, shown[1])
    end)

    it("a family or a rule id shows its family, in every ruleset that has it", function()
      write_raw(native .. "/_rules/DEP/DEP-50.md", rule_file("DEP-50", "critical", "in native too"))
      contract.clear_cache()
      run("RulesVault tree DEP")
      assert.are.equal("lua  2 rules, 1 retired, 1 family", shown[1][1])
      local joined = table.concat(shown[1], "\n")
      assert.is_truthy(joined:find("native  1 rule, 1 family", 1, true))
      assert.is_truthy(joined:find("DEP-50", 1, true))
      assert.is_nil(joined:find("ERR-100", 1, true))
      run("RulesVault tree ERR-100")
      assert.is_truthy(table.concat(shown[2], "\n"):find("ERR-101", 1, true))
      assert.is_nil(table.concat(shown[2], "\n"):find("DEP-01", 1, true))
    end)

    it("takes no part: it is the rules of a ruleset", function()
      run("RulesVault tree lua layouts")
      assert.is_true(told("tree shows the rules of a ruleset", vim.log.levels.ERROR))
      assert.are.same({}, shown)
    end)

    it("settles the ruleset of the buffer like the other verbs", function()
      vim.cmd({ cmd = "edit", args = { native .. "/_rules/ERR/ERR-100.md" } })
      run("RulesVault tree")
      assert.are.equal("native  2 rules, 1 family", shown[1][1])
    end)

    it("says how many rules could not be loaded", function()
      write_raw(lua .. "/_rules/DEP/DEP-77.md", rule_file("DEP-06", "critical", "duplicate of six"))
      contract.clear_cache()
      run("RulesVault tree lua")
      local joined = table.concat(shown[1], "\n")
      assert.is_truthy(joined:find("load error", 1, true))
    end)

    it("opens the report window with the lines when no seam replaces it", function()
      cmd.show = nil
      local tabs = #vim.api.nvim_list_tabpages()
      run("RulesVault tree native")
      assert.are.equal("rulesreport", vim.bo.filetype)
      assert.are.equal("native  2 rules, 1 family", vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
      vim.cmd.tabclose()
      assert.are.equal(tabs, #vim.api.nvim_list_tabpages())
    end)
  end)

  describe("cdx", function()
    it("copies a prompt that names the path and says rules are changed through the engine", function()
      run("RulesVault cdx DEP-06")
      assert.are.equal(1, #copied)
      assert.is_truthy(copied[1]:find(real(lua .. "/_rules/DEP/DEP-06.md"), 1, true))
      assert.is_truthy(copied[1]:find("the rule DEP-06", 1, true))
      assert.is_truthy(copied[1]:find(":Rules new, set, retire and move", 1, true))
      assert.is_true(told("Copied a prompt for DEP-06", vim.log.levels.INFO))
    end)

    it("names the part of a ruleset, and takes --rel", function()
      vim.cmd({ cmd = "edit", args = { lua .. "/_rules/DEP/DEP-01.md" } })
      run("RulesVault cdx lua layouts --rel")
      assert.is_truthy(copied[1]:find("(the layouts of the ruleset lua)", 1, true))
      assert.is_truthy(copied[1]:find("../../_layouts", 1, true))
      run("RulesVault cdx DEP")
      assert.is_truthy(copied[2]:find("the rules of the family DEP", 1, true))
    end)
  end)

  describe("the commands of the family", function()
    it("has no new and no paste: a rule is made by :Rules new, and nothing here writes one", function()
      local handle = require("lib.nvim.bindings.usercmd.composer").registry().RulesVault
      assert.is_not_nil(handle)
      local verbs = {}
      for _, route in ipairs(handle:spec().routes or {}) do
        verbs[#verbs + 1] = table.concat(route.path, " ")
      end
      table.sort(verbs)
      assert.are.same({ "cdx", "clipboard", "create", "find", "grep", "link", "open", "tree" }, verbs)
      assert.is_not_nil(require("lib.nvim.bindings.usercmd.composer").registry().Rules)
    end)

    it("writes nothing into the vault: no verb but create changes a file", function()
      local function snapshot()
        local out = {}
        for _, file in ipairs(vim.fn.glob(vault .. "/**/*", true, true)) do
          if vim.fn.isdirectory(file) == 0 then
            local f = assert(io.open(file, "rb"))
            out[file] = f:read("*a")
            f:close()
          end
        end
        return out
      end
      local before = snapshot()
      for _, line in ipairs({
        "RulesVault open DEP-06",
        "RulesVault open DEP",
        "RulesVault clipboard ERR --link",
        "RulesVault link lua",
        "RulesVault find lua",
        "RulesVault grep DEP-01",
        "RulesVault tree",
        "RulesVault cdx native",
        "RulesVault",
      }) do
        pcall(vim.cmd, line)
      end
      assert.are.same(before, snapshot())
    end)
  end)

  describe("completion", function()
    it("offers the verbs, and neither new nor paste", function()
      local verbs = complete("RulesVault ")
      for _, verb in ipairs({ "open", "clipboard", "link", "find", "grep", "tree", "cdx", "create" }) do
        assert.is_true(vim.tbl_contains(verbs, verb), verb)
      end
      assert.is_false(vim.tbl_contains(verbs, "new"))
      assert.is_false(vim.tbl_contains(verbs, "paste"))
    end)

    it("offers the rulesets, the parts, the ids and the families after a verb", function()
      local words = complete("RulesVault open ")
      for _, word in ipairs({
        "lua",
        "native",
        "rules",
        "layouts",
        "catalogs",
        "all",
        "DEP",
        "ERR",
        "DEP-01",
        "DEP-06",
        "ERR-100",
      }) do
        assert.is_true(vim.tbl_contains(words, word), word)
      end
      assert.is_false(vim.tbl_contains(words, "DEP-03"), "a retired rule is not offered (RULES_ID lists the loaded ones)")
    end)

    it("narrows by what is typed, ids and families through the types of :Rules", function()
      assert.are.same(
        { "DEP-01", "DEP-06" },
        vim.tbl_filter(function(w)
          return w:match("^DEP%-")
        end, complete("RulesVault clipboard DEP-0"))
      )
      local ids = require("lib.nvim.bindings.usercmd.composer.argtypes").get("RULES_ID").complete("DEP-0", {})
      assert.are.same({ "DEP-01", "DEP-06" }, ids)
      assert.are.same({ "native" }, complete("RulesVault open na"))
    end)

    it("offers the parts for the second word", function()
      local words = complete("RulesVault open lua ")
      table.sort(words)
      assert.are.same({ "all", "catalogs", "layouts", "rules" }, words)
    end)

    it("offers the flags of a verb", function()
      local flags = complete("RulesVault clipboard DEP-06 --")
      assert.is_true(vim.tbl_contains(flags, "--rel"))
      assert.is_true(vim.tbl_contains(flags, "--link"))
      local create = complete("RulesVault create --")
      for _, flag in ipairs({ "--git", "--yes", "--force" }) do
        assert.is_true(vim.tbl_contains(create, flag), flag)
      end
    end)

    it("fails soft without a vault: the parts and the ids of whatever is loaded, never an error", function()
      config.setup({})
      settings.reset()
      local words = complete("RulesVault open ")
      assert.is_true(vim.tbl_contains(words, "layouts"))
      assert.is_false(vim.tbl_contains(words, "lua"))
    end)

    it("folds the case of a ruleset only where the file system does", function()
      ops.CASE_BLIND = true
      assert.is_true(vim.tbl_contains(complete("RulesVault open LU"), "lua"))
      ops.CASE_BLIND = false
      assert.is_false(vim.tbl_contains(complete("RulesVault open LU"), "lua"))
    end)
  end)

  describe("the option float", function()
    local composer = require("lib.nvim.bindings.usercmd.composer")
    local entries = require("lib.nvim.bindings.usercmd.composer.help.entries")

    it("leaves no flag and no positional argument without a description", function()
      assert.are.equal(
        "",
        table.concat(
          vim.tbl_map(function(m)
            return ("%s %s %s"):format(m.route, m.kind, m.name)
          end, composer.help.undocumented("RulesVault")),
          ", "
        )
      )
      assert.are.equal(
        "",
        table.concat(
          vim.tbl_map(function(m)
            return ("%s %s %s"):format(m.route, m.kind, m.name)
          end, composer.help.undocumented("RulesVault", { args = true })),
          ", "
        )
      )
    end)

    it("keeps every flag text to one short line without a trailing full stop", function()
      local seen = 0
      for _, route in ipairs(composer.registry().RulesVault:spec().routes or {}) do
        for _, flag in ipairs(route.flags or {}) do
          seen = seen + 1
          local text = entries.flag_desc(route, flag) or ""
          local what = ("--%s of %s"):format(flag.name, table.concat(route.path, " "))
          assert.is_true(text ~= "", what)
          assert.is_nil(text:find("\n", 1, true), what)
          assert.is_true(#text <= 80, what .. " stays short")
          assert.is_nil(text:find("%.$"), what .. " has no trailing full stop")
        end
        for _, arg in ipairs(route.args or {}) do
          local text = arg.desc or require("lib.nvim.bindings.usercmd.composer.argtypes").get(arg.type).desc or ""
          local what = ("%s of %s"):format(arg.name, table.concat(route.path, " "))
          assert.is_true(text ~= "", what)
          assert.is_true(#text <= 100, what .. " stays short")
          assert.is_nil(text:find("%.$"), what .. " has no trailing full stop")
        end
      end
      assert.is_true(seen >= 6, "the flags were actually walked")
    end)

    it("describes the type of the target in one short line", function()
      local text = require("lib.nvim.bindings.usercmd.composer.argtypes").get("RULES_VAULT_TARGET").desc or ""
      assert.is_true(text ~= "")
      assert.is_true(#text <= 80)
      assert.is_nil(text:find("%.$"))
    end)
  end)

  describe("the bare command", function()
    it("shows the vault, where it came from, its rulesets and its git state", function()
      run("RulesVault")
      assert.are.equal(1, #notes)
      local text = notes[1].text
      assert.is_truthy(text:find("Vault: " .. vim.fs.normalize(vault), 1, true))
      assert.is_truthy(text:find("(from setup({ vault = ... }))", 1, true))
      assert.is_truthy(text:find("rulesets: lua, native", 1, true))
      assert.is_truthy(text:find(":RulesVault open|clipboard|link|find|grep|tree|cdx", 1, true))
    end)
  end)
end)
