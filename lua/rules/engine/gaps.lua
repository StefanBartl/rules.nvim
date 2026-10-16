---@module 'rules.engine.gaps'
---@brief The numbers a family skips: `DEP-01` and `DEP-03` with no `DEP-02` between them.
---@description
--- Pure: takes ids, returns what is not taken; reads no file. A gap is a **hint, never a load error**: it appears
--- legitimately when a rule is deleted instead of retired, and a ruleset may number in blocks on purpose
--- (`PRIN-10`..`PRIN-19` for one topic, `PRIN-20`.. for the next). What the caller counts as taken is its business;
--- `rules.contract` hands in the ids of the loaded rules **and** of the retired ones (a retired rule keeps its id, so it
--- leaves no gap).
---
--- Only ids of the shape `<letters>-<digits>` have a number (the shape `rules.contract` numbers by for `next_id`); any
--- other id is none of this module's business. `DEP-1` and `DEP-01` are one number. A number of more than 15 digits is
--- not counted (a double holds no more exactly, and the span to it would be a gap of no use to anybody).

local canonical = require("lib.nvim.json.canonical")

local M = {}

--- Numbers of more digits than this are left out.
M.MAX_DIGITS = 15

--- How many ranges of one family the text of `M.text` spells out before it says "and N more".
M.MAX_LISTED = 12

---@class Rules.GapRange
---@field from integer  first number not taken
---@field to integer  last number not taken (`from` when it is one number)

---@class Rules.FamilyGaps
---@field family string
---@field first integer  the smallest number taken
---@field last integer  the largest number taken
---@field taken integer  how many numbers between them are taken
---@field missing integer  how many are not
---@field width integer  digits of the widest number the family uses, at least 2: the spelling of an id that is missing
---@field ranges Rules.GapRange[]  what is missing, in order

--- The ids of a family between its smallest and largest number that nobody has taken. Families with no gap are not in
--- the answer, so an empty list is "every family is numbered without a hole".
---@param ids string[]  every id that is taken (a repeated one counts once)
---@return Rules.FamilyGaps[] gaps  by family, in byte order
function M.find(ids)
  local fams = {} ---@type table<string, { set: table<number, true>, width: integer }>
  for _, id in ipairs(ids) do
    local family, num = id:match("^(%a+)%-(%d+)$")
    if family then
      local fam = fams[family] or { set = {}, width = 2 }
      fams[family] = fam
      fam.width = math.max(fam.width, #num)
      local digits = (num:gsub("^0+", ""))
      if #digits <= M.MAX_DIGITS then
        fam.set[tonumber(digits == "" and "0" or digits)] = true
      end
    end
  end

  local out = {}
  for family, fam in pairs(fams) do
    local numbers = {}
    for n in pairs(fam.set) do
      numbers[#numbers + 1] = n
    end
    table.sort(numbers)
    local ranges, missing = {}, 0
    for i = 2, #numbers do
      local hole = numbers[i] - numbers[i - 1] - 1
      if hole > 0 then
        ranges[#ranges + 1] = { from = numbers[i - 1] + 1, to = numbers[i] - 1 }
        missing = missing + hole
      end
    end
    if missing > 0 then
      out[#out + 1] = {
        family = family,
        first = numbers[1],
        last = numbers[#numbers],
        taken = #numbers,
        missing = missing,
        width = fam.width,
        ranges = ranges,
      }
    end
  end
  table.sort(out, function(a, b)
    return canonical.bytes_less(a.family, b.family)
  end)
  return out
end

--- An id as the family spells it: the number padded with zeros to the width the family uses.
---@param family string
---@param n integer
---@param width integer
---@return string
function M.id(family, n, width)
  local digits = ("%.0f"):format(n)
  return family .. "-" .. ("0"):rep(width - #digits) .. digits
end

--- One line about a family: `DEP: DEP-02, DEP-05..DEP-07 not taken between DEP-01 and DEP-08`. A family with more
--- ranges than `M.MAX_LISTED` says how many it leaves out.
---@param gap Rules.FamilyGaps
---@return string
function M.text(gap)
  local parts = {}
  for i = 1, math.min(#gap.ranges, M.MAX_LISTED) do
    local range = gap.ranges[i]
    local from = M.id(gap.family, range.from, gap.width)
    parts[i] = range.to == range.from and from or (from .. ".." .. M.id(gap.family, range.to, gap.width))
  end
  if #gap.ranges > M.MAX_LISTED then
    parts[#parts + 1] = ("and %d more range(s)"):format(#gap.ranges - M.MAX_LISTED)
  end
  return ("%s: %s not taken between %s and %s"):format(
    gap.family,
    table.concat(parts, ", "),
    M.id(gap.family, gap.first, gap.width),
    M.id(gap.family, gap.last, gap.width)
  )
end

--- How many numbers are not taken, over all families.
---@param gaps Rules.FamilyGaps[]
---@return integer
function M.total(gaps)
  local n = 0
  for _, gap in ipairs(gaps) do
    n = n + gap.missing
  end
  return n
end

return M
