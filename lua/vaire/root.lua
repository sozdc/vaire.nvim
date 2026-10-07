local config_module = require("vaire.config")

local M = {}

local ROOT_STATE_NAME = "vaire-root"
local ROOT_FILE_MODE = tonumber("600", 8)
local ROOT_DIRECTORY_MODE = tonumber("700", 8)

local function root_state_path()
  return vim.fs.joinpath(vim.fn.stdpath("state"), ROOT_STATE_NAME)
end

local function load_saved_root()
  local path = root_state_path()
  local stat = vim.uv.fs_lstat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end

  local file = vim.uv.fs_open(path, "r", 0)
  if not file then
    return nil
  end
  local file_stat = vim.uv.fs_fstat(file)
  if not file_stat or file_stat.type ~= "file" or file_stat.size > 65536 then
    vim.uv.fs_close(file)
    return nil
  end
  local value = vim.uv.fs_read(file, file_stat.size, 0)
  vim.uv.fs_close(file)
  if not value then
    return nil
  end
  value = vim.trim(value)
  return value ~= "" and value or nil
end

local function save_root(root)
  local path = root_state_path()
  local directory = vim.fs.dirname(path)
  local directory_stat = vim.uv.fs_lstat(directory)
  if not directory_stat then
    if vim.fn.mkdir(directory, "p", ROOT_DIRECTORY_MODE) == 0 then
      return nil, "could not create Vaire state directory: " .. directory
    end
    directory_stat = vim.uv.fs_lstat(directory)
  end
  if not directory_stat or directory_stat.type ~= "directory" then
    return nil, "Vaire state path is not a directory: " .. directory
  end

  local file, temporary, create_error = vim.uv.fs_mkstemp(path .. ".XXXXXX")
  if not file then
    return nil, "could not create temporary Vaire state file: " .. tostring(create_error)
  end
  local function fail_save(message)
    if file then
      vim.uv.fs_close(file)
    end
    if temporary then
      vim.uv.fs_unlink(temporary)
    end
    return nil, message
  end

  local chmodded, chmod_error = vim.uv.fs_fchmod(file, ROOT_FILE_MODE)
  if not chmodded then
    return fail_save("could not set Vaire state file permissions: " .. tostring(chmod_error))
  end
  local content = root .. "\n"
  local offset = 0
  while offset < #content do
    local written, write_error = vim.uv.fs_write(file, content, offset)
    if not written or written == 0 then
      return fail_save("could not write Vaire state file: " .. tostring(write_error or "short write"))
    end
    offset = offset + written
  end
  local synced, sync_error = vim.uv.fs_fsync(file)
  if not synced then
    return fail_save("could not synchronize Vaire state file: " .. tostring(sync_error))
  end
  local closed, close_error = vim.uv.fs_close(file)
  file = nil
  if not closed then
    return fail_save("could not close Vaire state file: " .. tostring(close_error))
  end

  local renamed, rename_error = vim.uv.fs_rename(temporary, path)
  if not renamed then
    return fail_save("could not replace Vaire state file: " .. tostring(rename_error))
  end
  temporary = nil

  local directory_fd, open_error = vim.uv.fs_open(directory, "r", 0)
  if not directory_fd then
    return nil, "could not open Vaire state directory for synchronization: " .. tostring(open_error)
  end
  local directory_synced, directory_sync_error = vim.uv.fs_fsync(directory_fd)
  local directory_closed, directory_close_error = vim.uv.fs_close(directory_fd)
  if not directory_synced then
    return nil, "could not synchronize Vaire state directory: " .. tostring(directory_sync_error)
  end
  if not directory_closed then
    return nil, "could not close Vaire state directory: " .. tostring(directory_close_error)
  end
  return true
end

local function resolve_root(base, root)
  return config_module.resolve({
    root = root,
    notes = {
      directory = base.notes.directory,
      daily_directory = base.notes.daily_directory,
    },
    mappings = base.mappings,
  })
end

local function usable_root(base, root)
  if not root then
    return nil
  end
  local ok, resolved = pcall(resolve_root, base, root)
  return ok and resolved or nil
end

local function find_existing_root(base)
  local explicit = usable_root(base, base.root)
  if explicit then
    return explicit
  end
  return usable_root(base, load_saved_root())
end

function M.new(base, notify_error, present_action)
  local pending_root_actions = {}
  local prompting_for_root = false

  local function clear_pending_root_actions()
    pending_root_actions = {}
    prompting_for_root = false
  end

  local function run_pending_root_actions(config)
    local actions = pending_root_actions
    clear_pending_root_actions()
    for _, action in ipairs(actions) do
      present_action(function()
        return action(config)
      end)
    end
  end

  local prompt_for_root
  prompt_for_root = function()
    local ok, message = pcall(vim.ui.input, { prompt = "Vaire vault root: " }, function(value)
      if value == nil then
        clear_pending_root_actions()
        return
      end

      local resolved_ok, resolved = pcall(resolve_root, base, value)
      if not resolved_ok then
        notify_error(tostring(resolved))
        vim.schedule(function()
          local reprompted, reprompt_error = prompt_for_root()
          if not reprompted then
            clear_pending_root_actions()
            notify_error(reprompt_error)
          end
        end)
        return
      end

      local saved_ok, saved, save_error = pcall(save_root, resolved.root)
      if not saved_ok or not saved then
        notify_error("Could not persist Vaire vault root: " .. tostring(saved_ok and save_error or saved))
      end
      run_pending_root_actions(resolved)
    end)
    if not ok then
      return nil, "could not open vault prompt: " .. tostring(message)
    end
    return true
  end

  local controller = {}
  function controller:with_root(action)
    if prompting_for_root then
      pending_root_actions[#pending_root_actions + 1] = action
      -- true means accepted into the queue, not completed; canceling the prompt drops every pending action.
      return true
    end

    local resolved = find_existing_root(base)
    if resolved then
      return action(resolved)
    end

    pending_root_actions[#pending_root_actions + 1] = action
    prompting_for_root = true
    local prompted, prompt_error = prompt_for_root()
    if not prompted then
      clear_pending_root_actions()
      return nil, prompt_error
    end
    return true
  end
  return controller
end

return M
