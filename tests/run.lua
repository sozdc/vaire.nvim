local script = debug.getinfo(1, "S").source:gsub("^@", "")
local repo_root = vim.fn.fnamemodify(script, ":p:h:h")
package.path = repo_root .. "/lua/?.lua;" .. repo_root .. "/lua/?/init.lua;" .. package.path

local config = require("vaire.config")
local notes = require("vaire.notes")
local uv = vim.uv

local tests = {}

local function test(name, callback)
  tests[#tests + 1] = { name = name, callback = callback }
end

local function equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. "\nexpected: " .. tostring(expected) .. "\nactual: " .. tostring(actual), 2)
  end
end

local function truthy(value, message)
  if not value then
    error(message or "expected a truthy value", 2)
  end
end

local function expect_error(callback, pattern)
  local ok, message = pcall(callback)
  if ok then
    error("expected an error", 2)
  end
  if pattern and not tostring(message):find(pattern, 1, true) then
    error("error did not contain " .. pattern .. ": " .. tostring(message), 2)
  end
end

local function write_file(path, content)
  local fd, message = uv.fs_open(path, "w", 420)
  truthy(fd, message)
  local written, write_error = uv.fs_write(fd, content, 0)
  truthy(written == #content, write_error or "short write")
  truthy(uv.fs_close(fd), "could not close fixture file")
end

local function with_root(callback)
  local root = vim.fn.tempname()
  truthy(vim.fn.mkdir(root, "p") == 1, "could not create temporary root")
  local ok, message = pcall(callback, root)
  vim.fn.delete(root, "rf")
  if not ok then
    error(message, 0)
  end
end

test("expands supported roots and retains canonical forms", function()
  with_root(function(root)
    vim.env.VAIRE_TEST_ROOT = root
    local resolved = config.resolve({ root = "$VAIRE_TEST_ROOT/." })
    equal(resolved.root, vim.fs.normalize(root))
    equal(resolved.root_real, vim.fs.normalize(uv.fs_realpath(root)))
    equal(resolved.notes.directory_abs, vim.fs.joinpath(resolved.root, "10-Notes"))
    equal(resolved.notes.daily_directory_abs, vim.fs.joinpath(resolved.root, "00-Daily"))
    equal(resolved.mappings, false)
    equal(resolved.prompt_root, false)
  end)

  local home = vim.env.HOME
  truthy(home and vim.fn.isdirectory(home) == 1, "HOME must be a directory for ~ expansion")
  equal(config.resolve({ root = "~" }).root, vim.fs.normalize(home))
end)

test("rejects missing and unsupported roots", function()
  expect_error(function()
    config.resolve({ root = vim.fn.tempname() })
  end, "root must exist as a directory")
  expect_error(function()
    config.resolve({ root = "/" })
  end, "root must not resolve to the filesystem root")
  expect_error(function()
    config.resolve({ root = "~someone/Documents" })
  end, "~user")
  expect_error(function()
    config.resolve({ root = "${HOME}/Documents" })
  end, "${NAME}")
  expect_error(function()
    config.resolve({ root = "$VAIRE_MISSING_ROOT_9381" })
  end, "is not set")
  expect_error(function()
    config.resolve({ root = "relative-vault" })
  end, "absolute")
end)

test("allows deferred roots only with prompt_root enabled", function()
  with_root(function(root)
    local unset = config.resolve({ prompt_root = true })
    equal(unset.root, nil)
    equal(unset.root_real, nil)
    equal(unset.notes.directory_abs, nil)
    equal(unset.prompt_root, true)

    local missing = vim.fs.joinpath(root, "not-created")
    local deferred = config.resolve({ root = missing, prompt_root = true })
    equal(deferred.root, missing)
    equal(deferred.root_real, nil)
    equal(deferred.notes.directory_abs, vim.fs.joinpath(missing, "10-Notes"))
    equal(deferred.prompt_root, true)

    expect_error(function()
      config.resolve({ root = missing })
    end, "root must exist as a directory")
    expect_error(function()
      config.resolve({ root = "/", prompt_root = true })
    end, "filesystem root")
    expect_error(function()
      config.resolve({ root = "$VAIRE_MISSING_ROOT_9381", prompt_root = true })
    end, "is not set")
    expect_error(function()
      config.resolve({ root = missing, prompt_root = "yes" })
    end, "prompt_root")

    local target = vim.fs.joinpath(root, "target")
    local link = vim.fs.joinpath(root, "root-link")
    truthy(vim.fn.mkdir(target, "p") == 1, "could not create symlink target")
    truthy(uv.fs_symlink(target, link), "could not create root symlink")
    expect_error(function()
      config.resolve({ root = vim.fs.joinpath(link, "missing"), prompt_root = true })
    end, "symbolic link")
  end)
end)

test("rejects roots with symbolic link components", function()
  with_root(function(root)
    local target = vim.fs.joinpath(root, "target")
    local link = vim.fs.joinpath(root, "root-link")
    truthy(vim.fn.mkdir(target, "p") == 1, "could not create symlink target")
    truthy(uv.fs_symlink(target, link), "could not create root symlink")
    expect_error(function()
      config.resolve({ root = link })
    end, "symbolic link")
  end)
end)

test("validates configured directory boundaries", function()
  with_root(function(root)
    local invalid = {
      "",
      "/absolute",
      "trailing/",
      "back\\slash",
      "a//b",
      ".",
      "a/.",
      "..",
      "a/../b",
      "a/../../outside",
      ".obsidian",
      ".obsidian/plugins",
    }
    for _, directory in ipairs(invalid) do
      expect_error(function()
        config.resolve({ root = root, notes = { directory = directory } })
      end)
    end
    for _, directory in ipairs({ false, {} }) do
      expect_error(function()
        config.resolve({ root = root, notes = { directory = directory } })
      end)
    end
    expect_error(function()
      config.resolve({ root = root, mappings = "yes" })
    end, "mappings")
    expect_error(function()
      config.resolve({ root = root, mapppings = true })
    end, "unknown setup option: mapppings")
    expect_error(function()
      config.resolve({ root = root, notes = { directroy = "notes" } })
    end, "unknown notes option: directroy")

    local resolved = config.resolve({
      root = root,
      notes = { directory = "notes/team", daily_directory = "daily/archive" },
      mappings = true,
    })
    equal(resolved.notes.directory_abs, vim.fs.joinpath(root, "notes/team"))
    equal(resolved.notes.daily_directory_abs, vim.fs.joinpath(root, "daily/archive"))
    equal(resolved.mappings, true)
  end)
end)

test("derives safe nested note paths", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    equal(notes.note_path(resolved, " team/design "), vim.fs.joinpath(root, "10-Notes/team/design.md"))
    equal(notes.note_path(resolved, "team/design.md"), vim.fs.joinpath(root, "10-Notes/team/design.md"))

    local invalid = { "/tmp/escape", "../escape", "team/../escape", "team/", "team\\escape", ".", "team//design", "team/." }
    for _, input in ipairs(invalid) do
      local path = notes.note_path(resolved, input)
      equal(path, nil, "expected rejection for " .. input)
    end

    for _, input in ipairs({ ".md", "team/.md" }) do
      local path, message = notes.note_path(resolved, input)
      equal(path, nil, "expected rejection for " .. input)
      equal(message, "note paths must include a non-empty filename before .md")
    end
  end)
end)

