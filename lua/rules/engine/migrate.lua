---@module 'rules.engine.migrate'
---@brief Turn a ruleset of documents with ```rule blocks into one file per rule plus layouts.
---@description
--- The legacy shape keeps many rules in one reading document. The new shape
--- (`docs/RULESET-FORMAT.md`) keeps each rule in its own file and makes the
--- document from a *layout*. This module converts the one into the other and
--- **proves** the result before it writes anything: a document is converted
--- only when rendering the new files gives back the old text, byte for byte,
--- apart from the table of contents (which is generated now; the number of
--- lines that differ is reported).
---
--- What a rule file holds (variant B of the measurement,
--- `NOTES/speicherformat-messung/ERGEBNIS-2026-10-13.md` in the vault):
---   * the frontmatter has `id`, `severity`, `family`;
---   * the heading that names the rule, the prose, the `---` that frames it, as
---     they were;
---   * a ```rule block only when it says more than `id` and `severity`
---     (`check`, `agent`, ...), without those two lines. A rule whose block sits
---     somewhere other than right under its heading keeps an *empty* block as a
---     marker for the place.
---
--- A layout is the document with each rule replaced by `{{rule ID}}` and the
--- table of contents by `{{toc}}`.
---
--- `convert_document` is pure (text in, texts out). `run` walks a ruleset and,
--- with `write`, writes the files; `compare` loads two rulesets and says whether
--- they hold the same rules.

local parser = require("rules.engine.parser")
local catalog = require("rules.engine.catalog")
local fswalk = require("rules.engine.fswalk")
local loader = require("rules.engine.loader")
local expand_path = require("lib.nvim.cross.fs.expand_path")

local M = {}

M.DEFAULT_RULES_DIR = "_rules"
M.DEFAULT_LAYOUTS_DIR = "_layouts"

---@param line string
---@return boolean
local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

--- A line of the hand-kept table of contents: `  - [text](#anchor)`.
---@param line string
---@return boolean
local function is_toc_line(line)
  return line:match("^%s*%- %[.-%]%(#.-%)%s*$") ~= nil
end

---@class Rules.Conversion
---@field output string  the document's path relative to the root
---@field rule_files {id: string, family: string, text: string}[]
---@field layout_text string|nil
---@field toc "same"|"differs"|"none"
---@field toc_lines_changed integer
---@field problems string[]  a non-empty list means nothing was converted

