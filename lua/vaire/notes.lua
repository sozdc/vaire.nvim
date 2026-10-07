local M = {}

local uv = vim.uv
local NOTE_MODE = tonumber("600", 8)

local MONTHS = {
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
}

local function is_strictly_beneath(path, parent)
  return path ~= parent and path:sub(1, #parent + 1) == parent .. "/"
end

local function invalid(message)
  return nil, message
end

function M.note_path(config, input)
  if type(input) ~= "string" then
    return invalid("note path must be a string")
  end

  local name = vim.trim(input)
  if name == "" then
    return invalid("use a relative note path including a filename")
  end
  if name:sub(1, 1) == "/" then
    return invalid("note paths must stay inside the configured notes directory")
  end
  if name:sub(-1) == "/" then
    return invalid("note paths must include a filename, not a trailing directory")
  end
  if name:find("\\", 1, true) then
    return invalid("note paths must use forward slashes")
  end

  local parts = vim.split(name, "/", { plain = true, trimempty = false })
  for _, part in ipairs(parts) do
    if part == "" or part == "." or part == ".." then
      return invalid("note paths must not contain empty, . or .. path segments")
    end
  end

  local filename = parts[#parts]
  local stem = filename:gsub("%.md$", "")
  if vim.trim(stem) == "" then
    return invalid("note paths must include a non-empty filename before .md")
  end

  if not name:match("%.md$") then
    name = name .. ".md"
  end

  local path = vim.fs.normalize(vim.fs.joinpath(config.notes.directory_abs, name))
  if not is_strictly_beneath(path, config.notes.directory_abs) then
    return invalid("note paths must stay inside the configured notes directory")
  end
  return path
end

function M.daily_path(config, date)
  date = date or os.date("*t")
  local year = tonumber(date.year)
  local month = tonumber(date.month)
  local day = tonumber(date.day)
  if not year or not month or not day or not MONTHS[month] then
    return invalid("daily date must contain a valid year, month, and day")
  end

  return vim.fs.normalize(vim.fs.joinpath(
    config.notes.daily_directory_abs,
    string.format("%04d", year),
    string.format("%02d-%s", month, MONTHS[month]),
    string.format("%02d-%02d-%04d.md", day, month, year)
  ))
end

function M.note_heading(path)
  if type(path) ~= "string" then
    return nil, "note path must be a string"
  end

  local basename = vim.fs.basename(path)
  local title = basename:gsub("%.md$", ""):gsub("[-_]", " ")
  return (title:gsub("(%a)([%w']*)", function(first, rest)
    return first:upper() .. rest
  end))
end

function M.vault_path(config, item_path, item_cwd)
  if type(item_path) ~= "string" or vim.trim(item_path) == "" then
    return invalid("could not determine the selected note path")
  end

  local path = vim.trim(item_path)
  if path:sub(1, 1) ~= "/" then
    local cwd = item_cwd
    if cwd == nil or cwd == "" then
      cwd = config.root
    elseif type(cwd) ~= "string" then
      return invalid("selected note working directory is invalid")
    elseif cwd:sub(1, 1) ~= "/" then
      cwd = vim.fs.joinpath(config.root, cwd)
    end
    path = vim.fs.joinpath(cwd, path)
  end
  path = vim.fs.normalize(path)

  if not is_strictly_beneath(path, config.root) then
    return invalid("selected note is outside the configured vault")
  end

  local stat = uv.fs_lstat(path)
  if not stat or stat.type ~= "file" then
    return invalid("selected note does not exist as a regular file")
  end

  local real = uv.fs_realpath(path)
  if not real then
    return invalid("selected note has no resolvable real path")
  end
  real = vim.fs.normalize(real)
  if real ~= path then
    return invalid("selected note must not use symbolic link components")
  end
  if not is_strictly_beneath(real, config.root_real) then
    return invalid("selected note resolves outside the configured vault")
  end

  return path
end

local function validate_existing_directory(path, boundary, label)
  local stat, stat_error = uv.fs_lstat(path)
  if not stat then
    return nil, string.format("%s: %s", label, tostring(stat_error))
  end
  if stat.type == "link" then
    return nil, label .. " must not be a symbolic link: " .. path
  end
  if stat.type ~= "directory" then
    return nil, label .. " is not a directory: " .. path
  end

  local real, real_error = uv.fs_realpath(path)
  if not real then
    return nil, string.format("%s has no resolvable real path: %s", label, tostring(real_error))
  end
  real = vim.fs.normalize(real)
  if real ~= path then
    return nil, label .. " must not contain symbolic link components: " .. path
  end
  if real ~= boundary and not is_strictly_beneath(real, boundary) then
    return nil, label .. " resolves outside its allowed directory: " .. path
  end
  return real
end

local function sync_directory(path, label)
  local directory, open_error = uv.fs_open(path, "r", 0)
  if not directory then
    return nil, "could not open " .. label .. " for synchronization: " .. tostring(open_error)
  end

  local synced, sync_error = uv.fs_fsync(directory)
  local closed, close_error = uv.fs_close(directory)
  if not synced then
    return nil, "could not synchronize " .. label .. ": " .. tostring(sync_error)
  end
  if not closed then
    return nil, "could not close synchronized " .. label .. ": " .. tostring(close_error)
  end
  return true
end

local function ensure_directory(path, boundary, label)
  local stat, stat_error = uv.fs_lstat(path)
  local created = false
  if not stat then
    local create_error
    created, create_error = uv.fs_mkdir(path, 493)
    if not created then
      stat, stat_error = uv.fs_lstat(path)
      if not stat then
        return nil, string.format("%s: %s", label, tostring(create_error or stat_error))
      end
    end
  end

  local real, validation_error = validate_existing_directory(path, boundary, label)
  if not real then
    return nil, validation_error
  end
  if created then
    local synced, sync_error = sync_directory(vim.fs.dirname(path), label .. " parent directory")
    if not synced then
      return nil, sync_error
    end
  end
  return real
end

local function configured_directory(config, directory)
  if directory ~= config.notes.directory_abs and directory ~= config.notes.daily_directory_abs then
    return nil, "note directory is not configured"
  end
  if not is_strictly_beneath(directory, config.root) then
    return nil, "note directory is outside the configured vault"
  end

  local current = config.root
  local relative = directory:sub(#config.root + 2)
  for _, part in ipairs(vim.split(relative, "/", { plain = true, trimempty = false })) do
    current = vim.fs.joinpath(current, part)
    local real, message = ensure_directory(current, config.root_real, "configured directory component")
    if not real then
      return nil, message
    end
  end

  local real, real_error = uv.fs_realpath(directory)
  if not real then
    return nil, "configured directory has no resolvable real path: " .. tostring(real_error)
  end
  real = vim.fs.normalize(real)
  if real ~= directory then
    return nil, "configured directory must not contain symbolic link components"
  end
  if not is_strictly_beneath(real, config.root_real) then
    return nil, "configured directory resolves outside the vault"
  end
  return real
end

local function candidate_parent(configured, configured_real, path)
  local parent = vim.fs.dirname(path)
  if parent ~= configured and not is_strictly_beneath(parent, configured) then
    return nil, "note parent is outside the configured directory"
  end

  local current = configured
  local relative = parent:sub(#configured + 2)
  if relative ~= "" then
    for _, part in ipairs(vim.split(relative, "/", { plain = true, trimempty = false })) do
      current = vim.fs.joinpath(current, part)
      local real, message = ensure_directory(current, configured_real, "note parent component")
      if not real then
        return nil, message
      end
    end
  end
  return true
end

local function valid_existing_target(path, configured, configured_real)
  if not is_strictly_beneath(path, configured) then
    return nil, "note path is outside the configured directory"
  end

  local stat, stat_error = uv.fs_lstat(path)
  if not stat then
    return nil, stat_error
  end
  if stat.type ~= "file" then
    return nil, "note path is not a regular file"
  end

  local real, real_error = uv.fs_realpath(path)
  if not real then
    return nil, real_error
  end
  real = vim.fs.normalize(real)
  if real ~= path then
    return nil, "note path must not use symbolic link components"
  end
  if not is_strictly_beneath(real, configured_real) then
    return nil, "note path resolves outside the configured directory"
  end
  return true
end

local function write_all(file, data)
  local offset = 0
  while offset < #data do
    local written, write_error = uv.fs_write(file, data, offset)
    if not written then
      return nil, write_error
    end
    if written == 0 then
      return nil, "short write"
    end
    offset = offset + written
  end
  return true
end

local function cleanup_temporary(file, temp_path, message)
  local errors = { message }
  if file then
    local closed, close_error = uv.fs_close(file)
    if not closed then
      errors[#errors + 1] = "could not close temporary note: " .. tostring(close_error)
    end
  end

  local removed, remove_error = uv.fs_unlink(temp_path)
  if not removed then
    errors[#errors + 1] = "could not remove temporary note: " .. tostring(remove_error)
  end
  return invalid(table.concat(errors, "; "))
end

function M.ensure_file(config, directory, path, lines)
  if type(path) ~= "string" or path == "" then
    return invalid("note path must be a non-empty absolute path")
  end
  if type(lines) ~= "table" then
    return invalid("note content must be a list of lines")
  end
  for index, line in ipairs(lines) do
    if type(line) ~= "string" then
      return invalid("note content line " .. index .. " must be a string")
    end
  end
  if type(directory) ~= "string" or directory == "" then
    return invalid("note directory is not configured")
  end

  directory = vim.fs.normalize(directory)
  path = vim.fs.normalize(path)
  local configured_real, directory_error = configured_directory(config, directory)
  if not configured_real then
    return invalid(directory_error)
  end
  if not is_strictly_beneath(path, directory) then
    return invalid("note path is outside the configured directory")
  end

  local parent_ok, parent_error = candidate_parent(directory, configured_real, path)
  if not parent_ok then
    return invalid(parent_error)
  end

  local target_stat = uv.fs_lstat(path)
  if target_stat then
    local existing, existing_error = valid_existing_target(path, directory, configured_real)
    if existing then
      return "existing"
    end
    return invalid(existing_error)
  end

  local data = table.concat(lines, "\n") .. "\n"
  local parent = vim.fs.dirname(path)
  local temp_template = vim.fs.joinpath(parent, ".vaire-write-XXXXXX")
  local file, temp_path, temp_error = uv.fs_mkstemp(temp_template)
  if not file then
    return invalid("could not create temporary note: " .. tostring(temp_error))
  end

  local stable, stable_error = validate_existing_directory(parent, configured_real, "note parent")
  if not stable then
    return cleanup_temporary(file, temp_path, stable_error)
  end

  local chmodded, chmod_error = uv.fs_fchmod(file, NOTE_MODE)
  if not chmodded then
    return cleanup_temporary(file, temp_path, "could not set note permissions: " .. tostring(chmod_error))
  end

  local written, write_error = write_all(file, data)
  if not written then
    return cleanup_temporary(file, temp_path, "could not write note: " .. tostring(write_error))
  end

  local synced, sync_error = uv.fs_fsync(file)
  if not synced then
    return cleanup_temporary(file, temp_path, "could not synchronize note: " .. tostring(sync_error))
  end

  local closed, close_error = uv.fs_close(file)
  if not closed then
    return cleanup_temporary(nil, temp_path, "could not close note: " .. tostring(close_error))
  end

  stable, stable_error = validate_existing_directory(parent, configured_real, "note parent")
  if not stable then
    return cleanup_temporary(nil, temp_path, stable_error)
  end

  local linked, link_error = uv.fs_link(temp_path, path)
  if linked then
    local removed, remove_error = uv.fs_unlink(temp_path)
    local directory_synced, directory_sync_error = sync_directory(parent, "note directory")
    if removed and directory_synced then
      return "created"
    end

    local errors = {}
    if not removed then
      errors[#errors + 1] = "note was published but its temporary link could not be removed: " .. tostring(remove_error)
    end
    if not directory_synced then
      errors[#errors + 1] = "note was published but directory synchronization failed: " .. tostring(directory_sync_error)
    end
    return invalid(table.concat(errors, "; "))
  end

  local removed, remove_error = uv.fs_unlink(temp_path)
  local directory_synced, directory_sync_error = sync_directory(parent, "note directory")
  local existing, existing_error = valid_existing_target(path, directory, configured_real)
  if existing and removed and directory_synced then
    return "existing"
  end

  local errors = {
    "could not publish note: " .. tostring(link_error),
  }
  if not removed then
    errors[#errors + 1] = "could not remove temporary note: " .. tostring(remove_error)
  end
  if not directory_synced then
    errors[#errors + 1] = directory_sync_error
  end
  if not existing then
    errors[#errors + 1] = "target validation failed: " .. tostring(existing_error)
  end
  return invalid(table.concat(errors, "; "))
end

function M.daily_lines()
  return { "# Notes", "", "", "", "[[daily]]" }
end

function M.note_lines(path)
  local heading, heading_error = M.note_heading(path)
  if not heading then
    return nil, heading_error
  end
  return { "# " .. heading, "" }
end

return M
