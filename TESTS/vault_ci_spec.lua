-- TESTS/vault_ci_spec.lua -- the CI workflow of a rules-vault (templates/rules-vault-ci.yml): its commands are run, as
-- written, against small vaults. Green on a clean vault, red on each of the faults the CI is there to catch.
--
-- The `run:` blocks of the template are taken out of the file and run with bash in the folder of a fixture vault, with
-- `nvim` and `.deps/rules.nvim` pointing at this editor and this plugin: what is proved is the text of the template,
-- not a copy of it. A second look at the real rulesets (571 rules, too slow and too big for a spec) is opt-in:
--
--   RULES_REAL_LUA=<Checklists of wkdbook-Lua> RULES_REAL_NATIVE=<Checklists of wkdbook-native> \
--     nvim -n -i NONE --headless -u NONE -l <testing.nvim>/scripts/testing.lua run . --file vault_ci
--
-- (PowerShell: set `$env:RULES_REAL_LUA` and `$env:RULES_REAL_NATIVE` first.) The two folders are copied to a temporary
-- vault (`rulesets/lua`, `rulesets/native`) before anything runs; nothing is ever written into them.
---@diagnostic disable: need-check-nil
local catalog = require("rules.engine.catalog")
local fswalk = require("rules.engine.fswalk")

---@return string
local function tmp_dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return (path:gsub("\\", "/"))
end

---@param path string
---@param text string
local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param path string
---@return string|nil
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

---@param lines string[]
---@return string
local function doc(lines)
  return table.concat(lines, "\n") .. "\n"
end

local plugin_root = vim.fs.dirname(
  vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(vim.api.nvim_get_runtime_file("lua/rules/contract.lua", false)[1])))
)
local lib_marker = assert(vim.api.nvim_get_runtime_file("lua/lib/nvim", false)[1], "lib.nvim is not on the runtimepath")
local lib_dir = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(lib_marker)))
local TEMPLATE = plugin_root .. "/templates/rules-vault-ci.yml"

---The bash the workflow runs in: the bash of Git on Windows (the first `bash` there may be the one of WSL), else `bash`.
---@return string|nil
local function find_bash()
  if vim.fn.has("win32") ~= 1 then
    local found = vim.fn.exepath("bash")
    return found ~= "" and found or nil
  end
  local git = vim.fn.exepath("git")
  if git == "" then
    return nil
  end
  local top = vim.fs.dirname(vim.fs.normalize(git))
  for _ = 1, 3 do
    top = vim.fs.dirname(top)
    for _, rel in ipairs({ "/bin/bash.exe", "/usr/bin/bash.exe" }) do
      if (vim.uv or vim.loop).fs_stat(top .. rel) then
        return top .. rel
      end
    end
  end
  return nil
end

