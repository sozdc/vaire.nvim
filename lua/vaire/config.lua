local M = {}

local uv = vim.uv

local SETUP_OPTIONS = {
  mappings = true,
  notes = true,
  prompt_root = true,
  root = true,
}

local NOTE_OPTIONS = {
  daily_directory = true,
  directory = true,
}

local function fail(message)
  error("Vaire: " .. message, 0)
end

local function is_strictly_beneath(path, parent)
  return path ~= parent and path:sub(1, #parent + 1) == parent .. "/"
end

local function validate_options(value, allowed, label)
  for key in pairs(value) do
    if not allowed[key] then
      fail("unknown " .. label .. " option: " .. tostring(key))
    end
  end
end

local function expand_root(value)
  if value:sub(1, 1) == "~" then
    if value ~= "~" and value:sub(1, 2) ~= "~/" then
      fail("root supports only ~ or ~/...; ~user paths are unsupported")
    end

    local home = vim.env.HOME
    if not home or home == "" then
      fail("root uses ~ but HOME is not set")
    end
    value = home .. value:sub(2)
  end

  if value:find("${", 1, true) then
    fail("root does not support ${NAME}; use $NAME")
  end

  value = value:gsub("%$([%a_][%w_]*)", function(name)
    local replacement = vim.env[name]
    if replacement == nil then
      fail("environment variable $" .. name .. " is not set")
    end
    return replacement
  end)

  if value:find("%$", 1) then
    fail("root contains an unsupported environment reference")
  end

  return value
end

local function validate_directory(root, value, label)
  if type(value) ~= "string" or vim.trim(value) == "" then
    fail(label .. " must be a non-empty relative POSIX path")
  end
  if value:sub(1, 1) == "/" or value:sub(-1) == "/" or value:find("\\", 1, true) then
    fail(label .. " must be a relative POSIX path without leading/trailing slashes or backslashes")
  end

  local parts = vim.split(value, "/", { plain = true, trimempty = false })
  for _, part in ipairs(parts) do
    if part == "" or part == "." or part == ".." then
      fail(label .. " must not contain empty, . or .. path segments")
    end
  end

  if parts[1] == ".obsidian" then
    fail(label .. " must not target .obsidian")
  end

  if not root then
    return nil
  end
  local absolute = vim.fs.normalize(vim.fs.joinpath(root, value))
  if not is_strictly_beneath(absolute, root) then
    fail(label .. " must remain strictly beneath the vault root")
  end
  return absolute
end

local function validate_root(root, allow_missing)
  if root:sub(1, 1) ~= "/" then
    fail("root must resolve to an absolute path")
  end

  local stat = uv.fs_lstat(root)
  if not stat then
    if not allow_missing then
      fail("root must exist as a directory: " .. root)
    end

    local current = "/"
    local parts = vim.split(root, "/", { plain = true, trimempty = true })
    for index, part in ipairs(parts) do
      current = vim.fs.joinpath(current, part)
      local component = uv.fs_lstat(current)
      if not component then
        break
      end
      if component.type == "link" then
        fail("root must not contain symbolic link components")
      end
      if index < #parts and component.type ~= "directory" then
        fail("root component is not a directory: " .. current)
      end
    end
    return nil
  end

  if stat.type == "link" then
    fail("root must not contain symbolic link components")
  end
  if stat.type ~= "directory" then
    fail("root must exist as a directory: " .. root)
  end

  local root_real = uv.fs_realpath(root)
  if not root_real then
    fail("root has no resolvable real path: " .. root)
  end
  root_real = vim.fs.normalize(root_real)
  if root_real == "/" then
    fail("root must not resolve to the filesystem root")
  end
  if root_real ~= root then
    fail("root must not contain symbolic link components")
  end
  return root_real
end

function M.resolve(opts)
  if type(opts) ~= "table" then
    fail("setup options are required")
  end
  validate_options(opts, SETUP_OPTIONS, "setup")

  local prompt_root = opts.prompt_root
  if prompt_root == nil then
    prompt_root = false
  elseif type(prompt_root) ~= "boolean" then
    fail("prompt_root must be a boolean")
  end

  local root
  local root_real
  if opts.root == nil then
    if not prompt_root then
      fail("root must be an explicit non-empty path")
    end
  else
    if type(opts.root) ~= "string" or vim.trim(opts.root) == "" then
      fail("root must be an explicit non-empty path")
    end
    root = vim.fs.normalize(vim.trim(expand_root(opts.root)))
    root_real = validate_root(root, prompt_root)
  end

  local notes_opts = opts.notes
  if notes_opts ~= nil and type(notes_opts) ~= "table" then
    fail("notes must be a table")
  end
  notes_opts = notes_opts or {}
  validate_options(notes_opts, NOTE_OPTIONS, "notes")

  local mappings = opts.mappings
  if mappings == nil then
    mappings = false
  elseif type(mappings) ~= "boolean" then
    fail("mappings must be a boolean")
  end

  local notes_directory_name = notes_opts.directory
  local daily_directory_name = notes_opts.daily_directory
  if notes_directory_name == nil then
    notes_directory_name = "10-Notes"
  end
  if daily_directory_name == nil then
    daily_directory_name = "00-Daily"
  end

  local notes_directory = validate_directory(root, notes_directory_name, "notes.directory")
  local daily_directory = validate_directory(root, daily_directory_name, "notes.daily_directory")

  return {
    root = root,
    root_real = root_real,
    notes = {
      directory = notes_directory_name,
      daily_directory = daily_directory_name,
      directory_abs = notes_directory,
      daily_directory_abs = daily_directory,
    },
    mappings = mappings,
    prompt_root = prompt_root,
  }
end

return M
