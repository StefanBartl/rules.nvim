---@module 'rules.buffers'
---@brief The open buffers of a ruleset around a write: what changed on disk is reloaded, an unsaved buffer is reported.
---@description
--- A write through `rules-ops/1` changes files of a ruleset: a rule, a layout, a generated document. A buffer that
--- holds one of them would be stale. `snapshot` remembers the bytes of those files before the write, `refresh` looks
--- at them after it and, for each file whose bytes changed:
---
---  - the buffer is unmodified: it is reloaded (`:edit`)
---  - the buffer has unsaved changes: it is left alone and named as a conflict (the file on disk changed under it;
---    `:edit!` takes the file's version, `:write!` the buffer's)
---  - the file is gone (a retired rule moved away): the buffer is left and named
---  - the buffer cannot be reloaded (a window that may not change its buffer, an autocmd that vetoes the read): it
---    keeps its old text and is set `modified` and `readonly`, so `:w` cannot put the old text over the new file;
---    named as stale (`:edit!` reads the file again)
---
--- A file the write did not change is not touched, even in a modified buffer.
---
--- Not its job: the write itself (`rules.write`), the message (`rules.ui.cmd`).

local M = {}

local CASE_INSENSITIVE = vim.fn.has("win32") == 1 or vim.fn.has("mac") == 1

---The real path of a file or folder, or, when it does not exist (yet), the real path of its nearest folder that does,
---with the rest of the name behind it: a buffer of a rule file that the write is about to make must be found under
---the same spelling of the ruleset (macOS: `/var/...` and `/private/var/...` are one folder).
---@param path string  normalized
---@return string
local function real_of(path)
  local rest = {}
  local head = path
  while true do
    local real = vim.uv.fs_realpath(head)
    if real then
      local out = vim.fs.normalize(real)
      for i = #rest, 1, -1 do
        out = out:gsub("/+$", "") .. "/" .. rest[i]
      end
      return out
    end
    local parent = vim.fs.dirname(head)
    if parent == head or parent == "." or parent == "" then
      break
    end
    rest[#rest + 1] = vim.fs.basename(head)
    head = parent
  end
  return path
end

---A key that is the same for every spelling of a path (the real path: 8.3 short names, links; case on Windows and
---macOS); a path that does not exist keeps its own last parts.
---@param path string
---@return string
local function key_of(path)
  local key = (real_of(vim.fs.normalize(path)):gsub("/+$", ""))
  if CASE_INSENSITIVE then
    key = vim.fn.tolower(key)
  end
  return key
end

---@param path string
---@return string|nil bytes
local function read_bytes(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local bytes = file:read("*a")
  file:close()
  return bytes
end

---@class Rules.BufferSnap
---@field buf integer
---@field name string
---@field bytes string|nil  the file before the write

---@class Rules.BufferReport
---@field reloaded string[]   files whose unmodified buffer was reloaded
---@field conflicts string[]  files that changed under a buffer with unsaved changes
---@field gone string[]       files that are no longer there (retired): their buffers were left
---@field stale string[]      files whose unmodified buffer could not be reloaded (it shows the old text, `readonly`)

---The loaded buffers that hold a file of one of `roots` (a ruleset folder or file), with the bytes of the file.
---@param roots string[]
---@return Rules.BufferSnap[]
function M.snapshot(roots)
  local keys = {}
  for _, root in ipairs(roots) do
    keys[#keys + 1] = key_of(root)
  end
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        local key = key_of(name)
        for _, root in ipairs(keys) do
          if key == root or key:sub(1, #root + 1) == root .. "/" then
            out[#out + 1] = { buf = buf, name = name, bytes = read_bytes(name) }
            break
          end
        end
      end
    end
  end
  return out
end

---Whether the text of the buffer is the text of the file (`bytes`), as the editor reads it.
---@param buf integer
---@param bytes string
---@return boolean
local function holds(buf, bytes)
  local want = vim.split(bytes, "\n", { plain = true })
  if want[#want] == "" then
    want[#want] = nil
  end
  local dos = vim.bo[buf].fileformat == "dos"
  for i, line in ipairs(want) do
    want[i] = dos and (line:gsub("\r$", "")) or line
  end
  local have = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #have == 0 or (#have == 1 and have[1] == "") then
    have = {}
  end
  return vim.deep_equal(have, want)
end

---A reload that failed leaves the buffer as the editor left it: after a veto before the read (an error in
---`BufReadPre`) that is an empty buffer that looks unmodified, and `:w!` on it would write nothing over the file the
---write made. The old text is put back, and the buffer is set `modified` and `readonly`: `:w` refuses, `:edit!` reads
---the file again and clears both.
---@param buf integer
---@param lines string[]  the text before the reload
local function keep_old(buf, lines)
  pcall(function()
    if not vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines) then
      local modifiable = vim.bo[buf].modifiable
      -- the failed `:edit` may have set 'readonly' already: changing the text of such a buffer warns (W10)
      vim.bo[buf].readonly = false
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = modifiable
    end
  end)
  vim.bo[buf].readonly = true
  vim.bo[buf].modified = true
end

---Read the file of an unmodified buffer again. In its window when it has one (`:edit` works on the current buffer).
---@param buf integer
---@param bytes string  the file after the write
---@return boolean ok  the buffer holds the file; false: it holds the old text and `:w` is refused
local function reload(buf, bytes)
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local win = vim.fn.bufwinid(buf)
  local function edit()
    vim.cmd("silent keepalt edit")
  end
  local ok
  if win ~= -1 then
    ok = pcall(vim.api.nvim_win_call, win, edit)
  else
    ok = pcall(vim.api.nvim_buf_call, buf, edit)
  end
  -- an error after the read (an autocmd of `BufReadPost`) aborts `:edit`, but the buffer holds the file
  if ok or holds(buf, bytes) then
    return true
  end
  keep_old(buf, before)
  return false
end

---After the write: reload what changed, name what could not be.
---@param snaps Rules.BufferSnap[]
---@return Rules.BufferReport
function M.refresh(snaps)
  ---@type Rules.BufferReport
  local report = { reloaded = {}, conflicts = {}, gone = {}, stale = {} }
  for _, snap in ipairs(snaps) do
    if vim.api.nvim_buf_is_valid(snap.buf) and vim.api.nvim_buf_is_loaded(snap.buf) then
      local after = read_bytes(snap.name)
      if after ~= snap.bytes then
        if after == nil then
          report.gone[#report.gone + 1] = snap.name
        elseif vim.bo[snap.buf].modified then
          report.conflicts[#report.conflicts + 1] = snap.name
        elseif reload(snap.buf, after) then
          report.reloaded[#report.reloaded + 1] = snap.name
        else
          -- a window that may not change its buffer ('winfixbuf'), a veto by an autocmd before the read
          report.stale[#report.stale + 1] = snap.name
        end
      end
    end
  end
  return report
end

return M
