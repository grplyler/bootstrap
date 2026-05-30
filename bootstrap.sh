#!/usr/bin/env bash
# bootstrap.sh - fancy python/rich bootstrap installer for Linux and macOS.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/grplyler/bootstrap/master/bootstrap.sh | bash
#   ./bootstrap.sh
#
# This shell wrapper does the bare minimum to get a Rich-powered Python wizard
# running on a fresh box:
#   1. detect the OS + package manager
#   2. install python3 + pip if missing
#   3. install the `rich` library (pip --user)
#   4. hand off to the embedded Python wizard, which drives a top-level menu of
#      categories (Terminal / System Tools / Services), lets you check off what
#      you want, then installs it.

set -euo pipefail

# ----- helpers -------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# ----- detect OS -----------------------------------------------------------

OS="linux"
case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux)  OS="linux" ;;
  *)      die "Unsupported OS: $(uname -s)" ;;
esac
log "Detected OS: $OS"

# ----- sudo handling -------------------------------------------------------

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if need_cmd sudo; then
    SUDO="sudo"
  elif [ "$OS" = "linux" ]; then
    die "Run as root or install sudo."
  fi
fi

# ----- detect package manager ----------------------------------------------

PM=""
if [ "$OS" = "macos" ]; then
  PM="brew"
  if ! need_cmd brew; then
    log "Installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -x /opt/homebrew/bin/brew ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi
elif need_cmd apt-get; then PM="apt"
elif need_cmd dnf;     then PM="dnf"
elif need_cmd yum;     then PM="yum"
elif need_cmd pacman;  then PM="pacman"
elif need_cmd zypper;  then PM="zypper"
elif need_cmd apk;     then PM="apk"
else die "No supported package manager found (brew/apt/dnf/yum/pacman/zypper/apk)."
fi
log "Detected package manager: $PM"

# ----- ensure python3 + pip ------------------------------------------------

pm_update_once() {
  case "$PM" in
    brew)   brew update ;;
    apt)    $SUDO apt-get update -y ;;
    dnf)    $SUDO dnf -y makecache ;;
    yum)    $SUDO yum -y makecache ;;
    pacman) $SUDO pacman -Sy --noconfirm ;;
    zypper) $SUDO zypper --non-interactive refresh ;;
    apk)    $SUDO apk update ;;
  esac
}

pm_install_boot() {
  [ "$#" -eq 0 ] && return 0
  case "$PM" in
    brew)   brew install "$@" ;;
    apt)    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "$@" ;;
    dnf)    $SUDO dnf install -y "$@" ;;
    yum)    $SUDO yum install -y "$@" ;;
    pacman) $SUDO pacman -S --noconfirm --needed "$@" ;;
    zypper) $SUDO zypper --non-interactive install "$@" ;;
    apk)    $SUDO apk add "$@" ;;
  esac
}

if ! need_cmd python3; then
  log "Installing python3"
  pm_update_once
  case "$PM" in
    brew)            pm_install_boot python ;;
    pacman)          pm_install_boot python python-pip ;;
    apt)             pm_install_boot python3 python3-pip ;;
    dnf|yum|zypper)  pm_install_boot python3 python3-pip ;;
    apk)             pm_install_boot python3 py3-pip ;;
  esac
fi

# Make sure pip exists (some distros split it out).
if ! python3 -m pip --version >/dev/null 2>&1; then
  log "Installing pip"
  case "$PM" in
    apt)            pm_install_boot python3-pip ;;
    dnf|yum|zypper) pm_install_boot python3-pip ;;
    pacman)         pm_install_boot python-pip ;;
    apk)            pm_install_boot py3-pip ;;
    brew)           : ;; # bundled with brew python
  esac
fi

# ----- ensure rich ---------------------------------------------------------

if ! python3 -c 'import rich' >/dev/null 2>&1; then
  log "Installing 'rich' (one-time)"
  python3 -m pip install --user --quiet rich 2>/dev/null \
    || python3 -m pip install --user --quiet --break-system-packages rich 2>/dev/null \
    || pip3 install --user --quiet rich \
    || die "Failed to install rich. Install manually: python3 -m pip install --user rich"
fi

# ----- write + run the python wizard ---------------------------------------

WIZARD_PY="$(mktemp -t bootstrap-wizard.XXXXXX.py)"
trap 'rm -f "$WIZARD_PY"' EXIT

cat > "$WIZARD_PY" <<'PYEOF'
#!/usr/bin/env python3
"""bootstrap wizard - Rich-powered installer for Linux and macOS.

Top-level menu of categories:
  Terminal      zsh, oh-my-zsh, powerlevel10k, MesloLGS Nerd Font, tmux,
                tpm, eza, zoxide, a nice tmux config
  System Tools  htop, btop
  Services      openssh-server, podman, docker, rustdesk

Arrow keys (or j/k) to move, Space to toggle, Enter to confirm, q/Esc to back out.
"""

import os
import sys
import json
import shutil
import subprocess
import urllib.request

from rich.console import Console, Group
from rich.panel import Panel
from rich.text import Text
from rich.table import Table
from rich.live import Live
from rich.align import Align

console = Console()

# ----- environment handed down from bootstrap.sh --------------------------

OS = os.environ.get("BOOTSTRAP_OS", "linux")
PM = os.environ.get("BOOTSTRAP_PM", "")
SUDO = os.environ.get("BOOTSTRAP_SUDO", "")

