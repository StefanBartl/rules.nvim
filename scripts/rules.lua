-- scripts/rules.lua -- the headless command line of `rules-export/1` (read only).
--
--   nvim --headless -u NONE -i NONE -n -l scripts/rules.lua call <method> [--params=<json>|-] [OPTIONS]
--   nvim --headless -u NONE -i NONE -n -l scripts/rules.lua list --format=json [--family=F] [--severity=S]
--                                                           [--limit=N] [--offset=N] [OPTIONS]
--
-- OPTIONS  --ruleset=<path>        a ruleset file or folder (repeatable; `@vault/<name>` is a ruleset of the vault);
--                                   default `$RULES_RULESETS`, else the project file, else the vault's rulesets
--          --gate=<name>=<FAM,FAM> a gate (repeatable); default `$RULES_GATES`, merged over the project/vault files
--          --vault=<dir>           the rules-vault; default `$RULES_VAULT`, then `vault` in the project's .rules.json
--          --project=<dir>         the root whose `.rules.json` is read; default `$RULES_PROJECT`, else no project file
--
-- call   one method of the contract (`hello`, `snapshot`, `list`, `rule`, `next_id`, `sources`, `ops`); the document goes
--        to stdout. `--params` is the JSON of the method's parameters (`-` reads it from stdin).
-- list   `rules.list` with the parameters as flags; `--format=json` is the only format.
--
-- Exit code: 0 an answer, 1 an error document (also on stdout), 2 wrong usage or no lib.nvim.
-- lib.nvim is found through $LIB_NVIM_DIR, $LIB_NVIM_PATH, $REPOS_DIR/lib.nvim, .deps/lib.nvim, a sibling
-- checkout, then lazy.nvim's data folder.

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(script)))
vim.opt.rtp:prepend(vim.fn.escape(plugin_root, ","))

---@param dir string|nil
---@return boolean
local function has_lib(dir)
  return dir ~= nil and dir ~= "" and vim.fn.isdirectory(dir .. "/lua/lib/nvim") == 1
end

---@return string|nil
local function find_lib()
  local repos = vim.env.REPOS_DIR
  local candidates = {
    LIB_NVIM_DIR = vim.env.LIB_NVIM_DIR,
    LIB_NVIM_PATH = vim.env.LIB_NVIM_PATH,
    REPOS_DIR = (repos and repos ~= "") and (repos .. "/lib.nvim") or nil,
    deps = plugin_root .. "/.deps/lib.nvim",
    sibling = vim.fs.dirname(plugin_root) .. "/lib.nvim",
    lazy = vim.fn.stdpath("data") .. "/lazy/lib.nvim",
  }
  for _, key in ipairs({ "LIB_NVIM_DIR", "LIB_NVIM_PATH", "REPOS_DIR", "deps", "sibling", "lazy" }) do
    if has_lib(candidates[key]) then
      return candidates[key]
    end
  end
  return nil
end

local lib = find_lib()
if not lib then
  io.stderr:write("error: lib.nvim not found (set LIB_NVIM_DIR, or REPOS_DIR with a lib.nvim checkout)\n")
  os.exit(2)
end
vim.opt.rtp:append(vim.fn.escape(lib, ","))

local function usage()
  io.stderr:write(
    "usage: rules.lua call <method> [--params=<json>|-] | list --format=json [--family=F] [--severity=S] "
      .. "[--limit=N] [--offset=N]   (options: --ruleset=PATH --gate=NAME=FAM,FAM --vault=DIR --project=DIR)\n"
  )
  os.exit(2)
end

local command = _G.arg[1]
if command ~= "call" and command ~= "list" then
  usage()
end

local KNOWN = {
  params = "value",
  format = "value",
  family = "value",
  severity = "value",
  limit = "value",
  offset = "value",
  ruleset = "value",
  gate = "value",
  vault = "value",
  project = "value",
}
local flags, rulesets, gates, positional = {}, {}, {}, {}
for i = 2, #_G.arg do
  local a = _G.arg[i]
  if a:sub(1, 2) == "--" then
    local key, value = a:match("^%-%-([^=]+)=(.*)$")
    if not key or not KNOWN[key] or value == "" then
      usage()
    end
    if key == "ruleset" then
      rulesets[#rulesets + 1] = value
    elseif key == "gate" then
      gates[#gates + 1] = value
    else
      flags[key] = value
    end
  else
    positional[#positional + 1] = a
  end
end

local env = require("rules.env")
local opts = env.opts()
if #rulesets > 0 then
  opts.rulesets = rulesets
end
if #gates > 0 then
  opts.gates = env.parse_gates(table.concat(gates, ";"))
end
opts.vault = flags.vault
if flags.project then
  opts.project = flags.project
end

local method, request
if command == "call" then
  if #positional ~= 1 then
    usage()
  end
  method = positional[1]
  local params = flags.params
  if params == "-" then
    params = io.stdin:read("*a")
  end
  if params ~= nil and params ~= "" then
    -- a write method carries its fields at the top of the request, a read method under `params`
    local def = require("rules.api").METHODS[method]
    request = (def and def.flat) and params or ('{"params":' .. params .. "}")
  end
else
  if #positional ~= 0 or flags.format ~= "json" then
    usage()
  end
  method = "list"
  local params = { family = flags.family, severity = flags.severity }
  for _, key in ipairs({ "limit", "offset" }) do
    if flags[key] ~= nil then
      local number = tonumber(flags[key]) or usage()
      -- `inf` and `nan` read as numbers but no JSON carries them: the text goes to the contract, which refuses it
      -- as a document (a whole number is the only thing it takes)
      local whole = number == number and number > -math.huge and number < math.huge and number % 1 == 0
      params[key] = whole and number or flags[key]
    end
  end
  request = vim.json.encode({ params = params })
end

local text, code = require("rules.api").call(method, request, opts)
io.stdout:write(text, "\n")
io.stdout:flush()
os.exit(code == nil and 0 or 1)
