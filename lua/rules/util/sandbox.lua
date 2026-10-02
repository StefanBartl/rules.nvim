---@module 'rules.util.sandbox'
---@brief Evaluate a rule block's table-constructor body with no access to
--- the host, and give a `lua_predicate` its environment back only on request.
---@description
--- A ruleset is code: its blocks are Lua. A block body is evaluated in an
--- **empty environment**, so it cannot call `os.execute`, `io.open`, `require`
--- or anything on `vim` -- a body that tries fails as a malformed block, like
--- any other. That is a *capability* boundary, not a resource one: string
--- methods stay reachable through a literal (`("x"):rep(2e9)` allocates 2 GB in
--- one C call), so a hostile ruleset can still burn memory. What it cannot do
--- is touch the disk, a process or the network, and -- because the evaluation
--- runs under an instruction budget with the JIT off -- it cannot hang the host
--- in a *Lua* loop (measured: `while true do end` aborts in ~2 ms, where a bare
--- count hook never fires inside a JIT-compiled loop). The budget counts VM
--- instructions, so it does not see time spent inside one C call: a pattern with
--- nested quantifiers handed to `find` on a long literal can still run for a
--- long while. That is the same resource boundary as the memory case above.
---
--- A `check.fn` of a `lua_predicate` is a closure created in that empty
--- environment, so as written it would see no `vim`, no `string`, no `ipairs`.
--- `rebind` gives it a real environment, and only the predicates this module
--- itself produced are eligible -- the caller decides *whether* a predicate is
--- trusted, this module only knows *how* to enable one.

-- ERR-05/06: `safe_call` rather than a hand-rolled `pcall` -- the same
-- traceback on failure the rest of the engine reports.
local safe_error = require("lib.lua.error")
local errline = require("rules.engine.checks.errline")

local M = {}

--- VM instructions a block body may run before it is aborted. A real body is a
--- table constructor with a few closures -- a few hundred instructions -- so
--- this is several orders of magnitude of headroom, not a tuning knob.
local INSTRUCTION_BUDGET = 1e6

--- Functions this module created, so `rebind` never changes the environment
--- of one it did not (a test double, a host callback).
---@type table<function, true>
local created_here = setmetatable({}, { __mode = "k" })

--- Run `fn` under the instruction budget, with the JIT off for the duration,
--- and put the host's own hook and JIT state back afterwards -- a profiler or
--- coverage tool that had installed a hook keeps it.
---@param fn function
---@return boolean ok
---@return any result_or_error  the error as a single line when `ok` is false
local function run_budgeted(fn)
  local jit_lib = rawget(_G, "jit")
  local jit_was_on = jit_lib ~= nil and jit_lib.status() == true
  local prev_hook, prev_mask, prev_count = debug.gethook()

  if jit_was_on then
    jit_lib.off()
  end
  debug.sethook(function()
    error("instruction budget exceeded (runaway loop?)", 0)
  end, "", INSTRUCTION_BUDGET)

  local ok, result = safe_error.safe_call(fn)

  debug.sethook(prev_hook, prev_mask or "", prev_count or 0)
  if jit_was_on then
    jit_lib.on()
  end

  if not ok then
    return false, errline.first_line(result.message)
  end
  return true, result
end

--- Evaluate `{ <body> }` in an empty environment.
---@param body string  a table-constructor body: fields, not the braces
---@param chunkname string  shown in load/runtime error messages
---@return table|nil value  the evaluated table
---@return string|nil err  set when `value` is nil
function M.eval_table(body, chunkname)
  local chunk, load_err = load("return {" .. body .. "}", chunkname, "t", {})
  if not chunk then
    return nil, load_err
  end

  local ok, value = run_budgeted(chunk)
  if not ok then
    return nil, value
  end

  if type(value) == "table" and type(value.check) == "table" and type(value.check.fn) == "function" then
    created_here[value.check.fn] = true
  end
  return value, nil
end

--- Give a sandbox-created predicate the real global environment.
---@param fn function
---@return boolean rebound  false when `fn` was not created by `eval_table`
function M.rebind(fn)
  if not created_here[fn] then
    return false
  end

  if rawget(_G, "setfenv") then
    setfenv(fn, _G)
    return true
  end

  -- Lua 5.2+: the environment is an upvalue named `_ENV`.
  local i = 1
  while true do
    local name = debug.getupvalue(fn, i)
    if name == nil then
      return false
    end
    if name == "_ENV" then
      debug.setupvalue(fn, i, _G)
      return true
    end
    i = i + 1
  end
end

return M
