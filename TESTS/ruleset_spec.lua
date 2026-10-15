-- TESTS/ruleset_spec.lua -- the headless tool `scripts/ruleset.lua`: what it does with its command line, and the exit
-- codes a CI job reads.
---@diagnostic disable: need-check-nil

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

local script =
  assert(vim.api.nvim_get_runtime_file("scripts/ruleset.lua", false)[1], "scripts/ruleset.lua is not on the runtimepath")
local lib_marker = assert(vim.api.nvim_get_runtime_file("lua/lib/nvim", false)[1], "lib.nvim is not on the runtimepath")
local lib_dir = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(lib_marker)))

--- Run the script as the command line does.
---@param ... string
---@return { code: integer, stdout: string, stderr: string }
local function run(...)
  local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", script, ... }
  local done = vim.system(cmd, { text = true, env = { LIB_NVIM_DIR = lib_dir } }):wait(60000)
  return { code = done.code, stdout = done.stdout or "", stderr = done.stderr or "" }
end

--- A ruleset with one layout whose document is out of date, and a legacy document.
---@return string root
local function ruleset()
  local root = tmp_dir()
  write(
    root .. "/_rules/DEP/DEP-01.md",
    doc({ "---", "id: DEP-01", "severity: critical", "family: DEP", "---", "", "#### `DEP-01`", "", "Text." })
  )
  write(root .. "/_layouts/D.md", doc({ "---", "kind: layout", "output: D.md", "---", "# D", "", "{{rule DEP-01}}" }))
  return root
end

