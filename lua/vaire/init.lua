local config_module = require("vaire.config")
local notes = require("vaire.notes")
local ui = require("vaire.ui")

local M = {}

local configuration

local COMMAND_NAMES = { "VaireDaily", "VaireFind", "VaireSearch", "VaireNew", "VaireGit" }

local MAPPING_SPECS = {
  { lhs = "<leader>ad", callback = function() return M.daily() end, desc = "Vaire daily note" },
  { lhs = "<leader>af", callback = function() return M.find() end, desc = "Find Vaire notes" },
  { lhs = "<leader>as", callback = function() return M.search() end, desc = "Search Vaire notes" },
  { lhs = "<leader>an", callback = function() return M.new() end, desc = "New Vaire note" },
  { lhs = "<leader>vg", callback = function() return M.git() end, desc = "Open Vaire lazygit" },
}

local function preflight_commands()
  for _, name in ipairs(COMMAND_NAMES) do
    if vim.fn.exists(":" .. name) ~= 0 then
      error("Vaire: command already exists: " .. name, 0)
    end
  end
end

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "Vaire" })
end

local function run_command(callback)
  local ok, result, message = pcall(callback)
  if not ok then
    notify_error("Unexpected Vaire failure: " .. tostring(result))
  elseif not result and message then
    notify_error(message)
  end
end

local function register_commands(created)
  vim.api.nvim_create_user_command("VaireDaily", function()
    run_command(M.daily)
  end, {})
  created[#created + 1] = "VaireDaily"

  vim.api.nvim_create_user_command("VaireFind", function()
    run_command(M.find)
  end, {})
  created[#created + 1] = "VaireFind"

  vim.api.nvim_create_user_command("VaireSearch", function(opts)
    run_command(function()
      return M.search(opts.args)
    end)
  end, { nargs = "*" })
  created[#created + 1] = "VaireSearch"

  vim.api.nvim_create_user_command("VaireNew", function(opts)
    run_command(function()
      return M.new(opts.args)
    end)
  end, { nargs = "*" })
  created[#created + 1] = "VaireNew"

  vim.api.nvim_create_user_command("VaireGit", function()
    run_command(M.git)
  end, {})
  created[#created + 1] = "VaireGit"
end

local function register_mappings(created)
  for _, spec in ipairs(MAPPING_SPECS) do
    if vim.tbl_isempty(vim.fn.maparg(spec.lhs, "n", false, true)) then
      vim.keymap.set("n", spec.lhs, function()
        run_command(spec.callback)
      end, { desc = spec.desc })
      created[#created + 1] = spec.lhs
    else
      vim.notify(
        "Vaire mapping skipped; existing mapping: " .. spec.lhs,
        vim.log.levels.WARN,
        { title = "Vaire" }
      )
    end
  end
end

local function rollback_setup(commands, mappings)
  for index = #mappings, 1, -1 do
    pcall(vim.keymap.del, "n", mappings[index])
  end
  for index = #commands, 1, -1 do
    pcall(vim.api.nvim_del_user_command, commands[index])
  end
  ui.reset()
end

local function configured()
  if not configuration then
    return nil, 'Vaire is not configured; call require("vaire").setup({...})'
  end
  return configuration
end

local ROOT_STATE_NAME = "vaire-root"
local ROOT_FILE_MODE = tonumber("600", 8)
local ROOT_DIRECTORY_MODE = tonumber("700", 8)
local pending_root_actions = {}
local prompting_for_root = false

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

local function clear_pending_root_actions()
  pending_root_actions = {}
  prompting_for_root = false
end

local function run_pending_root_actions(config)
  local actions = pending_root_actions
  clear_pending_root_actions()
  for _, action in ipairs(actions) do
    local ok, result, message = pcall(action, config)
    if not ok then
      notify_error("Unexpected Vaire failure: " .. tostring(result))
    elseif not result and message then
      notify_error(message)
    end
  end
end

local function prompt_for_root()
  local ok, message = pcall(vim.ui.input, { prompt = "Vaire vault root: " }, function(value)
    if value == nil then
      clear_pending_root_actions()
      return
    end

    local resolved_ok, resolved = pcall(resolve_root, configuration, value)
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

local function with_root(action)
  local config, config_error = configured()
  if not config then
    return nil, config_error
  end
  if not config.prompt_root then
    return action(config)
  end

  if prompting_for_root then
    pending_root_actions[#pending_root_actions + 1] = action
    return true
  end

  local resolved = find_existing_root(config)
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

local function create_and_open(config, directory, path, lines)
  local result, message = notes.ensure_file(config, directory, path, lines)
  if not result then
    return nil, message
  end
  return ui.open(path)
end

function M.setup(opts)
  local resolved = config_module.resolve(opts)
  if configuration then
    if vim.deep_equal(configuration, resolved) then
      return configuration
    end
    error("Vaire: setup has already completed with different options", 0)
  end

  preflight_commands()
  local commands = {}
  local mappings = {}
  local ok, message = pcall(function()
    ui.setup()
    register_commands(commands)
    if resolved.mappings then
      register_mappings(mappings)
    end
  end)
  if not ok then
    rollback_setup(commands, mappings)
    message = tostring(message)
    if message:sub(1, 6) ~= "Vaire:" then
      message = "Vaire: setup failed: " .. message
    end
    error(message, 0)
  end

  configuration = resolved
  return configuration
end

function M.daily()
  return with_root(function(config)
    local path, path_error = notes.daily_path(config)
    if not path then
      return nil, path_error
    end
    return create_and_open(config, config.notes.daily_directory_abs, path, notes.daily_lines())
  end)
end

function M.new(input)
  return with_root(function(config)
    local function create(value)
      if value == nil then
        return true
      end
      local path, path_error = notes.note_path(config, value)
      if not path then
        return nil, path_error
      end
      local lines, lines_error = notes.note_lines(path)
      if not lines then
        return nil, lines_error
      end
      return create_and_open(config, config.notes.directory_abs, path, lines)
    end

    if input ~= nil and input ~= "" then
      return create(input)
    end

    local ok, message = pcall(vim.ui.input, { prompt = "Vaire note title: " }, function(value)
      local _, create_error = create(value)
      if create_error then
        notify_error(create_error)
      end
    end)
    if not ok then
      return nil, "could not open note prompt: " .. tostring(message)
    end
    return true
  end)
end

function M.find()
  return with_root(function(config)
    return ui.find(config, function(path)
      return ui.open(path)
    end)
  end)
end

function M.search(query)
  return with_root(function(config)
    return ui.search(config, query, function(path, position)
      return ui.open(path, position)
    end)
  end)
end

function M.git()
  return with_root(function(config)
    return ui.open_git(config.root)
  end)
end

return M
