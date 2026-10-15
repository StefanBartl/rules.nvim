-- TESTS/ops_layout_spec.lua -- what `new`, `retire`, `reinstate` and `move` do to a layout: the token goes where it is
-- asked to, outside fences and comments, and an undo gives the layout back byte for byte.
---@diagnostic disable: need-check-nil
local layout_edit = require("rules.engine.layout_edit")
local json = require("lib.nvim.json.canonical")
local ops = require("rules.ops")

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

---@param lines string[]
---@return string
local function doc(lines)
  return table.concat(lines, "\n") .. "\n"
end

---@param id string
---@return string
local function rule_file(id)
  return doc({
    "---",
    "id: " .. id,
    "severity: recommended",
    "family: " .. id:match("^(%a+)%-"),
    "---",
    "",
    "#### `" .. id .. "` — title of " .. id,
    "",
    "Text of " .. id .. ".",
    "",
    "---",
    "",
  })
end

---A ruleset with the rules DEP-01 to DEP-04 and one layout (regeln/DEP.md) of the given lines.
---@param layout string[]
---@return string root, table opts, string layout_path
local function fixture(layout)
  local base = vim.fn.tempname()
  local root = base .. "/fixture/Checklists"
  for n = 1, 4 do
    local id = ("DEP-%02d"):format(n)
    write_raw(("%s/_rules/DEP/%s.md"):format(root, id), rule_file(id))
  end
  local path = root .. "/_layouts/regeln/DEP.md"
  write_raw(path, doc(vim.list_extend({ "---", "kind: layout", "output: regeln/DEP.md", "---" }, layout)))
  return root, { rulesets = { root }, today = "2026-10-15" }, path
end

---@param opts table
---@param op table
---@param extra? table
---@return table entry
local function one(opts, op, extra)
  local result, err = ops.run(vim.tbl_extend("force", { ops = { op } }, extra or {}), opts)
  assert(result, vim.inspect(err))
  return result.results[1]
end

---A `new` of the family DEP with a place.
---@param opts table
---@param place table
---@return table entry
local function new_rule(opts, place)
  return one(opts, vim.tbl_extend("force", { op = "new", family = "DEP", title = "five", severity = "critical" }, place))
end

---The inverse of an entry as a client gets it: through JSON.
---@param entry table
---@return table
local function inverse_of(entry)
  assert.is_true(entry.ok, vim.inspect(entry))
  return vim.json.decode(json.encode(entry.inverse))
end

