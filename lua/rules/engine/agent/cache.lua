---@module 'rules.engine.agent.cache'
---@brief Answers of a model kept by the request that earned them, so the same question about the same files is not asked twice.
---@description
--- The key is a hash of everything that decides the answer: the system text, the prompt (which holds the rule text,
--- the question and the numbered content of the files), the backend and the model. A changed rule, a changed file or
--- another model is a different key, so a hit is never an answer to another question.
---
--- What is stored is the answer as received, not the result of `validate`: the answer is checked against the tree
--- again on every use, and a cache never turns an unchecked text into a verdict. A file that does not read back as an
--- entry (truncated, edited, from another version) is a miss, never an error.

local M = {}

---@class Rules.Agent.CacheEntry
---@field text string  the answer as received
---@field provider string
---@field model? string
---@field date string  `YYYY-MM-DD` it was stored

--- The key of a request.
---@param request { system: string, prompt: string }
---@param provider string
---@param model string|nil
---@return string key  64 hex characters
function M.key(request, provider, model)
  return vim.fn.sha256(table.concat({ request.system, request.prompt, provider, model or "" }, "\0"))
end

--- The folder the editor keeps answers in.
---@return string
function M.dir()
  return vim.fn.stdpath("cache") .. "/rules.nvim/agent"
end

---@param dir string
---@param key string
---@return string
local function path_of(dir, key)
  return dir .. "/" .. key .. ".json"
end

--- The entry stored under `key`, nil when there is none or it cannot be used.
---@param dir string
---@param key string
---@return Rules.Agent.CacheEntry|nil
function M.get(dir, key)
  if type(key) ~= "string" or not key:match("^%x+$") then
    return nil
  end
  local fh = io.open(path_of(dir, key), "rb")
  if not fh then
    return nil
  end
  local raw = fh:read("*a")
  fh:close()
  local ok, decoded = pcall(vim.json.decode, raw)
  if
    not ok
    or type(decoded) ~= "table"
    or type(decoded.text) ~= "string"
    or type(decoded.provider) ~= "string"
    or (decoded.model ~= nil and type(decoded.model) ~= "string")
    or type(decoded.date) ~= "string"
  then
    return nil
  end
  return { text = decoded.text, provider = decoded.provider, model = decoded.model, date = decoded.date }
end

--- Store an answer. A failure to write is not the caller's problem: the answer was got, only the saving was lost.
---@param dir string
---@param key string
---@param entry Rules.Agent.CacheEntry
---@return boolean stored
function M.put(dir, key, entry)
  if type(key) ~= "string" or not key:match("^%x+$") then
    return false
  end
  vim.fn.mkdir(dir, "p")
  local json = require("lib.nvim.json.canonical")
  local text = json.encode(
    json.object({ text = entry.text, provider = entry.provider, model = entry.model, date = entry.date }),
    { indent = 2 }
  ) .. "\n"
  return require("lib.nvim.fs.write.atomic")(path_of(dir, key), text) and true or false
end

return M
