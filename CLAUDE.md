# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A one-shot dev-machine bootstrapper meant to be run on a fresh Linux/macOS box, typically via:

```
curl -fsSL https://raw.githubusercontent.com/grplyler/bootstrap/master/bootstrap.sh | bash
```

The entire project is a single file, `bootstrap.sh`. There is no build step, no test suite, and no dependencies to install for development.

## Run / smoke-test

```sh
./bootstrap.sh            # interactive wizard
bash -n bootstrap.sh      # syntax-check the bash wrapper
```

There is no automated test harness. To verify changes, run the script (ideally in a throwaway container/VM since it installs packages and edits `~/.zshrc`). For a non-destructive partial check of the embedded Python, you can extract it: the wizard is the heredoc between the `PYEOF` markers — run `python3 -c 'import ast; ...'` or copy it out and `python3 -m py_compile` it. Piping through a non-TTY (`./bootstrap.sh < /dev/null`) triggers the non-interactive path, which **preselects and installs everything** — do not do this on a real machine.

## Architecture

`bootstrap.sh` has two distinct layers in one file:

1. **Bash bootstrap wrapper** (top of file). Does the minimum to reach Python: detect OS (`Darwin`/`Linux`), detect package manager (`brew`/`apt`/`dnf`/`yum`/`pacman`/`zypper`/`apk`), resolve `sudo`, install `python3`+`pip`, install the `rich` pip package, then write the embedded Python wizard to a `mktemp` file and exec it. State is passed to Python only through env vars: `BOOTSTRAP_OS`, `BOOTSTRAP_PM`, `BOOTSTRAP_SUDO`.

2. **Embedded Python wizard** (the `PYEOF` heredoc). A Rich-powered TUI that drives the actual installs. This is where nearly all logic lives.

### Why the TTY handling is the way it is

The script must work under `curl | bash`, where stdin is the pipe, not the keyboard. So:
- The bash wrapper runs the wizard with `</dev/tty` when available.
- The Python `get_key()` reads raw bytes from `/dev/tty` directly (`_TTY`), falling back to stdin.
- `has_tty()` gates all interactivity. When there's no TTY, the wizard skips menus, selects every item, and installs non-interactively. Keep this fallback intact when editing UI code.

### The wizard's data-driven core

Everything installable is declared in `CATEGORIES` (Terminal / System Tools / Services). Each entry is `(key, label, desc, deps)`. From this, three parallel structures must stay in sync for any item you add or remove:

- **`CATEGORIES`** — the catalog and menu source of truth.
- **`INSTALLERS`** — `key -> install_<x>(overwrite=False)` function.
- **`DETECTORS`** — `key -> () -> truthy-detail-or-None`, used to decide whether to prompt skip/overwrite.
- **`ORDER`** — explicit install sequence (dependencies first). `git` is an implicit dep only and never appears in a menu.

Dependencies are resolved by `expand_deps()` (transitive closure over the `deps` lists). The install loop (`do_install`) walks `ORDER`, runs each `DETECTORS[key]`; if already present it calls `prompt_action()` to ask skip-vs-overwrite and passes `overwrite=` into the installer. Installers are expected to be idempotent and to honor `overwrite` (reinstall package / `rm -rf` and re-clone / re-fetch).

### Cross-distro package abstraction

- `pm_install(*pkgs, reinstall=)` / `pm_install_cask(...)` emit the right command string per `PM` and run it.
- `pkg_name(logical)` maps a logical name to the distro-specific package name (e.g. `docker` -> `docker.io` on apt), with `""` meaning "skip / handled elsewhere".
- When adding a tool, prefer extending `pkg_name`'s table over hardcoding names in an installer.

### Running commands as the target user

Installs often run as root (sudo) but must write configs into the *invoking* user's home. `TARGET_USER`/`TARGET_HOME` are resolved from `SUDO_USER`. `run(cmd, as_user=True)` re-drops privileges via `sudo -u $TARGET_USER -H` when euid is 0. Anything that touches `~/.zshrc`, `~/.oh-my-zsh`, `~/.tmux*`, fonts, or clones into the user's home must use `as_user=True`. `.zshrc` edits go through `append_zshrc_once()` (grep-guarded, idempotent) — use it rather than blind appends.

## Conventions

- Keep the project a single self-contained file. The bash layer should stay minimal; new install logic belongs in the Python wizard.
- macOS paths frequently diverge (Homebrew casks, `systemsetup` for ssh, `Library/Fonts`, `sed -i ''`). Most installers branch on `OS == "macos"` — preserve those branches.
- Network installs that aren't from a package manager (rustdesk, p10k, fonts, omz, tpm) fetch from upstream GitHub/release APIs; `_github_asset()` picks release assets by arch.
