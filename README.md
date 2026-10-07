# vaire.nvim

Vaire is a Neovim plugin for creating and finding notes in one local filesystem vault. It provides daily notes, named-note creation, Markdown search, and an optional lazygit terminal. It does not manage tasks, modify Obsidian settings, or impose a vault metadata model.

## Requirements

- Neovim `>= 0.12`
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim) for pickers and the note window
- `lazygit` on `PATH` only if you use the Git action

## Installation

Add Vaire to your `lazy.nvim` plugin list:

```lua
{
  "sozdc/vaire.nvim",
  main = "vaire",
  dependencies = { "folke/snacks.nvim" },
  opts = {
    root = "~/Vaire",
  },
}
```

## Configuration

```lua
require("vaire").setup({
  root = "~/Vaire", -- required unless prompt_root = true
  prompt_root = false,
  notes = {
    directory = "10-Notes",
    daily_directory = "00-Daily",
  },
  mappings = false,
})
```

Options:

| Option | Default | Description |
| --- | --- | --- |
| `root` | — | Vault path. Required unless `prompt_root = true`. |
| `prompt_root` | `false` | Allow choosing an existing vault when an action needs one. |
| `notes.directory` | `10-Notes` | Relative directory for named notes. |
| `notes.daily_directory` | `00-Daily` | Relative directory for daily notes. |
| `mappings` | `false` | Add Vaire's normal-mode mappings. |

`root` accepts an absolute path, `~`, `~/...`, and `$NAME` environment references. Relative paths, `${NAME}`, `~user`, unset variables, and symbolic-link components are rejected. Note directories must be relative POSIX paths beneath the vault and may not target `.obsidian`.

With a fixed root, setup creates the vault, configured note directories, and `99-System/` when missing. Existing files and directories are preserved. Setup checks its dependencies before creating the vault; a later setup failure rolls back registered commands and mappings, but does not remove directories already created. Repeating setup with identical options is a no-op; different options are rejected. `setup` returns a configuration snapshot, not Vaire's mutable internal configuration.

## Choosing a vault

By default, configure `root` explicitly and Vaire uses that vault. With `prompt_root = true`, setup does not create a vault. On the first action, Vaire uses a valid configured root, then a valid root saved from an earlier selection, then prompts for an existing vault directory.

The selected root is saved at `stdpath("state") .. "/vaire-root"` using a private `0600` state file and atomic replacement. Invalid selections are reported and prompted again. Canceling skips queued actions and leaves the saved root unchanged. Actions requested while the root prompt is open are queued in order. If saving the selection fails, Vaire reports the persistence error but still runs the queued actions against the validated root. If a saved or configured root later becomes unusable, Vaire prompts again.

In prompt mode, an API action can return `true` to indicate it was accepted while waiting for the root prompt; this does not mean the action has completed.

## Vault layout

For the default configuration, Vaire uses:

```text
~/Vaire/
├── 00-Daily/       # Daily notes
├── 10-Notes/       # Named notes
├── 99-System/      # Created if missing; contents left untouched
└── .obsidian/      # Optional; managed by Obsidian
```

Vaire does not create `Home.md`, a vault README, or `.obsidian/`. Daily notes use `00-Daily/YYYY/MM-Mon/DD-MM-YYYY.md` and start with `# Notes` and `[[daily]]`. Named notes can use nested paths; a `.md` suffix is added when omitted.

## Commands and API

| Command | Behavior |
| --- | --- |
| `:VaireDaily` | Open or create today's daily note. |
| `:VaireNew [path]` | Create or open a note; prompts for a title when no path is given. |
| `:VaireFind` | Find Markdown notes in the vault. |
| `:VaireSearch [query]` | Search Markdown note contents. |
| `:VaireGit` | Open lazygit with the vault as its working directory. |

Mappings are disabled by default. Set `mappings = true` to add:

| Mapping | Action |
| --- | --- |
| `<leader>ad` | Daily note |
| `<leader>af` | Find notes |
| `<leader>as` | Search notes |
| `<leader>an` | New note |
| `<leader>vg` | Open lazygit |

Existing mappings are never overwritten; Vaire warns when a mapping is skipped.

The Lua API is:

```lua
local vaire = require("vaire")
vaire.setup({ root = "~/Vaire" })
vaire.daily()
vaire.new("team/architecture")
vaire.find()
vaire.search("architecture")
vaire.git()
```

In strict-root mode, failed Lua API actions return `nil, message` without notifying; commands and mappings display failures as notifications. Prompt callbacks also notify on errors. When `new()` is called without a path, it starts a title prompt and returns while that prompt is pending. In prompt-root mode, an action may likewise return `true` while queued. `setup` errors are raised with a `Vaire:` prefix.

## Note safety and discovery

- Absolute note paths, `.` and `..` segments, empty path segments, trailing slashes, backslashes, and empty `.md` filenames are rejected.
- Existing notes are opened without rewriting. New notes are written with `0600` permissions and published exclusively only after their complete contents are synchronized.
- If temporary-link cleanup or parent-directory synchronization fails after publication, the API reports an error even though the complete note may already exist.
- Vault roots, configured directories, note parents, and note files must not use symbolic-link components. Prompted roots use the same validation as configured roots.
- Find and search include hidden Markdown files and exclude `.obsidian/**`.
- Notes open in one reusable floating window. Switching notes preserves modified buffers without writing or discarding them.
- Git sessions are reused for the same vault root and replaced when opening a different root.

Vaire assumes a trusted, user-owned local vault. Its path checks protect against ordinary traversal and pre-existing symbolic-link escapes; they are not a sandbox against another process changing filesystem entries concurrently. Note creation requires filesystem support for hard links and file/directory synchronization.

## License

This project is distributed under the [MIT License](LICENSE).

## Development

Run the focused headless suite from the repository root:

```sh
make check
```

The suite covers setup and rollback, strict and prompted roots, path containment and symlink rejection, note creation and competing writers, picker behavior, modified-buffer preservation, and root-keyed Git sessions. The end-to-end setup and note-opening smoke can be run in headless Neovim; Snacks and lazygit are faked in the focused test suite.