ARCH = subprocess.run(["uname", "-m"], capture_output=True, text=True).stdout.strip()

TARGET_USER = os.environ.get("SUDO_USER") or os.environ.get("USER") or "root"


def _user_home():
    if OS == "macos":
        out = subprocess.run(
            ["dscl", ".", "-read", f"/Users/{TARGET_USER}", "NFSHomeDirectory"],
            capture_output=True, text=True).stdout.split()
        if len(out) >= 2:
            return out[1]
    else:
        try:
            import pwd
            return pwd.getpwnam(TARGET_USER).pw_dir
        except (KeyError, ImportError):
            pass
    return os.path.expanduser("~")


TARGET_HOME = _user_home()
ZSHRC = os.path.join(TARGET_HOME, ".zshrc")

BANNER = r"""
 _                 _       _
| |__   ___   ___ | |_ ___| |_ _ __ __ _ _ __
| '_ \ / _ \ / _ \| __/ __| __| '__/ _` | '_ \
| |_) | (_) | (_) | |_\__ \ |_| | | (_| | |_) |
|_.__/ \___/ \___/ \__|___/\__|_|  \__,_| .__/
                                        |_|
"""


# ----- catalog -------------------------------------------------------------

# Each item: key, label, desc, deps (other keys auto-pulled when selected).
CATEGORIES = [
    ("Terminal", [
        ("zsh",          "zsh",                 "Z shell + set as default", []),
        ("oh-my-zsh",    "oh-my-zsh",           "zsh framework",            ["zsh", "git"]),
        ("powerlevel10k","powerlevel10k",       "fast, pretty prompt",      ["oh-my-zsh"]),
        ("meslo-font",   "MesloLGS Nerd Font",  "patched font for p10k",    []),
        ("tmux",         "tmux",                "terminal multiplexer",     []),
        ("tpm",          "tpm",                 "tmux plugin manager",      ["tmux"]),
        ("eza",          "eza",                 "modern ls (aliased)",      []),
        ("zoxide",       "zoxide",              "smarter cd",               []),
        ("tmux-config",  "tmux config",         "catppuccin + cpu/battery", ["tmux", "tpm"]),
    ]),
    ("System Tools", [
        ("htop",         "htop",                "interactive process viewer", []),
        ("btop",         "btop",                "resource monitor (prettier)",[]),
    ]),
    ("Programming Languages", [
        ("rust",         "Rust",                "rustup toolchain",         []),
        ("go",           "Go",                  "official toolchain",       []),
        ("nodejs",       "Node.js",             "via nvm (LTS)",            []),
        ("vlang",        "V (vlang)",           "compiled from source",     ["git"]),
        ("odin",         "Odin",                "prebuilt / brew",          []),
        ("uv",           "uv",                  "Python pkg/proj manager",  []),
    ]),
    ("Services", [
        ("openssh-server","openssh-server",     "SSH daemon (enabled)",     []),
        ("podman",       "podman",              "daemonless containers",    []),
        ("docker",       "docker",              "containers",               []),
        ("rustdesk",     "rustdesk",            "remote desktop",           []),
    ]),
]

# Flat lookup.
ITEM = {}
ITEM_CAT = {}
for cat, items in CATEGORIES:
    for key, label, desc, deps in items:
        ITEM[key] = (label, desc, deps)
        ITEM_CAT[key] = cat
# `git` is an implicit dependency only; not shown in any menu.
ITEM.setdefault("git", ("git", "version control", []))


# ----- key reader (reads /dev/tty so it survives `curl | bash`) ------------

def _open_tty():
    try:
        return open("/dev/tty", "rb", buffering=0)
    except OSError:
        return None


_TTY = _open_tty()


def get_key():
    """Return 'up'/'down'/'enter'/'esc'/'space' or a single char."""
    import termios
    import tty as _tty
    fd = _TTY.fileno() if _TTY else sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    try:
        _tty.setraw(fd)
        ch = (_TTY.read(1) if _TTY else sys.stdin.buffer.read(1)).decode(errors="ignore")
        if ch == "\x1b":
            seq = (_TTY.read(2) if _TTY else sys.stdin.buffer.read(2)).decode(errors="ignore")
            return {"[A": "up", "[B": "down", "[C": "right", "[D": "left"}.get(seq, "esc")
        if ch in ("\r", "\n"):
            return "enter"
        if ch == " ":
            return "space"
        if ch == "\x03":
            raise KeyboardInterrupt
        return ch
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def has_tty():
    return _TTY is not None or (sys.stdin.isatty() and sys.stdout.isatty())


# ----- UI: top-level menu --------------------------------------------------

def render_main(idx, selected):
    rows = []
    entries = main_entries(selected)
    for i, (label, desc) in enumerate(entries):
        on = i == idx
        marker = "▸" if on else " "
        if on:
            line = Text(f" {marker} {label}", style="bold reverse cyan")
            line.append(f"   {desc}", style="reverse")
        else:
            line = Text(f" {marker} ", style="cyan")
            line.append(label, style="bold")
            line.append(f"   {desc}", style="dim")
        rows.append(line)
    body = Group(
        Align.center(Text(BANNER, style="bold cyan")),
        Text(""),
        *rows,
    )
    return Panel(
        body,
        title="[bold cyan]bootstrap[/]",
        subtitle="[dim]↑/↓ move · enter select · q quit[/]",
        border_style="cyan",
        padding=(1, 3),
    )


