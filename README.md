# Helix Steel Plugin Manager

A small plugin manager for Helix's Steel/Scheme configuration. It clones git repositories and loads their Scheme entry files as Helix plugins.

## Requirements

- Helix built with Steel support
- `git` available on `PATH`
- A Steel setup that uses `helix.scm` and `init.scm`

## Installation

The most reliable path is the bundled POSIX `sh` installer. With `--configure`, it installs `plugin-manager.scm` and writes the required managed blocks to `helix.scm` and `init.scm`. Existing installer-managed blocks are updated in place instead of duplicated.

```sh
cd "$HOME/src/helix/helix-steel-plugin-manager"
sh install.sh --configure
```

If `helix/plugin-manager.scm` already exists, the installer stops. Use `--force` to back up the existing file and replace it.

```sh
sh install.sh --configure --force
```

Use copy mode on systems where symlinks are unavailable or inconvenient.

```sh
sh install.sh --configure --copy
```

To install into a specific Helix Steel config directory:

```sh
sh install.sh --configure --config-dir "$HOME/.config/helix"
```

For a manual install, symlink this project into a path Helix can find. With the default config directory:

```sh
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/helix/helix"
ln -sf "$HOME/src/helix/helix-steel-plugin-manager/plugin-manager.scm" \
  "${XDG_CONFIG_HOME:-$HOME/.config}/helix/helix/plugin-manager.scm"
```

If you use `HELIX_STEEL_CONFIG`, symlink into that directory instead.

```sh
mkdir -p "$HELIX_STEEL_CONFIG/helix"
ln -sf "$HOME/src/helix/helix-steel-plugin-manager/plugin-manager.scm" \
  "$HELIX_STEEL_CONFIG/helix/plugin-manager.scm"
```

Expose the commands from `helix.scm`.

```scheme
(require (only-in "helix/plugin-manager.scm"
                  plugin-install
                  plugin-manager-init
                  plugin-manager-update
                  plugin-ensure
                  plugin-update
                  plugin-remove
                  plugin-enable
                  plugin-disable
                  plugin-load
                  plugin-load-all
                  plugin-list))

(provide plugin-install
         plugin-manager-init
         plugin-manager-update
         plugin-ensure
         plugin-update
         plugin-remove
         plugin-enable
         plugin-disable
         plugin-load
         plugin-load-all
         plugin-list)
```

Load enabled plugins from `init.scm`.

```scheme
(require (only-in "helix/plugin-manager.scm" plugin-manager-init))
(plugin-manager-init)
```

To keep startup plugin declarations compact, use `plugin-ensure`. The plugin
name is derived from the GitHub shorthand or git URL, and the entry file is
detected automatically.

```scheme
(require (only-in "helix/plugin-manager.scm"
                  plugin-ensure
                  plugin-manager-init))

(plugin-ensure "kn66/markdown-planner")
(plugin-ensure "kn66/helix-dired")
(plugin-manager-init)
```

Restart Helix or reload the Steel configuration after installation.

## How Helix Loads the Manager

Helix Steel reads configuration from the Helix config directory. By default, this directory is `${XDG_CONFIG_HOME:-$HOME/.config}/helix`, so the files are usually:

```text
~/.config/helix/helix.scm
~/.config/helix/init.scm
~/.config/helix/helix/plugin-manager.scm
```

`helix.scm` exposes Scheme functions as Helix commands. The installer adds the plugin manager functions there so commands such as `:plugin-install` and `:plugin-list` are available from Helix's command line.

`init.scm` runs when the Steel configuration is initialized. The installer adds this short block so previously installed and enabled plugins are loaded automatically:

```scheme
(require (only-in "helix/plugin-manager.scm" plugin-manager-init))
(plugin-manager-init)
```

`plugin-manager-init` wraps startup loading and reports plugin load failures as a Helix warning instead of making `init.scm` harder to read.

If `HELIX_STEEL_CONFIG` is set, Helix Steel uses that directory instead of the default config directory. In that case, write `helix.scm`, `init.scm`, and the `helix/plugin-manager.scm` module under `$HELIX_STEEL_CONFIG`.

