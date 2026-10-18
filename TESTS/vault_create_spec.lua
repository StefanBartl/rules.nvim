-- TESTS/vault_create_spec.lua -- `:RulesVault create`: the plan that is listed before anything is made, the required step
-- that is left to the user, what is made, and what is never done (overwrite a file, `git init` unasked, add a remote).
--
-- The command is run as a user types it (`vim.cmd("RulesVault create ...")`). The question is answered by the spec
-- (`rules.ui.confirm.choose` is replaced), the clipboard is a seam, `vim.ui.input` is replaced: nothing opens.
---@diagnostic disable: need-check-nil
local config = require("rules.config")
local settings = require("rules.settings")
local contract = require("rules.contract")
local confirm = require("rules.ui.confirm")
local cmd = require("rules.ui.vault_cmd")
local scaffold = require("rules.vault_scaffold")
local vault_api = require("rules.vault")

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

---@param path string
---@return string|nil
local function read_raw(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

---@param path string
---@return boolean
local function exists(path)
  return (vim.uv or vim.loop).fs_stat(path) ~= nil
end

---A file of the plugin.
---@param rel string
---@return string
local function plugin_file(rel)
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source))) .. "/" .. rel
end

local ENV = { "RULES_VAULT", "RULES_PROJECT", "RULES_RULESETS", "RULES_GATES" }

---The files `create` makes in a vault whose first ruleset is `default`.
local FILES = {
  "README.md",
  ".rules.json",
  ".gitattributes",
  ".gitignore",
  ".github/workflows/ci.yml",
  "rulesets/default/_rules/.gitkeep",
  "rulesets/default/_layouts/.gitkeep",
}

