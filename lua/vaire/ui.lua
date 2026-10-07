local notes = require("vaire.notes")

local M = {}

local snacks
local note_window
local git_session

local DEPENDENCY_MESSAGE = "folke/snacks.nvim with picker and win support is required"

local function dependency_error()
  error("Vaire: " .. DEPENDENCY_MESSAGE, 0)
end

local function notify_error(message)
  vim.notify(message, vim.log.levels.ERROR, { title = "Vaire" })
end

local function filter_obsidian(item)
  local path = type(item) == "table" and item.file or nil
  if type(path) ~= "string" then
    return true
  end
  if path:sub(1, 2) == "./" then
    path = path:sub(3)
  end
  return path:sub(1, 10) ~= ".obsidian/"
end

local function close_git_session(session)
  if not session then
    return
  end
  if session.win and vim.api.nvim_win_is_valid(session.win) then
    pcall(vim.api.nvim_win_close, session.win, true)
  end
  if session.buf and vim.api.nvim_buf_is_valid(session.buf) then
    pcall(vim.api.nvim_buf_delete, session.buf, { force = true })
  end
end

local function terminal_size()
  local width = math.max(1, math.floor(vim.o.columns * 0.9))
  local height = math.max(1, math.floor(vim.o.lines * 0.9))
  return width, height
end

local function open_git_window(buffer)
  local width, height = terminal_size()
  return vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Vaire: lazygit ",
    title_pos = "center",
  })
end

local function start_git(root)
  local session
  local ok, result = pcall(function()
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.bo[buffer].bufhidden = "wipe"
    vim.bo[buffer].swapfile = false
    session = { buf = buffer }
    session.win = open_git_window(buffer)
    git_session = session

    local job_id = vim.fn.termopen({ "lazygit" }, {
      cwd = root,
      on_exit = function()
        vim.schedule(function()
          if git_session ~= session then
            return
          end
          git_session = nil
          close_git_session(session)
        end)
      end,
    })
    if type(job_id) ~= "number" or job_id <= 0 then
      error("lazygit did not start", 0)
    end
    session.job_id = job_id
    vim.cmd("startinsert")
    return session
  end)

  if not ok then
    if git_session == session then
      git_session = nil
    end
    if session and session.job_id then
      pcall(vim.fn.jobstop, session.job_id)
    end
    close_git_session(session)
    return nil, "could not open lazygit: " .. tostring(result)
  end
  return result
end

function M.open_git(root)
  if not snacks then
    return nil, DEPENDENCY_MESSAGE
  end
  if vim.fn.executable("lazygit") ~= 1 then
    return nil, "lazygit executable was not found on PATH"
  end
  if git_session then
    if vim.api.nvim_win_is_valid(git_session.win) then
      vim.api.nvim_set_current_win(git_session.win)
      return git_session
    end
    local stale = git_session
    git_session = nil
    close_git_session(stale)
  end
  return start_git(root)
end


function M.setup()
  local ok, module = pcall(require, "snacks")
  if not ok or type(module) ~= "table" then
    dependency_error()
  end

  local win_ok, win = pcall(function()
    return module.win
  end)
  local picker_ok, picker = pcall(function()
    return module.picker
  end)
  if not win_ok
    or not picker_ok
    or type(win) ~= "table"
    or type(picker) ~= "table"
    or type(picker.files) ~= "function"
    or type(picker.grep) ~= "function"
  then
    dependency_error()
  end

  snacks = module
  return snacks
end

function M.reset()
  snacks = nil
  local session = git_session
  git_session = nil
  close_git_session(session)
end

local function set_cursor(position, window)
  if type(position) ~= "table" or not window.win or not vim.api.nvim_win_is_valid(window.win) then
    return
  end

  local line = position.line or position[1]
  local column = position.zero_based_column or position[2]
  if type(line) ~= "number" or type(column) ~= "number" then
    return
  end

  local buffer = vim.api.nvim_win_get_buf(window.win)
  local line_count = vim.api.nvim_buf_line_count(buffer)
  line = math.max(1, math.min(line_count, math.floor(line)))
  local text = vim.api.nvim_buf_get_lines(buffer, line - 1, line, false)[1] or ""
  column = math.max(0, math.min(#text, math.floor(column)))
  vim.api.nvim_win_set_cursor(window.win, { line, column })
end

function M.open(path, position)
  if not snacks then
    return nil, DEPENDENCY_MESSAGE
  end

  local ok, result = pcall(function()
    local buffer = vim.fn.bufadd(path)
    vim.fn.bufload(buffer)
    local title = " Vaire: " .. vim.fs.basename(path) .. " "

    if note_window and note_window:valid() then
      local current = vim.api.nvim_win_get_buf(note_window.win)
      if current ~= buffer and vim.bo[current].modified then
        -- Preserve unsaved note edits when the reusable window changes buffers.
        vim.bo[current].bufhidden = "hide"
      end
      note_window:set_buf(buffer)
      note_window:set_title(title, "center")
      note_window:focus()
      set_cursor(position, note_window)
      return note_window
    end

    note_window = snacks.win({
      buf = buffer,
      enter = true,
      width = 0.9,
      height = 0.9,
      border = "rounded",
      title = title,
      title_pos = "center",
    })
    set_cursor(position, note_window)
    return note_window
  end)
  if not ok then
    return nil, "could not open note: " .. tostring(result)
  end
  return result
end

local function select_note(config, on_select, picker, item)
  if not item or not item.file then
    notify_error("Could not determine the selected note")
    return
  end

  local path, path_error = notes.vault_path(config, item.file, item.cwd)
  if not path then
    notify_error(path_error)
    return
  end

  local closed, close_error = pcall(picker.close, picker)
  if not closed then
    notify_error("Could not close the note picker: " .. tostring(close_error))
    return
  end

  vim.schedule(function()
    local ok, result, message = pcall(on_select, path, item.pos)
    if not ok then
      notify_error("Could not open the selected note: " .. tostring(result))
    elseif not result and message then
      notify_error(message)
    end
  end)
end

function M.find(config, on_select)
  if not snacks then
    return nil, DEPENDENCY_MESSAGE
  end

  local ok, picker = pcall(function()
    return snacks.picker.files({
      cwd = config.root,
      ft = "md",
      hidden = true,
      exclude = { ".obsidian/**" },
      title = "Vaire notes",
      transform = filter_obsidian,
      confirm = function(active_picker, item)
        select_note(config, on_select, active_picker, item)
      end,
    })
  end)
  if not ok then
    return nil, "could not open the note picker: " .. tostring(picker)
  end
  return picker
end

function M.search(config, query, on_select)
  if not snacks then
    return nil, DEPENDENCY_MESSAGE
  end

  local ok, picker = pcall(function()
    return snacks.picker.grep({
      cwd = config.root,
      glob = "*.md",
      hidden = true,
      exclude = { ".obsidian/**" },
      search = query and query ~= "" and query or nil,
      transform = filter_obsidian,
      title = "Search Vaire",
      confirm = function(active_picker, item)
        select_note(config, on_select, active_picker, item)
      end,
    })
  end)
  if not ok then
    return nil, "could not open note search: " .. tostring(picker)
  end
  return picker
end

return M