test("derives the fixed English daily layout", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    equal(
      notes.daily_path(resolved, { year = 2026, month = 9, day = 19 }),
      vim.fs.joinpath(root, "00-Daily/2026/09-Sep/19-09-2026.md")
    )
  end)
end)

test("generates note headings from filenames", function()
  equal(notes.note_heading("/vault/10-Notes/project-alpha_note.md"), "Project Alpha Note")
  equal(notes.note_heading("/vault/10-Notes/v2-review.md"), "V2 Review")
end)

test("validates absolute and picker-relative existing paths", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    vim.fn.mkdir(resolved.notes.directory_abs, "p")
    local visible = vim.fs.joinpath(resolved.notes.directory_abs, "visible.md")
    write_file(visible, "# Visible\n")

    equal(notes.vault_path(resolved, visible), visible)
    equal(notes.vault_path(resolved, "10-Notes/visible.md", root), visible)
    equal(notes.vault_path(resolved, "visible.md", resolved.notes.directory_abs), visible)

    local outside = vim.fn.tempname()
    write_file(outside, "# Outside\n")
    local outside_result = notes.vault_path(resolved, outside)
    equal(outside_result, nil)

    local escaped_file = vim.fs.joinpath(resolved.notes.directory_abs, "escaped.md")
    truthy(uv.fs_symlink(outside, escaped_file), "could not create file escape symlink")
    equal(notes.vault_path(resolved, escaped_file), nil)

    local outside_dir = vim.fn.tempname()
    truthy(vim.fn.mkdir(outside_dir, "p") == 1, "could not create outside directory")
    local outside_nested = vim.fs.joinpath(outside_dir, "nested.md")
    write_file(outside_nested, "# Nested outside\n")
    local escaped_dir = vim.fs.joinpath(resolved.notes.directory_abs, "escaped-dir")
    truthy(uv.fs_symlink(outside_dir, escaped_dir), "could not create directory escape symlink")
    equal(notes.vault_path(resolved, "nested.md", escaped_dir), nil)

    vim.fn.delete(outside, "rf")
    vim.fn.delete(outside_dir, "rf")
  end)