def main_entries(selected):
    entries = []
    for cat, items in CATEGORIES:
        n = sum(1 for k, *_ in items if k in selected)
        tag = f"[{n} selected]" if n else "[ ]"
        entries.append((f"{cat}  {tag}", "choose what to install"))
    entries.append(("Review & Install", "run the installer"))
    entries.append(("Quit", "exit without installing"))
    return entries


def main_menu(selected):
    if not has_tty():
        return "install"  # non-interactive: install whatever was preselected
    idx = 0
    n = len(main_entries(selected))
    with Live(render_main(idx, selected), console=console,
              auto_refresh=False, screen=True) as live:
        while True:
            key = get_key()
            if key in ("up", "k"):
                idx = (idx - 1) % n
            elif key in ("down", "j"):
                idx = (idx + 1) % n
            elif key in ("q", "esc"):
                return "quit"
            elif key == "enter":
                if idx < len(CATEGORIES):
                    return ("category", CATEGORIES[idx][0])
                if idx == len(CATEGORIES):
                    return "install"
                return "quit"
            live.update(render_main(idx, selected), refresh=True)


# ----- UI: per-category checklist ------------------------------------------

def render_checklist(cat, items, idx, selected):
    rows = []
    for i, (key, label, desc, deps) in enumerate(items):
        on = i == idx
        box = "[x]" if key in selected else "[ ]"
        marker = "▸" if on else " "
        if on:
            line = Text(f" {marker} {box} {label}", style="bold reverse cyan")
            line.append(f"   {desc}", style="reverse")
        else:
            checked = key in selected
            line = Text(f" {marker} ", style="cyan")
            line.append(f"{box} ", style="green" if checked else "dim")
            line.append(label, style="bold" if checked else "")
            line.append(f"   {desc}", style="dim")
        rows.append(line)
    return Panel(
        Group(*rows),
        title=f"[bold cyan]{cat}[/]",
        subtitle="[dim]space toggle · a all · n none · enter back · esc back[/]",
        border_style="cyan",
        padding=(1, 2),
    )


def checklist(cat, items, selected):
    if not has_tty():
        return
    idx = 0
    with Live(render_checklist(cat, items, idx, selected), console=console,
              auto_refresh=False, screen=True) as live:
        while True:
            key = get_key()
            if key in ("up", "k"):
                idx = (idx - 1) % len(items)
            elif key in ("down", "j"):
                idx = (idx + 1) % len(items)
            elif key == "space":
                k = items[idx][0]
                selected.discard(k) if k in selected else selected.add(k)
            elif key == "a":
                for it in items:
                    selected.add(it[0])
            elif key == "n":
                for it in items:
                    selected.discard(it[0])
            elif key in ("enter", "esc", "q"):
                return
            live.update(render_checklist(cat, items, idx, selected), refresh=True)


# ----- dependency expansion + confirm --------------------------------------

def expand_deps(selected):
    out = set(selected)
    changed = True
    while changed:
        changed = False
        for key in list(out):
            for dep in ITEM.get(key, (None, None, []))[2]:
                if dep not in out:
                    out.add(dep)
                    changed = True
    return out


def confirm_screen(selected):
    table = Table(show_header=True, header_style="bold cyan", border_style="cyan")
    table.add_column("Category")
    table.add_column("Item")
    table.add_column("Notes", style="dim")
    shown = set()
    for cat, items in CATEGORIES:
        for key, label, desc, deps in items:
            if key in selected:
                table.add_row(cat, label, desc)
                shown.add(key)
    for key in sorted(selected - shown):
        if key in ITEM:
            table.add_row("(dependency)", ITEM[key][0], ITEM[key][1])
    console.print(Panel(table, title="[bold]About to install[/]",
                        border_style="green", padding=(1, 2)))
    if not has_tty():
        return True
    console.print("[bold]Proceed? [Y/n][/] ", end="")
    ans = get_key()
    console.print(ans)
    return ans in ("enter", "y", "Y")


# ----- shell command helpers -----------------------------------------------

def run(cmd, as_user=False, check=True):
    """Run a shell command string. as_user drops sudo->TARGET_USER when root."""
    if as_user and os.geteuid() == 0 and TARGET_USER != "root":
        full = ["sudo", "-u", TARGET_USER, "-H", "bash", "-c", cmd]
    else:
        full = ["bash", "-c", cmd]
    console.print(f"[dim]$ {cmd}[/]")
    rc = subprocess.run(full).returncode
    if check and rc != 0:
        raise RuntimeError(f"command failed ({rc}): {cmd}")
    return rc


def sudo_prefix():
    return (SUDO + " ") if SUDO else ""


