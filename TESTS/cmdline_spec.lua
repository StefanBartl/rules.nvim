-- TESTS/cmdline_spec.lua -- the words of `:Rules new/set/retire/move` as values and fields of a `rules-ops/1` operation.
---@diagnostic disable: need-check-nil
local cmdline = require("rules.cmdline")

describe("rules.cmdline.split_assignments", function()
  it("takes key=value words, and a value may hold spaces", function()
    local lead, values = cmdline.split_assignments({ "title=A", "new", "title", "severity=critical" }, cmdline.SET_KEYS, true)
    assert.are.same({}, lead)
    assert.are.same({ title = "A new title", severity = "critical" }, values)
  end)

  it("keeps a word that starts no known key before the first key as the lead (the title of :Rules new)", function()
    local lead, values =
      cmdline.split_assignments({ "Fix", "the", "thing", "severity=critical", "text=a=b", "c" }, cmdline.NEW_KEYS)
    assert.are.same({ "Fix", "the", "thing" }, lead)
    assert.are.same({ severity = "critical", text = "a=b c" }, values)
  end)

  it("lets an unknown key=value word continue the value before it", function()
    local _, values = cmdline.split_assignments({ "text=see", "a=b" }, cmdline.NEW_KEYS)
    assert.are.same({ text = "see a=b" }, values)
  end)

  it("refuses, in strict mode, an unknown key and a loose word before the first key", function()
    local lead, _, err = cmdline.split_assignments({ "colour=red" }, cmdline.SET_KEYS, true)
    assert.is_nil(lead)
    assert.is_truthy(err:find("unknown field 'colour'", 1, true))
    local _, _, loose = cmdline.split_assignments({ "severity" }, cmdline.SET_KEYS, true)
    assert.is_truthy(loose:find("expected key=value", 1, true))
  end)

  it("refuses a key given twice", function()
    local lead, _, err = cmdline.split_assignments({ "title=a", "title=b" }, cmdline.SET_KEYS, true)
    assert.is_nil(lead)
    assert.is_truthy(err:find("given twice", 1, true))
  end)

  it("keeps an empty value (the key with nothing after it)", function()
    local _, values = cmdline.split_assignments({ "check=" }, cmdline.SET_KEYS, true)
    assert.are.same({ check = "" }, values)
  end)
end)

describe("rules.cmdline.patch", function()
  it("keeps the texts as typed", function()
    local patch = cmdline.patch({ severity = "critical", title = "x", text = "" })
    assert.are.same({ severity = "critical", title = "x", text = "" }, patch)
  end)

  it("turns an empty check or agent into null (remove) and a JSON object into data", function()
    local patch = cmdline.patch({ check = "", agent = '{"question":"is it?"}' })
    assert.are.equal(vim.NIL, patch.check)
    assert.are.same({ question = "is it?" }, patch.agent)
  end)

  it("refuses a check that is no JSON object", function()
    for _, text in ipairs({ "grep", "[1,2]", "{oops", "5" }) do
      local patch, err = cmdline.patch({ check = text })
      assert.is_nil(patch, text)
      assert.is_truthy(err:find("check= takes a JSON object", 1, true), text)
    end
  end)

  it("refuses an empty patch", function()
    local patch, err = cmdline.patch({})
    assert.is_nil(patch)
    assert.is_truthy(err:find("nothing to set", 1, true))
  end)
end)

describe("rules.cmdline places", function()
  it("reads <file>#<section> and <file> (the top)", function()
    assert.are.same({ layout = "regeln/DEP.md", section = "Core" }, cmdline.to("regeln/DEP.md#Core"))
    assert.are.same({ layout = "regeln/DEP.md", section = "A # B" }, cmdline.to("regeln/DEP.md#A # B"))
    assert.are.same({ layout = "regeln/DEP.md", top = true }, cmdline.to("regeln/DEP.md"))
  end)

  it("refuses an empty file, section or place", function()
    for _, text in ipairs({ "#Core", "regeln/DEP.md#", "" }) do
      local place, err = cmdline.to(text)
      assert.is_nil(place, text)
      assert.is_string(err)
    end
  end)

  it("takes one of --to, --after, --before, and --first only with a section", function()
    assert.are.same({}, cmdline.place({}))
    assert.are.same({ after = "DEP-01" }, cmdline.place({ after = "DEP-01" }))
    assert.are.same({ before = "DEP-01" }, cmdline.place({ before = "DEP-01" }))
    assert.are.same({ layout = "a.md", section = "S", first = true }, cmdline.place({ to = "a.md#S", first = true }))
    for _, flags in ipairs({
      { after = "A-01", before = "A-02" },
      { to = "a.md#S", after = "A-01" },
      { first = true },
      { after = "A-01", first = true },
      { to = "a.md", first = true },
    }) do
      local place, err = cmdline.place(flags)
      assert.is_nil(place, vim.inspect(flags))
      assert.is_string(err)
    end
  end)

  it("reads the Place: line of the form", function()
    assert.are.same({}, cmdline.place_text("   "))
    assert.are.same({ after = "DEP-03" }, cmdline.place_text(" after DEP-03 "))
    assert.are.same({ before = "DEP-03" }, cmdline.place_text("before DEP-03"))
    assert.are.same({ layout = "regeln/DEP.md", section = "Core Rules" }, cmdline.place_text("regeln/DEP.md#Core Rules"))
    assert.are.same({ layout = "regeln/DEP.md", top = true }, cmdline.place_text("regeln/DEP.md"))
  end)
end)
