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
---     (`check`, `agent`, ...), without those two lines. A block that is not
---     right under its heading (only blank lines between) makes the document
---     refuse to convert: the heading is what names the rule.
---
--- A layout is the document with each rule replaced by `{{rule ID}}` and the
--- table of contents by `{{toc}}`.
---
--- `convert_document` is pure (text in, texts out). `run` walks a ruleset and,
--- with `write`, writes the files, checks them on disk, and takes everything it
--- wrote back when a write or that check fails; `compare` loads two rulesets and
--- says whether they hold the same rules.

local parser = require("rules.engine.parser")
local catalog = require("rules.engine.catalog")
local fswalk = require("rules.engine.fswalk")
local loader = require("rules.engine.loader")
local expand_path = require("lib.nvim.cross.fs.expand_path")
local is_subpath = require("lib.nvim.fs.is_subpath")
local frontmatter = require("lib.nvim.markdown.frontmatter")

local M = {}

M.DEFAULT_RULES_DIR = "_rules"
M.DEFAULT_LAYOUTS_DIR = "_layouts"

local uv = vim.uv or vim.loop

--- Paths that differ only in case are one file on Windows and (by default) on macOS.
local CASE_INSENSITIVE = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1

--- The longest id echoed in a message.
local SHOWN_BYTES = 100

--- An id out of a document, for a message: cut, with control characters made visible, so a hostile document cannot
--- forge lines or terminal escapes through it (the parser does the same with what it echoes).
---@param value string
---@return string
local function shown(value)
  local cut = value:sub(1, SHOWN_BYTES):gsub("%c", "?")
  return #value > SHOWN_BYTES and cut .. "..." or cut
end

---@param line string
---@return boolean
local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

--- A line of the hand-kept table of contents: `  - [text](#anchor)`. The same reading as
--- `^%s*%- %[.-%]%(#.-%)%s*$`, without that pattern's quadratic retry: a long line of `](#)x` runs cost seconds.
--- The `](#` is looked for once (the first one is the most permissive), and the last non-blank byte must be a `)` after it.
---@param line string
---@return boolean
local function is_toc_line(line)
  local _, prefix_end = line:find("^%s*%- %[")
  if not prefix_end then
    return false
  end
  -- anchored and greedy, so it only backs off over the trailing blanks
  local trimmed = line:match("^(.*%S)")
  if not trimmed or trimmed:sub(-1) ~= ")" then
    return false
  end
  local at = trimmed:find("](#", prefix_end + 1, true)
  return at ~= nil and at + 3 <= #trimmed
end