def pm_install(*pkgs, reinstall=False):
    pkgs = [p for p in pkgs if p]
    if not pkgs:
        return
    s = sudo_prefix()
    joined = " ".join(pkgs)
    if reinstall:
        cmds = {
            "brew":   f"brew reinstall {joined}",
            "apt":    f"DEBIAN_FRONTEND=noninteractive {s}apt-get install -y --reinstall {joined}",
            "dnf":    f"{s}dnf reinstall -y {joined}",
            "yum":    f"{s}yum reinstall -y {joined}",
            "pacman": f"{s}pacman -S --noconfirm {joined}",
            "zypper": f"{s}zypper --non-interactive install --force {joined}",
            "apk":    f"{s}apk add --no-cache {joined}",
        }
    else:
        cmds = {
            "brew":   f"brew install {joined}",
            "apt":    f"DEBIAN_FRONTEND=noninteractive {s}apt-get install -y {joined}",
            "dnf":    f"{s}dnf install -y {joined}",
            "yum":    f"{s}yum install -y {joined}",
            "pacman": f"{s}pacman -S --noconfirm --needed {joined}",
            "zypper": f"{s}zypper --non-interactive install {joined}",
            "apk":    f"{s}apk add {joined}",
        }
    run(cmds[PM])


def pm_install_cask(*pkgs, reinstall=False):
    if PM != "brew":
        return
    pkgs = [p for p in pkgs if p]
    if pkgs:
        verb = "reinstall" if reinstall else "install"
        run(f"brew {verb} --cask {' '.join(pkgs)}")


def pkg_name(logical):
    """Map a logical name to this PM's package name ('' = skip / handled elsewhere)."""
    table = {
        "zsh":            {"*": "zsh"},
        "git":            {"*": "git"},
        "tmux":           {"*": "tmux"},
        "eza":            {"*": "eza"},
        "zoxide":         {"*": "zoxide"},
        "htop":           {"*": "htop"},
        "btop":           {"*": "btop"},
        "podman":         {"*": "podman"},
        "openssh-server": {"apt": "openssh-server", "dnf": "openssh-server",
                            "yum": "openssh-server", "pacman": "openssh",
                            "zypper": "openssh", "apk": "openssh", "brew": ""},
        "docker":         {"apt": "docker.io", "dnf": "docker", "yum": "docker",
                            "pacman": "docker", "zypper": "docker", "apk": "docker",
                            "brew": ""},
    }
    m = table.get(logical, {})
    return m.get(PM, m.get("*", ""))


def append_zshrc_once(needle, line):
    run(f"touch '{ZSHRC}'", as_user=True)
    rc = subprocess.run(["bash", "-c", f"grep -qF {sh_quote(needle)} '{ZSHRC}'"]).returncode
    if rc != 0:
        run(f"printf '%s\\n' {sh_quote(line)} >> '{ZSHRC}'", as_user=True)


def sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


# ----- per-item installers -------------------------------------------------

def in_zshrc(needle):
    return subprocess.run(["bash", "-c", f"grep -qF {sh_quote(needle)} '{ZSHRC}'"],
                          stderr=subprocess.DEVNULL).returncode == 0


def install_zsh(overwrite=False):
    pm_install(pkg_name("zsh"), reinstall=overwrite)
    append_zshrc_once("export TERM=xterm-256color", "export TERM=xterm-256color")
    # set default shell
    zsh_bin = shutil.which("zsh") or "/bin/zsh"
    if os.path.exists(zsh_bin):
        run(f"grep -qx '{zsh_bin}' /etc/shells 2>/dev/null || "
            f"echo '{zsh_bin}' | {sudo_prefix()}tee -a /etc/shells >/dev/null", check=False)
        run(f"{sudo_prefix()}chsh -s '{zsh_bin}' '{TARGET_USER}'", check=False)


def install_git(overwrite=False):
    if overwrite or not shutil.which("git"):
        pm_install(pkg_name("git"), reinstall=overwrite)


def install_omz(overwrite=False):
    omz = os.path.join(TARGET_HOME, ".oh-my-zsh")
    present = os.path.isdir(omz)
    if present and overwrite:
        run(f"rm -rf '{omz}'", as_user=True)
        present = False
    if present:
        console.print("[dim]oh-my-zsh already present[/]")
    else:
        run('RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c '
            '"$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"',
            as_user=True)
    # KEEP_ZSHRC=yes leaves any pre-existing .zshrc (incl. an empty one we may
    # have touched earlier) untouched, so the installer won't add its source
    # line. Guarantee the rc actually loads oh-my-zsh.
    run(f"touch '{ZSHRC}'", as_user=True)
    if not in_zshrc("oh-my-zsh.sh"):
        append_zshrc_once('export ZSH="$HOME/.oh-my-zsh"',
                          'export ZSH="$HOME/.oh-my-zsh"')
        append_zshrc_once("ZSH_THEME=", 'ZSH_THEME="robbyrussell"')
        append_zshrc_once("oh-my-zsh.sh", 'source $ZSH/oh-my-zsh.sh')


def install_p10k(overwrite=False):
    omz = os.path.join(TARGET_HOME, ".oh-my-zsh")
    p10k = os.path.join(omz, "custom/themes/powerlevel10k")
    if os.path.isdir(p10k) and overwrite:
        run(f"rm -rf '{p10k}'", as_user=True)
    if os.path.isdir(p10k):
        run(f"git -C '{p10k}' pull --ff-only || true", as_user=True, check=False)
    else:
        run(f"git clone --depth=1 https://github.com/romkatv/powerlevel10k.git '{p10k}'",
            as_user=True)
    run(f"touch '{ZSHRC}'", as_user=True)
    sed_i = "sed -i ''" if OS == "macos" else "sed -i"
    if in_zshrc("ZSH_THEME="):
        run(f"{sed_i} 's|^ZSH_THEME=.*|ZSH_THEME=\"powerlevel10k/powerlevel10k\"|' '{ZSHRC}'",
            as_user=True, check=False)
    else:
        append_zshrc_once("ZSH_THEME=\"powerlevel10k",
                          'ZSH_THEME="powerlevel10k/powerlevel10k"')


