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

  it("with guard, a near miss of a known key after a value is an error, a word that is no near miss goes on", function()
    local keys = cmdline.WAIVE_KEYS
    for _, typo in ipairs({ "expire", "expiry", "expiration", "Expires", "path", "reasons", "reson" }) do
      local lead, _, err = cmdline.split_assignments({ "reason=legacy", "code", typo .. "=2030-12-31" }, keys, true, true)
      assert.is_nil(lead, typo)
      assert.is_truthy(err:find("unknown field '" .. typo .. "'", 1, true), typo)
      local bound, berr = cmdline.bind({ "DEP-01", "reason=legacy", typo .. "=x" }, keys, true, true)
      assert.is_nil(bound, typo)
      assert.is_truthy(berr:find("did you mean", 1, true), typo)
    end
    local _, values = cmdline.split_assignments({ "reason=set", "x=1", "see=also", "id=7" }, keys, true, true)
    assert.are.same({ reason = "set x=1 see=also id=7" }, values)
    -- without guard, the word is glued on as it always was
    local _, glued = cmdline.split_assignments({ "reason=legacy", "expire=2030-12-31" }, keys, true)
    assert.are.same({ reason = "legacy expire=2030-12-31" }, glued)
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

describe("rules.cmdline.words", function()
  it("cuts the argument string where Neovim cuts fargs, and keeps the text as typed", function()
    local words = cmdline.words("  set DEP-01  text=a\\ b\\\\ c\tx ")
    assert.are.same({
      { text = "set", sep = "  " },
      { text = "DEP-01", sep = " " },
      { text = "text=a\\ b\\\\", sep = "  " },
      { text = "c", sep = " " },
      { text = "x", sep = "\t" },
    }, words)
    assert.are.same({}, cmdline.words("   "))
  end)

  it("agrees with the fargs of a real user command on every line", function()
    local got
    vim.api.nvim_create_user_command("RulesWordsProbe", function(opts)
      got = opts
    end, { nargs = "*" })
    local lines = {
      "a b",
      "a  b",
      "a\\ b c",
      "a\\\\ b",
      "a\\\\\\ b",
      "C:\\Users\\x\\ end",
      'text={"pattern":"a  b"} --dry',
      "x\\",
      "\\",
      "a\tb",
      "  lead and trail  ",
      "--to=f#S\\ T",
    }
    for _, line in ipairs(lines) do
      vim.cmd("RulesWordsProbe " .. line)
      local texts = {}
      for i, word in ipairs(cmdline.words(got.args)) do
        texts[i] = cmdline.unescape(word.text)
      end
      assert.are.same(got.fargs, texts, line)
    end
    vim.api.nvim_del_user_command("RulesWordsProbe")
  end)

  it("puts words together with the blanks between them as typed", function()
    local words = cmdline.words("one  two\t three")
    assert.are.equal("one  two\t three", cmdline.join(words))
    assert.are.equal("a b", cmdline.join({ "a", "b" }))
    assert.are.equal("", cmdline.join({}))
  end)
end)

describe("rules.cmdline.bind", function()
  ---@param line string
  ---@param known string[]
  ---@param strict? boolean
  ---@return table|nil bound
  ---@return string|nil err
  local function bind(line, known, strict)
    return cmdline.bind(cmdline.words(line), known, strict)
  end

  it("takes the first word that is no known key= as the positional one, wherever it stands", function()
    local bound = bind("DEP Add the check severity=critical", cmdline.NEW_KEYS)
    assert.are.equal("DEP", bound.positional)
    assert.are.equal("Add the check", cmdline.join(bound.lead))
    assert.are.same({ severity = "critical" }, bound.values)

    bound = bind("text=Hello DEP Wrong title severity=critical", cmdline.NEW_KEYS)
    assert.are.equal("DEP", bound.positional)
    assert.are.equal("Wrong title", cmdline.join(bound.lead))
    assert.are.same({ text = "Hello", severity = "critical" }, bound.values)
  end)

  it("lets a key= word before the positional word take that one word only", function()
    local bound = bind("severity=critical text=two words DEP", cmdline.NEW_KEYS)
    assert.are.equal("words", bound.positional)
    assert.are.same({ severity = "critical", text = "two" }, bound.values)
    assert.are.same(
      { "DEP" },
      vim.tbl_map(function(w)
        return w.text
      end, bound.lead)
    )
  end)

  it("has no positional word when there are only key= words", function()
    local bound = bind("severity=critical", cmdline.NEW_KEYS)
    assert.is_nil(bound.positional)
    assert.are.same({}, bound.lead)
    assert.are.same({ severity = "critical" }, bound.values)
    assert.is_nil(bind("", cmdline.NEW_KEYS).positional)
  end)

  it("reads an unknown key= word as the positional one", function()
    local bound = bind("colour=red severity=critical", cmdline.NEW_KEYS)
    assert.are.equal("colour=red", bound.positional)
  end)

  it("keeps the blanks of a value over several words as typed", function()
    local bound = bind("DEP T  x text=a  b\\ c", cmdline.NEW_KEYS)
    assert.are.equal("T  x", cmdline.join(bound.lead))
    assert.are.same({ text = "a  b\\ c" }, bound.values)
  end)

  it("is strict after the positional word, and refuses a key given twice, before or after it", function()
    local bound, err = bind("DEP-01 loose severity=critical", cmdline.SET_KEYS, true)
    assert.is_nil(bound)
    assert.is_truthy(err:find("expected key=value, got 'loose'", 1, true))
    bound, err = bind("title=a DEP-01 title=b", cmdline.SET_KEYS, true)
    assert.is_nil(bound)
    assert.is_truthy(err:find("'title' given twice", 1, true))
    bound, err = bind("DEP-01 colour=red", cmdline.SET_KEYS, true)
    assert.is_nil(bound)
    assert.is_truthy(err:find("unknown field 'colour'", 1, true))
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

describe("rules.cmdline.paths", function()
  it("splits at the commas and drops the blanks around them, not the ones inside a path", function()
    assert.are.same({ "src/legacy" }, cmdline.paths("src/legacy"))
    assert.are.same({ "a", "b", "my dir/c" }, cmdline.paths("a,b , my dir/c"))
  end)

  it("keeps a comma inside braces: it belongs to a glob", function()
    assert.are.same({ "docs/**/*.{md,txt}", "src" }, cmdline.paths("docs/**/*.{md,txt},src"))
    assert.are.same({ "{a,{b,c}}/x", "y" }, cmdline.paths("{a,{b,c}}/x,y"))
  end)

  it("gives no paths for nothing, and an empty place for a stray comma, for the door to refuse", function()
    assert.are.same({}, cmdline.paths(""))
    assert.are.same({}, cmdline.paths("   "))
    assert.are.same({ "a", "" }, cmdline.paths("a,"))
    assert.are.same({ "a", "", "b" }, cmdline.paths("a,,b"))
  end)

  it("keeps what is not a separator as typed: % and # and a backslash", function()
    assert.are.same({ "100%/a#b", [[c\d]] }, cmdline.paths([[100%/a#b,c\d]]))
  end)

  it("treats an unbalanced brace as part of the place", function()
    assert.are.same({ "a}", "b" }, cmdline.paths("a},b"))
    assert.are.same({ "{a,b" }, cmdline.paths("{a,b"))
  end)
end)

describe("rules.cmdline.escape", function()
  it("writes a blank, a tab and a backslash as the words of the command line read them back", function()
    assert.are.equal([[Two\ Words]], cmdline.escape("Two Words"))
    assert.are.equal("a\\\tb", cmdline.escape("a\tb"))
    assert.are.equal([[a\\b\ c]], cmdline.escape([[a\b c]]))
    -- nothing else is marked: the arguments of the command are not expanded
    assert.are.equal("C#\\ and\\ 100%\\ Done", cmdline.escape("C# and 100% Done"))
    assert.are.equal("plain", cmdline.escape("plain"))
  end)

  it("comes back as one word, unchanged, through words and unescape", function()
    for _, text in ipairs({ "Two Words", [[a\b c]], [[ends\]], "C# and 100%  Done", "x\ty", [[\ ]] }) do
      local words = cmdline.words("--section=" .. cmdline.escape(text) .. " --next")
      assert.are.equal(2, #words)
      assert.are.equal("--section=" .. text, cmdline.unescape(words[1].text))
    end
  end)
end)

describe("rules.cmdline.reinstate_hint", function()
  local function inverse(places)
    return { op = "reinstate", id = "DEP-02", places = places }
  end

  it("says an after, a before and a section place with the layout, every value as one word", function()
    local hint = cmdline.reinstate_hint("DEP-02", inverse({ ["regeln/Dep Rules.md"] = { after = "DEP-01" } }))
    assert.are.equal(":Rules reinstate DEP-02 --layout=regeln/Dep\\ Rules.md --after=DEP-01", hint.command)
    assert.are.same({}, hint.notes)
    hint = cmdline.reinstate_hint("DEP-02", inverse({ ["regeln/DEP.md"] = { before = "DEP-03" } }))
    assert.are.equal(":Rules reinstate DEP-02 --layout=regeln/DEP.md --before=DEP-03", hint.command)
    hint = cmdline.reinstate_hint("DEP-02", inverse({ ["regeln/DEP.md"] = { section = "C# and 100% Done", first = true } }))
    assert.are.equal(":Rules reinstate DEP-02 --layout=regeln/DEP.md --section=C#\\ and\\ 100%\\ Done --first", hint.command)
    hint = cmdline.reinstate_hint("DEP-02", inverse({ ["regeln/DEP.md"] = { section = "Core" } }))
    assert.are.equal(":Rules reinstate DEP-02 --layout=regeln/DEP.md --section=Core", hint.command)
  end)

  it("takes the place of an inverse that is one place of its own", function()
    local hint = cmdline.reinstate_hint("DEP-02", { op = "reinstate", id = "DEP-02", layout = "regeln/DEP.md", after = "DEP-01" })
    assert.are.equal(":Rules reinstate DEP-02 --layout=regeln/DEP.md --after=DEP-01", hint.command)
  end)

  it("gives one line, for the first layout in the order of the names, and names the others in a note", function()
    local hint = cmdline.reinstate_hint(
      "DEP-02",
      inverse({
        ["z/last.md"] = { section = "Core", first = true },
        ["a first.md"] = { after = "DEP-01" },
        ["m/mid.md"] = { before = "DEP-05" },
      })
    )
    assert.are.equal(":Rules reinstate DEP-02 --layout=a\\ first.md --after=DEP-01", hint.command)
    assert.are.equal(1, #hint.notes)
    assert.is_truthy(hint.notes[1]:find('m/mid.md (before DEP-05), z/last.md (the start of the section "Core")', 1, true))
    assert.is_truthy(hint.notes[1]:find("takes one place", 1, true))
  end)

  it("has no line for the top of a layout or the n-th section of a name, and skips to a layout it can say", function()
    local hint = cmdline.reinstate_hint(
      "DEP-02",
      inverse({ ["a.md"] = { top = true }, ["b.md"] = { section = "Core", nth = 2 }, ["c.md"] = { after = "DEP-01" } })
    )
    assert.are.equal(":Rules reinstate DEP-02 --layout=c.md --after=DEP-01", hint.command)
    assert.is_truthy(hint.notes[1]:find('a.md (the top), b.md (the end of the section "Core" (the 2. of that name))', 1, true))
    -- the top of the only layout: no line, and the two steps that get there
    hint = cmdline.reinstate_hint("DEP-02", inverse({ ["my dir/a.md"] = { top = true } }))
    assert.is_nil(hint.command)
    assert.are.equal(2, #hint.notes)
    assert.is_truthy(hint.notes[2]:find(":Rules reinstate DEP-02, then :Rules move DEP-02 --to=my\\ dir/a.md", 1, true))
    -- a '#' in the layout name would be read by --to= as a section
    hint = cmdline.reinstate_hint("DEP-02", inverse({ ["a#b.md"] = { top = true } }))
    assert.is_nil(hint.command)
    assert.are.equal(1, #hint.notes)
    -- a second section of a name alone: no line, no two steps
    hint = cmdline.reinstate_hint("DEP-02", inverse({ ["a.md"] = { section = "Core", nth = 3 } }))
    assert.is_nil(hint.command)
    assert.are.equal(1, #hint.notes)
  end)

  it("has no line for a line of a section, and names it in the note", function()
    local hint =
      cmdline.reinstate_hint("DEP-02", inverse({ ["a.md"] = { section = "Core", line = 3 }, ["b.md"] = { after = "DEP-01" } }))
    assert.are.equal(":Rules reinstate DEP-02 --layout=b.md --after=DEP-01", hint.command)
    assert.is_truthy(hint.notes[1]:find('a.md (line 3 of the section "Core")', 1, true))
    -- alone: no --section line that would put it at the end of the section instead
    hint = cmdline.reinstate_hint("DEP-02", inverse({ ["a.md"] = { section = "Core", line = 3 } }))
    assert.is_nil(hint.command)
  end)

  it("tells that the blank lines around the old place are not part of the line", function()
    local hint = cmdline.reinstate_hint("DEP-02", inverse({ ["a.md"] = { after = "DEP-01", gap = { above = 2, below = 0 } } }))
    assert.are.equal(":Rules reinstate DEP-02 --layout=a.md --after=DEP-01", hint.command)
    assert.is_truthy(hint.notes[1]:find("blank lines", 1, true))
  end)

  it("says nothing without a place", function()
    for _, bad in ipairs({ vim.NIL, {}, { op = "reinstate", id = "DEP-02" }, inverse({}), inverse({ ["a.md"] = {} }) }) do
      local hint = cmdline.reinstate_hint("DEP-02", bad)
      assert.is_nil(hint.command)
      assert.are.same({}, hint.notes)
    end
    assert.is_nil(cmdline.reinstate_hint("DEP-02", nil).command)
  end)
end)
