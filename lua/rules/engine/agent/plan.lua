---@module 'rules.engine.agent.plan'
---@brief Bundle the manual rules of a run into request batches, one set of files per batch.
---@description
--- A rule with no `check` is a `manual` result. `plan(rules, root, opts)` decides, for every such rule, which
--- files an agent would look at and which rules can share one request. It sends nothing and asks nobody: no
--- `vim.api`, no network, so the same function runs in the editor and in the desktop host.
---
--- **Scope.** The files a rule is judged against come from, in this order: the rule's own `agent.include`, the
--- `include` of its family in `agent.scopes` (`.rules.json` or `setup()`), nothing. With nothing the rule is
--- not sent: it stays `manual` and says why ("no scope to look in"). A model asked about architecture with no
--- code attached answers confidently from nothing.
---
--- **Deny.** Paths that must never leave the machine are dropped here, before any request exists, so the
--- guarantee holds in every host: the built-in `DENY` list (environment files, private keys, credential
--- stores) plus `agent.deny`. A deny glob without a `/` names a file at any depth (`*.pem`), one with a `/`
--- is relative to the root (`secrets/**`); a glob that matches a directory denies everything below it. The
--- built-in list cannot be switched off.
---
--- **Size.** A rule whose files are more than `agent.max_context_bytes` is never cut down quietly: it
--- becomes `unclear` with the reason "context exceeds limit". `agent.max_files` of a rule caps its file list
--- on purpose; the batch says so (`truncated`).
---
--- **Batches.** Rules that look at exactly the same files share a request, at most `agent.batch_size` (8) of
--- them. Order is deterministic: rules by id, files by path.

local glob = require("rules.engine.glob")
local fswalk = require("rules.engine.fswalk")
local runner = require("rules.engine.runner")

local uv = vim.uv or vim.loop

local M = {}

M.DEFAULT_BATCH_SIZE = 8
M.DEFAULT_MAX_CONTEXT_BYTES = 60000

--- What never goes into a request, whatever `agent.deny` says.
---@type string[]
M.DENY = {
  ".env",
  ".env.*",
  "*.pem",
  "*.key",
  "*.p12",
  "*.pfx",
  "*.jks",
  "*.keystore",
  "*.kdbx",
  "id_rsa*",
  "id_dsa*",
  "id_ecdsa*",
  "id_ed25519*",
  ".netrc",
  ".npmrc",
  ".pypirc",
  ".git-credentials",
  "credentials.json",
}

---@class Rules.Agent.PlanConfig
---@field batch_size? integer
---@field max_context_bytes? integer
---@field deny? string[]
---@field scopes? table<string, { include?: string[] }>

---@class Rules.Agent.PlanOpts
---@field agent? Rules.Agent.PlanConfig  the merged `agent` block (`rules.config`); absent fields take their defaults
---@field files? string[]  every file of the tree, relative and "/"-separated; default: the walk of `root` (`fswalk`)
---@field size? fun(path: string): integer|nil  byte size of a relative path; default: `stat` under `root`

---@class Rules.Agent.BatchRule
---@field rule Rules.ParsedRule
---@field truncated? { total: integer, kept: integer }  the rule's own `max_files` cut its file list

---@class Rules.Agent.Batch
---@field id string  `b1`, `b2`, ... in plan order
---@field files string[]  relative paths the request carries, sorted
---@field bytes integer  their size together
---@field rules Rules.Agent.BatchRule[]  1 to `batch_size`, sorted by rule id
---@field scope "rule"|"family"  where the files came from (every rule of a batch has the same files, not always the same source)

---@class Rules.Agent.Skipped
---@field rule Rules.ParsedRule
---@field status "manual"|"unclear"  `manual`: not sent, stays on the worklist; `unclear`: sending it would have been wrong
---@field reason string

---@class Rules.Agent.Plan
---@field batches Rules.Agent.Batch[]
---@field skipped Rules.Agent.Skipped[]  sorted by rule id
---@field denied string[]  files a scope matched but the deny list removed, sorted and unique

