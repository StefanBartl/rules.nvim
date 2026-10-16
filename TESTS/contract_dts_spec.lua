-- TESTS/contract_dts_spec.lua -- the TypeScript declarations of the machine contract (schemas/rules-export/1/
-- rules-export.d.ts): the generator (scripts/contract/dts.lua) on small schemas, a schema outside its subset that is
-- refused by name, and the committed file against the one the schema generates now (the CI check, in a spec).
---@diagnostic disable: need-check-nil

local GENERATOR = assert(
  vim.api.nvim_get_runtime_file("scripts/contract/dts.lua", false)[1],
  "scripts/contract/dts.lua is not on the runtimepath"
)
local CLI = assert(
  vim.api.nvim_get_runtime_file("scripts/contract-dts.lua", false)[1],
  "scripts/contract-dts.lua is not on the runtimepath"
)
local SCHEMA = assert(
  vim.api.nvim_get_runtime_file("schemas/rules-export/1/rules-export.schema.json", false)[1],
  "the schema is not on the runtimepath"
)
local COMMITTED = assert(
  vim.api.nvim_get_runtime_file("schemas/rules-export/1/rules-export.d.ts", false)[1],
  "schemas/rules-export/1/rules-export.d.ts is not committed: run scripts/contract-dts.lua --write"
)
local LABEL = "schemas/rules-export/1/rules-export.schema.json"

local dts = dofile(GENERATOR)

