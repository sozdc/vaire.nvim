# vaire.nvim

Vaire is a small Neovim plugin for safe note actions inside one filesystem vault. It handles note navigation and creation without taking ownership of tasks, Obsidian configuration, or another editor's data model.

## Requirements

- Neovim `>= 0.12`
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim), used directly for its `picker.files`, `picker.grep`, and `win` support
- `lazygit`, required only for `:VaireGit` and `<leader>vg`

## Installation

Install from a local checkout with `lazy.nvim`; Snacks is installed as a runtime dependency:

```lua
{
  dir = "/path/to/vaire.nvim",
  main = "vaire",
  dependencies = { "folke/snacks.nvim" },
  opts = {
    root = "~/Vaire",
    prompt_root = true,
  },
}
```

`prompt_root` is opt-in and defaults to `false`. When enabled, `root` may be unset or point to a missing directory; setup still registers commands and mappings without opening a prompt. The configured or selected root must be a real directory, must not contain symbolic-link components, and must not be the filesystem root (`/`). Vaire creates configured note directories and missing note parents only when creating a note; it never creates a vault.

## Configuration

```lua
require("vaire").setup({
  root = "~/Vaire", -- required unless prompt_root = true
  prompt_root = true, -- default false
  notes = {
    directory = "10-Notes", -- default
    daily_directory = "00-Daily", -- default
  },
  mappings = false, -- default
})
```

`root` accepts an absolute path, `~`, `~/...`, and `$NAME` environment references. `${NAME}`, `~user`, relative roots, symbolic-link components, and unset environment variables are rejected. `notes.directory` and `notes.daily_directory` must be relative POSIX paths beneath the root, may not target `.obsidian`, and may not contain symbolic-link components. Both are created as needed.

## Expected vault layout

For a home-based Vaire vault, configure `root = "~/Vaire"` and use this layout:

```text
~/Vaire/                   # Required: an existing real directory
├── Home.md                # Optional vault index; Vaire does not create it
├── README.md              # Optional vault documentation
├── 00-Daily/              # Vaire daily notes; created as needed when a note is created
├── 10-Notes/              # Vaire named notes; created as needed when a note is created
├── 99-System/             # Optional user-managed vault content
└── .obsidian/             # Optional; managed by Obsidian
```

Only the root directory is required for Vaire to operate. It must already exist as a real directory before setup; Vaire does not create the vault root, `Home.md`, `README.md`, `99-System/`, or `.obsidian/`. With the default note-directory settings, Vaire creates `00-Daily/` and `10-Notes/` when it first creates a note in them. These paths can be changed with `notes.daily_directory` and `notes.directory`.

With `prompt_root = true`, the first `daily`, `new`, `find`, `search`, or `git` action uses a valid explicit root, then a valid root saved at `stdpath("state") .. "/vaire-root"`, then prompts for an existing vault directory. Vaire atomically replaces this private, machine-local state file with the selected absolute path and `0600` permissions. Invalid entries are reported and prompt again; cancellation skips pending actions without changing saved state. If persistence fails, Vaire reports the error and still performs pending actions against the validated selection, but does not claim that the root was saved. If a selected or saved root later disappears, Vaire prompts again. Concurrent actions while the root picker is open are queued and run once, in order, after selection. `:VaireNew` still prompts for a note title when no path is supplied.

Calling `setup` again with the same resolved options is a no-op; different options are rejected. Unknown setup and `notes` options are rejected to prevent misspellings from silently selecting defaults. Setup validates dependencies and rolls back any commands or mappings if registration fails. Setup failures are raised with a `Vaire:` prefix. In strict mode, public operations return `nil, message` on failure without notifying; commands, mappings, and prompt callbacks present failures as a Vaire notification.

## Commands and API

The public API is:

local vaire = require("vaire")
vaire.setup(opts)
vaire.daily()
vaire.new(path)
vaire.find()
vaire.search(query)
vaire.git()
```

Successful setup registers:

| Command | Behavior |
| --- | --- |
| `:VaireDaily` | Open or create today's daily note |
| `:VaireNew [path]` | Create or open a note beneath `notes.directory`; prompts when omitted |
| `:VaireFind` | Find Markdown notes in the vault |
| `:VaireSearch [query]` | Search Markdown note contents |
| `:VaireGit` | Open lazygit with the vault as its working directory |

Mappings are disabled by default. Set `mappings = true` to add only these normal-mode mappings:

| Mapping | Action |
| --- | --- |
| `<leader>ad` | Daily note |
| `<leader>af` | Find notes |
| `<leader>as` | Search notes |
| `<leader>an` | New note |
| `<leader>vg` | Open lazygit in the vault |

Existing mappings are never overwritten; Vaire warns for each skipped key.

## Safety and discovery

- Named notes may use nested paths and receive a `.md` suffix when omitted.
- Absolute paths, `..` or `.` segments, empty segments, trailing directories, backslashes, and filenames ending in `.md` with no non-empty stem are rejected.
- Existing files are opened without rewriting. New files are synchronized and atomically published only after their complete `0600` contents are ready.
- The vault root, configured directories, note parents, and note files must use real directory entries rather than symbolic links. Prompted roots use the same validation as configured roots.
- Daily notes keep the layout `00-Daily/YYYY/MM-Mon/DD-MM-YYYY.md` and start with the exact `# Notes`/`[[daily]]` template.
- Find and search operate from the configured root, include visible and hidden Markdown, and exclude `.obsidian/**`.
- Notes open in one reusable rounded floating window. Switching notes preserves any modified buffer without writing or discarding it.

Vaire does not add metadata, alter `.obsidian`, or provide task commands. Task storage and integrations remain outside this plugin.

Vaire assumes a trusted, user-owned local vault. Its validation protects against ordinary traversal and pre-existing symbolic-link escapes; it is not a sandbox against another process replacing filesystem entries concurrently. Note creation requires a filesystem that supports hard links and file and directory synchronization.

## Checks

Run the dependency-free focused suite with:

```sh
make check
```

The suite runs in a clean headless Neovim process and covers strict and prompted root setup, saved-root reuse and re-prompting, queued actions and cancellation, root/path containment, symbolic-link rejection, picker path validation, exact templates, synchronized exclusive creation, setup rollback, API error behavior, and modified-buffer preservation.
