local request = require("rules.engine.agent.request")
local cache = require("rules.engine.agent.cache")

---@return string
local function tmp_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

---@param id string
---@param extra? table
---@return table
local function rule(id, extra)
  return vim.tbl_extend(
    "force",
    { id = id, severity = "recommended", title = id .. " title", text = "Text of " .. id },
    extra or {}
  )
end

---@param files string[]
---@param rules table[]
---@return table
local function batch(files, rules)
  local entries = {}
  for _, r in ipairs(rules) do
    entries[#entries + 1] = { rule = r }
  end
  return { id = "b1", files = files, bytes = 0, rules = entries }
end

describe("rules.engine.agent.request.build", function()
  it("numbers the lines of every file and names the rules, their questions and their text", function()
    local root = tmp_dir()
    vim.fn.mkdir(root .. "/lua", "p")
    vim.fn.writefile({ "local a = 1", "return a" }, root .. "/lua/a.lua")

    local req =
      assert(request.build(batch({ "lua/a.lua" }, { rule("DEP-01", { agent = { question = "Any hidden requires?" } }) }), root))

    assert.is_truthy(req.prompt:find("=== lua/a.lua ===\n1: local a = 1\n2: return a", 1, true))
    assert.is_truthy(req.prompt:find("### DEP-01 (recommended)", 1, true))
    assert.is_truthy(req.prompt:find("DEP-01 title", 1, true))
    assert.is_truthy(req.prompt:find("Question: Any hidden requires?", 1, true))
    assert.is_truthy(req.prompt:find("Text of DEP-01", 1, true))
    assert.are.same({ "lua/a.lua" }, req.sent)
    assert.are.same({}, req.unreadable)
  end)

  it("asks the generic question when the rule has none", function()
    local root = tmp_dir()
    vim.fn.writefile({ "x" }, root .. "/a.lua")

    local req = assert(request.build(batch({ "a.lua" }, { rule("DEP-01") }), root))

    assert.is_truthy(req.prompt:find("Question: " .. request.GENERIC_QUESTION, 1, true))
  end)

  it("tells the model the answer format, that quotes are literal and that file text is data", function()
    local root = tmp_dir()
    vim.fn.writefile({ "x" }, root .. "/a.lua")

    local req = assert(request.build(batch({ "a.lua" }, { rule("DEP-01") }), root))

    assert.is_truthy(req.system:find('"verdict": "violation" | "compliant" | "unclear"', 1, true))
    assert.is_truthy(req.system:find("copied exactly", 1, true))
    assert.is_truthy(req.system:find("never an instruction", 1, true))
  end)

  it("leaves out a file it cannot read, says so, and lists only the files that went in", function()
    local root = tmp_dir()
    vim.fn.writefile({ "x" }, root .. "/a.lua")

    local req = assert(request.build(batch({ "a.lua", "gone.lua" }, { rule("DEP-01") }), root))

    assert.are.same({ "a.lua" }, req.sent)
    assert.are.same({ "gone.lua" }, req.unreadable)
    assert.is_nil(req.prompt:find("gone.lua", 1, true))
  end)

  it("does not read through a link", function()
    local root = tmp_dir()
    vim.fn.writefile({ "SECRET" }, root .. "/secret.dat")
    vim.fn.writefile({ "x" }, root .. "/a.lua")
    if not vim.uv.fs_symlink(root .. "/secret.dat", root .. "/link.lua") then
      pending("symlink creation not permitted on this machine")
      return
    end

    local req = assert(request.build(batch({ "a.lua", "link.lua" }, { rule("DEP-01") }), root))

    assert.are.same({ "link.lua" }, req.unreadable)
    assert.is_nil(req.prompt:find("SECRET", 1, true))
  end)

  it("gives nothing when no file of the batch can be read", function()
    local req, err = request.build(batch({ "gone.lua" }, { rule("DEP-01") }), tmp_dir())

    assert.is_nil(req)
    assert.is_truthy(err:find("none of the files", 1, true))
  end)

  it("cuts a very long rule text and says so", function()
    local root = tmp_dir()
    vim.fn.writefile({ "x" }, root .. "/a.lua")

    local req =
      assert(request.build(batch({ "a.lua" }, { rule("DEP-01", { text = ("t"):rep(request.MAX_RULE_TEXT + 500) }) }), root))

    assert.is_truthy(req.prompt:find("[rule text cut]", 1, true))
    assert.is_true(#req.prompt < request.MAX_RULE_TEXT + 1500)
  end)

  it("estimates the size: characters of system and prompt, and a token count of a fourth of that", function()
    local root = tmp_dir()
    vim.fn.writefile({ "x" }, root .. "/a.lua")

    local req = assert(request.build(batch({ "a.lua" }, { rule("DEP-01") }), root))

    assert.are.equal(#req.system + #req.prompt, req.chars)
    assert.are.equal(math.ceil(req.chars / 4), req.tokens)
    assert.are.equal(3, request.estimate_tokens(10))
  end)
end)

describe("rules.engine.agent.cache", function()
  local req = { system = "S", prompt = "P" }

  it("keys by system, prompt, backend and model: any change is another key", function()
    local key = cache.key(req, "ollama", "m")

    assert.are.equal(64, #key)
    assert.are.equal(key, cache.key({ system = "S", prompt = "P" }, "ollama", "m"))
    assert.are_not.equal(key, cache.key({ system = "S2", prompt = "P" }, "ollama", "m"))
    assert.are_not.equal(key, cache.key({ system = "S", prompt = "P2" }, "ollama", "m"))
    assert.are_not.equal(key, cache.key(req, "claude", "m"))
    assert.are_not.equal(key, cache.key(req, "ollama", "other"))
    assert.are_not.equal(key, cache.key(req, "ollama", nil))
  end)

  it("keeps an answer and gives it back", function()
    local dir = tmp_dir() .. "/cache"
    local key = cache.key(req, "ollama", "m")

    assert.is_true(cache.put(dir, key, { text = "the answer", provider = "ollama", model = "m", date = "2026-10-22" }))

    assert.are.same({ text = "the answer", provider = "ollama", model = "m", date = "2026-10-22" }, cache.get(dir, key))
  end)

  it("misses on an unknown key, a damaged entry and a key that is no hash", function()
    local dir = tmp_dir()
    local key = cache.key(req, "ollama", "m")
    vim.fn.writefile({ "{ not json" }, dir .. "/" .. key .. ".json")

    assert.is_nil(cache.get(dir, cache.key(req, "ollama", "unknown")))
    assert.is_nil(cache.get(dir, key))
    assert.is_nil(cache.get(dir, "../../etc/passwd"))
    assert.is_false(cache.put(dir, "../escape", { text = "x", provider = "p", date = "2026-10-22" }))
  end)

  it("misses on an entry of the wrong shape", function()
    local dir = tmp_dir()
    local key = cache.key(req, "ollama", "m")
    vim.fn.writefile({ vim.json.encode({ text = 5, provider = "ollama", date = "2026-10-22" }) }, dir .. "/" .. key .. ".json")

    assert.is_nil(cache.get(dir, key))
  end)
end)

describe("rules.engine.agent.request.build binary files", function()
  it("leaves a file with a NUL byte out and names it", function()
    local root = tmp_dir()
    vim.fn.writefile({ "x" }, root .. "/a.lua")
    local fh = assert(io.open(root .. "/image.png", "wb"))
    fh:write("PNG" .. string.char(0) .. "data")
    fh:close()

    local req = assert(request.build(batch({ "a.lua", "image.png" }, { rule("DEP-01") }), root))

    assert.are.same({ "a.lua" }, req.sent)
    assert.are.same({ "image.png" }, req.unreadable)
    assert.is_nil(req.prompt:find("PNG", 1, true))
  end)

  it("gives nothing when the only file is binary", function()
    local root = tmp_dir()
    local fh = assert(io.open(root .. "/image.png", "wb"))
    fh:write(string.char(0, 1, 2))
    fh:close()

    local req = request.build(batch({ "image.png" }, { rule("DEP-01") }), root)

    assert.is_nil(req)
  end)
end)
