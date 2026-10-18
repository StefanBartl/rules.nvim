-- TESTS/catalog_ask_spec.lua -- `:Rules catalog --check` names the documents that are out of date and, for a person at the
-- editor, asks whether to make them again now; a CI run (nobody to ask) only reports. The question is answered by the spec
-- (`rules.ui.confirm.choose` is replaced), nothing opens.
---@diagnostic disable: need-check-nil
local contract = require("rules.contract")
local confirm = require("rules.ui.confirm")

---@param path string
---@param text string
local function write_raw(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param path string
---@return boolean
local function exists(path)
  return (vim.uv or vim.loop).fs_stat(path) ~= nil
end

local RULE = "---\nid: DEP-01\nseverity: critical\nfamily: DEP\n---\n\n#### `DEP-01` — One\n\nText of one.\n"
local LAYOUT = "---\nkind: layout\noutput: regeln/DEP.md\n---\n# Dependencies\n\n{{rule DEP-01}}\n"

describe(":Rules catalog --check", function()
  local root
  local saved_uis = vim.api.nvim_list_uis
  local saved_notify = vim.notify
  local original_choose = confirm.choose
  local saved_ignore
  local asked, answer, notes

  ---@param on boolean
  local function ui(on)
    vim.api.nvim_list_uis = function()
      return on and { {} } or {}
    end
  end

  ---@param needle string
  ---@return boolean
  local function told(needle)
    for _, note in ipairs(notes) do
      if note.text:find(needle, 1, true) then
        return true
      end
    end
    return false
  end

  before_each(function()
    saved_ignore = vim.o.eventignore
    vim.o.eventignore = "FileType,Syntax"
    root = vim.fn.tempname() .. "/fixture/Checklists"
    write_raw(root .. "/_rules/DEP/DEP-01.md", RULE)
    write_raw(root .. "/_layouts/regeln/DEP.md", LAYOUT)
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
    require("rules").setup({ rulesets = { root } })
    contract.clear_cache()
    notes, asked, answer = {}, {}, 2
    vim.notify = function(msg, level)
      notes[#notes + 1] = { text = tostring(msg), level = level }
    end
    confirm.choose = function(question, choices, cb)
      asked[#asked + 1] = { question = question, choices = choices }
      cb(answer)
    end
    ui(true)
  end)

  after_each(function()
    vim.notify = saved_notify
    vim.api.nvim_list_uis = saved_uis
    confirm.choose = original_choose
    vim.o.eventignore = saved_ignore
    pcall(vim.api.nvim_del_user_command, "Rules")
    pcall(vim.api.nvim_del_user_command, "RulesVault")
  end)

  it("asks whether to make a document that is out of date again, and No leaves it alone", function()
    answer = 1
    vim.cmd("Rules catalog " .. root .. " --check")
    assert.are.equal(1, #asked)
    assert.is_truthy(asked[1].question:find("regeln/DEP.md", 1, true))
    assert.are.equal("No", asked[1].choices[1])
    assert.is_false(exists(root .. "/regeln/DEP.md"))
    assert.is_true(told("is out of date"))
  end)

  it("makes the documents when the answer is yes", function()
    vim.cmd("Rules catalog " .. root .. " --check")
    assert.are.equal(1, #asked)
    assert.is_true(exists(root .. "/regeln/DEP.md"))
    assert.is_true(told("1 written"))
  end)

  it("only reports when nobody can be asked, as a CI run does", function()
    ui(false)
    vim.cmd("Rules catalog " .. root .. " --check")
    assert.are.same({}, asked)
    assert.is_false(exists(root .. "/regeln/DEP.md"))
    assert.is_true(told("is out of date"))
  end)

  it("asks nothing when every document is current, or when it is asked to write", function()
    vim.cmd("Rules catalog " .. root)
    assert.is_true(exists(root .. "/regeln/DEP.md"))
    vim.cmd("Rules catalog " .. root .. " --check")
    assert.are.same({}, asked)
  end)
end)