end)

local function read_file(path)
  local file, message = uv.fs_open(path, "r", 420)
  truthy(file, message)
  local stat, stat_error = uv.fs_fstat(file)
  truthy(stat, stat_error)
  local content, read_error = uv.fs_read(file, stat.size, 0)
  truthy(content, read_error)
  truthy(uv.fs_close(file), "could not close read fixture")
  return content
end

test("creates notes without overwriting existing content", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    local path = notes.note_path(resolved, "nested/preserved.md")
    local first, first_error = notes.ensure_file(resolved, resolved.notes.directory_abs, path, { "original", "sentinel" })
    equal(first, "created", first_error)
    local second, second_error = notes.ensure_file(resolved, resolved.notes.directory_abs, path, { "replacement" })
    equal(second, "existing", second_error)
    equal(read_file(path), "original\nsentinel\n")
  end)
end)
test("opens existing notes without writing in read-only parents", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    local path = notes.note_path(resolved, "readonly.md")
    local created, create_error = notes.ensure_file(
      resolved,
      resolved.notes.directory_abs,
      path,
      { "original" }
    )
    equal(created, "created", create_error)

    local changed, chmod_error = uv.fs_chmod(resolved.notes.directory_abs, 365)
    truthy(changed, chmod_error)
    local ok, message = pcall(function()
      local result, result_error = notes.ensure_file(
        resolved,
        resolved.notes.directory_abs,
        path,
        { "replacement" }
      )
      equal(result, "existing", result_error)
      equal(read_file(path), "original\n")
    end)
    local restored, restore_error = uv.fs_chmod(resolved.notes.directory_abs, 493)
    truthy(restored, restore_error)
    if not ok then
      error(message, 0)
    end
  end)
end)

test("writes the exact daily template", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    local path = notes.daily_path(resolved, { year = 2026, month = 9, day = 19 })
    local result, message = notes.ensure_file(
      resolved,
      resolved.notes.daily_directory_abs,
      path,
      notes.daily_lines()
    )
    equal(result, "created", message)
    equal(read_file(path), "# Notes\n\n\n\n[[daily]]\n")
  end)
end)

test("does not publish a note before file synchronization succeeds", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    truthy(vim.fn.mkdir(resolved.notes.directory_abs, "p") == 1, "could not create notes directory")
    local path = notes.note_path(resolved, "sync-required.md")
    local original_fsync = uv.fs_fsync
    uv.fs_fsync = function()
      return nil, "forced synchronization failure"
    end
    local ok, result, message = pcall(
      notes.ensure_file,
      resolved,
      resolved.notes.directory_abs,
      path,
      { "not durable" }
    )
    uv.fs_fsync = original_fsync
    if not ok then
      error(result, 0)
    end

    equal(result, nil)
    truthy(message:find("could not synchronize note", 1, true), message)
    equal(uv.fs_lstat(path), nil, "unsynchronized note must not be published")
  end)
end)

test("does not publish a note before created directory metadata is synchronized", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    local path = notes.note_path(resolved, "nested/sync-required.md")
    local original_fsync = uv.fs_fsync
    uv.fs_fsync = function(file)
      local stat = uv.fs_fstat(file)
      if stat and stat.type == "directory" then
        return nil, "forced directory synchronization failure"
      end
      return original_fsync(file)
    end
    local ok, result, message = pcall(
      notes.ensure_file,
      resolved,
      resolved.notes.directory_abs,
      path,
      { "not durable" }
    )
    uv.fs_fsync = original_fsync
    if not ok then
      error(result, 0)
    end

    equal(result, nil)
    truthy(message:find("could not synchronize configured directory component parent directory", 1, true), message)
    equal(uv.fs_lstat(path), nil, "note must not be published before its parent metadata is durable")
  end)
end)

test("creates configured and nested parent directories safely", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    local path = notes.note_path(resolved, "team/design/note.md")
    local result, message = notes.ensure_file(resolved, resolved.notes.directory_abs, path, { "# Design", "" })
    equal(result, "created", message)
    equal(read_file(path), "# Design\n\n")
    equal(vim.uv.fs_stat(resolved.notes.directory_abs).type, "directory")
  end)
end)

test("rejects configured symlinks even when they stay inside the vault", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    local backing = vim.fs.joinpath(root, "backing")
    truthy(vim.fn.mkdir(backing, "p") == 1, "could not create configured backing directory")
    truthy(uv.fs_symlink(backing, resolved.notes.directory_abs), "could not create configured symlink")

    local path = notes.note_path(resolved, "linked.md")
    local result, message = notes.ensure_file(resolved, resolved.notes.directory_abs, path, { "inside" })
    equal(result, nil)
    truthy(message:find("symbolic link", 1, true), message)
    equal(uv.fs_lstat(vim.fs.joinpath(backing, "linked.md")), nil)
  end)
