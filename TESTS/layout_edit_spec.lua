-- TESTS/layout_edit_spec.lua -- the layout editor (`rules.engine.layout_edit`): what it takes for a heading or a token,
-- where a token goes in a section, and that `remove` and `place` give back the bytes they were given.
-- The real layouts of a vault are an opt-in second look at the end of this file (RULES_REAL_LUA, RULES_REAL_NATIVE,
-- RULES_REAL_GO: the ruleset folders; their layouts are copied to a temporary folder before anything is read, nothing
-- is ever written into them).
---@diagnostic disable: need-check-nil
local layout_edit = require("rules.engine.layout_edit")

---@param lines string[]
---@return string
local function doc(lines)
  return table.concat(lines, "\n") .. "\n"
end

describe("layout_edit: what is a heading and a token", function()
  -- a section A with a fenced/commented-out block whose lines look like headings and tokens, then the real ones
  local function with_block(block)
    local lines = { "## A", "", "Intro.", "" }
    vim.list_extend(lines, block)
    vim.list_extend(lines, { "", "{{rule GO-01}}", "{{rule GO-02}}", "", "## B", "" })
    return doc(lines)
  end

  local BLOCKS = {
    backtick = { "```", "## not a heading", "{{rule HID-01}}", "```" },
    tilde = { "~~~", "## not a heading", "{{rule HID-01}}", "~~~" },
    ["long backtick closes only with as many"] = { "````", "```", "## not a heading", "{{rule HID-01}}", "````" },
    ["tilde is not closed by backticks"] = { "~~~", "```", "## not a heading", "{{rule HID-01}}", "```", "~~~" },
    ["backtick is not closed by tildes"] = { "```", "~~~", "## not a heading", "{{rule HID-01}}", "~~~", "```" },
    ["indented by three spaces"] = { "   ~~~lua", "## not a heading", "{{rule HID-01}}", "   ~~~" },
    ["info string"] = { "~~~ lua `x`", "## not a heading", "{{rule HID-01}}", "~~~" },
    ["comment"] = { "<!--", "## not a heading", "{{rule HID-01}}", "-->" },
    ["comment that ends behind text"] = { "<!-- a", "## not a heading", "{{rule HID-01}}", "end --> text" },
    ["comment that starts behind text"] = { "see <!-- note", "## not a heading", "{{rule HID-01}}", "end -->" },
  }

  for name, block in pairs(BLOCKS) do
    it("sees no heading and no token in a " .. name, function()
      local text = with_block(block)
      -- the token is not there for the finders ...
      assert.is_false(layout_edit.has(text, "HID-01"), name)
      assert.is_nil(layout_edit.locate(text, "HID-01"))
      assert.is_nil((layout_edit.remove(text, "HID-01")))
      assert.is_nil((layout_edit.place(text, "NEW-01", { after = "HID-01" })))
      -- ... and the line that looks like a heading is no section
      assert.is_nil((layout_edit.place(text, "NEW-01", { section = "not a heading" })))
      -- the generator would fill it, so a second one is refused (it would be placed twice)
      local _, why = layout_edit.place(text, "HID-01", { section = "A" })
      assert.is_truthy(why:find("code block or a comment", 1, true), name)
      -- the end of A is behind the real tokens, the start in front of the first real one
      local last = assert(layout_edit.place(text, "NEW-01", { section = "A" }))
      assert.is_truthy(last:find("{{rule GO-02}}\n{{rule NEW-01}}\n", 1, true), name)
      local first = assert(layout_edit.place(text, "NEW-01", { section = "A", first = true }))
      assert.is_truthy(first:find("\n{{rule NEW-01}}\n{{rule GO-01}}\n", 1, true), name)
      -- a real token below it is found and its place is its own
      assert.are.same({ section = "A", prev = nil }, layout_edit.locate(text, "GO-01"))
      assert.are.same({ section = "A", prev = "GO-01" }, layout_edit.locate(text, "GO-02"))
    end)
  end

  it("takes a fence that is not closed for open to the end", function()
    local text = doc({ "## A", "", "{{rule GO-01}}", "", "```", "## B", "{{rule GO-02}}" })
    assert.is_true(layout_edit.has(text, "GO-01"))
    assert.is_false(layout_edit.has(text, "GO-02"))
    assert.is_nil((layout_edit.place(text, "NEW-01", { section = "B" })))
  end)

  it("takes four spaces for no fence, and a backtick in the info string of a backtick fence for a code span", function()
    local indented = doc({ "## A", "", "    ```", "## B", "{{rule GO-02}}" })
    assert.is_true(layout_edit.has(indented, "GO-02"))
    local span = doc({ "## A", "", "``` a`b", "## B", "{{rule GO-02}}" })
    assert.is_true(layout_edit.has(span, "GO-02"))
    -- ... but a tilde fence may have a backtick in its info string
    local tilde = doc({ "## A", "", "~~~ a`b", "## B", "{{rule GO-02}}", "~~~" })
    assert.is_false(layout_edit.has(tilde, "GO-02"))
  end)

  it("does not let `<!--` inside a code span hide the rest of the layout", function()
    local text = doc({ "## A", "", "Write `<!--` for a comment.", "", "{{rule GO-01}}" })
    assert.is_true(layout_edit.has(text, "GO-01"))
    local one = doc({ "## A", "", "a <!-- b --> c", "", "{{rule GO-01}}" })
    assert.is_true(layout_edit.has(one, "GO-01"))
  end)

  it("takes a # line of the frontmatter for no heading", function()
    local text = doc({ "---", "# kind of layout", "output: regeln/GO.md", "---", "{{rule GO-01}}", "## A", "" })
    assert.is_nil((layout_edit.place(text, "NEW-01", { section = "kind of layout" })))
    -- the rule above every heading is the start of the layout
    local top = assert(layout_edit.place(text, "NEW-01", { top = true }))
    assert.is_truthy(top:find("---\n{{rule NEW-01}}\n{{rule GO-01}}\n## A", 1, true))
  end)

  it("keeps working with a token behind a real comment and a real fence that are closed", function()
    local text = doc({ "<!-- a -->", "~~~", "x", "~~~", "## A", "", "{{rule GO-01}}", "<!-- b", "-->", "{{rule GO-02}}" })
    assert.are.same({ section = "A", prev = nil }, layout_edit.locate(text, "GO-01"))
    assert.are.same({ section = "A", prev = "GO-01" }, layout_edit.locate(text, "GO-02"))
  end)
end)

