-- scripts/contract/dts.lua -- JSON Schema (the subset the schemas of this repo use) to TypeScript declarations.
--
-- Pure: a table in, text out; no file, no nvim API beyond `vim.json`. The command line around it is
-- scripts/contract-dts.lua; TESTS/contract_dts_spec.lua loads this file directly.
--
-- Why a generator of its own: this repo has no Node toolchain, and the schema is a small, fixed subset of JSON Schema.
-- A keyword outside that subset is an ERROR naming the keyword and its place in the schema, never a type that quietly
-- says `any`: a schema that grows a feature the generator cannot express must not ship a `.d.ts` that lies about it.
--
-- What is understood
--   shapes       type (string, number, integer, boolean, null, array, object, or a list of the first five), enum, const,
--                $ref ("#/$defs/<name>" only), oneOf / anyOf (a union), allOf (an intersection)
--   structure    properties, required, additionalProperties, items
--   no effect    title, description, $comment, default, examples, deprecated, readOnly, writeOnly, $schema, $id, and
--                the checks that only narrow a value the type cannot express: minimum, maximum, exclusiveMinimum,
--                exclusiveMaximum, multipleOf, minLength, maxLength, pattern, format, minItems, maxItems, uniqueItems,
--                minProperties, maxProperties
--   at the root  $defs (every entry becomes an exported type, named in PascalCase)
-- Anything else (prefixItems, patternProperties, if/then/else, not, $dynamicRef, a remote $ref, ...) is an error.
--
-- Output rules
--   * An object with properties is CLOSED unless `additionalProperties` says otherwise: a typo in a field name is a
--     type error for the reader. (A reader still ignores fields it does not know at run time; the type just does not
--     promise any.) `additionalProperties: true` is `[k: string]: unknown`, a schema is `[k: string]: T`.
--   * An object without properties is a dictionary: `{ [k: string]: unknown }`.
--   * A name in `required` that the object does not declare is `name: unknown`, so that an intersection
--     (`Head & { rev: unknown }`) keeps the field required.
--   * Keys are sorted (the JSON decoder does not keep the order of a file), LF line ends, one final newline: the same
--     schema always gives the same bytes.

local M = {}

---Keywords that describe, and change nothing in the type.
local ANNOTATION = {
  title = true,
  description = true,
  ["$comment"] = true,
  default = true,
  examples = true,
  deprecated = true,
  readOnly = true,
  writeOnly = true,
  ["$schema"] = true,
  ["$id"] = true,
}

---Checks of a value that a TypeScript type cannot say.
local CONSTRAINT = {
  minimum = true,
  maximum = true,
  exclusiveMinimum = true,
  exclusiveMaximum = true,
  multipleOf = true,
  minLength = true,
  maxLength = true,
  pattern = true,
  format = true,
  minItems = true,
  maxItems = true,
  uniqueItems = true,
  minProperties = true,
  maxProperties = true,
}

local STRUCTURE = { properties = true, required = true, additionalProperties = true, items = true }

---At most one of these may stand in a schema (`type` may be joined by `enum` or `const` that agree with it).
local SHAPES = { "$ref", "enum", "const", "oneOf", "anyOf", "allOf", "type" }

local PRIMITIVE = { string = "string", number = "number", integer = "number", boolean = "boolean", ["null"] = "null" }

local WRAP = 100

---Precedence of a rendered type: what needs brackets where.
local UNION, INTERSECTION, ATOM = 0, 1, 2

---@param path string
---@param message string
local function fail(path, message)
  error(("contract-dts: %s at %s"):format(message, path), 0)
end

---@param text string
---@return string
local function quote(text)
  local out = text:gsub('[%c"\\]', function(c)
    if c == '"' then
      return '\\"'
    elseif c == "\\" then
      return "\\\\"
    elseif c == "\n" then
      return "\\n"
    elseif c == "\r" then
      return "\\r"
    elseif c == "\t" then
      return "\\t"
    end
    return ("\\u%04x"):format(c:byte())
  end)
  return '"' .. out .. '"'
end

---@param value any
---@param path string
---@return string literal, string json_type
local function literal(value, path)
  if value == vim.NIL then
    return "null", "null"
  end
  local kind = type(value)
  if kind == "string" then
    return quote(value), "string"
  elseif kind == "boolean" then
    return tostring(value), "boolean"
  elseif kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      fail(path, "a number that is no JSON number")
    end
    local integral = value == math.floor(value)
    return integral and ("%d"):format(value) or ("%.14g"):format(value), integral and "integer" or "number"
  end
  fail(path, "an enum or const value that is not a string, number, boolean or null")
  return "", ""
end

