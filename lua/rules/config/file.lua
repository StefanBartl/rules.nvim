---@module 'rules.config.file'
---@brief Read one `.rules.json` (of a project or of a vault) and check it against the schema.
---@description
--- A missing file is not an error: it means "this place has no settings". A file that is there but cannot be used
--- is: unreadable, not a regular file, larger than `MAX_BYTES`, not JSON, not an object, a value of the wrong shape.
--- The answer says so (`problems`), it never turns into an empty table: "I could not read your settings" must not
--- look like "you have none" (`NOTES/DESIGN-DECISIONS.md`: a reader of user input fails loudly).
---
--- The file may lie in a repository somebody else controls, so it is read with `lib.nvim.fs.read_bounded`
--- (a FIFO or a huge file cannot block or exhaust the editor).
---
--- Not its job: what the entries mean (`rules.settings` resolves paths and `@vault/<name>`).

local schema = require("rules.config.schema")

local M = {}

---The name of the file in a project root and in a vault root.
M.NAME = ".rules.json"

---A settings file is a few lines; a megabyte is a mistake (or an attack).
M.MAX_BYTES = 1024 * 1024

---@class Rules.Config.File
---@field path string                 `<dir>/.rules.json`
---@field dir string                  the folder it lies in (the base of its relative paths)
---@field scope "project"|"vault"
---@field exists boolean
---@field config table                the valid part (keys of the schema)
---@field problems Rules.Config.Problem[]  non-empty: the file is refused as a whole
---@field unknown Rules.Config.Unknown[]

---@param dir string  absolute, `/`-separated
---@param scope "project"|"vault"
---@return Rules.Config.File
function M.read(dir, scope)
  local uv = vim.uv or vim.loop
  local path = dir .. "/" .. M.NAME
  ---@type Rules.Config.File
  local file = { path = path, dir = dir, scope = scope, exists = false, config = {}, problems = {}, unknown = {} }

  local function refuse(message)
    file.problems[#file.problems + 1] = { key = "", message = message }
    return file
  end

  if not uv.fs_lstat(path) then
    return file
  end
  file.exists = true

  local stat = uv.fs_stat(path)
  if not stat then
    return refuse("cannot be read (a link that leads nowhere?)")
  end
  if stat.type ~= "file" then
    return refuse(("must be a file, it is a %s"):format(stat.type))
  end
  local text, read_err = require("lib.nvim.fs.read_bounded")(path, M.MAX_BYTES)
  if not text then
    -- `read_bounded` names the path in its messages; the cause is what matters here
    local reason = tostring(read_err):find("too large", 1, true) and ("is larger than %d bytes"):format(M.MAX_BYTES)
      or "cannot be read"
    return refuse(reason)
  end
  -- an editor on Windows may save a byte order mark, which JSON does not allow
  text = text:gsub("^\239\187\191", "")

  local ok, decoded = pcall(vim.json.decode, text)
  if not ok then
    return refuse(("is not valid JSON (%s)"):format((tostring(decoded):gsub("^.-:%d+:%s*", ""))))
  end

  -- strict: `[]` and `{}` are two things in a file (the decoder marks an empty object)
  local checked = schema.check(decoded, scope, true)
  file.config, file.problems, file.unknown = checked.clean, checked.problems, checked.unknown
  return file
end

return M
