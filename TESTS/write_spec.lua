-- TESTS/write_spec.lua -- the editor's way to write: a request to `rules-ops/1`, the buffers looked after, the answer told.
---@diagnostic disable: need-check-nil
local write = require("rules.write")
local contract = require("rules.contract")

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

---@param id string
---@param severity string
---@param title string
---@param body string
---@return string
local function rule_file(id, severity, title, body)
  return table.concat({
    "---",
    "id: " .. id,
    "severity: " .. severity,
    "family: " .. id:match("^(%a+)%-"),
    "---",
    "",
    "#### `" .. id .. "` — " .. title,
    "",
    body,
    "",
  }, "\n")
end

local LAYOUT = table.concat({
  "---",
  "kind: layout",
  "output: regeln/DEP.md",
  "---",
  "# Dependencies",
  "",
  "## Core",
  "",
  "{{rule DEP-01}}",
  "",
  "## Extra",
  "",
  "{{rule DEP-02}}",
  "",
}, "\n")

---@return string root, table opts
local function fixture()
  local root = vim.fn.tempname() .. "/fixture/Checklists"
  write_raw(root .. "/_rules/DEP/DEP-01.md", rule_file("DEP-01", "recommended", "one", "Text of one."))
  write_raw(root .. "/_rules/DEP/DEP-02.md", rule_file("DEP-02", "critical", "two", "Text of two."))
  write_raw(root .. "/_layouts/regeln/DEP.md", LAYOUT)
  return root, { rulesets = { root }, today = "2026-10-14" }
end