---@param value any
---@return boolean
local function is_list(value)
  return type(value) == "table" and (next(value) == nil or vim.islist(value))
end

---@param key string
---@return string
local function pascal(key)
  local out = {}
  for word in key:gmatch("[%w]+") do
    out[#out + 1] = word:sub(1, 1):upper() .. word:sub(2)
  end
  return table.concat(out)
end

---@param name string
---@return string
local function property_name(name)
  if name:match("^[%a_$][%w_$]*$") then
    return name
  end
  return quote(name)
end

---@param node table
---@param indent string
---@return string|nil comment  the `/** ... */` block, no final newline
local function doc_comment(node, indent)
  local parts = {}
  for _, key in ipairs({ "title", "description" }) do
    local text = node[key]
    if type(text) == "string" and text ~= "" and text ~= parts[1] then
      parts[#parts + 1] = text
    end
  end
  if #parts == 0 then
    return nil
  end
  local lines = { indent .. "/**" }
  for _, line in ipairs(vim.split(table.concat(parts, "\n\n"), "\n", { plain = true })) do
    line = line:gsub("%*/", "*\\/"):gsub("%s+$", "")
    lines[#lines + 1] = line == "" and (indent .. " *") or (indent .. " * " .. line)
  end
  lines[#lines + 1] = indent .. " */"
  return table.concat(lines, "\n")
end

---@class rules.ContractDts.Ctx
---@field names table<string, string>  $defs key -> exported type name
---@field defs table<string, table>

---@type fun(node: any, indent: string, ctx: rules.ContractDts.Ctx, path: string, inline: boolean): string, integer
local render

---Joins the members of a union: on one line when they fit, else one per line behind a `|`.
---@param members any[]
---@param indent string
---@param ctx rules.ContractDts.Ctx
---@param path string
---@param inline boolean
---@return string
local function render_union(members, indent, ctx, path, inline)
  if #members == 0 then
    fail(path, "an empty oneOf or anyOf")
  end
  local parts = {}
  for i, member in ipairs(members) do
    parts[i] = (render(member, indent, ctx, ("%s/%d"):format(path, i - 1), true))
  end
  local one = table.concat(parts, " | ")
  if inline or (#parts == 1) or (#one <= WRAP and not one:find("\n", 1, true)) then
    return one
  end
  local pad = indent .. "  "
  local lines = {}
  for i, member in ipairs(members) do
    lines[i] = pad .. "| " .. (render(member, pad, ctx, ("%s/%d"):format(path, i - 1), true))
  end
  return "\n" .. table.concat(lines, "\n")
end

---@param node table
---@param indent string
---@param ctx rules.ContractDts.Ctx
---@param path string
---@return string
local function render_object(node, indent, ctx, path)
  local properties = node.properties
  if properties ~= nil and (type(properties) ~= "table" or is_list(properties) and next(properties) ~= nil) then
    fail(path .. "/properties", "properties must be an object")
  end
  properties = properties or {}
  local required, names, declared = {}, {}, {}
  if node.required ~= nil and not is_list(node.required) then
    fail(path .. "/required", "required must be a list of names")
  end
  for _, name in ipairs(node.required or {}) do
    if type(name) ~= "string" then
      fail(path .. "/required", "required must be a list of names")
    end
    required[name] = true
  end
  for name in pairs(properties) do
    names[#names + 1] = name
    declared[name] = true
  end
  for name in pairs(required) do
    if not declared[name] then
      names[#names + 1] = name
    end
  end
  table.sort(names)

  local extra = node.additionalProperties
  local has_fields = #names > 0
  if not has_fields then
    -- A dictionary: nothing is listed, so the values are whatever `additionalProperties` says.
    if extra == nil or extra == true then
      return "{ [k: string]: unknown }"
    elseif extra == false then
      return "{ [k: string]: never }"
    end
    return "{ [k: string]: " .. (render(extra, indent, ctx, path .. "/additionalProperties", true)) .. " }"
  end

  local pad = indent .. "  "
  local lines = { "{" }
  for _, name in ipairs(names) do
    local sub = properties[name]
    local text, comment
    if declared[name] then
      local where = path .. "/properties/" .. name
      text = render(sub, pad, ctx, where, false)
      comment = type(sub) == "table" and doc_comment(sub, pad) or nil
    else
      text = "unknown"
    end
    if comment then
      lines[#lines + 1] = comment
    end
    local optional = required[name] and "" or "?"
    lines[#lines + 1] = ("%s%s%s:%s%s;"):format(pad, property_name(name), optional, text:sub(1, 1) == "\n" and "" or " ", text)
  end
  if extra == true then
    lines[#lines + 1] = pad .. "[k: string]: unknown;"
  elseif type(extra) == "table" then
    lines[#lines + 1] = ("%s[k: string]: %s;"):format(pad, (render(extra, pad, ctx, path .. "/additionalProperties", true)))
  elseif extra ~= nil and extra ~= false then
    fail(path .. "/additionalProperties", "additionalProperties must be a boolean or a schema")
  end
  lines[#lines + 1] = indent .. "}"
  return table.concat(lines, "\n")
end

---@param type_name string
---@param node table
---@param indent string
---@param ctx rules.ContractDts.Ctx
---@param path string
---@return string text, integer precedence
local function render_typed(type_name, node, indent, ctx, path)
  if PRIMITIVE[type_name] then
    return PRIMITIVE[type_name], ATOM
  elseif type_name == "object" then
    return render_object(node, indent, ctx, path), ATOM
  elseif type_name == "array" then
    if node.items == nil then
      return "unknown[]", ATOM
    end
    local inner, precedence = render(node.items, indent, ctx, path .. "/items", true)
    if precedence < ATOM then
      return "(" .. inner .. ")[]", ATOM
    end
    return inner .. "[]", ATOM
  end
  fail(path .. "/type", ("unsupported type '%s'"):format(tostring(type_name)))
  return "", ATOM
end

---@param node any
---@param indent string  the indentation of the line this type starts on
---@param ctx rules.ContractDts.Ctx
---@param path string  where we are in the schema, for the messages
---@param inline boolean  true: a union stays on one line (inside brackets, an intersection or an array)
---@return string text, integer precedence
render = function(node, indent, ctx, path, inline)
  if node == true then
    return "unknown", ATOM
  elseif node == false then
    return "never", ATOM
  elseif type(node) ~= "table" or is_list(node) and next(node) ~= nil then
    fail(path, "a schema must be an object or a boolean")
  end

  for key in pairs(node) do
    if not (ANNOTATION[key] or CONSTRAINT[key] or STRUCTURE[key] or key == "$defs") then
      local is_shape = false
      for _, shape in ipairs(SHAPES) do
        is_shape = is_shape or shape == key
      end
      if not is_shape then
        fail(path, ("unsupported keyword '%s'"):format(key))
      end
    end
  end
  if node["$defs"] ~= nil and path ~= "#" then
    fail(path, "unsupported keyword '$defs' below the root")
  end

  local present = {}
  for _, shape in ipairs(SHAPES) do
    if node[shape] ~= nil then
      present[#present + 1] = shape
    end
  end
  local has_enum = node.enum ~= nil or node.const ~= nil
  -- `type` together with enum/const is fine when they agree (checked below); any other pair is not.
  if #present > 1 then
    local typed_literal = #present == 2 and node.type ~= nil and has_enum and not (node.enum ~= nil and node.const ~= nil)
    if not typed_literal then
      fail(path, ("unsupported combination of '%s' and '%s'"):format(present[1], present[2]))
    end
  end

  local shape = present[1]
  if shape == "type" and has_enum then
    shape = node.enum ~= nil and "enum" or "const"
  end
  if node.items ~= nil and node.type ~= "array" and not (node.type == nil and shape == nil) then
    fail(path, "items belongs to a schema of type array")
  end
  if (node.properties ~= nil or node.required ~= nil or node.additionalProperties ~= nil) and node.type ~= "object" then
    if not (node.type == nil and shape == nil) then
      fail(path, "properties, required and additionalProperties belong to a schema of type object")
    end
  end

  if shape == nil then
    -- Structure without a `type` is read by what it has; an empty schema is "anything".
    if node.properties ~= nil or node.required ~= nil or node.additionalProperties ~= nil then
      return render_object(node, indent, ctx, path), ATOM
    elseif node.items ~= nil then
      return render_typed("array", node, indent, ctx, path)
    end
    return "unknown", ATOM
  elseif shape == "$ref" then
    local ref = node["$ref"]
    local key = type(ref) == "string" and ref:match("^#/%$defs/(.+)$") or nil
    if not key or not ctx.names[key] then
      fail(path .. "/$ref", ("unsupported or unresolved $ref '%s' (only '#/$defs/<name>' of this schema)"):format(tostring(ref)))
    end
    return ctx.names[key], ATOM
  elseif shape == "enum" or shape == "const" then
    local values = shape == "enum" and node.enum or { node.const }
    if not is_list(values) or #values == 0 then
      fail(path .. "/" .. shape, "enum must be a non-empty list")
    end
    local allowed
    if type(node.type) == "string" then
      allowed = node.type
    end
    local parts, seen = {}, {}
    for i, value in ipairs(values) do
      local text, json_type = literal(value, ("%s/%s/%d"):format(path, shape, i - 1))
      if allowed and allowed ~= json_type and not (allowed == "number" and json_type == "integer") then
        fail(path .. "/" .. shape, ("value %s is not of the type '%s'"):format(text, allowed))
      end
      if not seen[text] then
        seen[text] = true
        parts[#parts + 1] = text
      end
    end
    return table.concat(parts, " | "), #parts > 1 and UNION or ATOM
  elseif shape == "oneOf" or shape == "anyOf" then
    local members = node[shape]
    if not is_list(members) then
      fail(path .. "/" .. shape, shape .. " must be a list of schemas")
    end
    if #members == 1 then
      return render(members[1], indent, ctx, ("%s/%s/0"):format(path, shape), inline)
    end
    return render_union(members, indent, ctx, path .. "/" .. shape, inline), UNION
  elseif shape == "allOf" then
    local members = node.allOf
    if not is_list(members) or #members == 0 then
      fail(path .. "/allOf", "allOf must be a non-empty list of schemas")
    end
    if #members == 1 then
      return render(members[1], indent, ctx, path .. "/allOf/0", inline)
    end
    local parts = {}
    for i, member in ipairs(members) do
      local text, precedence = render(member, indent, ctx, ("%s/allOf/%d"):format(path, i - 1), true)
      parts[i] = precedence == UNION and ("(" .. text .. ")") or text
    end
    return table.concat(parts, " & "), INTERSECTION
  end

  -- shape == "type"
  local declared = node.type
  if type(declared) == "string" then
    return render_typed(declared, node, indent, ctx, path)
  end
  if not is_list(declared) or #declared == 0 then
    fail(path .. "/type", "type must be a name or a non-empty list of names")
  end
  local parts, seen = {}, {}
  for _, name in ipairs(declared) do
    if not PRIMITIVE[name] then
      fail(path .. "/type", ("a list of types may hold primitive types only, not '%s'"):format(tostring(name)))
    end
    if not seen[PRIMITIVE[name]] then
      seen[PRIMITIVE[name]] = true
      parts[#parts + 1] = PRIMITIVE[name]
    end
  end
  return table.concat(parts, " | "), #parts > 1 and UNION or ATOM
end

---@class rules.ContractDts.Opts
---@field name? string   the exported name of the root type (default "Contract")
---@field label? string  what the header names as the source file

---Turns a decoded schema into the text of a `.d.ts`.
---@param schema table
---@param opts? rules.ContractDts.Opts
---@return string
function M.generate(schema, opts)
  opts = opts or {}
  local root_name = opts.name or "Contract"
  local label = opts.label or "the schema"
  if type(schema) ~= "table" or is_list(schema) and next(schema) ~= nil then
    fail("#", "the schema must be a JSON object")
  end

  local ctx = { names = {}, defs = schema["$defs"] or {} }
  if type(ctx.defs) ~= "table" or (is_list(ctx.defs) and next(ctx.defs) ~= nil) then
    fail("#/$defs", "$defs must be an object")
  end
  local keys, taken = {}, { [root_name] = "the root" }
  for key in pairs(ctx.defs) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local name = pascal(key)
    if name == "" or name:match("^%d") then
      fail("#/$defs/" .. key, "no usable type name can be made from this key")
    end
    if taken[name] then
      fail("#/$defs/" .. key, ("the type name %s is already taken by %s"):format(name, taken[name]))
    end
    taken[name] = "#/$defs/" .. key
    ctx.names[key] = name
  end

  local blocks = { ("/* Generated from %s by scripts/contract-dts.lua. Do not edit. */"):format(label) }
  local function add(name, node, path)
    local text = (render(node, "", ctx, path, false))
    local comment = type(node) == "table" and doc_comment(node, "") or nil
    local head = ("export type %s ="):format(name)
    local body
    if text:sub(1, 1) == "\n" then
      body = head .. text .. ";"
    else
      body = head .. " " .. text .. ";"
    end
    blocks[#blocks + 1] = comment and (comment .. "\n" .. body) or body
  end

  add(root_name, schema, "#")
  for _, key in ipairs(keys) do
    add(ctx.names[key], ctx.defs[key], "#/$defs/" .. key)
  end
  return table.concat(blocks, "\n\n") .. "\n"
end

---@param text string  the schema as JSON
---@param opts? rules.ContractDts.Opts
---@return string
function M.generate_text(text, opts)
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok then
    error("contract-dts: the schema is not valid JSON: " .. tostring(decoded), 0)
  end
  return M.generate(decoded, opts)
end

return M
