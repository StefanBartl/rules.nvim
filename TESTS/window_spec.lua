local window = require("rules.report.window")

--- Close every tab except the first, leaving a clean slate between tests --
--- `window.open` creates real tabs/windows, plenary doesn't reset those
--- between `it` blocks the way it resets Lua module state.
local function close_extra_tabs()
  while vim.fn.tabpagenr("$") > 1 do
    vim.cmd("tabclose")
  end
end

describe("rules.report.window.open", function()
  after_each(close_extra_tabs)

  it("opens a new tab with the given lines on first call", function()
    local tabs_before = vim.fn.tabpagenr("$")

    window.open({ "line one", "line two" })

    assert.are.equal(tabs_before + 1, vim.fn.tabpagenr("$"))
    local buf = vim.api.nvim_get_current_buf()
    assert.are.same({ "line one", "line two" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.are.equal("rulesreport", vim.bo[buf].filetype)
    assert.is_false(vim.bo[buf].modifiable)
  end)

  it("UI-31/51/52: reuses the same window on a second call instead of opening another tab", function()
    window.open({ "first run" })
    local tabs_after_first = vim.fn.tabpagenr("$")
    local win_after_first = vim.api.nvim_get_current_win()

    window.open({ "second run" })

    assert.are.equal(tabs_after_first, vim.fn.tabpagenr("$"))
    assert.are.equal(win_after_first, vim.api.nvim_get_current_win())
    local buf = vim.api.nvim_get_current_buf()
    assert.are.same({ "second run" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("opens a fresh tab again if the tagged window was closed", function()
    window.open({ "first run" })
    close_extra_tabs()
    local tabs_before_second = vim.fn.tabpagenr("$")

    window.open({ "second run" })

    assert.are.equal(tabs_before_second + 1, vim.fn.tabpagenr("$"))
  end)

  it("does not hijack the tagged window if the user navigated it away from the report", function()
    window.open({ "first run" })
    local win = vim.api.nvim_get_current_win()
    -- Simulate the user replacing the report buffer with something else in
    -- that same window, without clearing the vim.w tag.
    local other_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[other_buf].filetype = "text"
    vim.api.nvim_win_set_buf(win, other_buf)
    local tabs_before_second = vim.fn.tabpagenr("$")

    window.open({ "second run" })

    assert.are.equal(tabs_before_second + 1, vim.fn.tabpagenr("$"))
    -- the repurposed window/buffer must be untouched
    assert.are.same({ "" }, vim.api.nvim_buf_get_lines(other_buf, 0, -1, false))
  end)
end)
