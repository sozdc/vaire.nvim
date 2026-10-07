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

local function present_action(callback)
  local ok, result, message = pcall(callback)
  if not ok then
    notify_error("Unexpected Vaire failure: " .. tostring(result))
  elseif not result and message then
    notify_error(message)
  end
end

local function register_commands(created)
  vim.api.nvim_create_user_command("VaireDaily", function()
    present_action(M.daily)
  end, {})
  created[#created + 1] = "VaireDaily"

  vim.api.nvim_create_user_command("VaireFind", function()
    present_action(M.find)
  end, {})
  created[#created + 1] = "VaireFind"

  vim.api.nvim_create_user_command("VaireSearch", function(opts)
    present_action(function()
      return M.search(opts.args)
    end)
  end, { nargs = "*" })
  created[#created + 1] = "VaireSearch"

  vim.api.nvim_create_user_command("VaireNew", function(opts)
    present_action(function()
      return M.new(opts.args)
    end)
  end, { nargs = "*" })
  created[#created + 1] = "VaireNew"

  vim.api.nvim_create_user_command("VaireGit", function()
    present_action(M.git)
  end, {})
  created[#created + 1] = "VaireGit"
end

local function register_mappings(created)
  for _, spec in ipairs(MAPPING_SPECS) do
    if vim.tbl_isempty(vim.fn.maparg(spec.lhs, "n", false, true)) then
      vim.keymap.set("n", spec.lhs, function()
        present_action(spec.callback)
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
local root_controller

local function with_root(action)
  local config, config_error = configured()
  if not config then
    return nil, config_error
  end
  if root_controller then
    return root_controller:with_root(action)
  end
  return action(config)
end


local function create_and_open(config, directory, path, lines)
  local result, message = notes.ensure_file(config, directory, path, lines)
  if not result then
    return nil, message
  end
  return ui.open(path)
end

function M.setup(opts)
  local resolved = config_module.resolve(opts, true)
  if configuration then
    if vim.deep_equal(configuration, resolved) then
      return vim.deepcopy(configuration)
    end
    error("Vaire: setup has already completed with different options", 0)
  end

  preflight_commands()

  local commands = {}
  local mappings = {}
  local ok, message = pcall(function()
    ui.setup()
    if not resolved.prompt_root then
      local created, create_error = notes.ensure_root(resolved.root)
      if not created then
        error("Vaire: could not initialize vault: " .. create_error, 0)
      end
      resolved = config_module.resolve(opts)
      local directories_ready, directory_error = notes.ensure_configured_directories(resolved)
      if not directories_ready then
        error("Vaire: could not initialize vault: " .. directory_error, 0)
      end
    else
      pending_root_controller = require("vaire.root").new(resolved, notify_error, present_action)
    end
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
  root_controller = pending_root_controller

  configuration = resolved
  return vim.deepcopy(configuration)
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