After installation, type the full command names in Helix. There is no `:plugin` command by itself; the provided commands are named with the `plugin-` prefix, for example `:plugin-list` and `:plugin-install`.

## Usage

You can install from a GitHub `owner/repo` shorthand or from a regular git URL.

```scheme
(plugin-install "owner/repo")
(plugin-install "https://github.com/owner/repo.git")
```

Pass an explicit name, entry file, or branch when needed.

```scheme
(plugin-install "https://github.com/owner/repo.git" "repo-name" "plugin/main.scm")
(plugin-install "owner/repo" "repo-name" "helix.scm" "main")
```

After exposing the functions from `helix.scm`, you can use them from Helix's command line.

```text
:plugin-install owner/repo
:plugin-list
:plugin-ensure owner/repo
:plugin-update
:plugin-manager-update
:plugin-load repo
:plugin-disable repo
:plugin-enable repo
:plugin-remove repo
```

When `plugin-update` finds local changes in a plugin checkout, it keeps those
changes and prints the command to run if you want to discard them. Use
`:plugin-update <name> discard` to run `git reset --hard`, `git clean -fd`, and
then update that checkout.

`plugin-install` is idempotent for the same plugin name and source. If the plugin is already registered and its checkout exists, it reloads the plugin and returns `already installed <name>` instead of cloning again. If the checkout exists but the registry entry is missing, it registers that checkout and loads it.

`plugin-ensure` wraps `plugin-install` for startup use. It accepts the same
optional arguments, but most plugins only need `(plugin-ensure "owner/repo")`.
Install failures are reported as Helix warnings so one unavailable plugin does
not stop the rest of `init.scm`.

Update the plugin manager itself from Helix with:

```text
:plugin-manager-update
```

The installer writes the manager source checkout path to `helix/plugin-manager-source`, so `plugin-manager-update` can run `git pull --ff-only` in that checkout. Symlink installs pick up the new file immediately after restart or Steel reload. Copy installs are refreshed by copying the updated `plugin-manager.scm` into the Helix config directory.

## Plugin Format

The manager loads the selected entry file from the cloned repository as a Scheme module with `require`. The entry file should `provide` the commands or values it wants to expose, like any other Helix Steel plugin.

```scheme
(provide hello-plugin)

(define (hello-plugin)
  "hello from plugin")
```

If no entry file is given, the manager uses the first existing file in this order:

- `helix.scm`
- `init.scm`
- `plugin.scm`
- `cog.scm`
- `<plugin-name>.scm`

## Storage

Installed plugins and the registry are stored under the parent directory of `get-init-scm-path`.

```text
<steel-config-dir>/steel/plugins/
<steel-config-dir>/steel/plugins/registry.scm
```

With the default Helix config layout, this is usually:

```text
~/.config/helix/steel/plugins/
~/.config/helix/steel/plugins/registry.scm
```

## Project Maintenance

This repository is intended to be managed separately from the Helix source tree.

```sh
cd "$HOME/src/helix/helix-steel-plugin-manager"
git init
git add README.md plugin-manager.scm install.sh
git commit -m "Initial plugin manager"
```

When `plugin-manager.scm` changes, run `:plugin-manager-update` from Helix or run `git pull --ff-only` in this repository and rerun `sh install.sh --configure`. Symlink-based installs pick up the updated file after Helix is restarted or the Steel configuration is reloaded. Copy-based installs are refreshed by `:plugin-manager-update` when the installer metadata is present, or by rerunning `sh install.sh --configure --copy`.

## Notes

- `plugin-disable` only excludes the plugin from future `plugin-load-all` calls. It does not unload definitions already evaluated in the current Steel engine.
- `plugin-update` runs `git pull --ff-only`. Plugins with local changes are kept unless you pass `discard`.
- `plugin-manager-update` runs `git pull --ff-only` for the plugin manager checkout. If that checkout has local changes, use `:plugin-manager-update discard` to reset them before updating.
- `plugin-remove` deletes the cloned directory by default.
