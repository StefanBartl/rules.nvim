local errline = require("rules.engine.checks.errline")

describe("rules.engine.checks.errline.first_line", function()
  it("keeps a plain single-line message unchanged", function()
    assert.are.equal("boom", errline.first_line("boom"))
  end)

  it("keeps only the first line of a debug.traceback()-style message", function()
    local traceback = "boom\nstack traceback:\n\t[C]: in function 'error'\n\t...\n"

    assert.are.equal("boom", errline.first_line(traceback))
  end)

  it("returns the leading text even with no trailing newline in the first line", function()
    assert.are.equal("only line, no trailing newline", errline.first_line("only line, no trailing newline"))
  end)
end)
