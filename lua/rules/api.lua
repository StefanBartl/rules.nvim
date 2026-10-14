---@module 'rules.api'
---@brief The one door of `rules-export/1`: `call(method, request, opts)` answers with canonical JSON, never throws.
---@description
--- A table of methods on `lib.nvim.contract.api`; the mechanics (request size, schema, unknown parameter, type,
--- error codes) are lib.nvim's. A request is `{ "schema": 1, "params": { ... } }`. `opts` is
--- `{ rulesets?, gates? }` (default: `setup()`), hidden in every error text.
---
--- Methods: `hello`, `snapshot`, `list`, `rule`, `next_id`, `sources`. All read only.
---
---```lua
--- local text, code = require("rules.api").call("rule", '{"params":{"id":"LUA-12"}}', { rulesets = { dir } })
---```

local contract = require("rules.contract")
local api_mod = require("lib.nvim.contract.api")

local M = {}

local api = api_mod.make({
  doc = contract.doc,
  engine_opts = { "rulesets", "gates" },
  root_of = function(opts)
    return contract.root_of(opts)
  end,
  methods = {
    hello = {
      params = {},
      run = function(_, opts)
        return contract.hello(opts), nil
      end,
    },
    snapshot = {
      params = {},
      run = function(_, opts)
        return contract.snapshot(opts)
      end,
    },
    list = {
      params = { family = "string", severity = "string", limit = "integer", offset = "integer" },
      run = function(params, opts)
        return contract.list(params, opts)
      end,
    },
    rule = {
      params = { id = "string" },
      required = { "id" },
      run = function(params, opts)
        return contract.rule(params.id, opts)
      end,
    },
    next_id = {
      params = { family = "string" },
      run = function(params, opts)
        return contract.next_id(params, opts)
      end,
    },
    sources = {
      params = {},
      run = function(_, opts)
        return contract.sources(opts)
      end,
    },
  },
})

M.METHODS = api.METHODS
M.MAX_REQUEST_BYTES = api.MAX_REQUEST_BYTES

---@return string[]
function M.methods()
  return api.methods()
end

---@param name string
---@param request string|table|nil
---@param opts Rules.Contract.Opts|nil
---@return string text
---@return string|nil code
function M.call(name, request, opts)
  return api.call(name, request, opts or {})
end

M.minimal_error = api.minimal_error

return M