---@param path string
---@return string
local function read(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

---@param path string
---@param text string
local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

---@param schema table
---@return string
local function gen(schema)
  return dts.generate(schema, { name = "T", label = "x" })
end

local HEADER = "/* Generated from x by scripts/contract-dts.lua. Do not edit. */\n\n"

describe("scripts/contract/dts.lua: what it writes", function()
  it("maps the types the schemas use, with sorted properties and optional marks", function()
    local text = gen({
      type = "object",
      required = { "a" },
      properties = {
        f = { ["$ref"] = "#/$defs/thing" },
        a = { type = "string" },
        b = { type = "array", items = { type = "integer" } },
        c = { enum = { "x", "y" } },
        d = { type = { "string", "null" } },
        e = { const = 1 },
        g = { type = "boolean" },
        h = { type = "number" },
        i = { type = "null" },
      },
      ["$defs"] = { thing = { type = "boolean", description = "a flag" } },
    })
    assert.are.equal(HEADER .. table.concat({
      "export type T = {",
      "  a: string;",
      "  b?: number[];",
      '  c?: "x" | "y";',
      "  d?: string | null;",
      "  e?: 1;",
      "  f?: Thing;",
      "  g?: boolean;",
      "  h?: number;",
      "  i?: null;",
      "};",
      "",
      "/**",
      " * a flag",
      " */",
      "export type Thing = boolean;",
      "",
    }, "\n"), text)
  end)

  it("reads a schema from JSON text and gives the same bytes for the same schema every time", function()
    local json = '{"type":"object","required":["id"],"properties":{"id":{"type":"string"},"n":{"type":"integer"}}}'
    local first = dts.generate_text(json, { name = "T", label = "x" })
    assert.are.equal(first, dts.generate_text(json, { name = "T", label = "x" }))
    assert.are.equal(first, gen(vim.json.decode(json)))
    assert.is_nil(first:find("\r", 1, true), "LF only")
    assert.is_truthy(first:find("\n$"))
    assert.is_nil(first:find("\n\n$"), "exactly one final newline")
  end)

  it("makes a union of oneOf/anyOf, an intersection of allOf, and brackets where precedence needs them", function()
    local text = gen({
      oneOf = { { ["$ref"] = "#/$defs/a" }, { ["$ref"] = "#/$defs/b" } },
      ["$defs"] = {
        a = { type = "string" },
        b = { type = "array", items = { anyOf = { { type = "string" }, { type = "integer" } } } },
        both = { allOf = { { ["$ref"] = "#/$defs/a" }, { oneOf = { { type = "string" }, { type = "boolean" } } } } },
      },
    })
    assert.matches("export type T = A | B;", text, 1, true)
    assert.matches("export type B = (string | number)[];", text, 1, true)
    assert.matches("export type Both = A & (string | boolean);", text, 1, true)
  end)

  it("keeps a union that does not fit on a line one member per line", function()
    local members, defs = {}, {}
    for i = 1, 14 do
      local key = ("definition_%02d"):format(i)
      members[i] = { ["$ref"] = "#/$defs/" .. key }
      defs[key] = { type = "string" }
    end
    local text = gen({ oneOf = members, ["$defs"] = defs })
    assert.matches("export type T =\n  | Definition01\n  | Definition02\n", text, 1, true)
    assert.matches("\n  | Definition14;\n", text, 1, true)
  end)

  it("closes an object that lists its properties, and opens a dictionary and what additionalProperties says", function()
    local text = gen({
      type = "object",
      properties = {
        closed = { type = "object", properties = { a = { type = "string" } } },
        open = { type = "object", properties = { a = { type = "string" } }, additionalProperties = true },
        typed = { type = "object", additionalProperties = { type = "integer" } },
        dict = { type = "object" },
        none = { type = "object", additionalProperties = false },
      },
    })
    assert.matches("closed?: {\n    a?: string;\n  };", text, 1, true)
    assert.matches("open?: {\n    a?: string;\n    [k: string]: unknown;\n  };", text, 1, true)
    assert.matches("typed?: { [k: string]: number };", text, 1, true)
    assert.matches("dict?: { [k: string]: unknown };", text, 1, true)
    assert.matches("none?: { [k: string]: never };", text, 1, true)
  end)

  it("keeps a field required that an object only names in `required` (it is declared in another part)", function()
    local text = gen({
      allOf = {
        { ["$ref"] = "#/$defs/head" },
        { type = "object", required = { "kind", "rev" }, properties = { kind = { const = "x.doc" } } },
      },
      ["$defs"] = { head = { type = "object", properties = { rev = { type = "string" } } } },
    })
    assert.matches('export type T = Head & {\n  kind: "x.doc";\n  rev: unknown;\n};', text, 1, true)
  end)

  it("writes title and description as a comment and cannot be broken out of it", function()
    local text = gen({
      type = "object",
      properties = {
        a = { type = "string", description = "ends */ early\n\nsecond paragraph" },
      },
      title = "T: the title",
      description = "the description",
    })
    assert.matches("/**\n * T: the title\n *\n * the description\n */\nexport type T = {", text, 1, true)
    assert.matches("  /**\n   * ends *\\/ early\n   *\n   * second paragraph\n   */\n  a?: string;", text, 1, true)
  end)

  it("quotes a property name that is no identifier and a string value with a quote in it", function()
    local text = gen({
      type = "object",
      properties = { ["a-b"] = { enum = { 'say "hi"', "back\\slash" } } },
    })
    assert.matches('"a-b"?: "say \\"hi\\"" | "back\\\\slash";', text, 1, true)
  end)

  it("names a type after the key in PascalCase and refuses two keys that make the same name", function()
    local text = gen({ ["$defs"] = { next_id = { type = "string" }, ["rule-summary"] = { type = "string" } } })
    assert.matches("export type NextId = string;", text, 1, true)
    assert.matches("export type RuleSummary = string;", text, 1, true)
    local ok, err = pcall(gen, { ["$defs"] = { a_b = { type = "string" }, ["a-b"] = { type = "string" } } })
    assert.is_false(ok)
    assert.matches("already taken", err, 1, true)
    ok, err = pcall(gen, { ["$defs"] = { t = { type = "string" } } })
    assert.is_false(ok, "a $defs key that makes the name of the root type")
    assert.matches("already taken by the root", err, 1, true)
  end)
end)

describe("scripts/contract/dts.lua: what it refuses", function()
  ---@param bad table  the schema of the property `p`
  ---@return string message
  local function refused(bad)
    local ok, err = pcall(gen, { type = "object", properties = { p = bad } })
    assert.is_false(ok, "this schema must be refused")
    return tostring(err)
  end

  it("stops on a keyword outside the subset and names it and where it stands", function()
    local cases = {
      prefixItems = { type = "array", prefixItems = { { type = "string" } } },
      patternProperties = { type = "object", patternProperties = { ["^x"] = { type = "string" } } },
      ["if"] = { ["if"] = { type = "string" } },
      ["then"] = { ["then"] = { type = "string" } },
      ["not"] = { ["not"] = { type = "string" } },
      contains = { type = "array", contains = { type = "string" } },
      dependentRequired = { type = "object", dependentRequired = { a = { "b" } } },
      unevaluatedProperties = { type = "object", unevaluatedProperties = false },
      definitions = { definitions = {} },
      ["$dynamicRef"] = { ["$dynamicRef"] = "#meta" },
      ["$anchor"] = { ["$anchor"] = "x" },
      propertyNames = { type = "object", propertyNames = { pattern = "^a" } },
      contentEncoding = { type = "string", contentEncoding = "base64" },
    }
    for keyword, bad in pairs(cases) do
      local message = refused(bad)
      assert.matches(("unsupported keyword '%s'"):format(keyword), message, 1, true)
      assert.matches("at #/properties/p", message, 1, true)
    end
  end)

  it("stops on a $ref that is not a def of this schema", function()
    assert.matches("unsupported or unresolved $ref", refused({ ["$ref"] = "https://example.com/other.json" }), 1, true)
    assert.matches("unsupported or unresolved $ref", refused({ ["$ref"] = "#/$defs/missing" }), 1, true)
    assert.matches("unsupported or unresolved $ref", refused({ ["$ref"] = "#/definitions/x" }), 1, true)
  end)

  it("stops on a type it does not know, a combination it cannot say and a value of the wrong type", function()
    assert.matches("unsupported type 'date'", refused({ type = "date" }), 1, true)
    assert.matches("primitive types only", refused({ type = { "string", "object" } }), 1, true)
    assert.matches(
      "unsupported combination of 'oneOf' and 'type'",
      refused({ type = "string", oneOf = { { type = "string" } } }),
      1,
      true
    )
    assert.matches(
      "unsupported combination of '$ref' and 'allOf'",
      refused({ ["$ref"] = "#/x", allOf = { { type = "string" } } }),
      1,
      true
    )
    assert.matches("is not of the type 'string'", refused({ type = "string", enum = { "a", 1 } }), 1, true)
    assert.matches("items belongs to a schema of type array", refused({ type = "string", items = { type = "string" } }), 1, true)
    assert.matches("belong to a schema of type object", refused({ type = "string", properties = { a = {} } }), 1, true)
    assert.matches("enum must be a non-empty list", refused({ enum = {} }), 1, true)
    assert.matches("empty oneOf or anyOf", refused({ oneOf = {} }), 1, true)
  end)

  it("stops on $defs below the root and on a schema that is no object", function()
    assert.matches("'$defs' below the root", refused({ ["$defs"] = {} }), 1, true)
    assert.matches("a schema must be an object or a boolean", refused("string"), 1, true)
    local ok, err = pcall(dts.generate_text, "{not json", { name = "T" })
    assert.is_false(ok)
    assert.matches("not valid JSON", err, 1, true)
  end)

  it("never answers with `any`", function()
    -- the one open case, an empty schema, is `unknown`: the honest word for "anything" in TypeScript
    local text = gen({ type = "object", properties = { p = {}, q = true } })
    assert.is_nil(text:find("any", 1, true))
    assert.matches("p?: unknown;", text, 1, true)
    assert.matches("q?: unknown;", text, 1, true)
  end)
end)

describe("rules-export.d.ts against its schema", function()
  it("is exactly what the committed schema generates (regenerate with scripts/contract-dts.lua --write)", function()
    local generated = dts.generate_text(read(SCHEMA), { name = "RulesExport", label = LABEL })
    assert.are.equal(generated, read(COMMITTED))
  end)

  it("has a type for every kind of document and for the pieces they share", function()
    local text = read(COMMITTED)
    for _, name in ipairs({
      "RulesExport",
      "Hello",
      "Snapshot",
      "List",
      "Rule",
      "NextId",
      "Sources",
      "Waivers",
      "Result",
      "Error",
      "Head",
      "RuleSummary",
      "Waiver",
    }) do
      assert.matches("export type " .. name .. " =", text, 1, true)
    end
    assert.is_nil(text:find(": any", 1, true))
  end)
end)

-- @spawn: every case starts the script in its own nvim
describe("scripts/contract-dts.lua @spawn", function()
  ---@type string[]
  local made = {}

  ---@return string
  local function tmp_dir()
    local path = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(path, "p")
    made[#made + 1] = path
    return path
  end

  after_each(function()
    for _, path in ipairs(made) do
      vim.fn.delete(path, "rf")
    end
    made = {}
  end)

  ---@param ... string
  ---@return { code: integer, stdout: string, stderr: string }
  local function run(...)
    local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-n", "-l", CLI, ... }
    local done = vim.system(cmd, { text = true }):wait(60000)
    return { code = done.code, stdout = done.stdout or "", stderr = done.stderr or "" }
  end

  it("--check is green for the committed file (this is the CI step)", function()
    local result = run("--check")
    assert.are.equal(0, result.code, result.stderr)
    assert.matches("is current", result.stdout, 1, true)
    assert.are.equal(0, run().code, "--check is the default")
  end)

  it("--write generates the committed bytes into another folder, and writes nothing else", function()
    local dir = tmp_dir()
    local out = dir .. "/rules-export.d.ts"
    local result = run("--write", "--out=" .. out)
    assert.are.equal(0, result.code, result.stderr)
    assert.are.equal(read(COMMITTED), read(out))
    assert.are.equal(1, #vim.fn.glob(dir .. "/*", false, true), "one file")
  end)

  it("fails --check when the schema changed and the declarations were not regenerated, and --write repairs it", function()
    local dir = tmp_dir()
    local schema, out = dir .. "/rules-export.schema.json", dir .. "/rules-export.d.ts"
    write(out, read(COMMITTED))
    write(schema, read(SCHEMA))
    local common = { "--schema=" .. schema, "--out=" .. out, "--name=RulesExport", "--label=" .. LABEL }
    local function with(flag)
      return { flag, unpack(common) }
    end

    -- the same schema in another folder: current, so the failure below is the schema's doing
    local same = run(unpack(with("--check")))
    assert.are.equal(0, same.code, same.stderr)

    local needle = '"has_check": { "type": "boolean" },'
    local changed, replaced = read(SCHEMA):gsub(vim.pesc(needle), function()
      return needle .. '\n        "extra_field": { "type": "string" },'
    end)
    assert.are.equal(1, replaced, "the schema no longer has the line this spec edits")
    write(schema, changed)

    local stale = run(unpack(with("--check")))
    assert.are.equal(1, stale.code, stale.stdout)
    assert.matches("stale: ", stale.stderr, 1, true)
    assert.matches("differs from the schema, first at line ", stale.stderr, 1, true)
    assert.matches("--write", stale.stderr, 1, true)
    assert.are.equal(read(COMMITTED), read(out), "--check writes nothing")

    local written = run(unpack(with("--write")))
    assert.are.equal(0, written.code, written.stderr)
    assert.matches("extra_field?: string;", read(out), 1, true)
    assert.are.equal(0, run(unpack(with("--check"))).code, "current after --write")
  end)

  it("fails --check when the declarations are missing", function()
    local dir = tmp_dir()
    local result = run("--check", "--out=" .. dir .. "/none.d.ts")
    assert.are.equal(1, result.code)
    assert.matches("does not exist", result.stderr, 1, true)
  end)

  it("exits 1 with the keyword and its place for a schema outside the subset, and writes nothing", function()
    local dir = tmp_dir()
    local schema, out = dir .. "/bad.schema.json", dir .. "/bad.d.ts"
    write(schema, '{"type":"object","properties":{"p":{"type":"array","prefixItems":[{"type":"string"}]}}}')
    local result = run("--write", "--schema=" .. schema, "--out=" .. out)
    assert.are.equal(1, result.code)
    assert.matches("unsupported keyword 'prefixItems' at #/properties/p", result.stderr, 1, true)
    assert.are.equal(0, vim.fn.filereadable(out), "no file for a schema that cannot be typed")
  end)

  it("exits 2 on wrong usage and 1 when the schema cannot be read", function()
    assert.are.equal(2, run("--chek").code)
    assert.are.equal(2, run("--check", "--write").code)
    assert.are.equal(2, run("--write=1").code)
    assert.are.equal(2, run("--out=").code)
    local dir = tmp_dir()
    assert.are.equal(1, run("--schema=" .. dir .. "/none.schema.json").code)
  end)
end)