---The steps of the template that run a script: `{ name, script }`, in the order of the file.
---@param template string
---@return { name: string, script: string }[]
local function steps_of(template)
  local out, name = {}, nil
  local lines = vim.split(template, "\n", { plain = true })
  local i = 1
  while i <= #lines do
    local line = lines[i]
    local step = line:match("^      %- name: (.+)$")
    if step then
      name = step
    elseif line:match("^      %- uses:") then
      name = nil
    end
    if line:match("^        run: |%s*$") then
      local body = {}
      i = i + 1
      while i <= #lines and (lines[i] == "" or lines[i]:match("^          ")) do
        body[#body + 1] = lines[i]:sub(11)
        i = i + 1
      end
      out[#out + 1] = { name = name or "?", script = table.concat(body, "\n") .. "\n" }
    else
      i = i + 1
    end
  end
  return out
end

---@param script string
---@return string
local function for_here(script)
  local nvim = "'" .. vim.fs.normalize(vim.v.progpath) .. "' --headless"
  script = script:gsub("nvim %-%-headless", function()
    return nvim
  end)
  script = script:gsub("%.deps/rules%.nvim/", function()
    return "'" .. plugin_root .. "'/"
  end)
  return script
end

---@class VaultCiStep
---@field name string
---@field code integer
---@field out string

---Run the steps of the template in `vault`, each on its own (the CI stops at the first red step; here every step is
---asked, to see which ones turn red).
---@param vault string
---@param template? string
---@return VaultCiStep[] steps
---@return table<string, VaultCiStep> by_name
local function run_template(vault, template)
  local bash = assert(find_bash(), "no bash")
  local steps, by_name = {}, {}
  for _, step in ipairs(steps_of(template or assert(read(TEMPLATE)))) do
    local done = vim
      .system({ bash, "-c", for_here(step.script) }, { cwd = vault, text = true, env = { LIB_NVIM_DIR = lib_dir } })
      :wait(120000)
    local result = { name = step.name, code = done.code, out = (done.stdout or "") .. (done.stderr or "") }
    steps[#steps + 1] = result
    by_name[step.name] = result
  end
  return steps, by_name
end

---@param steps VaultCiStep[]
---@return string[]
local function red(steps)
  local out = {}
  for _, step in ipairs(steps) do
    if step.code ~= 0 then
      out[#out + 1] = step.name
    end
  end
  return out
end

local LINE_ENDINGS = "The checked-out rule files have LF line endings (no CR)"
local DOCUMENTS = "The reading documents are up to date (catalog --check, every ruleset)"
local LOADS = "Every ruleset loads without errors (duplicate id, invalid severity)"
local ROUND_TRIP = "Writing keeps the rule files byte for byte (round trip)"

---@param id string
---@param severity? string
---@return string
local function rule_text(id, severity)
  return doc({
    "---",
    "id: " .. id,
    "severity: " .. (severity or "critical"),
    "family: " .. id:match("^(%u+)"),
    "---",
    "",
    "#### `" .. id .. "`",
    "",
    "The text of " .. id .. ".",
  })
end

---A ruleset of one family with its layout and the document made from it.
---@param root string  the vault
---@param name string
---@param family string
---@param ids string[]
local function ruleset(root, name, family, ids)
  local dir = root .. "/rulesets/" .. name
  local layout = { "---", "kind: layout", "output: " .. family .. ".md", "---", "# " .. family, "" }
  for _, id in ipairs(ids) do
    write(("%s/_rules/%s/%s.md"):format(dir, family, id), rule_text(id))
    layout[#layout + 1] = "{{rule " .. id .. "}}"
    layout[#layout + 1] = ""
  end
  write(dir .. "/_layouts/" .. family .. ".md", doc(layout))
  local results, load_errors = catalog.build(dir)
  assert(#load_errors == 0, table.concat(load_errors, "; "))
  assert(results[1] and results[1].status == "written", "the document of " .. name .. " is made")
end

---A vault of two rulesets (as the real one is arranged), in good order.
---@return string root
local function make_vault()
  local root = tmp_dir()
  write(root .. "/.gitattributes", "* text=auto eol=lf\n")
  write(root .. "/.rules.json", '{ "rulesets": ["rulesets/lua", "rulesets/native"], "gates": {} }\n')
  ruleset(root, "lua", "DEP", { "DEP-01", "DEP-02" })
  ruleset(root, "native", "NAT", { "NAT-01" })
  return root
end

describe("the CI template of a rules-vault @spawn", function()
  local template = assert(read(TEMPLATE))

  if not find_bash() then
    it("needs a bash", function()
      pending("no bash to run the workflow's steps in")
    end)
    return
  end

  it("takes the steps out of the file: the four of the workflow, in order", function()
    local names = {}
    for _, step in ipairs(steps_of(template)) do
      names[#names + 1] = step.name
    end
    assert.are.same({ LINE_ENDINGS, DOCUMENTS, LOADS, ROUND_TRIP }, names)
  end)

  describe("a vault in good order", function()
    it("is green in every step, on both rulesets", function()
      local steps, by_name = run_template(make_vault())
      assert.are.same({}, red(steps), vim.inspect(steps))
      assert.is_truthy(by_name[DOCUMENTS].out:find("rulesets/lua", 1, true))
      assert.is_truthy(by_name[DOCUMENTS].out:find("rulesets/native", 1, true))
      assert.is_truthy(by_name[LOADS].out:find("3 rule(s) in 3 file(s), 2 family(ies), 2 ruleset(s)", 1, true))
      assert.is_truthy(by_name[LOADS].out:find("ok: every ruleset loads without errors", 1, true))
      assert.is_truthy(by_name[ROUND_TRIP].out:find("rule files: 3, refused: 0, failed: 0", 1, true))
    end)

    it("is green for a vault with a ruleset that has no rule yet (what :RulesVault create makes)", function()
      local root = tmp_dir()
      write(root .. "/.gitattributes", "* text=auto eol=lf\n")
      write(root .. "/rulesets/default/_rules/.gitkeep", "")
      write(root .. "/rulesets/default/_layouts/.gitkeep", "")
      local steps, by_name = run_template(root)
      assert.are.same({}, red(steps), vim.inspect(steps))
      assert.is_truthy(by_name[LOADS].out:find("0 rule(s)", 1, true))
    end)

    it("is green for the vault `:RulesVault create` really makes, in all four steps", function()
      local scaffold = require("rules.vault_scaffold")
      local root = tmp_dir() .. "/vault"
      local plan = assert(scaffold.plan({ root = root, name = "default" }))
      assert(scaffold.create(plan))
      assert.is_truthy(read(root .. "/rulesets/default/_rules/.gitkeep"))
      local steps, by_name = run_template(root)
      assert.are.same({}, red(steps), vim.inspect(steps))
      assert.are.equal(4, #steps)
      assert.is_truthy(by_name[LOADS].out:find("0 rule(s) in 0 file(s), 0 family(ies), 1 ruleset(s)", 1, true))
      assert.is_truthy(by_name[ROUND_TRIP].out:find("rule files: 0, refused: 0, failed: 0", 1, true))
    end)

    it("is green for a rule made in that vault, and red once the rule is retired and made again", function()
      local scaffold = require("rules.vault_scaffold")
      local root = tmp_dir() .. "/vault"
      assert(scaffold.create(assert(scaffold.plan({ root = root, name = "default" }))))
      write(root .. "/rulesets/default/_rules/AAA/AAA-01.md", rule_text("AAA-01"))
      assert.are.same({}, red((run_template(root))))
      write(root .. "/rulesets/default/_retired/AAA/AAA-01.md", rule_text("AAA-01"))
      assert.is_truthy(vim.tbl_contains(red((run_template(root))), LOADS))
    end)
  end)

  describe("turns red", function()
    it("for a rule id that two files have, in one ruleset", function()
      local root = make_vault()
      write(root .. "/rulesets/lua/_rules/DEP/DEP-01-from-another-machine.md", rule_text("DEP-01"))
      local steps, by_name = run_template(root)
      assert.is_truthy(vim.tbl_contains(red(steps), LOADS), vim.inspect(steps))
      assert.is_truthy(by_name[LOADS].out:find("duplicate rule id DEP-01", 1, true))
      assert.is_truthy(by_name[LOADS].out:find("FAILED: 1 load error(s)", 1, true))
    end)

    it("for a rule id that two rulesets have: only the load step sees it", function()
      local root = make_vault()
      write(root .. "/rulesets/native/_rules/DEP/DEP-02.md", rule_text("DEP-02"))
      local steps, by_name = run_template(root)
      -- each ruleset alone is in order: the documents and the round trip do not see the clash
      assert.are.same({ LOADS }, red(steps), vim.inspect(steps))
      assert.is_truthy(by_name[LOADS].out:find("duplicate rule id DEP-02", 1, true))
    end)

    it("for a live rule next to a retired rule with its id, in one ruleset (two machines, no conflict in git)", function()
      -- machine A made AAA-05 and retired it; machine B did not pull and made AAA-05 again: git merges both
      local root = make_vault()
      write(root .. "/rulesets/lua/_rules/AAA/AAA-05.md", rule_text("AAA-05"))
      write(root .. "/rulesets/lua/_retired/AAA/AAA-05.md", rule_text("AAA-05"))
      local steps, by_name = run_template(root)
      assert.is_truthy(vim.tbl_contains(red(steps), LOADS), vim.inspect(steps))
      assert.is_truthy(by_name[LOADS].out:find("duplicate rule id AAA-05: ", 1, true), by_name[LOADS].out)
      assert.is_truthy(by_name[LOADS].out:find("lua/_retired/AAA/AAA-05.md (retired)", 1, true), by_name[LOADS].out)
      assert.is_truthy(by_name[LOADS].out:find("FAILED: 1 load error(s)", 1, true))
    end)

    it("for a live rule next to a retired one in another ruleset: only the load step sees it", function()
      local root = make_vault()
      write(root .. "/rulesets/native/_retired/DEP/DEP-02.md", rule_text("DEP-02"))
      local steps, by_name = run_template(root)
      assert.are.same({ LOADS }, red(steps), vim.inspect(steps))
      assert.is_truthy(by_name[LOADS].out:find("duplicate rule id DEP-02", 1, true))
    end)

    it("for a file under _rules/ that yields no rule: empty, no frontmatter, merge-conflict markers", function()
      for label, text in pairs({
        empty = "",
        ["no frontmatter"] = "#### `DEP-03`\n\nText.\n",
        ["conflict markers"] = "<<<<<<< HEAD\n" .. rule_text("DEP-03") .. "=======\n" .. rule_text("DEP-03") .. ">>>>>>> b\n",
      }) do
        local root = make_vault()
        write(root .. "/rulesets/lua/_rules/DEP/DEP-03.md", text)
        local steps, by_name = run_template(root)
        assert.is_truthy(vim.tbl_contains(red(steps), LOADS), label .. ": " .. vim.inspect(steps))
        assert.is_truthy(by_name[LOADS].out:find("DEP-03.md", 1, true), label)
        -- the reading documents and the round trip refuse it as well: none of the three is green on a rotten file
        assert.is_truthy(vim.tbl_contains(red(steps), DOCUMENTS), label .. ": " .. vim.inspect(steps))
        assert.is_truthy(vim.tbl_contains(red(steps), ROUND_TRIP), label .. ": " .. vim.inspect(steps))
      end
    end)

    it("is no fault for a README.md or a .gitkeep in _rules/, nor for a note in a folder of its own", function()
      local root = make_vault()
      write(root .. "/rulesets/lua/_rules/README.md", "# the rules\n")
      write(root .. "/rulesets/lua/_rules/DEP/.gitkeep", "")
      write(root .. "/rulesets/lua/notes/todo.md", "# todo\n")
      write(root .. "/rulesets/lua/_retired/.gitkeep", "")
      local steps = run_template(root)
      assert.are.same({}, red(steps), vim.inspect(steps))
    end)

    it("for a severity that is none", function()
      local root = make_vault()
      write(root .. "/rulesets/lua/_rules/DEP/DEP-02.md", rule_text("DEP-02", "urgent"))
      local steps, by_name = run_template(root)
      assert.is_truthy(vim.tbl_contains(red(steps), LOADS), vim.inspect(steps))
      assert.is_truthy(by_name[LOADS].out:find("load error: ", 1, true))
    end)

    it("for a reading document that is not the one the layout makes", function()
      local root = make_vault()
      local path = root .. "/rulesets/lua/DEP.md"
      write(path, assert(read(path)) .. "edited by hand\n")
      local steps, by_name = run_template(root)
      assert.is_truthy(vim.tbl_contains(red(steps), DOCUMENTS), vim.inspect(steps))
      assert.is_truthy(by_name[DOCUMENTS].out:find("stale", 1, true))
    end)

    it("for a CRLF file in the work tree, whatever the .gitattributes says", function()
      local root = make_vault()
      local path = root .. "/rulesets/lua/_rules/DEP/DEP-01.md"
      write(path, (assert(read(path)):gsub("\n", "\r\n")))
      local steps, by_name = run_template(root)
      assert.is_truthy(vim.tbl_contains(red(steps), LINE_ENDINGS), vim.inspect(steps))
      assert.is_truthy(by_name[LINE_ENDINGS].out:find("DEP-01.md", 1, true), by_name[LINE_ENDINGS].out)
      assert.is_truthy(by_name[LINE_ENDINGS].out:find("CRLF", 1, true))
    end)

    it("for a layout or a reading document with CRLF, not only for a rule file", function()
      for _, rel in ipairs({ "/rulesets/lua/_layouts/DEP.md", "/rulesets/lua/DEP.md" }) do
        local root = make_vault()
        write(root .. rel, (assert(read(root .. rel)):gsub("\n", "\r\n")))
        assert.is_truthy(vim.tbl_contains(red((run_template(root))), LINE_ENDINGS), rel)
      end
    end)

    it("for a folder `rulesets/` that is not there", function()
      local root = tmp_dir()
      write(root .. "/.gitattributes", "* text=auto eol=lf\n")
      local steps = run_template(root)
      assert.is_truthy(#red(steps) >= 2, vim.inspect(steps))
      assert.is_truthy(vim.tbl_contains(red(steps), LINE_ENDINGS), "an unreadable folder is not a clean checkout")
    end)

    -- the real thing: a repository checked out by a git that turns LF into CRLF (a Windows runner's default), with the
    -- `.gitattributes` the vault has. What the step looks at is the checkout, so what the attributes say only counts
    -- when it takes effect
    describe("in a real checkout (core.autocrlf=true, as on a Windows runner)", function()
      if vim.fn.exepath("git") == "" then
        it("needs git", function()
          pending("no git to make a checkout with")
        end)
        return
      end

      ---@param cwd string
      ---@param ... string
      local function git(cwd, ...)
        local cmd = { "git", "-c", "user.name=spec", "-c", "user.email=spec@example.com", "-c", "commit.gpgsign=false", ... }
        local done = vim.system(cmd, { cwd = cwd, text = true }):wait(60000)
        assert(done.code == 0, table.concat(cmd, " ") .. ": " .. (done.stderr or ""))
      end

      ---A vault committed with `gitattributes` (nil: none), and a checkout of it that git converts to CRLF if it may.
      ---@param gitattributes string|nil
      ---@return string checkout
      local function checkout(gitattributes)
        local source = make_vault()
        os.remove(source .. "/.gitattributes")
        if gitattributes then
          write(source .. "/.gitattributes", gitattributes)
        end
        git(source, "init", "-q")
        git(source, "-c", "core.autocrlf=false", "add", "-A")
        git(source, "-c", "core.autocrlf=false", "commit", "-q", "-m", "vault")
        local target = tmp_dir() .. "/vault"
        git(vim.fs.dirname(target), "-c", "core.autocrlf=true", "clone", "-q", "--no-hardlinks", source, target)
        return target
      end

      it("is green when the .gitattributes keeps LF (`* text=auto eol=lf`)", function()
        local steps = run_template(checkout("* text=auto eol=lf\n"))
        assert.are.same({}, red(steps), vim.inspect(steps))
      end)

      it("is red when the only eol=lf is a comment: the checkout is CRLF", function()
        local steps = run_template(checkout("# * text=auto eol=lf\n"))
        assert.is_truthy(vim.tbl_contains(red(steps), LINE_ENDINGS), vim.inspect(steps))
      end)

      it("is red when eol=lf is there for other files only (`*.png eol=lf`)", function()
        local steps = run_template(checkout("*.png eol=lf\n"))
        assert.is_truthy(vim.tbl_contains(red(steps), LINE_ENDINGS), vim.inspect(steps))
      end)

      it("is red without a .gitattributes", function()
        local steps = run_template(checkout(nil))
        assert.is_truthy(vim.tbl_contains(red(steps), LINE_ENDINGS), vim.inspect(steps))
      end)
    end)
  end)

  describe("only reads", function()
    it("leaves every file of the vault as it was, whatever the verdict", function()
      local root = make_vault()
      write(root .. "/rulesets/native/_rules/DEP/DEP-02.md", rule_text("DEP-02"))
      local function snapshot()
        local out = {}
        for _, file in ipairs(fswalk.files(root)) do
          out[file:sub(#root + 2)] = read(file)
        end
        return out
      end
      local before = snapshot()
      run_template(root)
      assert.are.same(before, snapshot())
    end)
  end)

  -- opt-in: the real rulesets of the WKDBooks, copied into a vault; see the header of this file
  describe("the real rulesets", function()
    local lua_dir, native_dir = vim.env.RULES_REAL_LUA, vim.env.RULES_REAL_NATIVE
    local have = lua_dir and lua_dir ~= "" and native_dir and native_dir ~= ""

    ---@param from string
    ---@param to string
    local function copy_tree(from, to)
      from = (from:gsub("\\", "/")):gsub("/+$", "")
      for _, file in ipairs(fswalk.files(from)) do
        local dest = to .. "/" .. file:sub(#from + 2)
        vim.fn.mkdir(vim.fs.dirname(dest), "p")
        assert((vim.uv or vim.loop).fs_copyfile(file, dest), "could not copy " .. file)
      end
    end

    -- no case without the two folders: a skipped case would turn every ordinary run into a "partial" one
    if not have then
      return
    end

    it("are green in every step, and red once an id is made twice", function()
      local root = tmp_dir()
      write(root .. "/.gitattributes", "* text=auto eol=lf\n")
      copy_tree(lua_dir, root .. "/rulesets/lua")
      copy_tree(native_dir, root .. "/rulesets/native")
      local steps, by_name = run_template(root)
      assert.are.same({}, red(steps), vim.inspect(steps))
      print(
        ("real rulesets: %s | %s"):format(
          vim.trim(by_name[LOADS].out:match("[^\n]*rule%(s%)[^\n]*") or "?"),
          (by_name[ROUND_TRIP].out:match("rule files:[^\n]*") or "?")
        )
      )

      -- the same vault with one id made a second time, the way a second machine would
      local first = vim.fn.glob(root .. "/rulesets/lua/_rules/*/*.md", false, true)[1]
      local text = assert(read(first))
      local id = assert(text:match("\nid:%s*(%S+)"))
      write(root .. "/rulesets/native/_rules/ZZZ/" .. id .. ".md", text)
      local again = run_template(root)
      assert.is_truthy(vim.tbl_contains(red(again), LOADS), vim.inspect(again))
    end)
  end)
end)