end)

test("rejects configured and nested symlink escapes", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    local outside = vim.fn.tempname()
    truthy(vim.fn.mkdir(outside, "p") == 1, "could not create outside directory")

    truthy(uv.fs_symlink(outside, resolved.notes.directory_abs), "could not create configured escape")
    local configured_path = notes.note_path(resolved, "escape.md")
    local configured_result, configured_error = notes.ensure_file(
      resolved,
      resolved.notes.directory_abs,
      configured_path,
      { "outside" }
    )
    equal(configured_result, nil)
    truthy(configured_error:find("symbolic link", 1, true), configured_error)

    vim.fn.delete(resolved.notes.directory_abs)
    truthy(vim.fn.mkdir(resolved.notes.directory_abs, "p") == 1, "could not recreate notes directory")
    local nested_escape = vim.fs.joinpath(resolved.notes.directory_abs, "escape")
    truthy(uv.fs_symlink(outside, nested_escape), "could not create nested escape")
    local nested_path = notes.note_path(resolved, "escape/note.md")
    local nested_result, nested_error = notes.ensure_file(resolved, resolved.notes.directory_abs, nested_path, { "outside" })
    equal(nested_result, nil)
    truthy(nested_error:find("symbolic link", 1, true), nested_error)
    equal(vim.uv.fs_stat(vim.fs.joinpath(outside, "note.md")), nil)

    vim.fn.delete(outside, "rf")
  end)
end)

test("rejects a parent replaced by a symlink before publication", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    local outside = vim.fn.tempname()
    truthy(vim.fn.mkdir(outside, "p") == 1, "could not create outside directory")
    local parent = vim.fs.joinpath(resolved.notes.directory_abs, "swap")
    truthy(vim.fn.mkdir(parent, "p") == 1, "could not create candidate parent")
    local path = notes.note_path(resolved, "swap/note.md")

    local original_mkstemp = uv.fs_mkstemp
    local swapped = false
    uv.fs_mkstemp = function(template)
      if not swapped then
        swapped = true
        truthy(uv.fs_rename(parent, parent .. "-original"), "could not move candidate parent")
        truthy(uv.fs_symlink(outside, parent), "could not replace candidate parent")
      end
      return original_mkstemp(template)
    end
    local ok, result, message = pcall(
      notes.ensure_file,
      resolved,
      resolved.notes.directory_abs,
      path,
      { "outside" }
    )
    uv.fs_mkstemp = original_mkstemp
    if not ok then
      error(result, 0)
    end

    equal(result, nil)
    truthy(message:find("symbolic link", 1, true), message)
    equal(uv.fs_lstat(vim.fs.joinpath(outside, "note.md")), nil)
    equal(#vim.fn.readdir(outside), 0, "temporary note escaped cleanup")
    vim.fn.delete(outside, "rf")
  end)
end)

test("propagates deterministic invalid-parent errors", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    vim.fn.mkdir(resolved.notes.directory_abs, "p")
    local invalid_parent = vim.fs.joinpath(resolved.notes.directory_abs, "not-a-directory")
    write_file(invalid_parent, "file\n")
    local path = notes.note_path(resolved, "not-a-directory/note.md")
    local result, message = notes.ensure_file(resolved, resolved.notes.directory_abs, path, { "blocked" })
    equal(result, nil)
    truthy(message, "invalid parent must return an error")
    equal(read_file(invalid_parent), "file\n")
    equal(uv.fs_stat(path), nil, "invalid parent must not create the child")
  end)
end)

