---@module 'rules.engine.glob'
---@brief Match a "/"-separated relative path against a glob: `*` within a segment, `**` across segments.
---@description
--- One matcher for `file_exists` (a globbed path) and for the agent planner (`include` and `deny`
--- globs). Segments, not a string match: `\` is a separator as it is for a literal path, and `.` or an
--- empty segment (`./lua/*/x.lua`, `lua//*/x`) means nothing, exactly as the filesystem treats it.
--- Everything but `*` is literal; there is no `?`, no `[...]` and no `{a,b}`.

local M = {}

--- One glob segment as an anchored Lua pattern: `*` is any run of characters,
--- everything else is literal.
---@param segment string
---@return string
local function segment_pattern(segment)
  return "^" .. vim.pesc(segment):gsub("%%%*", ".*") .. "$"
end

--- Whether path segments `parts[pi..]` match glob segments `glob[gi..]`.
---@param glob string[]
---@param gi integer
---@param parts string[]
---@param pi integer
---@return boolean
local function segments_match(glob, gi, parts, pi)
  if gi > #glob then
    return pi > #parts
  end
  if glob[gi] == "**" then
    for skip = pi, #parts + 1 do
      if segments_match(glob, gi + 1, parts, skip) then
        return true
      end
    end
    return false
  end
  if pi > #parts or not parts[pi]:find(segment_pattern(glob[gi])) then
    return false
  end
  return segments_match(glob, gi + 1, parts, pi + 1)
end

--- The segments of a glob, ready for `M.match`.
---@param glob string
---@return string[] segments
function M.compile(glob)
  local segments = {}
  for _, segment in ipairs(vim.split((glob:gsub("\\", "/")), "/", { plain = true })) do
    if segment ~= "" and segment ~= "." then
      segments[#segments + 1] = segment
    end
  end
  return segments
end

--- The segments of a "/"-separated relative path, empty ones dropped (a root with a trailing separator comes
--- back from a walk as `root//lua/...`, whose first segment would otherwise be empty).
---@param path string
---@return string[] parts
function M.split(path)
  return vim.split(path, "/", { plain = true, trimempty = true })
end

--- Whether path `parts` (from `M.split`) match compiled `segments` (from `M.compile`).
---@param segments string[]
---@param parts string[]
---@return boolean
function M.match(segments, parts)
  return segments_match(segments, 1, parts, 1)
end

--- Whether the relative `path` matches `glob`.
---@param glob string
---@param path string
---@return boolean
function M.matches(glob, path)
  return M.match(M.compile(glob), M.split((path:gsub("\\", "/"))))
end

return M