describe("layout_edit: the start of a section", function()
  it("is in front of the first token of the section's own text, not of one in a subsection", function()
    local text = doc({ "## A", "", "Intro.", "", "### Sub", "", "{{rule GO-01}}", "", "## B", "" })
    local out = assert(layout_edit.place(text, "NEW-01", { section = "A", first = true }))
    assert.are.equal(
      doc({ "## A", "", "Intro.", "", "{{rule NEW-01}}", "", "### Sub", "", "{{rule GO-01}}", "", "## B", "" }),
      out
    )
    -- with a token of its own, the start is in front of that one
    local own = doc({ "## A", "", "{{rule GO-02}}", "", "### Sub", "", "{{rule GO-01}}", "" })
    local own_out = assert(layout_edit.place(own, "NEW-01", { section = "A", first = true }))
    assert.is_truthy(own_out:find("## A\n\n{{rule NEW-01}}\n{{rule GO-02}}\n", 1, true))
    -- the end is still behind the last token of the whole section
    local last = assert(layout_edit.place(text, "NEW-01", { section = "A" }))
    assert.is_truthy(last:find("{{rule GO-01}}\n{{rule NEW-01}}\n", 1, true))
  end)

  it("is behind the introduction of a section that has only subsections with tokens, also at the end of the layout", function()
    local text = doc({ "## A", "Intro.", "### Sub", "{{rule GO-01}}" })
    local out = assert(layout_edit.place(text, "NEW-01", { section = "A", first = true }))
    assert.are.equal(doc({ "## A", "Intro.", "", "{{rule NEW-01}}", "", "### Sub", "{{rule GO-01}}" }), out)
  end)

  it("picks the n-th of several sections with the same heading", function()
    local text = doc({ "## A", "{{rule GO-01}}", "## Check", "", "{{rule GO-02}}", "## Check", "", "{{rule GO-03}}" })
    local second = assert(layout_edit.place(text, "NEW-01", { section = "Check", nth = 2, first = true }))
    assert.is_truthy(second:find("{{rule GO-02}}\n## Check\n\n{{rule NEW-01}}\n{{rule GO-03}}", 1, true))
    local default = assert(layout_edit.place(text, "NEW-01", { section = "Check", first = true }))
    assert.is_truthy(default:find("## Check\n\n{{rule NEW-01}}\n{{rule GO-02}}", 1, true))
    local _, why = layout_edit.place(text, "NEW-01", { section = "Check", nth = 3 })
    assert.is_truthy(why:find("no section", 1, true))
  end)
end)