test("publishes complete bytes before competing creation returns", function()
  with_root(function(root)
    local resolved = config.resolve({ root = root })
    local path = notes.note_path(resolved, "race/shared.md")
    local result_file = vim.fn.tempname()
    local signal_file = vim.fn.tempname()
    local release_file = vim.fn.tempname()
    local child_exit
    local child_payload = "race-winner-alpha"
    local parent_payload = "race-winner-beta"

    local job = vim.fn.jobstart({
      vim.v.progpath,
      "--headless",
      "--clean",
      "-l",
      vim.fs.joinpath(repo_root, "tests/race_child.lua"),
    }, {
      env = {
        VAIRE_REPO_ROOT = repo_root,
        VAIRE_RACE_ROOT = root,
        VAIRE_RACE_DIRECTORY = resolved.notes.directory_abs,
        VAIRE_RACE_PATH = path,
        VAIRE_RACE_PAYLOAD = child_payload,
        VAIRE_RACE_RESULT = result_file,
        VAIRE_RACE_WRITE_SIGNAL = signal_file,
        VAIRE_RACE_RELEASE = release_file,
      },
      on_exit = function(_, code)
        child_exit = code
      end,
    })
    truthy(job > 0, "could not start race child")
    truthy(vim.wait(10000, function()
      return uv.fs_stat(signal_file) ~= nil
    end, 10), "race child did not signal before writing")

    local parent_ok, parent_result, parent_error = pcall(
      notes.ensure_file,
      resolved,
      resolved.notes.directory_abs,
      path,
      { parent_payload }
    )
    write_file(release_file, "release\n")

    truthy(vim.wait(10000, function()
      return child_exit ~= nil
    end, 10), "race child did not finish")
    if not parent_ok then
      error(parent_result, 0)
    end
    equal(parent_result, "created", parent_error)
    equal(read_file(path), parent_payload .. "\n", "created target must be complete immediately")
    local stat = uv.fs_stat(path)
    equal(stat.type, "file")
    equal(stat.mode & 511, 384, "created note must use 0600 permissions")
    equal(child_exit, 0)
    equal(vim.fn.readfile(result_file)[1], "existing")
    equal(read_file(path), parent_payload .. "\n", "existing creator must not overwrite bytes")

    vim.fn.delete(result_file)
    vim.fn.delete(signal_file)
    vim.fn.delete(release_file)
  end)
end)
test("supports safe setup, discovery, and reusable note windows", function()
  with_root(function(root)
    local visible = vim.fs.joinpath(root, "visible.md")
    local hidden_directory = vim.fs.joinpath(root, ".hidden")
    local hidden = vim.fs.joinpath(hidden_directory, "private.md")
    truthy(vim.fn.mkdir(hidden_directory, "p") == 1, "could not create hidden directory")
    write_file(visible, "# Visible\n\nfind the needle here\n")
    write_file(hidden, "# Hidden\n")

    local windows = {}
    local fake_win = setmetatable({}, {
      __call = function(_, opts)
        local object = {
          buf = opts.buf,
          win = vim.api.nvim_open_win(opts.buf, opts.enter, {
            relative = "editor",
            row = 0,
            col = 0,
            width = 40,
            height = 8,
            style = "minimal",
          }),
        }
        function object:valid()
          return vim.api.nvim_win_is_valid(self.win)
            and vim.api.nvim_buf_is_valid(self.buf)
            and vim.api.nvim_win_get_buf(self.win) == self.buf
        end
        function object:set_buf(buffer)
          self.buf = buffer
          vim.api.nvim_win_set_buf(self.win, buffer)
        end
        function object:set_title(title)
          self.title = title
        end
        function object:focus()
          vim.api.nvim_set_current_win(self.win)
        end
        windows[#windows + 1] = object
        return object
      end,
    })

    local candidates = {
      { file = "visible.md", cwd = root },
      { file = ".hidden/private.md", cwd = root },
      { file = "./.obsidian/private.md", cwd = root },
      { file = ".obsidian.md", cwd = root },
    }
    local function make_picker(opts)
      local picker = { opts = opts, items = {}, closed = false }
      for _, candidate in ipairs(candidates) do
        local item = { file = candidate.file, cwd = candidate.cwd }
        local transformed = opts.transform(item, {})
        if transformed ~= false then
          picker.items[#picker.items + 1] = type(transformed) == "table" and transformed or item
        end
      end
      function picker:close()
        self.closed = true
      end
      return picker
    end
    local pickers = {}
    local fake_picker = {
      files = function(opts)
        local picker = make_picker(opts)
        pickers.files = picker
        return picker
      end,
      grep = function(opts)
        local picker = make_picker(opts)
        pickers.grep = picker
        return picker
      end,
    }
    package.loaded["snacks"] = { win = fake_win, picker = fake_picker }

    local notifications = {}
    local original_notify = vim.notify
    vim.notify = function(message, level, opts)
      notifications[#notifications + 1] = { message = message, level = level, opts = opts }
    end

    local vaire = require("vaire")
    local unavailable, unavailable_error = vaire.daily()
    equal(unavailable, nil)
    truthy(unavailable_error:find("not configured", 1, true), unavailable_error)
    equal(#notifications, 0, "Lua API failures must not notify")

    local original_keymap_set = vim.keymap.set
    local mapping_calls = 0
    vim.keymap.set = function(...)
      mapping_calls = mapping_calls + 1
      if mapping_calls == 2 then
        error("forced mapping registration failure")
      end
      return original_keymap_set(...)
    end
    local setup_ok, setup_error = pcall(vaire.setup, { root = root, mappings = true })
    vim.keymap.set = original_keymap_set
    truthy(not setup_ok, "forced setup failure must propagate")
    truthy(tostring(setup_error):find("Vaire: setup failed", 1, true), setup_error)
    for _, name in ipairs({ "VaireDaily", "VaireFind", "VaireSearch", "VaireNew", "VaireGit" }) do
      equal(vim.fn.exists(":" .. name), 0, "failed setup left command " .. name)
    end
    for _, lhs in ipairs({ "<leader>ad", "<leader>af", "<leader>as", "<leader>an", "<leader>vg" }) do
      truthy(vim.tbl_isempty(vim.fn.maparg(lhs, "n", false, true)), "failed setup left mapping " .. lhs)
    end

    local resolved = vaire.setup({ root = root, mappings = true })
    equal(vaire.setup({ root = root, mappings = true }), resolved, "identical setup must be idempotent")
    expect_error(function()
      vaire.setup({ root = root, notes = { directory = "other-notes" } })
    end, "different options")
    for _, name in ipairs({ "VaireDaily", "VaireFind", "VaireSearch", "VaireNew", "VaireGit" }) do
      equal(vim.fn.exists(":" .. name), 2, "successful setup did not register " .. name)
    end

    local notification_count = #notifications
    local invalid_result, invalid_error = vaire.new("../escape")
    equal(invalid_result, nil)
    truthy(invalid_error, "invalid Lua API call must return an error")
    equal(#notifications, notification_count, "Lua API failure unexpectedly notified")
    vim.cmd("VaireNew ../escape")
    equal(#notifications, notification_count + 1, "command failure must notify")
    equal(notifications[#notifications].message, invalid_error)

    local git_mapping = vim.fn.maparg("<leader>vg", "n", false, true)
    equal(git_mapping.desc, "Open Vaire lazygit")
    local original_executable = vim.fn.executable
    local original_termopen = vim.fn.termopen
    local executable_name
    local terminal_command
    local terminal_options
    vim.fn.executable = function(command)
      executable_name = command
      return 1
    end
    vim.fn.termopen = function(command, options)
      terminal_command = command
      terminal_options = options
      return 4242
    end
    local git_window, git_error = vaire.git()
    vim.fn.executable = original_executable
    vim.fn.termopen = original_termopen
    truthy(git_window, git_error)
    equal(executable_name, "lazygit")
    equal(terminal_command[1], "lazygit")
    equal(terminal_options.cwd, root)
    vim.cmd("VaireGit")
    truthy(vim.api.nvim_win_is_valid(git_window.win), "VaireGit did not keep lazygit open")
    vim.api.nvim_win_close(git_window.win, true)
    vim.cmd("stopinsert")

    local find_picker = vaire.find()
    local search_picker = vaire.search("needle")

    local function has_item(items, file)
      for _, item in ipairs(items) do
        if item.file == file then
          return true
        end
      end
      return false
    end
    for _, picker in ipairs({ find_picker, search_picker }) do
      truthy(has_item(picker.items, "visible.md"), "visible note must remain eligible")
      truthy(has_item(picker.items, ".hidden/private.md"), "hidden note must remain eligible")
      truthy(has_item(picker.items, ".obsidian.md"), "similar names must remain eligible")
      truthy(not has_item(picker.items, "./.obsidian/private.md"), "Obsidian directory must be excluded")
    end
    equal(pickers.files, find_picker)
    equal(pickers.grep, search_picker)

    search_picker.opts.confirm(search_picker, nil)
    equal(search_picker.closed, false, "invalid selection must leave the picker open")
    search_picker.opts.confirm(search_picker, {
      file = "visible.md",
      cwd = root,
      pos = { 3, 9 },
    })
    equal(search_picker.closed, true, "valid selection must close the picker")
    truthy(vim.wait(1000, function()
      return #windows == 1 and vim.api.nvim_win_is_valid(windows[1].win)
    end, 10), "search selection did not open a note window")
    local first_window = windows[1]
    local visible_buffer = first_window.buf
    local cursor = vim.api.nvim_win_get_cursor(first_window.win)
    equal(cursor[1], 3, "search must select the matched line")
    equal(cursor[2], 9, "search must select the matched byte column")
    equal(vim.fs.normalize(vim.api.nvim_buf_get_name(visible_buffer)), visible)

    vim.api.nvim_buf_set_lines(visible_buffer, -1, -1, false, { "unsaved change" })
    truthy(vim.bo[visible_buffer].modified, "fixture buffer must be modified")
    find_picker.opts.confirm(find_picker, {
      file = ".hidden/private.md",
      cwd = root,
    })
    equal(find_picker.closed, true, "valid selection must close the picker")
    truthy(vim.wait(1000, function()
      return #windows == 1
        and vim.api.nvim_buf_get_name(first_window.buf) == hidden
    end, 10), "find selection did not reuse the note window")
    equal(windows[1], first_window)
    truthy(vim.api.nvim_buf_is_valid(visible_buffer), "modified note buffer was discarded")
    truthy(vim.bo[visible_buffer].modified, "modified note lost its unsaved state")
    equal(vim.bo[visible_buffer].bufhidden, "hide")
    equal(vim.api.nvim_buf_get_lines(visible_buffer, -2, -1, false)[1], "unsaved change")

    vim.notify = original_notify
    vim.api.nvim_win_close(first_window.win, true)
  end)
end)

test("prompts for and persists roots without changing strict setup", function()
  with_root(function(root)
    local original_stdpath = vim.fn.stdpath
    local original_input = vim.ui.input
    local original_notify = vim.notify
    local state_directory = vim.fs.joinpath(root, "state")
    vim.fn.stdpath = function(kind)
      if kind == "state" then
        return state_directory
      end
      return original_stdpath(kind)
    end

    local input_callbacks = {}
    local input_prompts = {}
    vim.ui.input = function(options, callback)
      input_prompts[#input_prompts + 1] = options.prompt
      input_callbacks[#input_callbacks + 1] = callback
    end
    local notifications = {}
    vim.notify = function(message, level, options)
      notifications[#notifications + 1] = { message = message, level = level, options = options }
    end

    local events = {}
    local vaire_ui = require("vaire.ui")
    local original_open = vaire_ui.open
    local original_find = vaire_ui.find
    local original_search = vaire_ui.search
    local original_open_git = vaire_ui.open_git
    local function record(kind, value)
      events[#events + 1] = kind .. ":" .. value
      return { kind = kind, value = value }
    end
    vaire_ui.open = function(path)
      return record("open", path)
    end
    vaire_ui.find = function(config_value)
      return record("find", config_value.root)
    end
    vaire_ui.search = function(config_value)
      return record("search", config_value.root)
    end
    vaire_ui.open_git = function(path)
      return record("git", path)
    end

    local function fresh_plugin()
      for _, name in ipairs({ "VaireDaily", "VaireFind", "VaireSearch", "VaireNew", "VaireGit" }) do
        pcall(vim.api.nvim_del_user_command, name)
      end
      for _, lhs in ipairs({ "<leader>ad", "<leader>af", "<leader>as", "<leader>an", "<leader>vg" }) do
        pcall(vim.keymap.del, "n", lhs)
      end
      package.loaded["vaire"] = nil
      return require("vaire")
    end
    local function answer(value)
      local callback = table.remove(input_callbacks, 1)
      truthy(callback, "there is no pending Vaire input prompt")
      callback(value)
    end

    local vault = vim.fs.joinpath(root, "vault")
    truthy(vim.fn.mkdir(vault, "p") == 1, "could not create selected vault")
    local plugin = fresh_plugin()
    local configured = plugin.setup({
      prompt_root = true,
      mappings = true,
      notes = { directory = "Notes", daily_directory = "Journal" },
    })
    equal(configured.root, nil)
    equal(#input_prompts, 0, "setup must not prompt for a root")
    for _, name in ipairs({ "VaireDaily", "VaireFind", "VaireSearch", "VaireNew", "VaireGit" }) do
      equal(vim.fn.exists(":" .. name), 2, "prompt-enabled setup did not register " .. name)
    end
    truthy(not vim.tbl_isempty(vim.fn.maparg("<leader>ad", "n", false, true)), "prompt-enabled setup omitted mappings")

    equal(plugin.daily(), true)
    equal(plugin.find(), true)
    equal(plugin.search("needle"), true)
    equal(plugin.git(), true)
    equal(plugin.new("queued-note"), true)
    equal(#input_callbacks, 1, "concurrent actions must share one root prompt")
    answer(vault)

    local resolved_vault = config.resolve({
      root = vault,
      notes = { directory = "Notes", daily_directory = "Journal" },
    })
    local daily_path = notes.daily_path(resolved_vault)
    truthy(uv.fs_lstat(daily_path), "daily action did not create a note under the selected root")
    truthy(uv.fs_lstat(vim.fs.joinpath(vault, "Notes", "queued-note.md")), "new action did not use the selected root")
    equal(table.concat(events, "\n"), table.concat({
      "open:" .. daily_path,
      "find:" .. vault,
      "search:" .. vault,
      "git:" .. vault,
      "open:" .. vim.fs.joinpath(vault, "Notes", "queued-note.md"),
    }, "\n"), "queued actions must execute once in invocation order")

    local saved_path = vim.fs.joinpath(state_directory, "vaire-root")
    equal(read_file(saved_path), vault .. "\n")
    equal(uv.fs_stat(saved_path).mode & 511, 384, "saved vault path must have 0600 permissions")

    local missing_root = vim.fs.joinpath(root, "future-vault")
    local reused = fresh_plugin()
    reused.setup({ root = missing_root, prompt_root = true })
    local prompts_before_reuse = #input_prompts
    reused.git()
    equal(#input_prompts, prompts_before_reuse, "a second instance must reuse the saved root")
    equal(events[#events], "git:" .. vault)

    local explicit_vault = vim.fs.joinpath(root, "explicit-vault")
    truthy(vim.fn.mkdir(explicit_vault, "p") == 1, "could not create explicit vault")
    local explicit = fresh_plugin()
    explicit.setup({ root = explicit_vault, prompt_root = true })
    local prompts_before_explicit = #input_prompts
    explicit.git()
    equal(#input_prompts, prompts_before_explicit, "a valid explicit root must precede saved state")
    equal(events[#events], "git:" .. explicit_vault)

    local titled = fresh_plugin()
    titled.setup({ root = vault, prompt_root = true })
    titled.new()
    equal(input_prompts[#input_prompts], "Vaire note title: ", "root prompting must retain the note-title prompt")
    answer("prompted-title")
    truthy(uv.fs_lstat(vim.fs.joinpath(vault, "10-Notes", "prompted-title.md")), "note-title prompt did not create its note")

    local next_vault = vim.fs.joinpath(root, "next-vault")
    truthy(vim.fn.mkdir(next_vault, "p") == 1, "could not create replacement vault")
    truthy(vim.fn.delete(vault, "rf") == 0, "could not remove selected vault fixture")
    local root_link = vim.fs.joinpath(root, "vault-link")
    truthy(uv.fs_symlink(next_vault, root_link), "could not create invalid root symlink")
    local prompts_before_missing = #input_prompts
    titled.git()
    equal(#input_callbacks, 1, "a missing saved root must trigger a new prompt")
    answer(root_link)
    truthy(vim.wait(1000, function()
      return #input_callbacks == 1
    end, 10), "invalid symlink input did not reprompt")
    truthy(notifications[#notifications].message:find("symbolic link", 1, true), "invalid path failure was not reported")
    answer(next_vault)
    equal(input_prompts[#input_prompts], "Vaire vault root: ")
    truthy(#input_prompts > prompts_before_missing, "missing root did not ask for a replacement")
    equal(events[#events], "git:" .. next_vault, "pending action did not run on the replacement root")
    equal(read_file(saved_path), next_vault .. "\n")

    truthy(vim.fn.delete(next_vault, "rf") == 0, "could not remove saved vault fixture")
    local canceled = fresh_plugin()
    canceled.setup({ prompt_root = true })
    local events_before_cancel = #events
    canceled.daily()
    answer(nil)
    equal(#events, events_before_cancel, "cancelled root prompt must skip the action")
    equal(read_file(saved_path), next_vault .. "\n", "cancelled root prompt must leave saved state untouched")
    truthy(vim.fn.mkdir(next_vault, "p") == 1, "could not restore vault for persistence failure fixture")
    state_directory = vim.fs.joinpath(root, "failed-state")
    local failed_save = fresh_plugin()
    failed_save.setup({ prompt_root = true })
    failed_save.daily()
    local original_mkstemp = vim.uv.fs_mkstemp
    vim.uv.fs_mkstemp = function(template)
      if template:find("vaire-root", 1, true) then
        return nil, nil, "fixture write failure"
      end
      return original_mkstemp(template)
    end
    answer(next_vault)
    vim.uv.fs_mkstemp = original_mkstemp
    local failure_daily_path = notes.daily_path(config.resolve({ root = next_vault }))
    equal(events[#events], "open:" .. failure_daily_path, "a valid root must still perform its pending action when persistence fails")
    equal(uv.fs_lstat(vim.fs.joinpath(state_directory, "vaire-root")), nil, "failed persistence must not claim a saved root")
    truthy(notifications[#notifications].message:find("Could not persist Vaire vault root", 1, true), "state save failure must be reported")

    fresh_plugin()
    vaire_ui.open = original_open
    vaire_ui.find = original_find
    vaire_ui.search = original_search
    vaire_ui.open_git = original_open_git
    vim.fn.stdpath = original_stdpath
    vim.ui.input = original_input
    vim.notify = original_notify
  end)
end)

local passed = 0
for _, case in ipairs(tests) do
  local ok, message = pcall(case.callback)
  if not ok then
    io.stderr:write("FAIL: " .. case.name .. "\n" .. tostring(message) .. "\n")
    vim.cmd("cquit 1")
    return
  end
  passed = passed + 1
end

print(string.format("Vaire path checks passed: %d", passed))
vim.cmd("qa!")