---@param buf integer
---@return string
local function text_of(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

---@param messages { level: string, text: string }[]
---@return string
local function joined(messages)
  local out = {}
  for _, m in ipairs(messages) do
    out[#out + 1] = m.level .. ": " .. m.text
  end
  return table.concat(out, "\n")
end

describe("rules.write", function()
  local root, opts
  local origin

  -- a loaded buffer without a window: nothing to show, no syntax to load, no empty buffer left behind
  ---@param path string
  ---@return integer buf
  local function open(path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    return buf
  end

  -- the rule files are Markdown: their FileType would load a syntax that defines highlight groups, which the
  -- state guard counts as a leak of the spec
  local saved_ignore

  before_each(function()
    saved_ignore = vim.o.eventignore
    vim.o.eventignore = "FileType,Syntax"
    origin = vim.api.nvim_get_current_buf()
    root, opts = fixture()
    contract.clear_cache()
  end)

  after_each(function()
    vim.o.eventignore = saved_ignore
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if buf ~= origin then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end)

  local function rule_path(id)
    return assert(contract.view(opts).abs[id])
  end

  it("writes through the door and reloads the unmodified buffer of the changed file", function()
    local buf = open(rule_path("DEP-01"))
    local ops = { { op = "set", id = "DEP-01", patch = { severity = "critical" } } }
    local result = write.run(ops, { contract = opts })
    assert.is_true(result.ok)
    assert.are.equal("changed", result.entries[1].outcome)
    assert.is_truthy(read_raw(rule_path("DEP-01")):find("severity: critical", 1, true))
    assert.is_truthy(text_of(buf):find("severity: critical", 1, true))
    assert.is_false(vim.bo[buf].modified)
    assert.are.equal(1, #result.buffers.reloaded)
    assert.is_truthy(joined(write.messages(result, ops)):find("changed DEP-01", 1, true))
  end)

  it("reports a conflict when the buffer of the changed file has unsaved changes, and keeps the buffer", function()
    local buf = open(rule_path("DEP-01"))
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved first line" })
    local ops = { { op = "set", id = "DEP-01", patch = { severity = "critical" } } }
    local result = write.run(ops, { contract = opts })
    assert.is_true(result.ok)
    assert.are.equal(1, #result.buffers.conflicts)
    assert.are.equal("unsaved first line", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
    assert.is_true(vim.bo[buf].modified)
    local text = joined(write.messages(result, ops))
    assert.is_truthy(text:find("warn: ", 1, true))
    assert.is_truthy(text:find("unsaved changes", 1, true))
  end)

  it("reloads the generated document when the move rewrites it", function()
    local generated = root .. "/regeln/DEP.md"
    local first = write.run({ { op = "move", id = "DEP-02", section = "Core", layout = "regeln/DEP.md" } }, { contract = opts })
    assert.is_true(first.ok, vim.inspect(first.entries))
    local buf = open(generated)
    local before = text_of(buf)
    local back = write.run({ { op = "move", id = "DEP-02", section = "Extra", layout = "regeln/DEP.md" } }, { contract = opts })
    assert.is_true(back.ok, vim.inspect(back.entries))
    assert.are_not.equal(before, text_of(buf))
    assert.are.equal((read_raw(generated):gsub("\r", "")), text_of(buf) .. "\n")
  end)

  it("a dry run writes nothing, touches no buffer and shows the change as a diff", function()
    local buf = open(rule_path("DEP-01"))
    local before = read_raw(rule_path("DEP-01"))
    local lines_before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local ops = { { op = "set", id = "DEP-01", patch = { severity = "critical" } } }
    local result = write.run(ops, { contract = opts, dry = true })
    assert.is_true(result.ok)
    assert.are.equal("would_change", result.entries[1].outcome)
    -- no look at the buffers at all, and the one that is open is as it was
    assert.is_nil(result.buffers)
    assert.are.equal(before, read_raw(rule_path("DEP-01")))
    assert.are.same(lines_before, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.are.equal(tick, vim.api.nvim_buf_get_changedtick(buf))
    assert.is_false(vim.bo[buf].modified)
    local text = joined(write.messages(result, ops))
    assert.is_truthy(text:find("would change DEP-01", 1, true))
    assert.is_truthy(text:find("-severity: recommended", 1, true))
    assert.is_truthy(text:find("+severity: critical", 1, true))
  end)

  it("tells the refusal of the door word for word, as an error", function()
    local ops = { { op = "set", id = "NOPE-01", patch = { severity = "critical" } } }
    local result = write.run(ops, { contract = opts })
    assert.is_false(result.ok)
    local text = joined(write.messages(result, ops))
    assert.is_truthy(text:find("error: not_found: ", 1, true))
    local bad = write.run({ { op = "set", id = "DEP-01", patch = { severity = "urgent" } } }, { contract = opts })
    assert.is_truthy(bad.entries[1].error.message:find("severity must be one of", 1, true))
  end)

  it("answers an unusable request with the error of the contract and no entries", function()
    local result = write.run({ { op = "frobnicate" } }, { contract = opts })
    assert.is_false(result.ok)
    assert.is_table(result.err)
    assert.are.equal("invalid_argument", result.err.code)
    assert.are.same({}, result.entries)
    assert.is_truthy(joined(write.messages(result, {})):find("error: invalid_argument", 1, true))
  end)

  it("tells where a new rule was placed", function()
    local ops = { { op = "new", family = "DEP", title = "three", severity = "critical", after = "DEP-01" } }
    local result = write.run(ops, { contract = opts })
    assert.is_true(result.ok, vim.inspect(result.entries))
    assert.is_truthy(joined(write.messages(result, ops)):find("created DEP-03 in regeln/DEP.md", 1, true))
  end)

  it("tells a retired file's buffer and a buffer that could not be reloaded, as warnings", function()
    local result = {
      ok = true,
      entries = {},
      buffers = { reloaded = {}, conflicts = {}, gone = { "/a/DEP-01.md" }, stale = { "/a/DEP-02.md" } },
    }
    local text = joined(write.messages(result, {}))
    assert.is_truthy(text:find("warn: ", 1, true))
    assert.is_truthy(text:find("DEP-01.md is no longer there (retired)", 1, true))
    assert.is_truthy(text:find("DEP-02.md changed on disk and could not be reloaded", 1, true))
  end)

  it("cuts a long diff and says how much was cut", function()
    local long = {}
    for i = 1, 60 do
      long[#long + 1] = "line " .. i
    end
    local ops = { { op = "set", id = "DEP-01", patch = { text = table.concat(long, "\n") } } }
    local result = write.run(ops, { contract = opts, dry = true })
    local text = joined(write.messages(result, ops))
    assert.is_truthy(text:find("more line(s)", 1, true))
    assert.is_nil(text:find("line 60", 1, true))
  end)
end)