describe("layout_edit: where a token stands, and back", function()
  ---@param text string
  ---@param id string
  ---@return string|nil back, table|nil where
  local function round(text, id)
    local where = layout_edit.where(text, id)
    local out = assert(layout_edit.remove(text, id))
    local back = layout_edit.place(out, id, where)
    return back, where
  end

  it("is the rule above it, or the start of the section, or the layout", function()
    local text = doc({ "---", "kind: layout", "---", "{{rule A-01}}", "## S", "", "{{rule A-02}}", "{{rule A-03}}", "" })
    assert.are.same({ top = true }, layout_edit.where(text, "A-01"))
    assert.are.same({ section = "S", first = true }, layout_edit.where(text, "A-02"))
    assert.are.same({ after = "A-02" }, layout_edit.where(text, "A-03"))
    assert.is_nil(layout_edit.where(text, "A-09"))
  end)

  it("names the n-th section when the heading is not the first of its text", function()
    local text = doc({ "## Check", "{{rule A-01}}", "## Check", "", "{{rule A-02}}", "" })
    local back, where = round(text, "A-02")
    assert.are.same({ section = "Check", first = true, nth = 2 }, where)
    assert.are.equal(text, back)
  end)

  it("gives a rule that stands in a subsection a place in that subsection, not in the first token of the section", function()
    local text = doc({ "## A", "", "{{rule A-01}}", "", "### Sub", "", "{{rule A-02}}", "", "## B", "" })
    local back, where = round(text, "A-01")
    assert.are.same({ section = "A", first = true }, where)
    assert.are.equal(text, back)
  end)

  -- every shape a token can stand in: what is above it, what is below it, how many blank lines on each side. A token
  -- between two pieces of the author's text (prose above and below) comes back through `line` (behind the n-th line of
  -- the section). Not among them, because no place says it: a token at the end of a file without a final newline that
  -- has two blank lines above it (the file could not say it ended in a blank line).
  local ABOVE = {
    token = { "{{rule A-00}}" },
    prose = { "Some words." },
    heading = { "## Head" },
    nothing = {},
  }
  local BELOW = {
    token = { "{{rule A-99}}" },
    prose = { "More words." },
    heading = { "## Next" },
    nothing = {},
  }

  it("gives the same bytes back for every shape a token can stand in", function()
    local checked = 0
    for above_name, above in pairs(ABOVE) do
      for below_name, below in pairs(BELOW) do
        for blanks_above = 0, 2 do
          for blanks_below = 0, 2 do
            for _, final in ipairs({ true, false }) do
              local lines = { "# Title", "" }
              vim.list_extend(lines, above)
              for _ = 1, blanks_above do
                lines[#lines + 1] = ""
              end
              local run = 0
              while lines[#lines - run] == "" do
                run = run + 1
              end
              lines[#lines + 1] = "{{rule A-05}}"
              for _ = 1, blanks_below do
                lines[#lines + 1] = ""
              end
              vim.list_extend(lines, below)
              if final or #below > 0 or run < 2 then
                local text = table.concat(lines, "\n") .. (final and "\n" or "")
                local back, where = round(text, "A-05")
                local label = ("%s/%s %d/%d final=%s"):format(above_name, below_name, blanks_above, blanks_below, final)
                assert.are.equal(text, back, label .. " " .. vim.inspect(where))
                checked = checked + 1
              end
            end
          end
        end
      end
    end
    assert.is_true(checked > 100)
  end)

  it("refuses a line place whose text has changed since, and takes one without around as before", function()
    local text = doc({ "## A", "", "Intro.", "", "{{rule D-01}}", "", "More." })
    local back, where = round(text, "D-01")
    assert.are.equal(text, back)
    assert.are.equal(3, where.line)
    assert.is_truthy(tostring(where.around):match("^sha256:%x+$"), vim.inspect(where))
    -- what the author does to the layout between taking the token out and putting it back
    for name, edited in pairs({
      ["a second line in the introduction"] = doc({ "## A", "", "Intro.", "Intro, second line.", "", "More." }),
      ["a table instead of the introduction"] = doc({ "## A", "", "| a | b |", "|---|---|", "| 1 | 2 |", "", "More." }),
      ["other text below"] = doc({ "## A", "", "Intro.", "", "Other." }),
    }) do
      local out, err = layout_edit.place(edited, "D-01", where)
      assert.is_nil(out, name .. ": " .. tostring(out))
      assert.is_truthy(tostring(err):find("has changed", 1, true), name .. ": " .. tostring(err))
    end
    -- a place written before `around` existed is put where its line says, unchecked
    local old = vim.deepcopy(where)
    old.around = nil
    local edited = doc({ "## A", "", "Intro.", "Intro, second line.", "", "More." })
    assert.is_truthy(layout_edit.place(edited, "D-01", old))
  end)

  it("leaves a rule that is first of a tight section where it was (a heading right behind it)", function()
    -- NEW-46 of the lua ruleset: the token has a blank line above it and the next heading right under it
    local text = doc({ "### Beim Schreiben", "", "{{rule A-05}}", "## 4. Dokumentation", "", "{{rule A-11}}" })
    local back = round(text, "A-05")
    assert.are.equal(text, back)
  end)

  it("leaves a blank line more when a token put under an introduction that touches the next heading is taken out", function()
    -- the one exception (documented): the new token is written between a blank line before and one behind it, and a
    -- token taken out gives back only one of two blank lines around it
    local text = doc({ "## A", "", "Intro.", "## B", "" })
    local placed = assert(layout_edit.place(text, "NEW-01", { section = "A" }))
    assert.are.equal(doc({ "## A", "", "Intro.", "", "{{rule NEW-01}}", "", "## B", "" }), placed)
    assert.are.equal(doc({ "## A", "", "Intro.", "", "## B", "" }), (layout_edit.remove(placed, "NEW-01")))
  end)

  it("takes the blank line out that it put in front of a token at the very end, and keeps the author's", function()
    for _, text in ipairs({
      doc({ "## A", "", "Intro." }),
      doc({ "## A", "", "Intro.", "" }),
      doc({ "## A", "", "Intro.", "", "" }),
      doc({ "## A" }),
      doc({ "## A", "" }),
      "## A\n\nIntro.",
      "## A",
    }) do
      local placed = assert(layout_edit.place(text, "NEW-01", { section = "A" }))
      assert.is_true(layout_edit.has(placed, "NEW-01"))
      assert.are.equal(text, (assert(layout_edit.remove(placed, "NEW-01"))), text)
    end
  end)

  it("keeps the bytes when a token that was written at the very end is taken out and put back", function()
    local text = doc({ "## A", "", "Intro.", "", "{{rule A-01}}" })
    local back, where = round(text, "A-01")
    assert.are.equal(text, back, vim.inspect(where))
    assert.are.equal(doc({ "## A", "", "Intro." }), (layout_edit.remove(text, "A-01")))
  end)

  it("puts a token back with the blank lines it had when the layout around it was not changed (gap)", function()
    local text = doc({ "## A", "Intro.", "", "{{rule A-01}}", "## B" })
    local out = assert(layout_edit.remove(text, "A-01"))
    -- no gap: the way a new token goes in (a blank line in front of it and behind it)
    local plain = assert(layout_edit.place(out, "A-01", { section = "A", first = true }))
    assert.are_not.equal(text, plain)
    local exact = assert(layout_edit.place(out, "A-01", { section = "A", first = true, gap = { above = 1, below = 0 } }))
    assert.are.equal(text, exact)
  end)
end)

-- opt-in: the layouts of the real rulesets. Every token is taken out and put back where `where` says; counted by bytes.
describe("layout_edit: the real layouts", function()
  local folders = {}
  for _, name in ipairs({ "RULES_REAL_LUA", "RULES_REAL_NATIVE", "RULES_REAL_GO" }) do
    local dir = vim.env[name]
    if dir and dir ~= "" then
      folders[#folders + 1] = dir
    end
  end
  -- no case without a folder: a skipped case would turn every ordinary run into a "partial" one
  if #folders == 0 then
    return
  end

  it("give the same bytes back for every token that is taken out and put back", function()
    local total, same, other_section = 0, 0, 0
    local bad = {}
    local copies = vim.fn.tempname()
    vim.fn.mkdir(copies, "p")
    for _, dir in ipairs(folders) do
      for n, source in ipairs(vim.fn.glob(dir .. "/_layouts/**/*.md", false, true)) do
        local path = ("%s/%d.md"):format(copies, n)
        assert(vim.uv.fs_copyfile(source, path), "could not copy " .. source)
        local fh = assert(io.open(path, "rb"))
        local text = fh:read("*a")
        fh:close()
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
          local id = line:gsub("%s+$", ""):match("^{{rule%s+([^%s}]+)%s*}}$")
          if id and layout_edit.has(text, id) then
            total = total + 1
            local where = layout_edit.where(text, id)
            local back = layout_edit.place(assert(layout_edit.remove(text, id)), id, where)
            if back == text then
              same = same + 1
            else
              bad[#bad + 1] = id
              local was, now = layout_edit.locate(text, id), back and layout_edit.locate(back, id)
              if not now or was.section ~= now.section then
                other_section = other_section + 1
              end
            end
          end
        end
      end
    end
    print(("real layouts: %d tokens, %d the same bytes, %d not (%d in another section)"):format(total, same, #bad, other_section))
    assert.is_true(total > 0)
    assert.are.same({}, bad)
    assert.are.equal(0, other_section)
  end)
end)