--- The lines of a document that are not a table-of-contents line, and the number each has in the document.
---@param doc_lines string[]
---@return string[] kept
---@return integer[] numbers
local function without_toc(doc_lines)
  local kept, numbers = {}, {}
  for i, line in ipairs(doc_lines) do
    if not is_toc_line(line) then
      kept[#kept + 1] = line
      numbers[#numbers + 1] = i
    end
  end
  return kept, numbers
end

--- The table-of-contents lines of a document.
---@param doc_lines string[]
---@return string[]
local function toc_of(doc_lines)
  local out = {}
  for _, line in ipairs(doc_lines) do
    if is_toc_line(line) then
      out[#out + 1] = line
    end
  end
  return out
end

--- Lines as the text `vim.diff` wants: each ends in a newline, none for no lines.
---@param list string[]
---@return string
local function as_text(list)
  return #list == 0 and "" or table.concat(list, "\n") .. "\n"
end

--- The parameters of `{{toc ...}}` that give exactly the hand-kept lines out of `outline`, the default first, or nil.
---@param outline string[]  the lines of the document that can matter to a table of contents (see the caller)
---@param wanted string[]
---@return Rules.TocParams|nil
local function find_toc_params(outline, wanted)
  local joined = table.concat(wanted, "\n")
  for _, unicode in ipairs({ 0, 1 }) do
    for _, underscore in ipairs({ 1, 0 }) do
      -- an anchor with `unicode = 1` never looks at `underscore`: the second spelling would repeat the first
      if not (unicode == 1 and underscore == 0) then
        for _, max in ipairs({ 4, 2, 3, 5, 6 }) do
          for _, base in ipairs({ 2, 0, 4 }) do
            for _, step in ipairs({ 2, 0, 4 }) do
              local params = { max = max, base = base, step = step, unicode = unicode, underscore = underscore }
              if table.concat(catalog.toc_lines(outline, params), "\n") == joined then
                return params
              end
            end
          end
        end
      end
    end
  end
  return nil
end

---@class Rules.Conversion
---@field output string  the document's path relative to the root
---@field rule_files {id: string, family: string, text: string}[]
---@field layout_text string|nil
---@field document_text string|nil  the generated document that replaces the old one
---@field toc "same"|"differs"|"none"
---@field toc_lines_changed integer  lines of the generated table that are not in the hand-kept one (by a real line diff)
---@field toc_examples {old: string, new: string}[]|nil  up to three lines that changed
---@field hand_toc string[]|nil  the hand-kept table of contents
---@field problems string[]  a non-empty list means nothing was converted: the other fields are empty

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
  --- Give the document up: whatever was made of it so far is dropped, so a refusal never carries half a conversion.
  ---@return Rules.Conversion
  local function refuse()
    result.rule_files = {}
    result.layout_text = nil
    result.document_text = nil
    result.hand_toc = nil
    result.toc = "none"
    result.toc_lines_changed = 0
    result.toc_examples = nil
    return result
  end
  if text:find("\r", 1, true) then
    problem("has CRLF line endings; convert it to LF first")
    return refuse()
  end

  local lines = vim.split(text, "\n", { plain = true })
  local ends_with_newline = lines[#lines] == ""
  if ends_with_newline then
    lines[#lines] = nil
  else
    problem("does not end with a newline")
    return refuse()
  end

  -- The GENERATED header has to be line 1 (the loader looks only there), so a byte order mark or a frontmatter at the
  -- top of the document would be pushed down by it and stop being one.
  if text:sub(1, 3) == "\239\187\191" then
    problem("starts with a byte order mark, which the GENERATED header on line 1 would push down; remove it first")
    return refuse()
  end
  if (lines[1] or ""):match("^%-%-%-[ \t]*$") then
    local close
    for i = 2, #lines do
      if lines[i]:match("^%-%-%-[ \t]*$") then
        close = i
        break
      end
    end
    local head = close and frontmatter.parse(table.concat(lines, "\n", 1, close))
    -- two `---` lines around prose are thematic breaks, which stay what they are below the header
    if head and head.has_block and not head.prose then
      problem("starts with a frontmatter, which the GENERATED header on line 1 would push down; move it out first")
      return refuse()
    end
  end

  -- Fences, blocks and headings (outside other fences). A fence closes on at least as many backticks as opened it,
  -- as in the parser: a ````markdown example that shows a ```rule block is one fence. A ```rule block itself closes
  -- on exactly three, which is where the legacy scanner closes it.
  local fence, fence_is_rule = 0, false
  local blocks = {}
  local heading = {}
  local stray -- line of a ```rule line that is inside another fence: the loader reads it as a rule, this cannot place it
  for i, line in ipairs(lines) do
    if fence > 0 then
      if line:match("^```rule%s*$") then
        stray = stray or i
      end
      local ticks = line:match("^(`+)%s*$")
      local closes = ticks ~= nil and (#ticks >= fence and (not fence_is_rule or #ticks == 3))
      if closes then
        fence = 0
        if fence_is_rule then
          blocks[#blocks].e = i
        end
      end
    elseif line:match("^```") then
      fence = #line:match("^(`+)")
      fence_is_rule = line:match("^```rule%s*$") ~= nil
      if fence_is_rule then
        blocks[#blocks + 1] = { s = i }
      end
    elseif line:match("^#+ ") then
      heading[i] = true
    end
  end
  if stray then
    problem(
      (
        "line %d is a ```rule line inside another fenced block: the loader reads it as a rule, the migration "
        .. "cannot place it and it would be lost (move the example out of the document first)"
      ):format(stray)
    )
    return refuse()
  end
  if fence > 0 then
    problem("ends inside a fenced block")
    return refuse()
  end
  if #blocks == 0 then
    problem("has no ```rule block")
    return refuse()
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
    return refuse()
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
      problem(("rule %s appears twice"):format(shown(id)))
    elseif not is_blank(lines[block.s - 1] or "x") then
      problem(("rule %s: no blank line above the block"):format(shown(id)))
    elseif not is_blank(lines[block.e + 1] or "x") then
      problem(("rule %s: no blank line below the block"):format(shown(id)))
    else
      seen[id] = true
      -- the family as the runner matches it (`DEP2-01` is a family of its own), so the file reads back
      local family = id:match("^%a") and parser.family_of(id)
      if not family then
        problem(("rule %s: the id does not start with letters"):format(shown(id)))
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
    return refuse()
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
    -- the grammar of an id (it becomes a file name) is the parser's: whatever the rule file reader refuses stops here,
    -- before a path is made of it
    local parsed, errs = parser.split_text(shown(rule_file.id) .. ".md", rule_file.text)
    if not parsed then
      problem(("rule file for %s does not read back: %s"):format(shown(rule_file.id), errs[1]))
      return refuse()
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
    return refuse()
  end
  if toc_index then
    local hand = result.hand_toc
    if table.concat(toc_of(vim.split(rendered, "\n", { plain = true })), "\n") ~= table.concat(hand, "\n") then
      -- Only a heading or a fence line can change what the table lists, so the search below walks those lines and
      -- not the whole document: it tries up to 135 sets of parameters, each of them one pass.
      local outline = {}
      for _, line in ipairs(vim.split(rendered, "\n", { plain = true })) do
        local first = line:sub(1, 1)
        if first == "#" or first == "`" then
          outline[#outline + 1] = line
        end
      end
      local params = find_toc_params(outline, hand)
      if params then
        local better, err = render_with(catalog.toc_token(params))
        if not better then
          problem(err)
          return refuse()
        end
        rendered = better
      end
    end
  end
  result.document_text = catalog.header(layout_rel or ("_layouts/" .. output)) .. "\n" .. rendered
  if rendered ~= text then
    -- only the table of contents may differ
    local rendered_lines = vim.split(rendered, "\n", { plain = true })
    local text_lines = vim.split(text, "\n", { plain = true })
    local kept_rendered = without_toc(rendered_lines)
    local kept_text, text_numbers = without_toc(text_lines)
    for k = 1, math.max(#kept_rendered, #kept_text) do
      if kept_rendered[k] ~= kept_text[k] then
        problem(
          ("the rendered document differs from the original beyond its table of contents (first difference at line %d)"):format(
            text_numbers[k] or #text_lines
          )
        )
        return refuse()
      end
    end
    result.toc = "differs"
    local old = result.hand_toc or {}
    local new = toc_of(rendered_lines)
    -- a real line diff: a line that is inserted does not make every line after it count as changed
    local hunks = vim.diff(as_text(old), as_text(new), { result_type = "indices" })
    result.toc_lines_changed = 0
    result.toc_examples = {}
    for _, hunk in ipairs(hunks) do
      result.toc_lines_changed = result.toc_lines_changed + math.max(hunk[2], hunk[4])
      for k = 0, math.min(hunk[2], hunk[4]) - 1 do
        if #result.toc_examples < 3 then
          result.toc_examples[#result.toc_examples + 1] = { old = old[hunk[1] + k], new = new[hunk[3] + k] }
        end
      end
    end
  end
  return result
end

---@class Rules.MigrationReport
---@field conversions Rules.Conversion[]
---@field written string[]  paths written (empty without `write`, and empty after a rollback)
---@field rolled_back boolean|nil  a write or the check on disk failed, and what this run wrote was taken back
---@field problems string[]

--- A folder name given as an option, in one spelling: `/` between the parts, nothing before the first part but the
--- name, nothing after the last. Refused is what is not a plain place below the ruleset (the spelling rules of a
--- layout's `output`: no drive, no `..`, nothing a Windows file name cannot hold), so a name cannot lead out of it.
---@param name any
---@return string|nil dir
---@return string|nil why
local function clean_dir(name)
  if type(name) ~= "string" then
    return nil, "must be a string"
  end
  local dir = name:gsub("\\", "/"):gsub("/+", "/")
  while dir:sub(1, 2) == "./" do
    dir = dir:sub(3)
  end
  dir = dir:gsub("/+$", "")
  if dir == "" or dir:sub(1, 1) == "/" or dir:find('[%c:*?"<>|]') then
    return nil, 'must be a relative path below the ruleset, without any of : * ? " < > |'
  end
  for segment in dir:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      return nil, "must stay inside the ruleset (no `.` or `..`)"
    end
    if segment:find("[ .]$") then
      return nil, "must not have a part that ends in a space or a dot"
    end
  end
  return dir, nil
end

--- A key under which two spellings of one path are equal: normalized, and case-folded where the file system is.
---@param path string
---@return string
local function path_key(path)
  local key = vim.fs.normalize(path)
  if CASE_INSENSITIVE then
    key = key:find("[\128-\255]") and vim.fn.tolower(key) or key:lower()
  end
  return key
end

--- Convert every document of the ruleset at `root` that has rule blocks.
---
--- With `opts.write` the files are written in an order that can be undone: the rule files and the layouts first (they
--- are new files, and nothing reads a layout as a document), the documents last (until one is replaced, its rules
--- would load twice). Every document is checked to be writable before the first byte is written; if a write still
--- fails, or the check on disk of the generated documents does not come out, everything this run wrote is taken back
--- (the new files and the folders made for them are removed, the replaced documents put back) and `rolled_back` is
--- set.
---@param root string
---@param opts? { write?: boolean, rules_dir?: string, layouts_dir?: string }
---@return Rules.MigrationReport
function M.run(root, opts)
  opts = opts or {}
  local report = { conversions = {}, written = {}, problems = {} }
  local function problem(message)
    report.problems[#report.problems + 1] = message
  end

  local rules_dir, rules_why = clean_dir(opts.rules_dir or M.DEFAULT_RULES_DIR)
  if not rules_dir then
    problem(("rules_dir %q %s"):format(tostring(opts.rules_dir), rules_why))
    return report
  end
  local layouts_dir, layouts_why = clean_dir(opts.layouts_dir or M.DEFAULT_LAYOUTS_DIR)
  if not layouts_dir then
    problem(("layouts_dir %q %s"):format(tostring(opts.layouts_dir), layouts_why))
    return report
  end
  local base = vim.fs.normalize(vim.fn.fnamemodify(expand_path(root), ":p")):gsub("/+$", "")
  if vim.fn.isdirectory(base) ~= 1 then
    problem(("ruleset path %q is not a directory"):format(tostring(root)))
    return report
  end

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

  local planned = {} ---@type {path: string, text: string, written: boolean|nil}[]
  local replacements = {} ---@type {path: string, text: string, original: string, written: boolean|nil}[]
  local ids = {}
  local claimed = {} ---@type table<string, string> path key -> the target that has it

  local rules_folder = vim.fs.normalize(base .. "/" .. rules_dir)
  local layouts_folder = vim.fs.normalize(base .. "/" .. layouts_dir)

  --- Plan a new file. Refused is a target that is not below its folder once the `..` in it are resolved (an id is
  --- checked by the rule file reader already; this is the second lock), one that does not land inside the real root (a
  --- link on its way, a symlink or a junction, would carry the write, and the `mkdir` before it, out of the ruleset),
  --- one that is there already, and one that is the same file as another planned one (a case-insensitive file system
  --- makes `A-1` and `a-1` one).
  ---@param folder string  `rules_folder` or `layouts_folder`
  ---@param target string
  ---@param text string
  local function plan(folder, target, text)
    local key = path_key(target)
    if claimed[key] then
      problem(("%s and %s would be one file on this system"):format(claimed[key], target))
    end
    claimed[key] = claimed[key] or target
    if vim.fs.normalize(target):sub(1, #folder + 1) ~= folder .. "/" then
      problem(("%s is not below %s"):format(shown(target), folder))
    elseif not is_subpath(target, base, { realpath = true, ignore_case = CASE_INSENSITIVE }) then
      problem(("%s leaves the ruleset (a link on its way points elsewhere)"):format(target))
    elseif uv.fs_stat(target) then
      problem(("%s already exists"):format(target))
    end
    planned[#planned + 1] = { path = target, text = text }
  end

  for _, document in ipairs(documents) do
    local f = assert(io.open(document.path, "rb"))
    local text = f:read("*a")
    f:close()
    local conversion = M.convert_document(document.rel, text, layouts_dir .. "/" .. document.rel)
    report.conversions[#report.conversions + 1] = conversion
    vim.list_extend(report.problems, conversion.problems)
    for _, rule_file in ipairs(conversion.rule_files) do
      if ids[rule_file.id] then
        problem(("rule %s is in %s and in %s"):format(shown(rule_file.id), ids[rule_file.id], document.rel))
      end
      ids[rule_file.id] = document.rel
      plan(rules_folder, ("%s/%s/%s.md"):format(rules_folder, rule_file.family, rule_file.id), rule_file.text)
    end
    if conversion.layout_text then
      plan(layouts_folder, ("%s/%s"):format(layouts_folder, document.rel), conversion.layout_text)
      -- the document itself comes last: until it is replaced, its rules would load twice
      replacements[#replacements + 1] = { path = document.path, text = conversion.document_text, original = text }
    end
  end

  if opts.write and #report.problems == 0 then
    -- a document that cannot be replaced (read-only, locked) is found now, not after the new files are written
    for _, replacement in ipairs(replacements) do
      if not uv.fs_access(replacement.path, "W") then
        problem(("%s is not writable"):format(replacement.path))
      end
    end
  end

  if opts.write and #report.problems == 0 then
    local atomic = require("lib.nvim.fs.write.atomic")

    -- the folders this run makes (they are not there now), to take them away again
    local made_dirs = {} ---@type table<string, true>
    for _, file in ipairs(planned) do
      local dir = vim.fs.dirname(file.path)
      while #dir > #base and not uv.fs_stat(dir) do
        made_dirs[dir] = true
        dir = vim.fs.dirname(dir)
      end
    end

    local function undo()
      -- the documents were replaced last, so they are put back first
      for _, replacement in ipairs(replacements) do
        if replacement.written then
          local ok, err = atomic(replacement.path, replacement.original)
          if not ok then
            problem(("%s could not be put back (%s): restore it from version control"):format(replacement.path, err))
          end
        end
      end
      for _, file in ipairs(planned) do
        if file.written then
          uv.fs_unlink(file.path)
        end
      end
      local dirs = vim.tbl_keys(made_dirs)
      table.sort(dirs, function(a, b)
        return #a > #b
      end)
      for _, dir in ipairs(dirs) do
        uv.fs_rmdir(dir) -- only an empty one goes
      end
      report.written = {}
      report.rolled_back = true
    end

    local function write_all(files)
      for _, file in ipairs(files) do
        local ok, err = atomic(file.path, file.text, { mkdirp = true })
        if not ok then
          problem(("%s: %s"):format(file.path, err))
          return false
        end
        file.written = true
        report.written[#report.written + 1] = file.path
      end
      return true
    end

    if write_all(planned) and write_all(replacements) then
      -- The proof on disk: the documents the generator makes are the ones just written. Every document this run
      -- replaced needs a verdict of its own: a layout the walk does not reach (a folder the walk skips, one outside
      -- the root) would give none, and "nothing was wrong" must not be read out of "nothing was looked at".
      local results, errors = catalog.build(base, { check = true })
      local ours = {}
      for _, replacement in ipairs(replacements) do
        ours[replacement.path] = true
      end
      local answered, failed = {}, false
      for _, result in ipairs(results) do
        answered[result.output] = true
        if result.status ~= "unchanged" then
          problem(("%s is %s after the migration"):format(result.output, result.status))
          failed = failed or ours[result.output] == true
        end
        for _, message in ipairs(result.problems) do
          problem(message)
          failed = failed or ours[result.output] == true
        end
      end
      for _, replacement in ipairs(replacements) do
        if not answered[replacement.path] then
          problem(("%s: no layout the check reaches makes it, so the check on disk proved nothing"):format(replacement.path))
          failed = true
        end
      end
      -- trouble the ruleset had before (or elsewhere) is told, but it is not the migration's to undo
      vim.list_extend(report.problems, errors)
      if failed then
        undo()
      end
    else
      undo()
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