--- Convert one reading document.
---@param output string  the document's path relative to the root, with `/`
---@param text string
---@param layout_rel? string  where the layout will be (relative to the root), for the header of the new document
---@return Rules.Conversion
function M.convert_document(output, text, layout_rel)
  local result = { output = output, rule_files = {}, toc = "none", toc_lines_changed = 0, problems = {} }
  local function problem(message)
    result.problems[#result.problems + 1] = ("%s: %s"):format(output, message)
  end
  if text:find("\r", 1, true) then
    problem("has CRLF line endings; convert it to LF first")
    return result
  end

  local lines = vim.split(text, "\n", { plain = true })
  local ends_with_newline = lines[#lines] == ""
  if ends_with_newline then
    lines[#lines] = nil
  else
    problem("does not end with a newline")
    return result
  end

  -- fences, blocks and headings (outside other fences)
  local in_fence, fence_is_rule = false, false
  local blocks = {}
  local heading = {}
  for i, line in ipairs(lines) do
    if in_fence then
      if line:match("^```%s*$") then
        in_fence = false
        if fence_is_rule then
          blocks[#blocks].e = i
        end
      end
    elseif line:match("^```") then
      in_fence = true
      fence_is_rule = line:match("^```rule%s*$") ~= nil
      if fence_is_rule then
        blocks[#blocks + 1] = { s = i }
      end
    elseif line:match("^#+ ") then
      heading[i] = true
    end
  end
  if in_fence then
    problem("ends inside a fenced block")
    return result
  end
  if #blocks == 0 then
    problem("has no ```rule block")
    return result
  end

  -- segments: the naming heading (if the blank lines above the block lead to one) up to the next heading or segment
  local segments = {}
  for k, block in ipairs(blocks) do
    local s = block.s
    local j = block.s - 1
    while j >= 1 and is_blank(lines[j]) do
      j = j - 1
    end
    if j >= 1 and heading[j] then
      s = j
    else
      problem(("the block at line %d has no heading above it"):format(block.s))
    end
    segments[k] = { s = s, block = block }
  end
  for k, segment in ipairs(segments) do
    local next_start = #lines + 1
    for i = segment.block.e + 1, #lines do
      if heading[i] then
        next_start = i
        break
      end
    end
    if segments[k + 1] and segments[k + 1].s < next_start then
      next_start = segments[k + 1].s
    end
    segment.e = next_start - 1
  end
  if #result.problems > 0 then
    return result
  end

  local skeleton = {}
  local cursor = 1
  local seen = {}
  for _, segment in ipairs(segments) do
    local block = segment.block
    local first, second = lines[block.s + 1], lines[block.s + 2]
    local id = (first or ""):match('^id = "([^"]+)",$')
    local severity = (second or ""):match('^severity = "([^"]+)",$')
    if not id or not severity or not block.e or block.e < block.s + 3 then
      problem(('the block at line %d does not start with `id = "...",` and `severity = "...",`'):format(block.s))
    elseif seen[id] then
      problem(("rule %s appears twice"):format(id))
    elseif not is_blank(lines[block.s - 1] or "x") then
      problem(("rule %s: no blank line above the block"):format(id))
    elseif not is_blank(lines[block.e + 1] or "x") then
      problem(("rule %s: no blank line below the block"):format(id))
    else
      seen[id] = true
      local family = id:match("^(%a+)")
      if not family then
        problem(("rule %s: the id does not start with letters"):format(id))
      else
        local pre = {}
        for i = segment.s, block.s - 1 do
          pre[#pre + 1] = lines[i]
        end
        local rest = {}
        for i = block.s + 3, block.e - 1 do
          rest[#rest + 1] = lines[i]
        end
        local post = {}
        for i = block.e + 1, segment.e do
          post[#post + 1] = lines[i]
        end
        -- the heading is the line above the block (through blank lines only), so a block with nothing but id and
        -- severity can be left out of the file; one with more keeps those lines, without the two identity lines
        local implicit = #rest == 0
        local body = {}
        vim.list_extend(body, pre)
        if implicit then
          for i = 2, #post do
            body[#body + 1] = post[i]
          end
        else
          body[#body + 1] = "```rule"
          vim.list_extend(body, rest)
          body[#body + 1] = "```"
          vim.list_extend(body, post)
        end
        result.rule_files[#result.rule_files + 1] = {
          id = id,
          family = family,
          text = ("---\nid: %s\nseverity: %s\nfamily: %s\n---\n\n%s\n"):format(id, severity, family, table.concat(body, "\n")),
        }
        for i = cursor, segment.s - 1 do
          skeleton[#skeleton + 1] = lines[i]
        end
        skeleton[#skeleton + 1] = ("{{rule %s}}"):format(id)
        cursor = segment.e + 1
      end
    end
  end
  if #result.problems > 0 then
    result.rule_files = {}
    return result
  end
  for i = cursor, #lines do
    skeleton[#skeleton + 1] = lines[i]
  end

  -- the hand-kept table of contents: the first run of link lines, replaced by the token
  local toc_from, toc_to
  for i, line in ipairs(skeleton) do
    if is_toc_line(line) then
      toc_from = toc_from or i
      toc_to = i
    elseif toc_from and i > toc_to then
      break
    end
  end
  local toc_index
  if toc_from and toc_to - toc_from >= 1 then
    local with_token = {}
    for i = 1, toc_from - 1 do
      with_token[#with_token + 1] = skeleton[i]
    end
    toc_index = #with_token + 1
    with_token[toc_index] = catalog.TOC_TOKEN
    for i = toc_to + 1, #skeleton do
      with_token[#with_token + 1] = skeleton[i]
    end
    result.toc = "same"
    result.hand_toc = vim.list_slice(skeleton, toc_from, toc_to)
    skeleton = with_token
  end

  local by_id = {}
  for _, rule_file in ipairs(result.rule_files) do
    local parsed, errs = parser.split_text(rule_file.id .. ".md", rule_file.text)
    if not parsed then
      problem(("rule file for %s does not read back: %s"):format(rule_file.id, errs[1]))
      return result
    end
    by_id[rule_file.id] = parsed
  end
  local function lookup(id)
    return by_id[id], "no such rule file"
  end

  --- Render the layout with `token` for the table of contents.
  ---@param token string|nil
  ---@return string|nil rendered
  ---@return string|nil err
  local function render_with(token)
    if toc_index then
      skeleton[toc_index] = token
    end
    result.layout_text = ("---\nkind: layout\noutput: %s\n---\n%s\n"):format(output, table.concat(skeleton, "\n"))
    local layout, layout_err = catalog.parse_layout(result.layout_text)
    if not layout then
      return nil, "the layout does not read back: " .. layout_err
    end
    local doc, render_problems = catalog.render(layout, lookup, nil)
    if not doc then
      return nil, "rendering failed: " .. render_problems[1]
    end
    return doc, nil
  end

  -- the hand-kept table of contents says which levels it lists and how it indents; find the parameters that
  -- give exactly those lines (the default first)
  local rendered, render_err = render_with(catalog.TOC_TOKEN)
  if not rendered then
    problem(render_err)
    return result
  end
  if toc_index then
    local function toc_of(doc)
      local out = {}
      for _, line in ipairs(vim.split(doc, "\n", { plain = true })) do
        if is_toc_line(line) then
          out[#out + 1] = line
        end
      end
      return out
    end
    local hand = result.hand_toc
    if table.concat(toc_of(rendered), "\n") ~= table.concat(hand, "\n") then
      local document = {}
      for _, line in ipairs(vim.split(rendered, "\n", { plain = true })) do
        if not is_toc_line(line) then
          document[#document + 1] = line
        end
      end
      local wanted = table.concat(hand, "\n")
      for _, unicode in ipairs({ 0, 1 }) do
        for _, underscore in ipairs({ 1, 0 }) do
          for _, max in ipairs({ 4, 2, 3, 5, 6 }) do
            for _, base in ipairs({ 2, 0, 4 }) do
              for _, step in ipairs({ 2, 0, 4 }) do
                local params = { max = max, base = base, step = step, unicode = unicode, underscore = underscore }
                if table.concat(catalog.toc_lines(document, params), "\n") == wanted then
                  local better, err = render_with(catalog.toc_token(params))
                  if not better then
                    problem(err)
                    return result
                  end
                  rendered = better
                  goto found
                end
              end
            end
          end
        end
      end
      ::found::
    end
  end
  result.document_text = catalog.header(layout_rel or ("_layouts/" .. output)) .. "\n" .. rendered
  if rendered ~= text then
    -- only the table of contents may differ
    local function without_toc(doc)
      local kept = {}
      for _, line in ipairs(vim.split(doc, "\n", { plain = true })) do
        if not is_toc_line(line) then
          kept[#kept + 1] = line
        end
      end
      return table.concat(kept, "\n")
    end
    if without_toc(rendered) ~= without_toc(text) then
      problem("the rendered document differs from the original beyond its table of contents")
      return result
    end
    result.toc = "differs"
    local old = result.hand_toc or {}
    local new = {}
    for _, line in ipairs(vim.split(rendered, "\n", { plain = true })) do
      if is_toc_line(line) then
        new[#new + 1] = line
      end
    end
    local changed = math.abs(#old - #new)
    for i = 1, math.min(#old, #new) do
      if old[i] ~= new[i] then
        changed = changed + 1
      end
    end
    result.toc_lines_changed = changed
    result.toc_examples = {}
    for i = 1, math.min(#old, #new) do
      if old[i] ~= new[i] and #result.toc_examples < 3 then
        result.toc_examples[#result.toc_examples + 1] = { old = old[i], new = new[i] }
      end
    end
  end
  return result
end

---@class Rules.MigrationReport
---@field conversions Rules.Conversion[]
---@field written string[]  paths written (empty without `write`)
---@field problems string[]

--- Convert every document of the ruleset at `root` that has rule blocks.
---@param root string
---@param opts? { write?: boolean, rules_dir?: string, layouts_dir?: string }
---@return Rules.MigrationReport
function M.run(root, opts)
  opts = opts or {}
  local rules_dir = opts.rules_dir or M.DEFAULT_RULES_DIR
  local layouts_dir = opts.layouts_dir or M.DEFAULT_LAYOUTS_DIR
  local base = vim.fs.normalize(vim.fn.fnamemodify(expand_path(root), ":p")):gsub("/+$", "")
  local report = { conversions = {}, written = {}, problems = {} }

  local documents = {}
  for _, file in ipairs(fswalk.files(base)) do
    local rel = file:sub(#base + 2)
    if
      file:match("%.md$")
      and not rel:match("^" .. vim.pesc(rules_dir) .. "/")
      and not rel:match("^" .. vim.pesc(layouts_dir) .. "/")
    then
      local read_ok, lines = pcall(vim.fn.readfile, file)
      if read_ok and parser.classify(lines) == "legacy" then
        for _, line in ipairs(lines) do
          if line:match("^```rule%s*$") then
            documents[#documents + 1] = { path = file, rel = rel }
            break
          end
        end
      end
    end
  end
  table.sort(documents, function(a, b)
    return a.rel < b.rel
  end)

  local planned = {}
  local replacements = {}
  local ids = {}
  for _, document in ipairs(documents) do
    local f = assert(io.open(document.path, "rb"))
    local text = f:read("*a")
    f:close()
    local conversion = M.convert_document(document.rel, text, layouts_dir .. "/" .. document.rel)
    report.conversions[#report.conversions + 1] = conversion
    vim.list_extend(report.problems, conversion.problems)
    for _, rule_file in ipairs(conversion.rule_files) do
      if ids[rule_file.id] then
        report.problems[#report.problems + 1] = ("rule %s is in %s and in %s"):format(
          rule_file.id,
          ids[rule_file.id],
          document.rel
        )
      end
      ids[rule_file.id] = document.rel
      local target = ("%s/%s/%s/%s.md"):format(base, rules_dir, rule_file.family, rule_file.id)
      if vim.uv.fs_stat(target) then
        report.problems[#report.problems + 1] = ("%s already exists"):format(target)
      end
      planned[#planned + 1] = { path = target, text = rule_file.text }
    end
    if conversion.layout_text then
      local target = ("%s/%s/%s"):format(base, layouts_dir, document.rel)
      if vim.uv.fs_stat(target) then
        report.problems[#report.problems + 1] = ("%s already exists"):format(target)
      end
      planned[#planned + 1] = { path = target, text = conversion.layout_text }
      -- the document itself comes last: until it is replaced, its rules would load twice
      replacements[#replacements + 1] = { path = document.path, text = conversion.document_text }
    end
  end

  if opts.write and #report.problems == 0 then
    local atomic = require("lib.nvim.fs.write.atomic")
    local function write_all(files)
      for _, file in ipairs(files) do
        local ok, err = atomic(file.path, file.text, { mkdirp = true })
        if not ok then
          report.problems[#report.problems + 1] = ("%s: %s"):format(file.path, err)
          return false
        end
        report.written[#report.written + 1] = file.path
      end
      return true
    end
    if write_all(planned) and write_all(replacements) then
      -- the proof on disk: the documents the generator makes are the ones just written
      local results, errors = catalog.build(base, { check = true })
      for _, result in ipairs(results) do
        if result.status ~= "unchanged" then
          report.problems[#report.problems + 1] = ("%s is %s after the migration"):format(result.output, result.status)
        end
        vim.list_extend(report.problems, result.problems)
      end
      vim.list_extend(report.problems, errors)
    end
  end
  return report
end

---@class Rules.Comparison
---@field before integer
---@field after integer
---@field missing string[]  ids only in `before`
---@field added string[]  ids only in `after`
---@field different {id: string, fields: string[]}[]
---@field errors_before integer
---@field errors_after integer

--- Load two rulesets and compare the rules: same ids, same severity, check,
--- agent, text and title. A `check.fn` (a function) counts as equal to another.
---@param before_root string
---@param after_root string
---@return Rules.Comparison
function M.compare(before_root, after_root)
  local a, ea = loader.load({ before_root })
  local b, eb = loader.load({ after_root })
  local by = {}
  for _, rule in ipairs(b) do
    by[rule.id] = rule
  end
  local seen = {}
  local out = { before = #a, after = #b, missing = {}, added = {}, different = {}, errors_before = #ea, errors_after = #eb }

  local function same(x, y)
    if type(x) == "table" and type(y) == "table" then
      for k, v in pairs(x) do
        if not same(v, y[k]) then
          return false
        end
      end
      for k in pairs(y) do
        if x[k] == nil then
          return false
        end
      end
      return true
    end
    if type(x) == "function" and type(y) == "function" then
      return true
    end
    return x == y
  end

  for _, rule in ipairs(a) do
    seen[rule.id] = true
    local other = by[rule.id]
    if not other then
      out.missing[#out.missing + 1] = rule.id
    else
      local fields = {}
      for _, key in ipairs({ "severity", "check", "agent", "text", "title" }) do
        if not same(rule[key], other[key]) then
          fields[#fields + 1] = key
        end
      end
      if #fields > 0 then
        out.different[#out.different + 1] = { id = rule.id, fields = fields }
      end
    end
  end
  for _, rule in ipairs(b) do
    if not seen[rule.id] then
      out.added[#out.added + 1] = rule.id
    end
  end
  return out
end

return M
