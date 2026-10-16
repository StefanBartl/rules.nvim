-- scripts/contract-dts.lua -- the TypeScript types of the machine contract, made from its JSON Schema.
--
--   nvim --headless -u NONE -i NONE -n -l scripts/contract-dts.lua [--check]   exit 1 when the committed file is stale
--   nvim --headless -u NONE -i NONE -n -l scripts/contract-dts.lua --write     rewrite it (then commit the diff)
--
-- OPTIONS  --schema=FILE  the JSON Schema     (default schemas/rules-export/1/rules-export.schema.json)
--          --out=FILE     the declarations    (default: the schema's name with `.schema.json` replaced by `.d.ts`)
--          --name=NAME    the exported root type  (default: the schema's file name in PascalCase, `RulesExport`)
--          --label=TEXT   what the header names as the source (default: the schema's path from the plugin root)
--
-- `rules-export.schema.json` describes the documents of `rules-export/1` and the `rules.result` document of
-- `rules-ops/1`; `rules-export.d.ts` is what a TypeScript client (rules-desktop) imports. The generator
-- (scripts/contract/dts.lua) understands exactly the subset of JSON Schema the schema uses and stops with an error on
-- any other keyword rather than writing a type that says `any`. It needs no lib.nvim and no Node.
--
-- Exit code: 0 the file is current / was written, 1 it is stale or missing (--check), or the schema is outside the
-- subset or not readable, 2 wrong usage.

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(script)))
local dts = dofile(plugin_root .. "/scripts/contract/dts.lua")

local function usage()
  io.stderr:write("usage: contract-dts.lua [--check | --write] [--schema=FILE] [--out=FILE] [--name=NAME] [--label=TEXT]\n")
  os.exit(2)
end

local FLAGS = { check = "bool", write = "bool", schema = "value", out = "value", name = "value", label = "value" }
local flags = {}
for i = 1, #arg do
  local key, value = arg[i]:match("^%-%-([^=]+)=(.*)$")
  if not key then
    key = arg[i]:match("^%-%-([^=]+)$")
  end
  local kind = key and FLAGS[key]
  if not kind or (kind == "bool" and value ~= nil) or (kind == "value" and (value == nil or value == "")) then
    usage()
  end
  flags[key] = value or true
end
if flags.check and flags.write then
  usage()
end

local schema_path = flags.schema or (plugin_root .. "/schemas/rules-export/1/rules-export.schema.json")
local out_path = flags.out or (schema_path:gsub("%.schema%.json$", "") .. ".d.ts")
if out_path == schema_path then
  io.stderr:write("error: --out is the schema itself; name the declarations file with --out=FILE\n")
  os.exit(2)
end

---@param path string
---@return string|nil
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

local base = vim.fs.basename(schema_path):gsub("%.schema%.json$", ""):gsub("%.json$", "")
local name = flags.name
if not name then
  name = ""
  for word in base:gmatch("%w+") do
    name = name .. word:sub(1, 1):upper() .. word:sub(2)
  end
end

local label = flags.label
if not label then
  local normalized = vim.fs.normalize(schema_path)
  local prefix = plugin_root .. "/"
  label = normalized:sub(1, #prefix) == prefix and normalized:sub(#prefix + 1) or vim.fs.basename(schema_path)
end

local schema_text = read(schema_path)
if not schema_text then
  io.stderr:write("error: cannot read the schema " .. schema_path .. "\n")
  os.exit(1)
end

local ok, generated = pcall(dts.generate_text, schema_text, { name = name, label = label })
if not ok then
  io.stderr:write(tostring(generated) .. "\n")
  os.exit(1)
end

if flags.write then
  local f, err = io.open(out_path, "wb")
  if not f then
    io.stderr:write("error: cannot write " .. out_path .. ": " .. tostring(err) .. "\n")
    os.exit(1)
  end
  f:write(generated)
  f:close()
  io.stdout:write("wrote " .. out_path .. "\n")
  os.exit(0)
end

local committed = read(out_path)
if committed == generated then
  io.stdout:write("ok: " .. out_path .. " is current\n")
  os.exit(0)
end

local hint = "run: nvim --headless -u NONE -i NONE -n -l scripts/contract-dts.lua --write  (then commit " .. out_path .. ")"
if committed == nil then
  io.stderr:write("stale: " .. out_path .. " does not exist; " .. hint .. "\n")
  os.exit(1)
end
local want = vim.split(generated, "\n", { plain = true })
local have = vim.split(committed, "\n", { plain = true })
local line = 1
while want[line] ~= nil and want[line] == have[line] do
  line = line + 1
end
io.stderr:write(
  ("stale: %s differs from the schema, first at line %d\n  committed: %s\n  generated: %s\n%s\n"):format(
    out_path,
    line,
    have[line] or "(end of file)",
    want[line] or "(end of file)",
    hint
  )
)
os.exit(1)