-- @spawn: every case starts the script in its own nvim (the process net of testing.nvim lets a tagged case do that)
describe("scripts/ruleset.lua @spawn", function()
  it("exits 2 for a flag it does not know, and does nothing", function()
    local root = ruleset()
    for _, args in ipairs({
      { "catalog", "--chek", root },
      { "catalog", "--check=1", root },
      { "catalog", "--check=true", root },
      { "catalog", "--write", root },
      { "catalog", "--rules-dir=x", root },
      { "migrate", "--wirte", root },
      { "migrate", "--write=true", root },
      { "migrate", "--rules_dir=x", root },
      { "migrate", "--rules-dir", root },
      { "migrate", "--rules-dir=", root },
      { "migrate", "--layouts-dir", root },
      { "migrate", "--check", root },
      { "migrate", "--", root },
    }) do
      local result = run(unpack(args))
      assert.are.equal(2, result.code, table.concat(args, " "))
      assert.matches("usage:", result.stderr, 1, true)
    end
    assert.is_nil(read(root .. "/D.md"), "no document was written by a misspelt --check")
  end)

  it("exits 2 for a wrong command or the wrong number of folders", function()
    local root = ruleset()
    assert.are.equal(2, run().code)
    assert.are.equal(2, run("other", root).code)
    assert.are.equal(2, run("catalog").code)
    assert.are.equal(2, run("catalog", root, root).code)
  end)

  it("checks with --check: a stale document exits 1 and stays as it is", function()
    local root = ruleset()
    assert.are.equal(0, run("catalog", root).code, "the document is made")
    local made = read(root .. "/D.md")
    assert.is_truthy(made)
    assert.are.equal(0, run("catalog", "--check", root).code, "up to date")

    write(root .. "/D.md", made .. "edited by hand\n")
    local result = run("catalog", "--check", root)
    assert.are.equal(1, result.code)
    assert.matches("stale", result.stdout, 1, true)
    assert.are.equal(made .. "edited by hand\n", read(root .. "/D.md"), "--check writes nothing")

    assert.are.equal(0, run("catalog", root).code, "without --check it is written again")
    assert.are.equal(made, read(root .. "/D.md"))
  end)

  describe("check", function()
    ---@param root string
    ---@param id string
    ---@param severity? string
    local function rule(root, id, severity)
      write(
        root .. "/_rules/DEP/" .. id .. ".md",
        doc({
          "---",
          "id: " .. id,
          "severity: " .. (severity or "critical"),
          "family: DEP",
          "---",
          "",
          "#### `" .. id .. "`",
          "",
          "Text.",
        })
      )
    end

    it("is wrong usage with a flag it does not know, a second folder, or the flags of another command", function()
      local root = ruleset()
      for _, args in ipairs({
        { "check", "--chek", root },
        { "check", "--check", root },
        { "check", "--write", root },
        { "check", "--vault", root },
        { "check", root, root },
      }) do
        local result = run(unpack(args))
        assert.are.equal(2, result.code, table.concat(args, " "))
        assert.matches("usage:", result.stderr, 1, true)
      end
    end)

    it("exits 0 for rulesets that load, and says how many rules", function()
      local root = ruleset()
      local result = run("check", root)
      assert.are.equal(0, result.code, result.stdout .. result.stderr)
      assert.matches("1 rule(s) in 1 file(s), 1 family(ies), 1 ruleset(s)", result.stdout, 1, true)
      assert.matches("ok: every ruleset loads without errors", result.stdout, 1, true)
    end)

    it("exits 1 for a rule id that two files have, and names it", function()
      local root = ruleset()
      write(root .. "/_rules/DEP/DEP-01-twice.md", read(root .. "/_rules/DEP/DEP-01.md"))
      local result = run("check", root)
      assert.are.equal(1, result.code, result.stdout)
      assert.matches("duplicate rule id DEP-01", result.stdout, 1, true)
      assert.matches("FAILED: 1 load error(s)", result.stdout, 1, true)
    end)

    it("exits 1 for a rule id that two rulesets have, which each ruleset alone does not show", function()
      local vault = tmp_dir()
      local one, other = vault .. "/rulesets/one", vault .. "/rulesets/other"
      rule(one, "DEP-01")
      rule(other, "DEP-01")
      assert.are.equal(0, run("check", "--vault=" .. vault, one).code)
      assert.are.equal(0, run("check", "--vault=" .. vault, other).code)
      local both = run("check", "--vault=" .. vault)
      assert.are.equal(1, both.code, both.stdout .. both.stderr)
      assert.matches("duplicate rule id DEP-01", both.stdout, 1, true)
      assert.matches("2 ruleset(s)", both.stdout, 1, true)
    end)

    it("exits 1 for a severity that is none, and writes nothing", function()
      local vault = tmp_dir()
      local root = vault .. "/rulesets/one"
      rule(root, "DEP-01", "urgent")
      local before = read(root .. "/_rules/DEP/DEP-01.md")
      local result = run("check", "--vault=" .. vault)
      assert.are.equal(1, result.code, result.stdout)
      assert.matches("load error: ", result.stdout, 1, true)
      assert.are.equal(before, read(root .. "/_rules/DEP/DEP-01.md"))
    end)

    it("is exit 2 when there is nothing to check", function()
      local result = run("check", "--vault=" .. tmp_dir())
      assert.are.equal(2, result.code)
      assert.matches("no ruleset folder is configured", result.stderr, 1, true)
    end)

    describe("the ids of the retired rules", function()
      ---@param root string
      ---@param file string  below the ruleset
      ---@param id string
      local function put(root, file, id)
        write(
          root .. "/" .. file,
          doc({ "---", "id: " .. id, "severity: critical", "family: AAA", "---", "", "#### `" .. id .. "`", "", "Text." })
        )
      end

      ---No path of this machine in what the check prints: it goes into a CI log and a document that is committed.
      ---@param out string
      ---@param vault string
      local function assert_portable(out, vault)
        for _, path in ipairs({ vault, vim.uv.fs_realpath(vault) or vault, vim.fn.fnamemodify(vault, ":p") }) do
          assert.is_nil(out:find(vim.fs.normalize(path), 1, true), out)
        end
      end

      it("a live rule next to a retired one with its id fails the check, in one ruleset", function()
        -- two machines: one made AAA-05 and retired it, the other (no pull in between) made it again; git merged it
        local vault = tmp_dir()
        local root = vault .. "/rulesets/one"
        put(root, "_rules/AAA/AAA-05.md", "AAA-05")
        put(root, "_retired/AAA/AAA-05.md", "AAA-05")
        local result = run("check", "--vault=" .. vault)
        assert.are.equal(1, result.code, result.stdout .. result.stderr)
        assert.matches(
          "duplicate rule id AAA-05: one/_rules/AAA/AAA-05.md:7 and one/_retired/AAA/AAA-05.md",
          result.stdout,
          1,
          true
        )
        assert.matches("FAILED: 1 load error(s)", result.stdout, 1, true)
        assert.matches("1 rule(s) in 1 file(s)", result.stdout, 1, true)
        assert_portable(result.stdout, vault)
      end)

      it("and across the rulesets of the vault, which neither shows alone", function()
        local vault = tmp_dir()
        put(vault .. "/rulesets/one", "_rules/AAA/AAA-05.md", "AAA-05")
        put(vault .. "/rulesets/other", "_retired/AAA/AAA-05.md", "AAA-05")
        assert.are.equal(0, run("check", "--vault=" .. vault, vault .. "/rulesets/one").code)
        assert.are.equal(0, run("check", "--vault=" .. vault, vault .. "/rulesets/other").code)
        local result = run("check", "--vault=" .. vault)
        assert.are.equal(1, result.code, result.stdout .. result.stderr)
        assert.matches(
          "duplicate rule id AAA-05: one/_rules/AAA/AAA-05.md:7 and other/_retired/AAA/AAA-05.md",
          result.stdout,
          1,
          true
        )
        assert_portable(result.stdout, vault)
      end)

      it("a retired rule on its own passes, and so does the next id after it", function()
        local vault = tmp_dir()
        put(vault .. "/rulesets/one", "_rules/AAA/AAA-06.md", "AAA-06")
        put(vault .. "/rulesets/one", "_retired/AAA/AAA-05.md", "AAA-05")
        local result = run("check", "--vault=" .. vault)
        assert.are.equal(0, result.code, result.stdout .. result.stderr)
      end)

      it("a retired file that does not read fails the check", function()
        local vault = tmp_dir()
        put(vault .. "/rulesets/one", "_rules/AAA/AAA-06.md", "AAA-06")
        write(vault .. "/rulesets/one/_retired/AAA/AAA-05.md", "")
        local result = run("check", "--vault=" .. vault)
        assert.are.equal(1, result.code, result.stdout .. result.stderr)
        assert.matches("one/_retired/AAA/AAA-05.md: a retired rule needs a frontmatter", result.stdout, 1, true)
        assert_portable(result.stdout, vault)
      end)
    end)

    describe("a file under _rules/ that yields no rule", function()
      ---@return string vault
      local function vault_with(name, text)
        local vault = tmp_dir()
        rule(vault .. "/rulesets/one", "DEP-01")
        write(vault .. "/rulesets/one/_rules/" .. name, text)
        return vault
      end

      for label, text in pairs({
        ["an empty file"] = "",
        ["a file without a frontmatter"] = "#### `DEP-02`\n\nText.\n",
        ["a file that starts with merge-conflict markers"] = "<<<<<<< HEAD\n---\nid: DEP-02\n=======\n>>>>>>> x\n",
        ["a frontmatter without an id"] = "---\nfamily: DEP\n---\n\n#### `DEP-02`\n",
      }) do
        it(label .. " fails the check and the catalog check, and is named", function()
          local vault = vault_with("DEP/DEP-02.md", text)
          local result = run("check", "--vault=" .. vault)
          assert.are.equal(1, result.code, result.stdout .. result.stderr)
          assert.matches("one/_rules/DEP/DEP-02.md", result.stdout, 1, true)
          assert.matches("FAILED: 1 load error(s)", result.stdout, 1, true)
          local catalog = run("catalog", "--check", vault .. "/rulesets/one")
          assert.are.equal(1, catalog.code, catalog.stdout .. catalog.stderr)
          assert.matches("DEP-02.md", catalog.stdout, 1, true)
        end)
      end

      it("is no fault for the files that are no rule files: .gitkeep and README.md", function()
        local vault = vault_with("DEP/.gitkeep", "")
        write(vault .. "/rulesets/one/_rules/README.md", "# the rules\n")
        local result = run("check", "--vault=" .. vault)
        assert.are.equal(0, result.code, result.stdout .. result.stderr)
      end)
    end)
  end)

  describe("roundtrip", function()
    local roundtrip =
      assert(vim.api.nvim_get_runtime_file("scripts/roundtrip.lua", false)[1], "scripts/roundtrip.lua is not on the runtimepath")

    ---@param ... string
    ---@return { code: integer, stdout: string, stderr: string }
    local function round(...)
      local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", roundtrip, ... }
      local done = vim.system(cmd, { text = true, env = { LIB_NVIM_DIR = lib_dir } }):wait(60000)
      -- `print` of a headless nvim goes to stderr
      return { code = done.code, stdout = (done.stdout or "") .. (done.stderr or ""), stderr = "" }
    end

    it("is green for a ruleset in order", function()
      local result = round(ruleset())
      assert.are.equal(0, result.code, result.stdout .. result.stderr)
      assert.matches("rule files: 1, refused: 0, failed: 0", result.stdout, 1, true)
    end)

    for label, text in pairs({
      ["an empty file"] = "",
      ["a file without a frontmatter"] = "#### `DEP-02`\n\nText.\n",
      ["a file that starts with merge-conflict markers"] = "<<<<<<< HEAD\n=======\n>>>>>>> x\n",
    }) do
      it("fails for " .. label .. " under _rules/, and names the file", function()
        local root = ruleset()
        write(root .. "/_rules/DEP/DEP-02.md", text)
        local result = round(root)
        assert.are.equal(1, result.code, result.stdout .. result.stderr)
        assert.matches("FAILED: load error: ", result.stdout, 1, true)
        assert.matches("DEP-02.md", result.stdout, 1, true)
        assert.matches("failed: 1", result.stdout, 1, true)
      end)
    end

    it("fails for a live rule next to a retired one with its id", function()
      local root = ruleset()
      write(root .. "/_retired/DEP/DEP-01.md", read(root .. "/_rules/DEP/DEP-01.md"))
      local result = round(root)
      assert.are.equal(1, result.code, result.stdout .. result.stderr)
      assert.matches("duplicate rule id DEP-01", result.stdout, 1, true)
    end)
  end)

  it("takes the folder flags of migrate with a value", function()
    local root = tmp_dir()
    write(
      root .. "/regeln/DOC.md",
      doc({ "#### `A-1`", "", "```rule", 'id = "A-1",', 'severity = "critical",', "```", "", "Text." })
    )
    local only_look = run("migrate", "--rules-dir=src/rules", "--layouts-dir=src/layouts", root)
    assert.are.equal(0, only_look.code)
    assert.matches("nothing written", only_look.stdout, 1, true)
    assert.is_nil(read(root .. "/src/rules/A/A-1.md"))

    local done = run("migrate", "--write", "--rules-dir=src/rules", "--layouts-dir=src/layouts", root)
    assert.are.equal(0, done.code, done.stdout)
    assert.is_truthy(read(root .. "/src/rules/A/A-1.md"))
    assert.is_truthy(read(root .. "/src/layouts/regeln/DOC.md"))
  end)

  it("exits 1 for a folder that is none, and for a folder name that leads out", function()
    local root = tmp_dir()
    local missing = run("migrate", root .. "/not/there")
    assert.are.equal(1, missing.code)
    assert.matches("is not a directory", missing.stdout, 1, true)
    assert.are.equal(1, run("migrate", "--layouts-dir=../lay", root).code)
  end)

  it("names a refused document as refused", function()
    local root = tmp_dir()
    write(root .. "/BAD.md", doc({ "#### `A-1`", "```rule", 'id = "A-1",', 'severity = "critical",', "```", "t" }))
    local result = run("migrate", root)
    assert.are.equal(1, result.code)
    assert.matches("BAD.md%s+refused", result.stdout)
    assert.matches("problem: ", result.stdout, 1, true)
  end)
end)
