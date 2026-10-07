local repo_root = vim.env.VAIRE_REPO_ROOT
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local original_fs_write = vim.uv.fs_write
if vim.env.VAIRE_RACE_WRITE_SIGNAL then
  local signaled = false
  vim.uv.fs_write = function(...)
    if not signaled then
      signaled = true
      local signal_file, signal_error = vim.uv.fs_open(vim.env.VAIRE_RACE_WRITE_SIGNAL, "w", 420)
      if not signal_file then
        error("could not create race signal: " .. tostring(signal_error))
      end
      local signaled_bytes, write_error = original_fs_write(signal_file, "ready\n", 0)
      local closed, close_error = vim.uv.fs_close(signal_file)
      if not signaled_bytes then
        error("could not write race signal: " .. tostring(write_error))
      end
      if not closed then
        error("could not close race signal: " .. tostring(close_error))
      end
      local release_path = vim.env.VAIRE_RACE_RELEASE
      if not release_path then
        error("VAIRE_RACE_RELEASE is required for the race handshake")
      end
      if not vim.wait(10000, function()
        return vim.uv.fs_stat(release_path) ~= nil
      end, 10) then
        error("timed out waiting for VAIRE_RACE_RELEASE")
      end
    end
    return original_fs_write(...)
  end
end

local config = require("vaire.config")
local notes = require("vaire.notes")

local resolved = config.resolve({ root = vim.env.VAIRE_RACE_ROOT })
local result, message = notes.ensure_file(
  resolved,
  vim.env.VAIRE_RACE_DIRECTORY,
  vim.env.VAIRE_RACE_PATH,
  { vim.env.VAIRE_RACE_PAYLOAD }
)

if result then
  vim.fn.writefile({ result }, vim.env.VAIRE_RACE_RESULT)
  vim.cmd("cquit 0")
else
  vim.fn.writefile({ "error: " .. tostring(message) }, vim.env.VAIRE_RACE_RESULT)
  vim.cmd("cquit 1")
end
