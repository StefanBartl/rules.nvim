---@module 'rules.ui.project'
---@brief The project whose waivers file `:Rules waive`, `renew` and `unwaive` write -- never one outside the working directory.
---@description
--- A waiver lives in the checked project (`<project>/.rules-waivers.json`), and `:Rules check` reads the one in the working
--- directory. So the working directory is the project, with one refinement: the file of the current buffer may lie in a
--- project of its own BELOW the working directory (a monorepo, a folder of repositories), and then that is the one.
---
--- The rule, in the order it is applied:
---
---  1. `--project=<dir>` names it: handed to the door as typed (relative to the working directory)
---  2. the nearest folder above the buffer's file that holds a `.rules-waivers.json`, a `.rules.json` or a `.git`, when it
---     lies strictly below the working directory
---  3. the working directory (no `project` in the request: the door's own default)
---
--- Nothing outside the working directory is ever chosen: a buffer of a file elsewhere, a scratch buffer, a nameless one
--- and a file whose folders have no marker below the working directory all mean the working directory. (The door refuses a
--- project outside the working directory anyway: `project must be the configured project or a folder inside it`.)
---
--- Not its job: checking a folder (the door, `rules.waiver_ops.resolve_project`), writing.

local M = {}

--- What makes a folder a project of its own.
M.MARKERS = { ".rules-waivers.json", ".rules.json", ".git" }

local CASE_INSENSITIVE = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1

---@param path string
---@return string|nil real  with `/`, no trailing slash
local function real_of(path)
  local real = vim.uv.fs_realpath(path)
  if not real then
    return nil
  end
  return (vim.fs.normalize(real):gsub("/+$", ""))
end

---The part of `path` below `base` (both real), nil when `path` is `base` itself or lies elsewhere.
---@param base string
---@param path string
---@return string|nil below
local function below(base, path)
  local b, p = base, path
  if CASE_INSENSITIVE then
    b, p = b:lower(), p:lower()
  end
  if p:sub(1, #b + 1) == b .. "/" then
    return path:sub(#base + 2)
  end
  return nil
end

---The project of the file of a buffer when it is one below the working directory: its folder relative to the working
---directory (`/`), nil when the working directory is the project.
---@param buf? integer  default: the current buffer
---@param cwd? string   default: the working directory
---@return string|nil relative
function M.of_buffer(buf, cwd)
  buf = buf or 0
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local base = real_of(cwd or vim.fn.getcwd())
  local dir = real_of(vim.fs.dirname(name))
  if not base or not dir then
    return nil
  end
  while below(base, dir) do
    for _, marker in ipairs(M.MARKERS) do
      if vim.uv.fs_stat(dir .. "/" .. marker) then
        return below(base, dir)
      end
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

---The `project` of a request: what `--project=` said, else the project of the buffer, else nothing (the working
---directory).
---@param given? string  the value of `--project=`
---@param buf? integer
---@return string|nil project
function M.request(given, buf)
  if given ~= nil then
    return given
  end
  return M.of_buffer(buf)
end

---The folder of a `project` of a request, as the door resolves it; nil when the door would refuse it. For the places that
---read the waivers file without asking the door (completion).
---@param project? string
---@return string|nil dir
function M.dir(project)
  local contract = require("rules.contract")
  local opts = contract.editor_opts()
  local ok, dir = pcall(function()
    local rulesets = contract.rulesets(opts)
    return (require("rules.waiver_ops").resolve_project(project, opts, rulesets))
  end)
  return ok and dir or nil
end

return M
