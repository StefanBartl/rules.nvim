local read = require("rules.engine.agent.read")

---@return string
local function tmp_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

for _, portable in ipairs({ false, true }) do
  describe("rules.engine.agent.read.file (" .. (portable and "without libuv files" or "with libuv files") .. ")", function()
    it("reads a regular file as it is, bytes and line endings", function()
      local dir = tmp_dir()
      local fh = assert(io.open(dir .. "/a.txt", "wb"))
      fh:write("one\r\ntwo\n")
      fh:close()

      local content, err = read.file(dir .. "/a.txt", 100, portable)

      assert.is_nil(err)
      assert.are.equal("one\r\ntwo\n", content)
    end)

    it("reads an empty file as the empty text", function()
      local dir = tmp_dir()
      vim.fn.writefile({}, dir .. "/empty.txt")

      assert.are.equal("", read.file(dir .. "/empty.txt", 100, portable))
    end)

    it("refuses a file over the limit and reads exactly the limit", function()
      local dir = tmp_dir()
      local fh = assert(io.open(dir .. "/a.txt", "wb"))
      fh:write(("x"):rep(10))
      fh:close()

      local over, err = read.file(dir .. "/a.txt", 9, portable)

      assert.is_nil(over)
      assert.is_truthy(err:find("too large", 1, true))
      assert.are.equal(("x"):rep(10), read.file(dir .. "/a.txt", 10, portable))
    end)

    it("says why for a missing file and for a folder", function()
      local dir = tmp_dir()

      local missing, missing_err = read.file(dir .. "/nope", 100, portable)
      local folder, folder_err = read.file(dir, 100, portable)

      assert.is_nil(missing)
      assert.is_truthy(missing_err:find("not found", 1, true))
      assert.is_nil(folder)
      assert.is_truthy(folder_err:find("not a regular file", 1, true))
    end)

    it("does not read through a link", function()
      local dir = tmp_dir()
      vim.fn.writefile({ "SECRET" }, dir .. "/target.txt")
      if not vim.uv.fs_symlink(dir .. "/target.txt", dir .. "/link.txt") then
        pending("symlink creation not permitted on this machine")
        return
      end

      local content = read.file(dir .. "/link.txt", 100, portable)

      assert.is_nil(content)
    end)
  end)
end