def _font_dir():
    if OS == "macos":
        return os.path.join(TARGET_HOME, "Library/Fonts")
    return os.path.join(TARGET_HOME, ".local/share/fonts")


MESLO_FILES = [
    "MesloLGS%20NF%20Regular.ttf",
    "MesloLGS%20NF%20Bold.ttf",
    "MesloLGS%20NF%20Italic.ttf",
    "MesloLGS%20NF%20Bold%20Italic.ttf",
]


def install_meslo(overwrite=False):
    font_dir = _font_dir()
    run(f"mkdir -p '{font_dir}'", as_user=True)
    base = "https://github.com/romkatv/powerlevel10k-media/raw/master"
    for f in MESLO_FILES:
        dest = f.replace("%20", " ")
        if overwrite:
            run(f"curl -fsSL '{base}/{f}' -o '{font_dir}/{dest}'", as_user=True, check=False)
        else:
            run(f"[ -f '{font_dir}/{dest}' ] || curl -fsSL '{base}/{f}' -o '{font_dir}/{dest}'",
                as_user=True, check=False)
    if OS == "linux":
        run(f"fc-cache -f '{font_dir}' >/dev/null 2>&1 || true", as_user=True, check=False)


def install_tmux(overwrite=False):
    pm_install(pkg_name("tmux"), reinstall=overwrite)


def install_tpm(overwrite=False):
    tpm = os.path.join(TARGET_HOME, ".tmux/plugins/tpm")
    if os.path.isdir(tpm) and overwrite:
        run(f"rm -rf '{tpm}'", as_user=True)
    if os.path.isdir(tpm):
        run(f"git -C '{tpm}' pull --ff-only || true", as_user=True, check=False)
    else:
        run(f"git clone --depth=1 https://github.com/tmux-plugins/tpm.git '{tpm}'", as_user=True)


def install_eza(overwrite=False):
    pm_install(pkg_name("eza"), reinstall=overwrite)
    append_zshrc_once("alias ls='eza", "alias ls='eza --group-directories-first'")
    append_zshrc_once("alias ll='eza", "alias ll='eza -l --group-directories-first'")
    append_zshrc_once("alias la='eza", "alias la='eza -la --group-directories-first'")


def install_zoxide(overwrite=False):
    pm_install(pkg_name("zoxide"), reinstall=overwrite)
    append_zshrc_once("zoxide init zsh", 'eval "$(zoxide init zsh)"')


TMUX_CONF = r"""# ~/.tmux.conf

# Options to make tmux more pleasant
set -g mouse on
set -g default-terminal "tmux-256color"

# Configure the catppuccin plugin
set -g @catppuccin_flavor "mocha"
set -g @catppuccin_window_status_style "rounded"

# Load catppuccin
run ~/.config/tmux/plugins/catppuccin/tmux/catppuccin.tmux

# Make the status line pretty and add some modules
set -g status-right-length 100
set -g status-left-length 100
set -g status-left ""
set -g status-right "#{E:@catppuccin_status_application}"
set -agF status-right "#{E:@catppuccin_status_cpu}"
set -agF status-right "#{E:@catppuccin_status_ram}"
set -ag status-right "#{E:@catppuccin_status_session}"
set -ag status-right "#{E:@catppuccin_status_uptime}"
set -agF status-right "#{E:@catppuccin_status_battery}"

run ~/.config/tmux/plugins/tmux-plugins/tmux-cpu/cpu.tmux
run ~/.config/tmux/plugins/tmux-plugins/tmux-battery/battery.tmux

# Initialize TPM (keep at the bottom of tmux.conf)
run '~/.tmux/plugins/tpm/tpm'
"""


def install_tmux_config(overwrite=False):
    conf = os.path.join(TARGET_HOME, ".tmux.conf")
    plug = os.path.join(TARGET_HOME, ".config/tmux/plugins")
    run(f"mkdir -p '{plug}/catppuccin' '{plug}/tmux-plugins'", as_user=True)
    repos = [
        (f"{plug}/catppuccin/tmux", "https://github.com/catppuccin/tmux.git", "v2.1.3"),
        (f"{plug}/tmux-plugins/tmux-cpu", "https://github.com/tmux-plugins/tmux-cpu.git", None),
        (f"{plug}/tmux-plugins/tmux-battery", "https://github.com/tmux-plugins/tmux-battery.git", None),
    ]
    for path, url, branch in repos:
        if os.path.isdir(path):
            run(f"git -C '{path}' pull --ff-only || true", as_user=True, check=False)
        else:
            b = f"-b {branch} " if branch else ""
            run(f"git clone --depth=1 {b}{url} '{path}'", as_user=True)
    if os.path.exists(conf):
        run(f"[ -f '{conf}.bak' ] || cp '{conf}' '{conf}.bak'", as_user=True, check=False)
    # write config via the target user
    payload = sh_quote(TMUX_CONF)
    run(f"printf '%s' {payload} > '{conf}'", as_user=True)


def install_htop(overwrite=False):
    pm_install(pkg_name("htop"), reinstall=overwrite)


def install_btop(overwrite=False):
    pm_install(pkg_name("btop"), reinstall=overwrite)