describe(":RulesVault create", function()
  local saved_env, saved_notify, saved_uis, saved_input, saved_choose, saved_template
  local notes, copied, asked, answer, typed
  local base, root

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

  ---@param on boolean
  local function ui(on)
    vim.api.nvim_list_uis = function()
      return on and { {} } or {}
    end
  end

  ---@param line string
  local function run(line)
    vim.cmd(line)
  end

  ---@param dir string
  ---@return string
  local function in_command(dir)
    return (dir:gsub(" ", "\\ "))
  end

  ---@return boolean
  local function nothing_made()
    return not exists(root)
  end

  before_each(function()
    saved_env = {}
    for _, name in ipairs(ENV) do
      saved_env[name] = vim.env[name]
      vim.env[name] = nil
    end
    saved_notify, saved_uis, saved_input = vim.notify, vim.api.nvim_list_uis, vim.ui.input
    saved_choose, saved_template = confirm.choose, scaffold.template_path
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
    config.setup({})
    settings.reset()
    require("rules").setup({})
    contract.clear_cache()
    base = tmp_dir()
    root = base .. "/rules-vault"
    notes, copied, asked, typed = {}, {}, {}, {}
    answer = 2
    vim.notify = function(msg, level)
      notes[#notes + 1] = { text = tostring(msg), level = level }
    end
    confirm.choose = function(question, choices, cb)
      asked[#asked + 1] = { question = question, choices = choices }
      cb(answer)
    end
    vim.ui.input = function(opts, cb)
      typed[#typed + 1] = opts
      cb(typed.reply)
    end
    cmd.copy = function(text)
      copied[#copied + 1] = text
      return true
    end
    ui(false)
  end)

  after_each(function()
    vim.notify, vim.api.nvim_list_uis, vim.ui.input = saved_notify, saved_uis, saved_input
    confirm.choose, scaffold.template_path = saved_choose, saved_template
    cmd.copy = nil
    for _, name in ipairs(ENV) do
      vim.env[name] = saved_env[name]
    end
    config.setup({})
    settings.reset()
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
  end)

  describe("the plan", function()
    it("says first what happens and what is left to you, with the required step marked", function()
      ui(true)
      run("RulesVault create " .. in_command(root))
      assert.are.equal(1, #asked)
      local question = asked[1].question
      assert.is_truthy(question:find("Create a rules vault", 1, true))
      assert.is_truthy(question:find(vim.fs.normalize(root), 1, true))
      for _, file in ipairs(FILES) do
        assert.is_truthy(question:find("+ " .. file, 1, true), file)
      end
      -- the step that has no effect until it is done, marked and last
      local marker = question:find(">>> 4. REQUIRED, and done by you afterwards <<<", 1, true)
      assert.is_truthy(marker)
      assert.is_truthy(question:find(('vault = "%s",'):format(vim.fs.normalize(root)), 1, true))
      assert.is_truthy(question:find("$RULES_VAULT", 1, true))
      assert.is_truthy(question:find("will NOT find", 1, true))
      assert.is_true(question:find("+ README.md", 1, true) < marker)
      assert.is_true(question:find("3. No git repository is made", 1, true) < marker)
      assert.is_nil(question:sub(marker):find("+ ", 1, true), "nothing is made after the required step")
      -- and nothing about a remote beyond saying there is none
      assert.is_truthy(question:find("No remote", 1, true))
    end)

    it("starts the dialog on the harmless answer", function()
      ui(true)
      run("RulesVault create " .. in_command(root))
      assert.are.same({ "No", "Yes, create it" }, asked[1].choices)
    end)

    it("makes nothing when the answer is no", function()
      ui(true)
      answer = 1
      run("RulesVault create " .. in_command(root))
      assert.is_true(nothing_made())
      assert.is_true(told("the vault was not created"))
      assert.are.same({}, copied)
    end)

    it("makes nothing when the dialog is dismissed", function()
      ui(true)
      answer = nil
      run("RulesVault create " .. in_command(root))
      assert.is_true(nothing_made())
    end)

    it("--yes skips the question, and a session without a screen needs it", function()
      run("RulesVault create " .. in_command(root))
      assert.is_true(told("nobody to ask: run it with --yes", vim.log.levels.ERROR))
      assert.are.same({}, asked)
      assert.is_true(nothing_made())

      run("RulesVault create " .. in_command(root) .. " --yes")
      assert.are.same({}, asked)
      assert.is_true(exists(root .. "/.rules.json"))
    end)

    it("says kept for a file that is there, and says it before anything is made", function()
      ui(true)
      write_raw(root .. "/README.md", "MINE\n")
      run("RulesVault create " .. in_command(root))
      local question = asked[1].question
      assert.is_truthy(question:find("= README.md   (there already, stays as it is)", 1, true))
      assert.is_nil(question:find("+ README.md", 1, true))
      assert.is_truthy(question:find("(exists: it is used as it is)", 1, true))
      assert.is_truthy(question:find("never overwritten", 1, true))
    end)
  end)

  describe("what it makes", function()
    it("a folder with the files of a vault and a first ruleset called default", function()
      run("RulesVault create " .. in_command(root) .. " --yes")
      for _, file in ipairs(FILES) do
        assert.is_true(exists(root .. "/" .. file), file)
      end
      assert.are.equal("* text=auto eol=lf\n", read_raw(root .. "/.gitattributes"))
      assert.are.equal("", read_raw(root .. "/rulesets/default/_rules/.gitkeep"))
      assert.are.equal("", read_raw(root .. "/rulesets/default/_layouts/.gitkeep"))
      assert.is_truthy(read_raw(root .. "/.gitignore"):find(".deps/", 1, true))
      assert.is_truthy(read_raw(root .. "/README.md"):find("rulesets/<name>/", 1, true))
      assert.is_truthy(read_raw(root .. "/README.md"):find("$RULES_VAULT", 1, true))
    end)

    it("a .rules.json with the ruleset and the gates, in paths relative to the file and with none of this machine", function()
      run("RulesVault create " .. in_command(root) .. " --yes")
      local text = read_raw(root .. "/.rules.json")
      local decoded = vim.json.decode(text)
      assert.are.same({ "rulesets/default" }, decoded.rulesets)
      assert.are.same({}, decoded.gates)
      assert.is_nil(text:find(vim.fs.normalize(base), 1, true))
      assert.is_nil(text:find(base, 1, true))
      assert.is_nil(text:find("\\", 1, true))
      assert.is_nil(text:match('"/') or text:match('"%a:'))
    end)

    it("takes the name of the ruleset from the second word", function()
      run("RulesVault create " .. in_command(root) .. " lua --yes")
      assert.is_true(exists(root .. "/rulesets/lua/_rules/.gitkeep"))
      assert.is_true(exists(root .. "/rulesets/lua/_layouts/.gitkeep"))
      assert.is_false(exists(root .. "/rulesets/default"))
      assert.are.same({ "rulesets/lua" }, vim.json.decode(read_raw(root .. "/.rules.json")).rulesets)
    end)

    it("makes the workflow from the template of the plugin", function()
      run("RulesVault create " .. in_command(root) .. " --yes")
      local template = assert(read_raw(plugin_file("templates/rules-vault-ci.yml")))
      assert.are.equal(template, read_raw(root .. "/.github/workflows/ci.yml"))
    end)

    it("makes a vault that rules.nvim reads, with no problem and no warning", function()
      run("RulesVault create " .. in_command(root) .. " lua --yes")
      vim.env.RULES_VAULT = root
      settings.reset()
      local found, message = vault_api.root({ project = tmp_dir() })
      assert.is_nil(message)
      assert.are.equal(vim.fs.normalize(root), found)
      assert.are.same({ vim.fs.normalize(root) .. "/rulesets/lua" }, vault_api.rulesets({ project = tmp_dir() }))
      local res = settings.resolve({ project = tmp_dir() })
      assert.are.same({}, res.problems)
      assert.are.same({}, res.warnings)
      local view = assert(contract.view({ rulesets = vault_api.rulesets({ project = tmp_dir() }) }))
      assert.are.same({}, view.load_errors)
      assert.are.equal(0, #view.rules)
    end)

    it("creates the folder a named vault points to, and rules.nvim finds it then", function()
      vim.env.RULES_VAULT = root
      settings.reset()
      local _, before = vault_api.root({ project = tmp_dir() })
      assert.is_truthy(before:find("the vault is not a folder", 1, true))
      run("RulesVault create " .. in_command(root) .. " --yes")
      local found = vault_api.root({ project = tmp_dir() })
      assert.are.equal(vim.fs.normalize(root), found)
      assert.is_false(told("A vault is in use already"))
    end)

    it("asks for the folder when none is given, and makes nothing when the question is left", function()
      ui(true)
      typed.reply = nil
      run("RulesVault create")
      assert.are.equal(1, #typed)
      assert.is_truthy(typed[1].default:find("rules-vault", 1, true))
      assert.are.same({}, asked)
      assert.is_true(nothing_made())

      typed.reply = root
      run("RulesVault create")
      assert.are.equal(1, #asked)
      assert.is_truthy(asked[1].question:find(vim.fs.normalize(root), 1, true))
      assert.is_true(exists(root .. "/.rules.json"))
    end)

    it("reads a folder with a blank in it as typed, backslash before the blank", function()
      local spaced = base .. "/my vault"
      run("RulesVault create " .. in_command(spaced) .. " --yes")
      assert.is_true(exists(spaced .. "/.rules.json"))
    end)

    it("reports a word after the two it takes", function()
      run("RulesVault create " .. in_command(root) .. " lua extra words --yes")
      assert.is_true(told("unexpected argument: extra words", vim.log.levels.ERROR))
      assert.is_true(nothing_made())
    end)

    describe("a folder word that ends with a path separator (Tab completion on Windows: sub\\)", function()
      local saved_sep

      before_each(function()
        saved_sep = cmd.BACKSLASH_SEPARATOR
        cmd.BACKSLASH_SEPARATOR = true
        vim.fn.mkdir(base .. "/sub", "p")
      end)

      after_each(function()
        cmd.BACKSLASH_SEPARATOR = saved_sep
      end)

      it("is the folder, and the blank after it starts the next word, when that folder is there", function()
        run("RulesVault create " .. base .. "/sub\\ lua --yes")
        assert.is_true(exists(base .. "/sub/rulesets/lua/_rules/.gitkeep"))
        assert.is_true(exists(base .. "/sub/.rules.json"))
        assert.is_false(exists(base .. "/sub lua"))
      end)

      it("takes a flag that the blank glued to the folder as a flag, and a blank at the end as nothing", function()
        run("RulesVault create " .. base .. "/sub\\ --yes")
        assert.is_true(exists(base .. "/sub/.rules.json"))
        assert.is_false(exists(base .. "/sub --yes"))
        notes = {}
        vim.fn.mkdir(base .. "/sub2", "p")
        run("RulesVault create " .. base .. "/sub2\\  --yes")
        assert.is_true(exists(base .. "/sub2/.rules.json"))
      end)

      it("stays an escaped blank when the folder before it is not there: a folder with a blank in its name", function()
        run("RulesVault create " .. base .. "/new\\ vault --yes")
        assert.is_true(exists(base .. "/new vault/.rules.json"))
        assert.is_true(exists(base .. "/new vault/rulesets/default/_rules/.gitkeep"))
      end)

      it("stays an escaped blank when the folder with the blank is there", function()
        vim.fn.mkdir(base .. "/sub lua", "p")
        run("RulesVault create " .. base .. "/sub\\ lua --yes")
        assert.is_true(exists(base .. "/sub lua/.rules.json"))
        assert.is_false(exists(base .. "/sub/.rules.json"))
      end)

      it("is the folder for an escaped blank before a normal character on a system where a backslash is no separator", function()
        cmd.BACKSLASH_SEPARATOR = false
        run("RulesVault create " .. base .. "/sub\\ lua --yes")
        assert.is_true(exists(base .. "/sub lua/.rules.json"))
        assert.is_false(exists(base .. "/sub/.rules.json"))
      end)

      it("reads the blank after an escaped one the same way: a folder with a blank, then the name", function()
        vim.fn.mkdir(base .. "/my vault", "p")
        run("RulesVault create " .. base .. "/my\\ vault\\ lua --yes")
        assert.is_true(exists(base .. "/my vault/rulesets/lua/_rules/.gitkeep"))
      end)
    end)
  end)

  describe("into a vault that has rulesets already", function()
    ---@return string[]
    local function found_names()
      vim.env.RULES_VAULT = root
      settings.reset()
      local folders = vault_api.rulesets({ project = tmp_dir() })
      return vim.tbl_map(function(path)
        return vim.fs.basename(path)
      end, folders)
    end

    local function existing()
      write_raw(root .. "/rulesets/lua/_rules/.gitkeep", "")
      write_raw(root .. "/rulesets/native/_rules/.gitkeep", "")
    end

    it("makes no .rules.json that lists only the new ruleset: every ruleset is still found", function()
      existing()
      ui(true)
      run("RulesVault create " .. in_command(root) .. " fresh")
      local question = asked[1].question
      assert.is_truthy(question:find(".rules.json is NOT made", 1, true))
      assert.is_truthy(question:find("lua, native", 1, true))
      assert.is_nil(question:find("+ .rules.json", 1, true))
      assert.is_false(exists(root .. "/.rules.json"))
      assert.is_true(exists(root .. "/rulesets/fresh/_rules/.gitkeep"))
      assert.are.same({ "fresh", "lua", "native" }, found_names())
      assert.is_true(told(".rules.json was not made"))
    end)

    it("still makes the .rules.json of a vault that has no other ruleset, with the new one in it", function()
      write_raw(root .. "/rulesets/fresh/_rules/.gitkeep", "")
      run("RulesVault create " .. in_command(root) .. " fresh --yes")
      assert.are.same({ "rulesets/fresh" }, vim.json.decode(read_raw(root .. "/.rules.json")).rulesets)
    end)

    it("keeps a .rules.json that does not list the new ruleset, and says in the plan and the result what to add", function()
      existing()
      local text = '{"rulesets": ["rulesets/lua", "rulesets/native"], "gates": {}}\n'
      write_raw(root .. "/.rules.json", text)
      ui(true)
      run("RulesVault create " .. in_command(root) .. " fresh")
      assert.are.equal(text, read_raw(root .. "/.rules.json"))
      local question = asked[1].question
      assert.is_truthy(question:find("does not list rulesets/fresh", 1, true))
      assert.is_truthy(question:find('add "rulesets/fresh"', 1, true))
      assert.is_true(told("does not list rulesets/fresh", vim.log.levels.WARN))
      assert.is_true(told('add "rulesets/fresh" to the "rulesets" list'))
      -- and that is the truth: the list hides the new ruleset
      assert.are.same({ "lua", "native" }, found_names())
    end)

    it("says nothing of it when the list names the new ruleset, in whatever spelling, or has no list", function()
      for _, text in ipairs({
        '{"rulesets": ["./rulesets/fresh/", "rulesets/lua"]}',
        '{"rulesets": ["@vault/fresh"]}',
        '{"gates": {}}',
      }) do
        local r = tmp_dir() .. "/vault"
        write_raw(r .. "/rulesets/lua/_rules/.gitkeep", "")
        write_raw(r .. "/.rules.json", text)
        notes = {}
        run("RulesVault create " .. in_command(r) .. " fresh --yes")
        assert.is_false(told("does not list"), text)
        assert.is_false(told("could not be read"), text)
        assert.are.equal(text, read_raw(r .. "/.rules.json"))
      end
    end)

    it("keeps a .rules.json that cannot be read, and says to check it", function()
      existing()
      write_raw(root .. "/.rules.json", "{ not json")
      run("RulesVault create " .. in_command(root) .. " fresh --yes")
      assert.are.equal("{ not json", read_raw(root .. "/.rules.json"))
      assert.is_true(told("could not be read", vim.log.levels.WARN))
      assert.is_true(told("rulesets/fresh"))
    end)
  end)

  describe("writes nowhere but below the folder", function()
    ---A folder link (a junction on Windows, which needs no privilege), or nil when none can be made here.
    ---@param target string
    ---@param at string
    ---@return boolean
    local function link(target, at)
      vim.fn.mkdir(vim.fs.dirname(at), "p")
      local ok = (vim.uv or vim.loop).fs_symlink(target, at, { dir = true, junction = true })
      return ok == true
    end

    ---@return string[]
    local function entries(dir)
      return vim.fn.readdir(dir)
    end

    for _, where in ipairs({ ".github", ".github/workflows", "rulesets", "rulesets/default", "rulesets/default/_rules" }) do
      it(("refuses a link at '%s' that leads out, and writes nothing at all"):format(where), function()
        local outside = tmp_dir() .. "/outside"
        vim.fn.mkdir(outside, "p")
        if not link(outside, root .. "/" .. where) then
          pending("no folder link can be made here")
          return
        end
        run("RulesVault create " .. in_command(root) .. " --yes")
        assert.is_true(told("leads out of the vault folder", vim.log.levels.ERROR))
        assert.is_true(told(where))
        assert.are.same({}, entries(outside))
        assert.is_false(exists(root .. "/README.md"))
        assert.is_false(exists(root .. "/.rules.json"))
        assert.is_false(told("ONE STEP IS LEFT"))
      end)
    end

    it("refuses it in the plan, before the question is asked", function()
      local outside = tmp_dir() .. "/outside"
      vim.fn.mkdir(outside, "p")
      if not link(outside, root .. "/rulesets") then
        pending("no folder link can be made here")
        return
      end
      ui(true)
      run("RulesVault create " .. in_command(root))
      assert.are.same({}, asked)
      assert.is_true(told("leads out of the vault folder", vim.log.levels.ERROR))
    end)

    it("refuses a link that leads nowhere", function()
      local gone = tmp_dir() .. "/gone"
      vim.fn.mkdir(gone, "p")
      if not link(gone, root .. "/rulesets") then
        pending("no folder link can be made here")
        return
      end
      vim.fn.delete(gone, "d")
      run("RulesVault create " .. in_command(root) .. " --yes")
      assert.is_true(told("rulesets", vim.log.levels.ERROR))
      assert.is_false(exists(root .. "/README.md"))
    end)

    it("takes a link that stays inside the folder", function()
      vim.fn.mkdir(root .. "/store", "p")
      if not link(root .. "/store", root .. "/rulesets") then
        pending("no folder link can be made here")
        return
      end
      run("RulesVault create " .. in_command(root) .. " --yes")
      assert.is_false(told("leads out"))
      assert.is_true(exists(root .. "/store/default/_rules/.gitkeep"))
    end)

    it("is checked again at the write: a link that appears after the plan", function()
      local outside = tmp_dir() .. "/outside"
      vim.fn.mkdir(outside, "p")
      vim.fn.mkdir(root, "p")
      local plan = assert(scaffold.plan({ root = root, name = "default" }))
      if not link(outside, root .. "/.github") then
        pending("no folder link can be made here")
        return
      end
      local res, err = scaffold.create(plan)
      assert.is_nil(res)
      assert.is_truthy(err:find("leads out of the vault folder", 1, true))
      assert.are.same({}, entries(outside))
      assert.is_false(exists(root .. "/README.md"))
    end)
  end)

  describe("after it is made", function()
    it("says the required step again, unmissable, and puts the setup line in the register", function()
      run("RulesVault create " .. in_command(root) .. " --yes")
      local line = ('vault = "%s",'):format(vim.fs.normalize(root))
      assert.are.same({ line }, copied)
      assert.is_true(told("!! ONE STEP IS LEFT, AND IT IS YOURS !!", vim.log.levels.WARN))
      assert.is_true(told("add   " .. line))
      assert.is_true(told("or set $RULES_VAULT"))
      assert.is_true(told("The line is in the + register."))
      assert.is_true(told("Created the vault " .. vim.fs.normalize(root)))
    end)

    it("says so when the register could not be written", function()
      cmd.copy = function()
        return false
      end
      run("RulesVault create " .. in_command(root) .. " --yes")
      assert.is_true(told("The + register could not be written, copy the line yourself."))
      assert.is_true(told("!! ONE STEP IS LEFT"))
    end)

    it("lists what it made, and what was there", function()
      write_raw(root .. "/.gitignore", "mine\n")
      run("RulesVault create " .. in_command(root) .. " --yes")
      assert.is_true(told("Used the existing folder"))
      assert.is_true(told("made: README.md, .rules.json, .gitattributes, .github/workflows/ci.yml"))
      assert.is_true(told("kept as they were: .gitignore"))
    end)

    it("makes a second run a no-op that still names the required step", function()
      run("RulesVault create " .. in_command(root) .. " --yes")
      notes = {}
      run("RulesVault create " .. in_command(root) .. " --yes")
      assert.is_true(told("nothing new to make"))
      assert.is_true(told("!! ONE STEP IS LEFT"))
    end)
  end)

  describe("never overwrites", function()
    it("a file that is there, whatever it holds", function()
      write_raw(root .. "/README.md", "MY README\n")
      write_raw(root .. "/.rules.json", '{"rulesets": ["mine"]}')
      write_raw(root .. "/.gitattributes", "* -text\n")
      write_raw(root .. "/.gitignore", "")
      write_raw(root .. "/.github/workflows/ci.yml", "name: mine\n")
      run("RulesVault create " .. in_command(root) .. " --yes")
      assert.are.equal("MY README\n", read_raw(root .. "/README.md"))
      assert.are.equal('{"rulesets": ["mine"]}', read_raw(root .. "/.rules.json"))
      assert.are.equal("* -text\n", read_raw(root .. "/.gitattributes"))
      assert.are.equal("", read_raw(root .. "/.gitignore"))
      assert.are.equal("name: mine\n", read_raw(root .. "/.github/workflows/ci.yml"))
      -- what was missing is made
      assert.is_true(exists(root .. "/rulesets/default/_rules/.gitkeep"))
      assert.is_true(told("kept as they were: README.md, .rules.json, .gitattributes, .gitignore, .github/workflows/ci.yml"))
      assert.is_true(told("made: rulesets/default/_rules/.gitkeep, rulesets/default/_layouts/.gitkeep"))
    end)

    it("a file that appears between the plan and the write", function()
      local plan = assert(scaffold.plan({ root = root, name = "default" }))
      write_raw(root .. "/README.md", "ARRIVED LATER\n")
      local result = assert(scaffold.create(plan))
      assert.are.equal("ARRIVED LATER\n", read_raw(root .. "/README.md"))
      assert.is_true(vim.tbl_contains(result.kept, "README.md"))
      assert.is_false(vim.tbl_contains(result.made, "README.md"))
    end)

    it("a folder where a file would go", function()
      vim.fn.mkdir(root .. "/README.md", "p")
      run("RulesVault create " .. in_command(root) .. " --yes")
      assert.are.equal(1, vim.fn.isdirectory(root .. "/README.md"))
      assert.is_true(told("kept as they were: README.md"))
    end)

    it("makes no placeholder in a folder that has files in it", function()
      write_raw(root .. "/rulesets/default/_rules/DEP/DEP-01.md", "rule\n")
      vim.fn.mkdir(root .. "/rulesets/default/_layouts", "p")
      run("RulesVault create " .. in_command(root) .. " --yes")
      assert.is_false(exists(root .. "/rulesets/default/_rules/.gitkeep"))
      assert.is_true(exists(root .. "/rulesets/default/_layouts/.gitkeep"), "an empty folder gets one")
    end)
  end)

  describe("git", function()
    ---@return boolean
    local function git_available()
      return vim.fn.executable("git") == 1
    end

    it("is not touched unless asked for", function()
      run("RulesVault create " .. in_command(root) .. " --yes")
      assert.is_false(exists(root .. "/.git"))
      assert.is_true(told("git: not asked for (--git)"))
    end)

    it("--git makes a repository, with no remote and nothing pushed", function()
      if not git_available() then
        pending("git is not installed")
        return
      end
      run("RulesVault create " .. in_command(root) .. " --yes --git")
      assert.is_true(exists(root .. "/.git"))
      assert.is_true(told("git: git init done (no remote)"))
      assert.are.equal("", vim.trim(vim.fn.system({ "git", "-C", root, "remote" })))
      local config_text = assert(read_raw(root .. "/.git/config"))
      assert.is_nil(config_text:find("[remote", 1, true))
      assert.is_nil(config_text:find("url =", 1, true))
      -- nothing is committed either
      assert.are_not.equal("", vim.trim(vim.fn.system({ "git", "-C", root, "status", "--short" })))
    end)

    it("--git is in the plan, with 'No remote'", function()
      if not git_available() then
        pending("git is not installed")
        return
      end
      ui(true)
      run("RulesVault create " .. in_command(root) .. " --git")
      assert.is_truthy(asked[1].question:find("3. git init in the folder (--git). No remote is added", 1, true))
    end)

    it("--git leaves a repository alone, and a folder inside another repository", function()
      if not git_available() then
        pending("git is not installed")
        return
      end
      vim.fn.mkdir(root, "p")
      vim.fn.system({ "git", "-C", root, "init", "-q" })
      local head = read_raw(root .. "/.git/HEAD")
      run("RulesVault create " .. in_command(root) .. " --yes --git")
      assert.is_true(told("git: already a git repository"))
      assert.are.equal(head, read_raw(root .. "/.git/HEAD"))

      local inner = root .. "/nested-vault"
      run("RulesVault create " .. in_command(inner) .. " --yes --git")
      assert.is_false(exists(inner .. "/.git"))
      assert.is_true(told("inside another repository"))

      -- a folder that is there already, below the top of the repository
      notes = {}
      local existing = root .. "/sub/existing"
      vim.fn.mkdir(existing, "p")
      run("RulesVault create " .. in_command(existing) .. " --yes --git")
      assert.is_false(exists(existing .. "/.git"))
      assert.is_true(told("inside another repository"))
    end)

    it("reports a git that fails without losing the files", function()
      local git = require("lib.nvim.git")
      local original = git.run
      git.run = function()
        return { code = 128, stdout = "", stderr = "fatal: it did not work" }
      end
      local ok, err = pcall(run, "RulesVault create " .. in_command(root) .. " --yes --git")
      git.run = original
      assert(ok, err)
      assert.is_true(exists(root .. "/.rules.json"))
      assert.is_true(told("git: git init failed: fatal: it did not work"))
      assert.is_true(told("!! ONE STEP IS LEFT"))
    end)
  end)

  describe("refuses before it asks", function()
    it("a name that cannot be a folder of a ruleset", function()
      ui(true)
      for _, name in ipairs({ "../x", "x.", ".hidden", "con", "NUL", "com1", "lpt9.txt", "a/b" }) do
        notes = {}
        run("RulesVault create " .. in_command(root) .. " " .. name)
        assert.is_true(told("ruleset name", vim.log.levels.ERROR) or told("reserved name", vim.log.levels.ERROR), name)
        assert.are.same({}, asked, name)
        assert.is_true(nothing_made(), name)
      end
    end)

    it("accepts the names a ruleset has", function()
      for _, name in ipairs({ "lua", "native", "my-rules_2", "v1.0", "default", "Console" }) do
        assert.is_true(scaffold.check_name(name), name)
      end
      for _, name in ipairs({ "a b", "", "-x", "a:b", "a*b" }) do
        assert.is_false(scaffold.check_name(name), name)
      end
    end)

    it("a file as the folder, and the root of a drive", function()
      ui(true)
      write_raw(base .. "/a-file", "x")
      run("RulesVault create " .. in_command(base .. "/a-file"))
      assert.is_true(told("is a file", vim.log.levels.ERROR))
      local top = vim.fn.has("win32") == 1 and "C:/" or "/"
      notes = {}
      run("RulesVault create " .. top)
      assert.is_true(told("refusing to use a drive or filesystem root", vim.log.levels.ERROR))
      assert.are.same({}, asked)
    end)

    it("another vault in use: asked in the plan, not refused; --yes and no one to ask still need --force", function()
      ui(true)
      local other = base .. "/other-vault"
      run("RulesVault create " .. in_command(other) .. " --yes")
      vim.env.RULES_VAULT = other
      settings.reset()
      notes, asked = {}, {}

      -- the question says another vault is in use, and No (the first answer) makes nothing
      answer = 1
      run("RulesVault create " .. in_command(root))
      assert.are.equal(1, #asked)
      assert.is_truthy(asked[1].question:find("A vault is in use already", 1, true))
      assert.is_truthy(asked[1].question:find("Create a rules vault", 1, true))
      assert.are.equal("No", asked[1].choices[1])
      assert.is_truthy(asked[1].choices[2]:find("another vault", 1, true))
      assert.is_true(nothing_made())

      -- Yes makes it
      answer = 2
      asked = {}
      run("RulesVault create " .. in_command(root))
      assert.are.equal(1, #asked)
      assert.is_true(exists(root .. "/.rules.json"))

      -- with --yes there is no question, so no vault is switched without --force
      local third = base .. "/third-vault"
      notes, asked = {}, {}
      run("RulesVault create " .. in_command(third) .. " --yes")
      assert.is_true(told("A vault is in use already", vim.log.levels.WARN))
      assert.is_true(told("--force"))
      assert.are.same({}, asked)
      assert.is_false(exists(third))

      -- nobody to ask: the same
      ui(false)
      notes = {}
      run("RulesVault create " .. in_command(third))
      assert.is_true(told("--force"))
      assert.is_false(exists(third))
      ui(true)

      -- the vault in use itself: what is missing is made, without --force and without the extra question
      os.remove(other .. "/.gitignore")
      run("RulesVault create " .. in_command(other) .. " --yes")
      assert.is_true(exists(other .. "/.gitignore"))

      run("RulesVault create " .. in_command(third) .. " --yes --force")
      assert.is_true(exists(third .. "/.rules.json"))
    end)

    it("a workflow template that is not there, before anything is made", function()
      scaffold.template_path = base .. "/no-such-template.yml"
      run("RulesVault create " .. in_command(root) .. " --yes")
      assert.is_true(told("the workflow template is missing", vim.log.levels.ERROR))
      assert.is_true(nothing_made())
    end)

    it("a file where a folder is needed, at any component, and makes no half scaffold", function()
      ui(true)
      for _, where in ipairs({ ".github", ".github/workflows", "rulesets", "rulesets/default", "rulesets/default/_rules" }) do
        local r = tmp_dir() .. "/vault"
        write_raw(r .. "/" .. where, "i am a file")
        notes, asked = {}, {}
        run("RulesVault create " .. in_command(r))
        assert.is_true(told("is a file, not a folder", vim.log.levels.ERROR), where)
        assert.is_true(told(where), where)
        assert.are.same({}, asked, where)
        assert.is_false(exists(r .. "/README.md"), where)
        assert.is_false(exists(r .. "/.rules.json"), where)
        assert.is_false(exists(r .. "/.gitignore"), where)
        run("RulesVault create " .. in_command(r) .. " --yes")
        assert.is_false(exists(r .. "/README.md"), where)
        assert.are.equal("i am a file", read_raw(r .. "/" .. where), where)
      end
    end)

    it("a folder below a file", function()
      write_raw(base .. "/a-file", "x")
      run("RulesVault create " .. in_command(base .. "/a-file/inner/vault") .. " --yes")
      assert.is_true(told("is a file, not a folder", vim.log.levels.ERROR))
      assert.is_false(exists(base .. "/a-file/inner"))
    end)

    it("a name too long for a file system, in the ruleset name and in the folder", function()
      ui(true)
      local long = ("a"):rep(300)
      run("RulesVault create " .. in_command(root) .. " " .. long)
      assert.is_true(told("is too long", vim.log.levels.ERROR))
      assert.are.same({}, asked)
      assert.is_true(nothing_made())

      notes = {}
      run("RulesVault create " .. in_command(base .. "/" .. long) .. " --yes")
      assert.is_true(told("is too long", vim.log.levels.ERROR))
      assert.is_false(exists(base .. "/" .. long))
      assert.is_false(told("ONE STEP IS LEFT"))

      -- the limit is 255 bytes a name: 255 fit, 256 do not (only the plan is made here, no path limit)
      local saved_limit = scaffold.PATH_LIMIT
      scaffold.PATH_LIMIT = nil
      local fits = scaffold.plan({ root = root, name = ("a"):rep(255) })
      local over, err = scaffold.plan({ root = root, name = ("a"):rep(256) })
      scaffold.PATH_LIMIT = saved_limit
      assert.is_truthy(fits)
      assert.is_nil(over)
      assert.is_truthy(err:find("256 bytes", 1, true))
    end)

    it("a path longer than the system takes", function()
      local saved_limit = scaffold.PATH_LIMIT
      scaffold.PATH_LIMIT = #root + 20
      local ok, err = pcall(run, "RulesVault create " .. in_command(root) .. " --yes")
      scaffold.PATH_LIMIT = saved_limit
      assert(ok, err)
      assert.is_true(told("path is too long", vim.log.levels.ERROR))
      assert.is_true(nothing_made())
    end)
  end)

  describe("the workflow template", function()
    local template = assert(read_raw(plugin_file("templates/rules-vault-ci.yml")))

    -- what the steps do when they run is TESTS/vault_ci_spec.lua; here: what the file says
    it("runs the checks, each as a step that turns the run red", function()
      assert.is_truthy(template:find("for ruleset in rulesets/*/", 1, true))
      assert.is_truthy(template:find("scripts/ruleset.lua catalog --check", 1, true))
      assert.is_truthy(template:find("scripts/ruleset.lua check --vault=.", 1, true))
      assert.is_truthy(template:find("scripts/roundtrip.lua rulesets/*/", 1, true))
      assert.is_truthy(template:find("eol=lf", 1, true))
      assert.is_truthy(template:find("set -euo pipefail", 1, true))
    end)

    it("needs no tool but Neovim and bash (the check was a jq step that no one ever ran)", function()
      assert.is_nil(template:find("jq ", 1, true))
      assert.is_nil(template:find("snapshot.json", 1, true))
    end)

    it("is a workflow: a name, the events, one job with its steps", function()
      assert.is_truthy(template:match("\nname: [^\n]+"))
      assert.is_truthy(template:match("\non:\n"))
      assert.is_truthy(template:match("\njobs:\n  rules:\n    name: [^\n]+\n    runs%-on: %${{ matrix%.os }}"))
      assert.is_truthy(template:find("os: [ubuntu-latest, windows-latest]", 1, true))
      assert.is_truthy(template:find("steps:", 1, true))
      assert.is_nil(template:find("\t", 1, true), "YAML is indented with blanks")
    end)

    it("only reads: it never pushes, publishes or reaches for a secret", function()
      for _, word in ipairs({ "git push", "git commit", "gh release", "gh pr", "secrets.", "npm publish", "contents: write" }) do
        assert.is_nil(template:find(word, 1, true), word)
      end
    end)
  end)
end)