describe("rules-ops/1 layouts: retire and its inverse", function()
  ---@param layout string[]
  ---@param id string
  ---@return table inverse, string path
  local function retire_and_back(layout, id)
    local root, opts, path = fixture(layout)
    local before = read_raw(path)
    local retired = one(opts, { op = "retire", id = id })
    local inverse = inverse_of(retired)
    assert.is_false(layout_edit.has(read_raw(path), id))
    local back = one(opts, inverse)
    assert.is_true(back.ok, vim.inspect(back))
    assert.are.equal(before, read_raw(path), vim.inspect(inverse))
    assert.is_truthy(read_raw(root .. "/_rules/DEP/" .. id .. ".md"))
    return inverse, path
  end

  it("G4-5: puts back a rule that stands tight above the next heading, byte for byte", function()
    local inverse = retire_and_back({
      "### Beim Schreiben",
      "",
      "{{rule DEP-01}}",
      "## 4. Dokumentation anlegen",
      "",
      "{{rule DEP-02}}",
      "{{rule DEP-03}}",
    }, "DEP-01")
    -- the blank lines around it are in the place, because the way a new token goes in would not write them
    assert.are.same({ above = 1, below = 0 }, inverse.places["regeln/DEP.md"].gap)
  end)

  it("G4-5: puts back a rule from every kind of neighbourhood", function()
    for _, layout in ipairs({
      { "## A", "", "{{rule DEP-01}}", "", "{{rule DEP-02}}", "", "## B", "", "{{rule DEP-03}}" },
      { "## A", "", "{{rule DEP-01}}", "{{rule DEP-02}}", "## B", "{{rule DEP-03}}" },
      { "## A", "Intro.", "{{rule DEP-01}}", "", "", "{{rule DEP-02}}", "", "", "## B", "", "", "{{rule DEP-03}}" },
      { "{{rule DEP-01}}", "", "{{rule DEP-02}}", "# T", "{{rule DEP-03}}" },
    }) do
      for _, id in ipairs({ "DEP-01", "DEP-02", "DEP-03" }) do
        retire_and_back(layout, id)
      end
    end
  end)

  it("G4-4: puts a rule that was first of its section back into that section, not into a subsection", function()
    local layout = { "## A", "", "Intro.", "", "{{rule DEP-01}}", "", "### Sub", "", "{{rule DEP-02}}", "", "## B", "" }
    local _, path = retire_and_back(layout, "DEP-01")
    local text = read_raw(path)
    assert.are.same({ section = "A", prev = nil }, layout_edit.locate(text, "DEP-01"))
    assert.are.same({ section = "Sub", prev = nil }, layout_edit.locate(text, "DEP-02"))
  end)

  it("G4-4: puts a rule that was first of its section back after an undo also with the section's other rules below", function()
    local layout = { "## A", "", "{{rule DEP-01}}", "", "### Sub", "", "{{rule DEP-02}}", "{{rule DEP-03}}", "" }
    retire_and_back(layout, "DEP-01")
    retire_and_back(layout, "DEP-02")
    retire_and_back(layout, "DEP-03")
  end)

  it("G4-4: names the n-th section when the heading is there more than once", function()
    local layout = {
      "## Rule one",
      "{{rule DEP-01}}",
      "##### Zum Check",
      "",
      "Text.",
      "",
      "{{rule DEP-02}}",
      "##### Zum Check",
      "",
      "More.",
      "",
      "{{rule DEP-03}}",
      "##### Zum Check",
      "",
    }
    local inverse = retire_and_back(layout, "DEP-03")
    assert.are.equal(2, inverse.places["regeln/DEP.md"].nth)
    -- the first of them needs no number
    local first = retire_and_back(layout, "DEP-02")
    assert.is_nil(first.places["regeln/DEP.md"].nth)
  end)

  it("takes a place with nth and gap from a client (the entry of places is checked)", function()
    local root, opts, path = fixture({ "## Check", "", "{{rule DEP-01}}", "## Check", "", "{{rule DEP-02}}" })
    assert.is_true(one(opts, { op = "retire", id = "DEP-02" }).ok)
    assert.is_true(root ~= nil)
    for _, bad in ipairs({
      { section = "Check", nth = 0 },
      { section = "Check", nth = 1.5 },
      { after = "DEP-01", nth = 2 },
      { section = "Check", gap = { above = -1, below = 0 } },
      { section = "Check", gap = { above = 1, side = 1 } },
      { section = "Check", gap = { above = 1000, below = 0 } },
      { section = "Check", gap = { 1, 0 } },
    }) do
      local entry = one(opts, { op = "reinstate", id = "DEP-02", places = { ["regeln/DEP.md"] = bad } })
      assert.is_false(entry.ok, vim.inspect(bad))
      assert.are.equal("invalid_argument", entry.error.code, vim.inspect(bad))
    end
    local good = one(opts, {
      op = "reinstate",
      id = "DEP-02",
      places = { ["regeln/DEP.md"] = { section = "Check", nth = 2, first = true, gap = { above = 1, below = 0 } } },
    })
    assert.is_true(good.ok, vim.inspect(good))
    assert.is_truthy(read_raw(path):find("## Check\n\n{{rule DEP-02}}", 1, true))
    assert.are.equal(2, select(2, read_raw(path):gsub("## Check", "")))
  end)

  it("takes nth and gap as the fields of a move, and the inverse of a move uses them", function()
    local layout = { "## Check", "", "{{rule DEP-01}}", "{{rule DEP-03}}", "## Check", "", "{{rule DEP-02}}", "## Z", "" }
    local _, opts, path = fixture(layout)
    local before = read_raw(path)
    local moved = one(opts, { op = "move", id = "DEP-02", layout = "regeln/DEP.md", section = "Check" })
    assert.is_true(moved.ok, vim.inspect(moved))
    local inverse = inverse_of(moved)
    assert.are.equal(2, inverse.nth)
    local back = one(opts, inverse)
    assert.is_true(back.ok, vim.inspect(back))
    assert.are.equal(before, read_raw(path))
  end)
end)

describe("rules-ops/1 layouts: new and its inverse", function()
  it("G4-3: leaves the layout as it was when a rule put into an empty last section is undone", function()
    for _, layout in ipairs({
      { "## A", "", "{{rule DEP-01}}", "", "## Last" },
      { "## A", "", "{{rule DEP-01}}", "", "## Last", "" },
      { "## A", "", "{{rule DEP-01}}", "", "## Last", "", "Intro of the last section." },
      { "## A", "", "{{rule DEP-01}}", "", "## Last", "", "Intro of the last section.", "" },
      { "## A", "", "{{rule DEP-01}}", "", "## Last", "", "Intro of the last section.", "", "" },
    }) do
      local _, opts, path = fixture(layout)
      local before = read_raw(path)
      local entry = new_rule(opts, { section = "Last", layout = "regeln/DEP.md" })
      assert.is_true(entry.ok, vim.inspect(entry))
      assert.is_truthy(read_raw(path):find("{{rule DEP-05}}", 1, true))
      local undone = one(opts, inverse_of(entry))
      assert.is_true(undone.ok, vim.inspect(undone))
      assert.are.equal(before, read_raw(path), vim.inspect(layout))
    end
  end)

  it("G4-1: puts a new rule outside the fence and the comment that hold look-alikes of headings and tokens", function()
    local layout = {
      "## A",
      "",
      "<!--",
      "## Hidden",
      "{{rule DEP-03}}",
      "-->",
      "",
      "{{rule DEP-01}}",
      "",
      "~~~",
      "{{rule DEP-04}}",
      "~~~",
      "",
      "## B",
      "",
    }
    local _, opts, path = fixture(layout)
    local entry = new_rule(opts, { section = "A", layout = "regeln/DEP.md" })
    assert.is_true(entry.ok, vim.inspect(entry))
    local text = read_raw(path)
    assert.is_truthy(text:find("{{rule DEP-01}}\n{{rule DEP-05}}\n\n~~~", 1, true), text)
    -- no section in a comment, no anchor in a fence
    local hidden = new_rule(opts, { section = "Hidden", layout = "regeln/DEP.md" })
    assert.is_false(hidden.ok)
    local fenced = new_rule(opts, { after = "DEP-04" })
    assert.is_false(fenced.ok)
    assert.are.equal(text, read_raw(path))
  end)
end)