def install_openssh(overwrite=False):
    if OS == "macos":
        run(f"{sudo_prefix()}systemsetup -setremotelogin on", check=False)
        return
    pm_install(pkg_name("openssh-server"), reinstall=overwrite)
    if shutil.which("systemctl"):
        svc = "sshd" if PM in ("dnf", "yum", "pacman", "zypper", "apk") else "ssh"
        run(f"{sudo_prefix()}systemctl enable --now {svc}", check=False)


def install_podman(overwrite=False):
    pm_install(pkg_name("podman"), reinstall=overwrite)


def install_docker(overwrite=False):
    if OS == "macos":
        pm_install_cask("docker", reinstall=overwrite)
        console.print("[yellow]macOS: launch Docker Desktop once -> open -a Docker[/]")
        return
    pm_install(pkg_name("docker"), reinstall=overwrite)
    if shutil.which("systemctl"):
        run(f"{sudo_prefix()}systemctl enable --now docker", check=False)
    if TARGET_USER != "root":
        run(f"{sudo_prefix()}usermod -aG docker '{TARGET_USER}'", check=False)
        console.print("[yellow]Log out + back in for docker group to apply.[/]")


def _github_asset(repo, predicate):
    """Return the first release asset download URL matching predicate(name)."""
    url = f"https://api.github.com/repos/{repo}/releases/latest"
    req = urllib.request.Request(url, headers={"User-Agent": "bootstrap"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    for asset in data.get("assets", []):
        if predicate(asset["name"]):
            return asset["browser_download_url"]
    return None


def install_rustdesk(overwrite=False):
    if OS == "macos":
        pm_install_cask("rustdesk", reinstall=overwrite)
        return
    arch = "aarch64" if ARCH in ("aarch64", "arm64") else "x86_64"
    s = sudo_prefix()
    if PM == "apt":
        url = _github_asset("rustdesk/rustdesk",
                            lambda n: n.endswith(f"{arch}.deb"))
        if not url:
            raise RuntimeError("no rustdesk .deb asset found for this arch")
        run(f"curl -fL '{url}' -o /tmp/rustdesk.deb")
        run(f"{s}apt-get install -y /tmp/rustdesk.deb", check=False)
        run(f"{s}dpkg -i /tmp/rustdesk.deb || {s}apt-get -f install -y", check=False)
    elif PM in ("dnf", "yum"):
        url = _github_asset("rustdesk/rustdesk",
                            lambda n: n.endswith(f"{arch}.rpm") and "suse" not in n.lower())
        if not url:
            raise RuntimeError("no rustdesk .rpm asset found for this arch")
        run(f"curl -fL '{url}' -o /tmp/rustdesk.rpm")
        run(f"{s}{PM} install -y /tmp/rustdesk.rpm", check=False)
    elif PM == "zypper":
        url = _github_asset("rustdesk/rustdesk",
                            lambda n: "suse" in n.lower() and n.endswith(f"{arch}.rpm"))
        url = url or _github_asset("rustdesk/rustdesk", lambda n: n.endswith(f"{arch}.rpm"))
        if not url:
            raise RuntimeError("no rustdesk .rpm asset found")
        run(f"curl -fL '{url}' -o /tmp/rustdesk.rpm")
        run(f"{s}zypper --non-interactive install --allow-unsigned-rpm /tmp/rustdesk.rpm",
            check=False)
    elif shutil.which("flatpak"):
        run("flatpak install -y flathub com.rustdesk.RustDesk", check=False)
    else:
        raise RuntimeError("no install path for rustdesk on this distro "
                           "(install flatpak or grab a build from rustdesk.com)")


# ----- programming languages -----------------------------------------------

def _go_arch():
    return "arm64" if ARCH in ("aarch64", "arm64") else "amd64"


def install_rust(overwrite=False):
    run("curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | "
        "sh -s -- -y --default-toolchain stable --no-modify-path", as_user=True)
    append_zshrc_once("cargo/env", '[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"')
    if overwrite:
        run('export PATH="$HOME/.cargo/bin:$PATH"; rustup update || true',
            as_user=True, check=False)


def install_go(overwrite=False):
    if OS == "macos":
        pm_install("go", reinstall=overwrite)
        return
    arch = _go_arch()
    ver = subprocess.run(
        ["bash", "-c", "curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1"],
        capture_output=True, text=True).stdout.strip() or "go1.22.5"
    tar = f"{ver}.linux-{arch}.tar.gz"
    s = sudo_prefix()
    run(f"curl -fL 'https://go.dev/dl/{tar}' -o /tmp/{tar}")
    run(f"{s}rm -rf /usr/local/go && {s}tar -C /usr/local -xzf /tmp/{tar}")
    append_zshrc_once("/usr/local/go/bin", 'export PATH="$PATH:/usr/local/go/bin"')


def install_nodejs(overwrite=False):
    # nvm: the canonical sh installer. It appends nvm init to the shell rc itself.
    run("curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash",
        as_user=True)
    run('export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; '
        'nvm install --lts', as_user=True, check=False)


def install_vlang(overwrite=False):
    vdir = os.path.join(TARGET_HOME, ".vlang")
    if os.path.isdir(vdir) and overwrite:
        run(f"rm -rf '{vdir}'", as_user=True)
    if os.path.isdir(vdir):
        run(f"git -C '{vdir}' pull --ff-only || true", as_user=True, check=False)
    else:
        run(f"git clone --depth=1 https://github.com/vlang/v '{vdir}'", as_user=True)
    if OS == "linux" and not (shutil.which("cc") or shutil.which("gcc")):
        pm_install("gcc", "make")
    run(f"make -C '{vdir}'", as_user=True)
    # Try a system-wide symlink; fall back to PATH if no sudo.
    if SUDO or os.geteuid() == 0:
        run(f"{sudo_prefix()}'{vdir}/v' symlink", check=False)
    else:
        append_zshrc_once(".vlang", f'export PATH="$PATH:{vdir}"')


def install_odin(overwrite=False):
    if OS == "macos":
        pm_install("odin", reinstall=overwrite)
        return
    arch = _go_arch()
    odir = os.path.join(TARGET_HOME, ".local/odin")
    url = _github_asset("odin-lang/Odin",
                        lambda n: "linux" in n.lower() and arch in n.lower()
                        and n.endswith(".zip"))
    url = url or _github_asset("odin-lang/Odin",
                               lambda n: "ubuntu" in n.lower() and n.endswith(".zip"))
    if not url:
        raise RuntimeError("no Odin linux release asset found for this arch")
    if not shutil.which("unzip"):
        pm_install("unzip")
    run("curl -fL '%s' -o /tmp/odin.zip" % url)
    run(f"rm -rf '{odir}' && mkdir -p '{odir}'", as_user=True)
    run(f"unzip -q /tmp/odin.zip -d '{odir}'", as_user=True)
    # Releases sometimes nest the binary one dir deep; flatten if so.
    run(f"[ -x '{odir}/odin' ] || (d=$(dirname \"$(find '{odir}' -name odin -type f | head -n1)\"); "
        f"[ -n \"$d\" ] && cp -r \"$d\"/* '{odir}/') || true", as_user=True, check=False)
    run(f"chmod +x '{odir}/odin' 2>/dev/null || true", as_user=True, check=False)
    append_zshrc_once(".local/odin", f'export PATH="$PATH:{odir}"')


def install_uv(overwrite=False):
    # Official astral installer; works on Linux + macOS, appends env to the rc.
    run("curl -LsSf https://astral.sh/uv/install.sh | sh", as_user=True)


# ----- detection: is it already installed / configured? --------------------

def _which(name):
    p = shutil.which(name)
    return p if p else None


def _meslo_present():
    font_dir = _font_dir()
    first = MESLO_FILES[0].replace("%20", " ")
    return font_dir if os.path.isfile(os.path.join(font_dir, first)) else None


def _sshd_present():
    if OS == "macos":
        r = subprocess.run(["systemsetup", "-getremotelogin"],
                           capture_output=True, text=True)
        return "Remote Login already on" if "On" in r.stdout else None
    return _which("sshd") or _which("ssh")


DETECTORS = {
    "git":           lambda: _which("git"),
    "zsh":           lambda: _which("zsh"),
    "oh-my-zsh":     lambda: (lambda d: d if os.path.isdir(d) else None)(
                         os.path.join(TARGET_HOME, ".oh-my-zsh")),
    "powerlevel10k": lambda: (lambda d: d if os.path.isdir(d) else None)(
                         os.path.join(TARGET_HOME, ".oh-my-zsh/custom/themes/powerlevel10k")),
    "meslo-font":    _meslo_present,
    "tmux":          lambda: _which("tmux"),
    "tpm":           lambda: (lambda d: d if os.path.isdir(d) else None)(
                         os.path.join(TARGET_HOME, ".tmux/plugins/tpm")),
    "eza":           lambda: _which("eza"),
    "zoxide":        lambda: _which("zoxide"),
    "tmux-config":   lambda: (lambda d: d if os.path.exists(d) else None)(
                         os.path.join(TARGET_HOME, ".tmux.conf")),
    "htop":          lambda: _which("htop"),
    "btop":          lambda: _which("btop"),
    "rust":          lambda: _which("rustc") or _which("cargo")
                         or (os.path.join(TARGET_HOME, ".cargo/bin/cargo")
                             if os.path.exists(os.path.join(TARGET_HOME, ".cargo/bin/cargo")) else None),
    "go":            lambda: _which("go") or ("/usr/local/go/bin/go"
                         if os.path.exists("/usr/local/go/bin/go") else None),
    "nodejs":        lambda: _which("node") or (os.path.join(TARGET_HOME, ".nvm")
                         if os.path.isdir(os.path.join(TARGET_HOME, ".nvm")) else None),
    "vlang":         lambda: _which("v") or (os.path.join(TARGET_HOME, ".vlang/v")
                         if os.path.exists(os.path.join(TARGET_HOME, ".vlang/v")) else None),
    "odin":          lambda: _which("odin") or (os.path.join(TARGET_HOME, ".local/odin/odin")
                         if os.path.exists(os.path.join(TARGET_HOME, ".local/odin/odin")) else None),
    "uv":            lambda: _which("uv") or next(
                         (p for p in (os.path.join(TARGET_HOME, ".local/bin/uv"),
                                      os.path.join(TARGET_HOME, ".cargo/bin/uv"))
                          if os.path.exists(p)), None),
    "openssh-server": _sshd_present,
    "podman":        lambda: _which("podman"),
    "docker":        lambda: _which("docker"),
    "rustdesk":      lambda: _which("rustdesk"),
}


def detect(key):
    fn = DETECTORS.get(key)
    if not fn:
        return None
    try:
        return fn()
    except Exception:  # noqa: BLE001
        return None


def prompt_action(label, detail):
    """Already present -> ask skip/overwrite. Returns 'skip' or 'overwrite'."""
    console.print(f"[yellow]• {label} already present[/] [dim]({detail})[/] "
                  "— [bold]s[/]kip / [bold]o[/]verwrite? [s] ", end="")
    if not has_tty():
        console.print("skip")
        return "skip"
    while True:
        k = get_key()
        if k in ("o", "O"):
            console.print("overwrite")
            return "overwrite"
        if k in ("s", "S", "enter", "esc", "q"):
            console.print("skip")
            return "skip"


INSTALLERS = {
    "git": install_git,
    "zsh": install_zsh,
    "oh-my-zsh": install_omz,
    "powerlevel10k": install_p10k,
    "meslo-font": install_meslo,
    "tmux": install_tmux,
    "tpm": install_tpm,
    "eza": install_eza,
    "zoxide": install_zoxide,
    "tmux-config": install_tmux_config,
    "htop": install_htop,
    "btop": install_btop,
    "rust": install_rust,
    "go": install_go,
    "nodejs": install_nodejs,
    "vlang": install_vlang,
    "odin": install_odin,
    "uv": install_uv,
    "openssh-server": install_openssh,
    "podman": install_podman,
    "docker": install_docker,
    "rustdesk": install_rustdesk,
}

# Install order: deps first, then the rest in catalog order.
ORDER = ["git", "zsh", "oh-my-zsh", "powerlevel10k", "meslo-font",
         "tmux", "tpm", "tmux-config", "eza", "zoxide",
         "htop", "btop",
         "rust", "go", "nodejs", "vlang", "odin", "uv",
         "openssh-server", "podman", "docker", "rustdesk"]


def do_install(selected):
    selected = expand_deps(selected)
    results = []
    for key in ORDER:
        if key not in selected:
            continue
        label = ITEM.get(key, (key,))[0]
        console.rule(f"[bold cyan]{label}[/]")

        # Already installed / configured? Let the user skip or overwrite.
        overwrite = False
        detail = detect(key)
        if detail:
            if prompt_action(label, detail) == "skip":
                results.append((label, "skip", "already present"))
                continue
            overwrite = True

        try:
            INSTALLERS[key](overwrite=overwrite)
            results.append((label, "ok", "reinstalled" if overwrite else ""))
        except Exception as e:  # noqa: BLE001
            console.print(f"[red]!! {label} failed: {e}[/]")
            results.append((label, "fail", str(e)))

    # summary
    badge = {"ok": "[green]ok[/]", "skip": "[yellow]skipped[/]", "fail": "[red]failed[/]"}
    table = Table(show_header=True, header_style="bold", border_style="cyan")
    table.add_column("Item")
    table.add_column("Result")
    table.add_column("Notes", style="dim")
    for label, state, msg in results:
        table.add_row(label, badge.get(state, state), msg)
    console.print(Panel(table, title="[bold]Summary[/]", border_style="green", padding=(1, 2)))

    tips = []
    if "zsh" in selected:
        tips.append("Log out + back in (or run 'zsh') to start using zsh.")
    if "powerlevel10k" in selected:
        tips.append("Run 'p10k configure' to finish the prompt wizard.")
    if "meslo-font" in selected:
        tips.append("Set your terminal font to 'MesloLGS NF'.")
    if "tmux-config" in selected:
        tips.append("In tmux press prefix + I to install plugins via tpm.")
    if selected & {"rust", "go", "nodejs", "vlang", "odin", "uv"}:
        tips.append("Open a new shell so the language toolchains land on your PATH.")
    if tips:
        console.print(Panel("\n".join(f"• {t}" for t in tips),
                            title="[bold]Next steps[/]", border_style="yellow", padding=(1, 2)))


# ----- main loop -----------------------------------------------------------

def main():
    selected = set()
    # Preselect everything when there's no interactive TTY (e.g. plain pipe).
    if not has_tty():
        console.print("[yellow]No interactive terminal; installing all items.[/]")
        for _, items in CATEGORIES:
            for key, *_ in items:
                selected.add(key)
        if confirm_screen(expand_deps(selected)):
            do_install(selected)
        return

    while True:
        action = main_menu(selected)
        if action == "quit":
            console.print("Bye.")
            return
        if isinstance(action, tuple) and action[0] == "category":
            cat = action[1]
            items = next(its for c, its in CATEGORIES if c == cat)
            checklist(cat, items, selected)
            continue
        if action == "install":
            if not selected:
                console.print("[yellow]Nothing selected.[/]")
                continue
            console.clear()
            if confirm_screen(expand_deps(selected)):
                do_install(selected)
                return
            # else loop back to menu


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        console.print("\n[red]Aborted.[/]")
        sys.exit(130)
PYEOF

log "Launching wizard"
export BOOTSTRAP_OS="$OS" BOOTSTRAP_PM="$PM" BOOTSTRAP_SUDO="$SUDO"
if [ -r /dev/tty ]; then
  python3 "$WIZARD_PY" </dev/tty
else
  python3 "$WIZARD_PY"
fi