---@param patterns string[]
---@return string[][] compiled
local function compile_deny(patterns)
  local compiled = {}
  for _, pattern in ipairs(patterns) do
    local normalized = pattern:gsub("\\", "/")
    -- Without a slash a glob names a file at any depth (like a gitignore line).
    local anchored = normalized:find("/", 1, true) and normalized or ("**/" .. normalized)
    compiled[#compiled + 1] = glob.compile(anchored)
  end
  return compiled
end

--- Whether `parts` or any directory above it matches a deny glob.
---@param compiled string[][]
---@param parts string[]
---@return boolean
local function is_denied(compiled, parts)
  for _, segments in ipairs(compiled) do
    for depth = 1, #parts do
      if glob.match(segments, { unpack(parts, 1, depth) }) then
        return true
      end
    end
  end
  return false
end

---@param root string
---@return string[] files
local function walk(root)
  local prefix = (root:gsub("\\", "/"):gsub("/+$", "")) .. "/"
  local out = {}
  for _, abs in ipairs(fswalk.files(root)) do
    if abs:sub(1, #prefix) == prefix then
      out[#out + 1] = abs:sub(#prefix + 1)
    end
  end
  return out
end

--- Which include globs a rule has, and where they come from.
---@param rule Rules.ParsedRule
---@param scopes table<string, { include?: string[] }>
---@return string[]|nil includes
---@return "rule"|"family"|nil source
local function scope_of(rule, scopes)
  local own = rule.agent and rule.agent.include
  if type(own) == "table" and #own > 0 then
    return own, "rule"
  end
  local family = scopes[runner.family_of(rule.id)]
  local inherited = family and family.include
  if type(inherited) == "table" and #inherited > 0 then
    return inherited, "family"
  end
  return nil, nil
end

--- Plan one run: which manual rules go out in which request, and which stay behind and why.
---@param rules Rules.ParsedRule[]  any rules; those with a `check` are not manual and are left alone
---@param root string  the tree the files are read from
---@param opts? Rules.Agent.PlanOpts
---@return Rules.Agent.Plan
function M.plan(rules, root, opts)
  opts = opts or {}
  local cfg = opts.agent or {}
  local batch_size = cfg.batch_size or M.DEFAULT_BATCH_SIZE
  local max_bytes = cfg.max_context_bytes or M.DEFAULT_MAX_CONTEXT_BYTES
  local scopes = cfg.scopes or {}
  local deny = compile_deny(vim.list_extend(vim.deepcopy(M.DENY), cfg.deny or {}))

  local files = opts.files or walk(root)
  table.sort(files)
  local sizes = {}
  local function size_of(path)
    if sizes[path] == nil then
      local bytes
      if opts.size then
        bytes = opts.size(path)
      else
        local stat = uv.fs_stat(root .. "/" .. path)
        bytes = stat and stat.size
      end
      sizes[path] = bytes or 0
    end
    return sizes[path]
  end

  local split, denied_path = {}, {}
  for _, path in ipairs(files) do
    split[path] = glob.split(path)
    denied_path[path] = is_denied(deny, split[path])
  end

  local denied_set = {}
  ---@type Rules.Agent.Skipped[]
  local skipped = {}
  ---@type table<string, { files: string[], bytes: integer, entries: Rules.Agent.BatchRule[], scope: "rule"|"family" }>
  local groups = {}
  ---@type string[]
  local group_order = {}

  local manual = {}
  for _, rule in ipairs(rules) do
    if rule.check == nil then
      manual[#manual + 1] = rule
    end
  end
  table.sort(manual, function(a, b)
    return a.id < b.id
  end)

  for _, rule in ipairs(manual) do
    local includes, source = scope_of(rule, scopes)
    if not includes then
      skipped[#skipped + 1] = { rule = rule, status = "manual", reason = "no scope to look in" }
    else
      local compiled = {}
      for _, pattern in ipairs(includes) do
        compiled[#compiled + 1] = glob.compile(pattern)
      end
      local matched, denied_here = {}, 0
      for _, path in ipairs(files) do
        for _, segments in ipairs(compiled) do
          if glob.match(segments, split[path]) then
            if denied_path[path] then
              denied_set[path] = true
              denied_here = denied_here + 1
            else
              matched[#matched + 1] = path
            end
            break
          end
        end
      end

      if #matched == 0 then
        local reason = "scope matches no file"
        if denied_here > 0 then
          reason = ("scope matches no file that may be sent (%d denied)"):format(denied_here)
        end
        skipped[#skipped + 1] = { rule = rule, status = "manual", reason = reason }
      else
        local truncated
        local cap = rule.agent and rule.agent.max_files
        if cap and #matched > cap then
          truncated = { total = #matched, kept = cap }
          matched = { unpack(matched, 1, cap) }
        end
        local bytes = 0
        for _, path in ipairs(matched) do
          bytes = bytes + size_of(path)
        end
        if bytes > max_bytes then
          skipped[#skipped + 1] = {
            rule = rule,
            status = "unclear",
            reason = ("context exceeds limit (%d bytes, limit %d)"):format(bytes, max_bytes),
          }
        else
          local key = table.concat(matched, "\n")
          local group = groups[key]
          if not group then
            group = { files = matched, bytes = bytes, entries = {}, scope = source }
            groups[key] = group
            group_order[#group_order + 1] = key
          end
          group.entries[#group.entries + 1] = { rule = rule, truncated = truncated }
        end
      end
    end
  end

  -- Groups in the order their first rule appears (rules are sorted by id), cut into batches of `batch_size`.
  local batches = {}
  for _, key in ipairs(group_order) do
    local group = groups[key]
    for first = 1, #group.entries, batch_size do
      batches[#batches + 1] = {
        id = "b" .. (#batches + 1),
        files = group.files,
        bytes = group.bytes,
        rules = { unpack(group.entries, first, math.min(first + batch_size - 1, #group.entries)) },
        scope = group.scope,
      }
    end
  end

  local denied = vim.tbl_keys(denied_set)
  table.sort(denied)
  table.sort(skipped, function(a, b)
    return a.rule.id < b.rule.id
  end)
  return { batches = batches, skipped = skipped, denied = denied }
end

return M
