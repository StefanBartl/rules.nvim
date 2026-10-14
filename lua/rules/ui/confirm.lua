---@module 'rules.ui.confirm'
---@brief The question of `:Rules` before a step that is not undone by a keystroke (retire, create from the form).
---@description
--- `lib.nvim.ui.kit.confirm`: the themed button dialog every plugin of the family uses. It answers by callback, once,
--- never before `choose` returns. The first choice is the one the dialog starts on, so it is always the harmless one.
---
--- `M.choose` is the seam the specs replace: a spec that asks a question answers it itself, the dialog never opens.

local M = {}

---A question with several answers. `cb` gets the index of the answer (1-based), `nil` when the dialog was dismissed
---(`<Esc>`, `q`) or could not open: not an answer, nothing happens.
---@param question string
---@param choices string[]  the first is the harmless one
---@param cb fun(index: integer|nil)
function M.choose(question, choices, cb)
  require("lib.nvim.ui.kit").confirm({
    question = question,
    choices = choices,
    on_answer = function(choice)
      for i, label in ipairs(choices) do
        if label == choice then
          cb(i)
          return
        end
      end
      cb(nil)
    end,
  })
end

---Yes or no, "No" first. `cb(true)` only for the yes.
---@param question string
---@param yes_label string  shown as "Yes, <yes_label>"
---@param cb fun(accepted: boolean)
function M.yesno(question, yes_label, cb)
  M.choose(question, { "No", "Yes, " .. yes_label }, function(index)
    cb(index == 2)
  end)
end

return M
