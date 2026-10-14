---@module 'rules.env'
---@brief Rulesets, gates and the project root from the environment, for the headless entry points (host, command line).
---`$RULES_VAULT` is not here: `rules.settings` reads it itself, ranked below `setup()` and above the project file.

local M = {}

---Paths separated by `;`, or by `:` -- except the colon of a drive letter, a lone letter at the start of a path
---(`C:/rules`, as in `C:/a:D:/b`).
---@param text string
---@return string[]
function M.split_paths(text)
  local out = {}
  for piece in text:gmatch("[^;]+") do
    local current, i = "", 1
    while i <= #piece do
      local ch = piece:sub(i, i)
      local drive = ch == ":" and current:match("^%a$") ~= nil and piece:sub(i + 1, i + 1):match("[/\\]") ~= nil
      if ch == ":" and not drive then
        if current ~= "" then
          out[#out + 1] = current
        end
        current = ""
      else
        current = current .. ch
      end
      i = i + 1
    end
    if current ~= "" then
      out[#out + 1] = current
    end
  end
  return out
end

---`name=FAM,FAM;name=FAM` as a table of gates; a malformed entry is skipped.
---@param text string
---@return table<string, string[]>
function M.parse_gates(text)
  local gates = {}
  for entry in text:gmatch("[^;]+") do
    local name, list = entry:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
    if name then
      local families = {}
      for fam in list:gmatch("[^,%s]+") do
        families[#families + 1] = fam
      end
      gates[name] = families
    end
  end
  return gates
end

---`$RULES_RULESETS`, `$RULES_GATES` and `$RULES_PROJECT` (the root whose `.rules.json` is read); unset means "from
---`setup()`, the project file and the vault" (`rules.settings`).
---@return Rules.Contract.Opts
function M.opts()
  local opts = {}
  local sets = vim.env.RULES_RULESETS
  if sets and sets ~= "" then
    opts.rulesets = M.split_paths(sets)
  end
  local gates = vim.env.RULES_GATES
  if gates and gates ~= "" then
    opts.gates = M.parse_gates(gates)
  end
  local project = vim.env.RULES_PROJECT
  if project and project ~= "" then
    opts.project = project
  end
  return opts
end

return M
