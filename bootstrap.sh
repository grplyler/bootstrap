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
    ("Dev Tools", [
        ("claude-code",  "Claude Code",         "Anthropic CLI agent",      []),
        ("vscode",       "VS Code",             "editor",                   []),
    ]),
    ("SDR Tools", [
        ("rtlsdr",       "rtl-sdr",             "RTL-SDR userland (source)", []),
        ("gqrx",         "Gqrx",                "SDR receiver GUI",         ["rtlsdr"]),
        ("sdrpp",        "SDR++",               "cross-platform SDR GUI",   ["rtlsdr"]),
    ]),
    ("Services", [
        ("openssh-server","openssh-server",     "SSH daemon (enabled)",     []),
        ("podman",       "podman",              "daemonless containers",    []),
        ("docker",       "docker",              "containers",               []),
        ("rustdesk",     "rustdesk",            "remote desktop",           []),
        ("tailscale",    "Tailscale",           "mesh VPN (run 'tailscale up')", []),
    ]),
    ("Configuration", [
        ("disable-wayland","Disable Wayland (basic)", "force X11 in GDM; helps rustdesk headless", []),
        ("rustdesk-config","Rustdesk",          "static password + headless access mode", ["rustdesk"]),
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


# ----- UI: single-screen selector ------------------------------------------

# One flat row list: category headers, indented items, then action buttons.
def _build_rows():
    rows = []
    for cat, items in CATEGORIES:
        rows.append(("header", cat))
        for key, *_ in items:
            rows.append(("item", key))
    rows.append(("action", "install"))
    rows.append(("action", "quit"))
    return rows


ROWS = _build_rows()
SELECTABLE = [i for i, (typ, _) in enumerate(ROWS) if typ != "header"]
ACTION_LABEL = {"install": "Review & Apply", "quit": "Quit"}


def render_selector(idx, selected):
    # Window the rows so a tall catalog still fits / scrolls within the panel.
    height = console.size.height or 40
    avail = max(8, height - 9)  # leave room for banner + borders + subtitle
    show_banner = avail > len(ROWS) + 6
    if show_banner:
        avail -= 7
    start = 0
    if len(ROWS) > avail:
        start = max(0, min(idx - avail // 2, len(ROWS) - avail))
    window = list(enumerate(ROWS))[start:start + avail]

    lines = []
    for ridx, (typ, val) in window:
        on = ridx == idx
        if typ == "header":
            n = sum(1 for k, *_ in dict(CATEGORIES)[val] if k in selected)
            t = Text(f"  {val} ", style="bold magenta")
            t.append(f"({n}/{len(dict(CATEGORIES)[val])})", style="dim")
            lines.append(t)
        elif typ == "item":
            label, desc, _ = ITEM[val]
            checked = val in selected
            box = "[x]" if checked else "[ ]"
            marker = "▸" if on else " "
            if on:
                t = Text(f" {marker}   {box} {label}", style="bold reverse cyan")
                t.append(f"  {desc}", style="reverse")
            else:
                t = Text(f" {marker}   ", style="cyan")
                t.append(f"{box} ", style="green" if checked else "dim")
                t.append(label, style="bold" if checked else "")
                t.append(f"  {desc}", style="dim")
            lines.append(t)
        else:  # action button
            marker = "▸" if on else " "
            style = "bold reverse green" if on else "bold green"
            lines.append(Text(f" {marker} {ACTION_LABEL[val]}", style=style))

    head = []
    if show_banner:
        head = [Align.center(Text(BANNER, style="bold cyan")), Text("")]
    return Panel(
        Group(*head, *lines),
        title="[bold cyan]bootstrap[/]",
        subtitle="[dim]↑/↓ move · space toggle (on=keep/install, off=remove) · "
                 "a all · n none · enter · q quit[/]",
        border_style="cyan",
        padding=(1, 2),
    )


def selector(selected):
    """One screen for everything. Returns 'install' or 'quit'."""
    if not has_tty():
        return "install"
    pos = 0
    with Live(render_selector(SELECTABLE[pos], selected), console=console,
              auto_refresh=False, screen=True) as live:
        while True:
            idx = SELECTABLE[pos]
            key = get_key()
            if key in ("up", "k"):
                pos = (pos - 1) % len(SELECTABLE)
            elif key in ("down", "j"):
                pos = (pos + 1) % len(SELECTABLE)
            elif key in ("q", "esc"):
                return "quit"
            elif key == "a":
                selected |= MENU_KEYS
            elif key == "n":
                selected.difference_update(MENU_KEYS)
            elif key == "space":
                typ, val = ROWS[idx]
                if typ == "item":
                    selected.discard(val) if val in selected else selected.add(val)
            elif key == "enter":
                typ, val = ROWS[idx]
                if typ == "action":
                    return val
                if typ == "item":
                    selected.discard(val) if val in selected else selected.add(val)
            live.update(render_selector(SELECTABLE[pos], selected), refresh=True)


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


def pm_remove(*pkgs):
    pkgs = [p for p in pkgs if p]
    if not pkgs:
        return
    s = sudo_prefix()
    joined = " ".join(pkgs)
    cmds = {
        "brew":   f"brew uninstall {joined}",
        "apt":    f"DEBIAN_FRONTEND=noninteractive {s}apt-get remove -y {joined}",
        "dnf":    f"{s}dnf remove -y {joined}",
        "yum":    f"{s}yum remove -y {joined}",
        "pacman": f"{s}pacman -Rns --noconfirm {joined}",
        "zypper": f"{s}zypper --non-interactive remove {joined}",
        "apk":    f"{s}apk del {joined}",
    }
    run(cmds[PM], check=False)


def pm_uninstall_cask(*pkgs):
    if PM != "brew":
        return
    pkgs = [p for p in pkgs if p]
    if pkgs:
        run(f"brew uninstall --cask {' '.join(pkgs)}", check=False)


def strip_zshrc(*needles):
    """Remove every .zshrc line containing any of the given fixed strings."""
    for n in needles:
        run(f"[ -f '{ZSHRC}' ] && grep -vF {sh_quote(n)} '{ZSHRC}' > '{ZSHRC}.tmp' "
            f"&& mv '{ZSHRC}.tmp' '{ZSHRC}' || true", as_user=True, check=False)


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
        "cmake":          {"*": "cmake"},
        "pkgconfig":      {"apt": "pkg-config", "brew": "pkg-config", "apk": "pkgconf",
                            "*": "pkgconf"},
        "libusb-dev":     {"apt": "libusb-1.0-0-dev", "dnf": "libusb1-devel",
                            "yum": "libusb1-devel", "pacman": "libusb",
                            "zypper": "libusb-1_0-devel", "apk": "libusb-dev",
                            "brew": "libusb"},
        "gqrx":           {"apt": "gqrx-sdr", "dnf": "gqrx", "yum": "gqrx",
                            "pacman": "gqrx", "zypper": "gqrx", "apk": "",
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


def install_tailscale(overwrite=False):
    if OS == "macos":
        pm_install_cask("tailscale", reinstall=overwrite)
        console.print("[yellow]macOS: launch Tailscale from Applications and sign in.[/]")
        return
    # Official installer adds the repo + package for every supported distro.
    run("curl -fsSL https://tailscale.com/install.sh | sh")
    if shutil.which("systemctl"):
        run(f"{sudo_prefix()}systemctl enable --now tailscaled", check=False)
    console.print("[yellow]Run 'sudo tailscale up' to authenticate this machine.[/]")


# ----- configuration -------------------------------------------------------

def _gdm_conf():
    """Path to the GDM config that holds WaylandEnable, or None."""
    for p in ("/etc/gdm3/custom.conf", "/etc/gdm/custom.conf"):
        if os.path.exists(p):
            return p
    return None


def install_disable_wayland(overwrite=False):
    if OS == "macos":
        console.print("[yellow]Wayland is Linux-only; nothing to disable on macOS.[/]")
        return
    conf = _gdm_conf()
    if not conf:
        console.print("[yellow]No GDM config (/etc/gdm*/custom.conf); only applies to "
                      "GDM desktops. Skipping.[/]")
        return
    s = sudo_prefix()
    run(f"[ -f '{conf}.bak' ] || {s}cp '{conf}' '{conf}.bak'", check=False)
    # Uncomment / overwrite any existing WaylandEnable line, then ensure it exists.
    run(f"{s}sed -i 's/^#\\?WaylandEnable=.*/WaylandEnable=false/' '{conf}'", check=False)
    run(f"grep -q '^WaylandEnable=false' '{conf}' 2>/dev/null || "
        f"{s}sed -i '/^\\[daemon\\]/a WaylandEnable=false' '{conf}'", check=False)
    console.print("[yellow]Wayland disabled in GDM; reboot (or restart GDM) for X11.[/]")


RUSTDESK_HEADLESS_MARKER = "/etc/bootstrap-rustdesk-headless"
RUSTDESK_PW = None  # captured during install, surfaced in the final tips


def _gen_password(n=14):
    import secrets
    import string
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(n))


def _read_line(prompt_text, default=""):
    """Read one line of input from the TTY; falls back to default with no TTY."""
    console.print(prompt_text, end="")
    if not has_tty():
        console.print("[dim](auto)[/]")
        return default
    buf = ""
    while True:
        k = get_key()
        if k == "enter":
            console.print("")
            return buf or default
        if k == "esc":
            console.print("")
            return default
        if k in ("\x7f", "\b"):  # backspace
            buf = buf[:-1]
            continue
        if len(k) == 1 and k.isprintable():
            buf += k


def install_rustdesk_config(overwrite=False):
    global RUSTDESK_PW
    if OS == "macos":
        console.print("[yellow]Headless config is Linux-only; in the RustDesk app set a "
                      "permanent password under Settings → Security.[/]")
        return
    pw = os.environ.get("BOOTSTRAP_RUSTDESK_PASSWORD", "").strip()
    if not pw and has_tty():
        pw = _read_line("[bold]RustDesk static password (enter to autogenerate): [/]").strip()
    if not pw:
        pw = _gen_password()
    RUSTDESK_PW = pw
    s = sudo_prefix()
    # Background service = unattended/headless access.
    if shutil.which("systemctl"):
        run(f"{s}systemctl enable --now rustdesk 2>/dev/null || "
            f"{s}systemctl enable --now rustdesk.service", check=False)
    # Set the permanent password (talks to the running service).
    run(f"{s}rustdesk --password {sh_quote(pw)}", check=False)
    run(f"{s}touch '{RUSTDESK_HEADLESS_MARKER}'", check=False)
    # Show the machine's RustDesk ID for convenience.
    run(f"{s}rustdesk --get-id 2>/dev/null || true", check=False)


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


# ----- dev tools -----------------------------------------------------------

def install_claude_code(overwrite=False):
    # Native installer; drops `claude` into ~/.local/bin and appends PATH.
    run("curl -fsSL https://claude.ai/install.sh | bash", as_user=True)
    append_zshrc_once('.local/bin', 'export PATH="$HOME/.local/bin:$PATH"')


def _code_arch():
    return "arm64" if ARCH in ("aarch64", "arm64") else "x64"


def install_vscode(overwrite=False):
    if OS == "macos":
        pm_install_cask("visual-studio-code", reinstall=overwrite)
        return
    arch = _code_arch()
    s = sudo_prefix()
    base = "https://code.visualstudio.com/sha/download?build=stable&os="
    if PM == "apt":
        run(f"curl -fL '{base}linux-deb-{arch}' -o /tmp/vscode.deb")
        run(f"{s}apt-get install -y /tmp/vscode.deb", check=False)
        run(f"{s}dpkg -i /tmp/vscode.deb || {s}apt-get -f install -y", check=False)
    elif PM in ("dnf", "yum"):
        run(f"curl -fL '{base}linux-rpm-{arch}' -o /tmp/vscode.rpm")
        run(f"{s}{PM} install -y /tmp/vscode.rpm", check=False)
    elif PM == "zypper":
        run(f"curl -fL '{base}linux-rpm-{arch}' -o /tmp/vscode.rpm")
        run(f"{s}zypper --non-interactive install --allow-unsigned-rpm /tmp/vscode.rpm",
            check=False)
    elif shutil.which("flatpak"):
        run("flatpak install -y flathub com.visualstudio.code", check=False)
    elif shutil.which("snap"):
        run(f"{s}snap install code --classic", check=False)
    else:
        raise RuntimeError("no install path for VS Code on this distro "
                           "(install flatpak/snap or use the repo at code.visualstudio.com)")


# ----- libraries & packages ------------------------------------------------

def install_rtlsdr(overwrite=False):
    s = sudo_prefix()
    # Build deps.
    if OS == "macos":
        pm_install("libusb", "cmake", "pkg-config")
    else:
        pm_install(pkg_name("cmake"), pkg_name("libusb-dev"), pkg_name("pkgconfig"))
        if not (shutil.which("cc") or shutil.which("gcc")):
            pm_install("gcc", "make")
    # Clear out any distro-packaged librtlsdr so the source build wins.
    if PM == "apt":
        run(f"{s}apt-get purge -y '^librtlsdr' || true", check=False)
    run(f"{s}rm -rf /usr/lib/librtlsdr* /usr/include/rtl-sdr* "
        "/usr/local/lib/librtlsdr* /usr/local/include/rtl-sdr* "
        "/usr/local/include/rtl_* /usr/local/bin/rtl_*", check=False)
    # Build from osmocom source.
    src = os.path.join(TARGET_HOME, ".local/src/rtl-sdr")
    if os.path.isdir(src) and overwrite:
        run(f"rm -rf '{src}'", as_user=True)
    if os.path.isdir(src):
        run(f"git -C '{src}' pull --ff-only || true", as_user=True, check=False)
    else:
        run(f"mkdir -p '{os.path.dirname(src)}'", as_user=True)
        run(f"git clone https://github.com/osmocom/rtl-sdr '{src}'", as_user=True)
    udev = "-DINSTALL_UDEV_RULES=ON" if OS == "linux" else ""
    run(f"rm -rf '{src}/build' && mkdir -p '{src}/build'", as_user=True)
    run(f"cmake -S '{src}' -B '{src}/build' {udev}", as_user=True)
    run(f"cmake --build '{src}/build' -j", as_user=True)
    run(f"{s}cmake --install '{src}/build'", check=False)
    if OS == "linux":
        run(f"[ -f '{src}/rtl-sdr.rules' ] && {s}cp '{src}/rtl-sdr.rules' "
            "/etc/udev/rules.d/ || true", check=False)
        run(f"{s}ldconfig", check=False)
        # Blacklist the DVB kernel module so the dongle is usable as an SDR.
        run("echo 'blacklist dvb_usb_rtl28xxu' | "
            f"{s}tee /etc/modprobe.d/blacklist-dvb_usb_rtl28xxu.conf >/dev/null", check=False)


def install_gqrx(overwrite=False):
    if OS == "macos":
        pm_install_cask("gqrx", reinstall=overwrite)
        return
    name = pkg_name("gqrx")
    if name:
        pm_install(name, reinstall=overwrite)
    elif shutil.which("flatpak"):
        run("flatpak install -y flathub dl.gqrx.gqrx", check=False)
    else:
        raise RuntimeError("no gqrx package for this distro; install flatpak then "
                           "'flatpak install flathub dl.gqrx.gqrx'")


def _github_tag_asset(repo, tag, predicate):
    """Return the first asset URL from a specific release tag matching predicate."""
    url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
    req = urllib.request.Request(url, headers={"User-Agent": "bootstrap"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    for asset in data.get("assets", []):
        if predicate(asset["name"]):
            return asset["browser_download_url"]
    return None


def install_sdrpp(overwrite=False):
    if OS != "linux" or PM != "apt":
        raise RuntimeError("SDR++ auto-install supports Debian/Ubuntu (apt) only; "
                           "grab a build from github.com/AlexandreRouma/SDRPlusPlus/releases")
    arch = ("arm64" if ARCH in ("aarch64", "arm64") else "amd64")
    osr = subprocess.run(
        ["bash", "-c", '. /etc/os-release 2>/dev/null; echo "$ID:$VERSION_CODENAME"'],
        capture_output=True, text=True).stdout.strip()
    did, _, codename = osr.partition(":")
    repo = "AlexandreRouma/SDRPlusPlus"
    url = None
    if did and codename:
        exact = f"sdrpp_{did}_{codename}_{arch}.deb"
        url = _github_tag_asset(repo, "nightly", lambda n: n == exact)
    if not url:  # fall back to any debian/ubuntu build for this arch
        url = _github_tag_asset(
            repo, "nightly",
            lambda n: n.endswith(f"_{arch}.deb") and ("debian" in n or "ubuntu" in n))
    if not url:
        raise RuntimeError("no matching SDR++ .deb in the nightly release for this system")
    s = sudo_prefix()
    run(f"curl -fL '{url}' -o /tmp/sdrpp.deb")
    run(f"{s}apt-get install -y /tmp/sdrpp.deb", check=False)
    run(f"{s}dpkg -i /tmp/sdrpp.deb || {s}apt-get -f install -y", check=False)


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


def _wayland_disabled():
    if OS == "macos":
        return None
    conf = _gdm_conf()
    if not conf:
        return None
    rc = subprocess.run(["bash", "-c", f"grep -q '^WaylandEnable=false' '{conf}'"]).returncode
    return conf if rc == 0 else None


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
    "claude-code":   lambda: _which("claude") or (os.path.join(TARGET_HOME, ".local/bin/claude")
                         if os.path.exists(os.path.join(TARGET_HOME, ".local/bin/claude")) else None),
    "vscode":        lambda: _which("code"),
    "rtlsdr":        lambda: _which("rtl_sdr") or _which("rtl_test")
                         or ("/usr/local/lib"
                             if subprocess.run(["bash", "-c",
                                "ls /usr/local/lib/librtlsdr* >/dev/null 2>&1"]).returncode == 0
                             else None),
    "gqrx":          lambda: _which("gqrx"),
    "sdrpp":         lambda: _which("sdrpp"),
    "openssh-server": _sshd_present,
    "podman":        lambda: _which("podman"),
    "docker":        lambda: _which("docker"),
    "rustdesk":      lambda: _which("rustdesk"),
    "tailscale":     lambda: _which("tailscale"),
    "disable-wayland": _wayland_disabled,
    "rustdesk-config": lambda: (RUSTDESK_HEADLESS_MARKER
                         if os.path.exists(RUSTDESK_HEADLESS_MARKER) else None),
}


def detect(key):
    fn = DETECTORS.get(key)
    if not fn:
        return None
    try:
        return fn()
    except Exception:  # noqa: BLE001
        return None


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
    "claude-code": install_claude_code,
    "vscode": install_vscode,
    "rtlsdr": install_rtlsdr,
    "gqrx": install_gqrx,
    "sdrpp": install_sdrpp,
    "openssh-server": install_openssh,
    "podman": install_podman,
    "docker": install_docker,
    "rustdesk": install_rustdesk,
    "tailscale": install_tailscale,
    "disable-wayland": install_disable_wayland,
    "rustdesk-config": install_rustdesk_config,
}

# Install order: deps first, then the rest in catalog order.
ORDER = ["git", "zsh", "oh-my-zsh", "powerlevel10k", "meslo-font",
         "tmux", "tpm", "tmux-config", "eza", "zoxide",
         "htop", "btop",
         "rust", "go", "nodejs", "vlang", "odin", "uv",
         "claude-code", "vscode", "rtlsdr", "gqrx", "sdrpp",
         "openssh-server", "podman", "docker", "rustdesk", "tailscale",
         "disable-wayland", "rustdesk-config"]


# ----- uninstallers --------------------------------------------------------

def uninstall_zsh():
    bash_bin = shutil.which("bash") or "/bin/bash"
    run(f"{sudo_prefix()}chsh -s '{bash_bin}' '{TARGET_USER}'", check=False)
    strip_zshrc("export TERM=xterm-256color")
    pm_remove(pkg_name("zsh"))


def uninstall_omz():
    run(f"rm -rf '{os.path.join(TARGET_HOME, '.oh-my-zsh')}'", as_user=True, check=False)
    strip_zshrc('export ZSH="$HOME/.oh-my-zsh"', "oh-my-zsh.sh", "ZSH_THEME=")


def uninstall_p10k():
    p10k = os.path.join(TARGET_HOME, ".oh-my-zsh/custom/themes/powerlevel10k")
    run(f"rm -rf '{p10k}'", as_user=True, check=False)
    run(f"rm -f '{os.path.join(TARGET_HOME, '.p10k.zsh')}'", as_user=True, check=False)
    # If oh-my-zsh stays, point the theme back at the default.
    sed_i = "sed -i ''" if OS == "macos" else "sed -i"
    run(f"[ -f '{ZSHRC}' ] && {sed_i} 's|^ZSH_THEME=.*|ZSH_THEME=\"robbyrussell\"|' '{ZSHRC}' "
        "|| true", as_user=True, check=False)


def uninstall_meslo():
    fd = _font_dir()
    for f in MESLO_FILES:
        run(f"rm -f '{fd}/{f.replace('%20', ' ')}'", as_user=True, check=False)
    if OS == "linux":
        run(f"fc-cache -f '{fd}' >/dev/null 2>&1 || true", as_user=True, check=False)


def uninstall_tmux():
    pm_remove(pkg_name("tmux"))


def uninstall_tpm():
    run(f"rm -rf '{os.path.join(TARGET_HOME, '.tmux/plugins/tpm')}'", as_user=True, check=False)


def uninstall_eza():
    pm_remove(pkg_name("eza"))
    strip_zshrc("alias ls='eza", "alias ll='eza", "alias la='eza")


def uninstall_zoxide():
    pm_remove(pkg_name("zoxide"))
    strip_zshrc("zoxide init zsh")


def uninstall_tmux_config():
    conf = os.path.join(TARGET_HOME, ".tmux.conf")
    run(f"if [ -f '{conf}.bak' ]; then mv '{conf}.bak' '{conf}'; else rm -f '{conf}'; fi",
        as_user=True, check=False)
    run(f"rm -rf '{os.path.join(TARGET_HOME, '.config/tmux/plugins')}'", as_user=True, check=False)


def uninstall_htop():
    pm_remove(pkg_name("htop"))


def uninstall_btop():
    pm_remove(pkg_name("btop"))


def uninstall_rust():
    run('export PATH="$HOME/.cargo/bin:$PATH"; '
        'command -v rustup >/dev/null 2>&1 && rustup self uninstall -y '
        '|| rm -rf "$HOME/.cargo" "$HOME/.rustup"', as_user=True, check=False)
    strip_zshrc("cargo/env")


def uninstall_go():
    if OS == "macos":
        pm_remove("go")
        return
    run(f"{sudo_prefix()}rm -rf /usr/local/go", check=False)
    strip_zshrc("/usr/local/go/bin")


def uninstall_nodejs():
    run(f"rm -rf '{os.path.join(TARGET_HOME, '.nvm')}'", as_user=True, check=False)
    strip_zshrc("NVM_DIR", "nvm.sh", "nvm bash_completion")


def uninstall_vlang():
    run(f"rm -rf '{os.path.join(TARGET_HOME, '.vlang')}'", as_user=True, check=False)
    run(f"{sudo_prefix()}rm -f /usr/local/bin/v", check=False)
    strip_zshrc(".vlang")


def uninstall_odin():
    if OS == "macos":
        pm_remove("odin")
        return
    run(f"rm -rf '{os.path.join(TARGET_HOME, '.local/odin')}'", as_user=True, check=False)
    strip_zshrc(".local/odin")


def uninstall_uv():
    run('command -v uv >/dev/null 2>&1 && uv self uninstall 2>/dev/null; '
        'rm -f "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx"; '
        'rm -rf "$HOME/.local/share/uv"', as_user=True, check=False)


def uninstall_claude_code():
    run('command -v claude >/dev/null 2>&1 && claude uninstall 2>/dev/null; '
        'rm -f "$HOME/.local/bin/claude"', as_user=True, check=False)


def uninstall_vscode():
    if OS == "macos":
        pm_uninstall_cask("visual-studio-code")
        return
    if PM == "apt":
        run(f"{sudo_prefix()}apt-get remove -y code", check=False)
    elif PM in ("dnf", "yum", "zypper"):
        pm_remove("code")
    elif shutil.which("flatpak"):
        run("flatpak uninstall -y com.visualstudio.code", check=False)
    elif shutil.which("snap"):
        run(f"{sudo_prefix()}snap remove code", check=False)


def uninstall_rtlsdr():
    s = sudo_prefix()
    src = os.path.join(TARGET_HOME, ".local/src/rtl-sdr")
    run(f"{s}rm -rf /usr/lib/librtlsdr* /usr/include/rtl-sdr* "
        "/usr/local/lib/librtlsdr* /usr/local/include/rtl-sdr* "
        "/usr/local/include/rtl_* /usr/local/bin/rtl_* "
        "/usr/local/lib/pkgconfig/librtlsdr.pc", check=False)
    if OS == "linux":
        run(f"{s}rm -f /etc/udev/rules.d/rtl-sdr.rules "
            "/etc/modprobe.d/blacklist-dvb_usb_rtl28xxu.conf", check=False)
        run(f"{s}ldconfig", check=False)
    run(f"rm -rf '{src}'", as_user=True, check=False)


def uninstall_gqrx():
    if OS == "macos":
        pm_uninstall_cask("gqrx")
        return
    name = pkg_name("gqrx")
    if name:
        pm_remove(name)
    elif shutil.which("flatpak"):
        run("flatpak uninstall -y dl.gqrx.gqrx", check=False)


def uninstall_sdrpp():
    if OS == "linux" and PM == "apt":
        run(f"{sudo_prefix()}apt-get remove -y sdrpp", check=False)
    else:
        run(f"{sudo_prefix()}rm -f /usr/bin/sdrpp /usr/local/bin/sdrpp", check=False)


def uninstall_openssh():
    if OS == "macos":
        run(f"{sudo_prefix()}systemsetup -setremotelogin off", check=False)
        return
    if shutil.which("systemctl"):
        svc = "sshd" if PM in ("dnf", "yum", "pacman", "zypper", "apk") else "ssh"
        run(f"{sudo_prefix()}systemctl disable --now {svc}", check=False)
    pm_remove(pkg_name("openssh-server"))


def uninstall_podman():
    pm_remove(pkg_name("podman"))


def uninstall_docker():
    if OS == "macos":
        pm_uninstall_cask("docker")
        return
    if shutil.which("systemctl"):
        run(f"{sudo_prefix()}systemctl disable --now docker", check=False)
    pm_remove(pkg_name("docker"))


def uninstall_rustdesk():
    if OS == "macos":
        pm_uninstall_cask("rustdesk")
        return
    if PM in ("apt", "dnf", "yum", "zypper"):
        pm_remove("rustdesk")
    elif shutil.which("flatpak"):
        run("flatpak uninstall -y com.rustdesk.RustDesk", check=False)
    else:
        run(f"{sudo_prefix()}rm -f /usr/bin/rustdesk", check=False)


def uninstall_tailscale():
    if OS == "macos":
        pm_uninstall_cask("tailscale")
        return
    s = sudo_prefix()
    if shutil.which("systemctl"):
        run(f"{s}systemctl disable --now tailscaled", check=False)
    pm_remove("tailscale")
    run(f"{s}rm -rf /var/lib/tailscale", check=False)


def uninstall_disable_wayland():
    if OS == "macos":
        return
    conf = _gdm_conf()
    if not conf:
        return
    s = sudo_prefix()
    # Restore our backup if present, else just comment the line back out.
    run(f"if [ -f '{conf}.bak' ]; then {s}mv '{conf}.bak' '{conf}'; "
        f"else {s}sed -i 's/^WaylandEnable=false/#WaylandEnable=false/' '{conf}'; fi",
        check=False)


def uninstall_rustdesk_config():
    if OS == "macos":
        return
    s = sudo_prefix()
    run(f"{s}rustdesk --password '' 2>/dev/null || true", check=False)
    if shutil.which("systemctl"):
        run(f"{s}systemctl disable --now rustdesk 2>/dev/null || true", check=False)
    run(f"{s}rm -f '{RUSTDESK_HEADLESS_MARKER}'", check=False)


UNINSTALLERS = {
    "zsh": uninstall_zsh,
    "oh-my-zsh": uninstall_omz,
    "powerlevel10k": uninstall_p10k,
    "meslo-font": uninstall_meslo,
    "tmux": uninstall_tmux,
    "tpm": uninstall_tpm,
    "eza": uninstall_eza,
    "zoxide": uninstall_zoxide,
    "tmux-config": uninstall_tmux_config,
    "htop": uninstall_htop,
    "btop": uninstall_btop,
    "rust": uninstall_rust,
    "go": uninstall_go,
    "nodejs": uninstall_nodejs,
    "vlang": uninstall_vlang,
    "odin": uninstall_odin,
    "uv": uninstall_uv,
    "claude-code": uninstall_claude_code,
    "vscode": uninstall_vscode,
    "rtlsdr": uninstall_rtlsdr,
    "gqrx": uninstall_gqrx,
    "sdrpp": uninstall_sdrpp,
    "openssh-server": uninstall_openssh,
    "podman": uninstall_podman,
    "docker": uninstall_docker,
    "rustdesk": uninstall_rustdesk,
    "tailscale": uninstall_tailscale,
    "disable-wayland": uninstall_disable_wayland,
    "rustdesk-config": uninstall_rustdesk_config,
}

# Menu-visible keys (everything except implicit deps like `git`).
MENU_KEYS = {k for _, items in CATEGORIES for k, *_ in items}


def plan(installed, keep):
    """Desired-state diff. Returns (to_install, to_remove) as ORDER-sorted lists."""
    desired = expand_deps(keep)
    to_install = [k for k in ORDER if k in desired and k not in installed]
    to_remove = [k for k in reversed(ORDER)
                 if k in installed and k in MENU_KEYS and k not in desired]
    return to_install, to_remove


def do_apply(installed, keep):
    to_install, to_remove = plan(installed, keep)
    results = []

    for key in to_install:
        label = ITEM.get(key, (key,))[0]
        console.rule(f"[bold green]install {label}[/]")
        try:
            INSTALLERS[key]()
            results.append((label, "installed", ""))
        except Exception as e:  # noqa: BLE001
            console.print(f"[red]!! {label} failed: {e}[/]")
            results.append((label, "fail", str(e)))

    for key in to_remove:
        label = ITEM.get(key, (key,))[0]
        console.rule(f"[bold red]remove {label}[/]")
        fn = UNINSTALLERS.get(key)
        if not fn:
            results.append((label, "skip", "no uninstaller"))
            continue
        try:
            fn()
            results.append((label, "removed", ""))
        except Exception as e:  # noqa: BLE001
            console.print(f"[red]!! {label} remove failed: {e}[/]")
            results.append((label, "fail", str(e)))

    # summary
    badge = {"installed": "[green]installed[/]", "removed": "[red]removed[/]",
             "skip": "[yellow]skipped[/]", "fail": "[bold red]failed[/]"}
    table = Table(show_header=True, header_style="bold", border_style="cyan")
    table.add_column("Item")
    table.add_column("Result")
    table.add_column("Notes", style="dim")
    for label, state, msg in results:
        table.add_row(label, badge.get(state, state), msg)
    console.print(Panel(table, title="[bold]Summary[/]", border_style="green", padding=(1, 2)))

    final = expand_deps(keep)
    tips = []
    if "zsh" in final:
        tips.append("Log out + back in (or run 'zsh') to start using zsh.")
    if "powerlevel10k" in final:
        tips.append("Run 'p10k configure' to finish the prompt wizard.")
    if "meslo-font" in final:
        tips.append("Set your terminal font to 'MesloLGS NF'.")
    if "tmux-config" in final:
        tips.append("In tmux press prefix + I to install plugins via tpm.")
    if final & {"rust", "go", "nodejs", "vlang", "odin", "uv"}:
        tips.append("Open a new shell so the language toolchains land on your PATH.")
    if "rtlsdr" in final:
        tips.append("Replug your RTL-SDR dongle (or reboot) so the udev rules + "
                    "DVB blacklist take effect; test with 'rtl_test'.")
    if "tailscale" in final and OS != "macos":
        tips.append("Run 'sudo tailscale up' to authenticate this machine on your tailnet.")
    if "disable-wayland" in final and OS != "macos":
        tips.append("Reboot (or restart GDM) so the session falls back to X11.")
    if "rustdesk-config" in final and RUSTDESK_PW:
        tips.append(f"RustDesk static password set to: {RUSTDESK_PW}  "
                    "(connect via the ID shown above).")
    if to_remove:
        tips.append("Open a new shell to drop any removed tools from your environment.")
    if tips:
        console.print(Panel("\n".join(f"• {t}" for t in tips),
                            title="[bold]Next steps[/]", border_style="yellow", padding=(1, 2)))


# ----- confirm + main loop -------------------------------------------------

def confirm_apply(to_install, to_remove):
    groups = []
    if to_install:
        t = Table(show_header=False, box=None, padding=(0, 1))
        for k in to_install:
            t.add_row("[green]+[/]", ITEM[k][0], f"[dim]{ITEM[k][1]}[/]")
        groups.append(Panel(t, title="[green]Install[/]", border_style="green"))
    if to_remove:
        t = Table(show_header=False, box=None, padding=(0, 1))
        for k in to_remove:
            t.add_row("[red]-[/]", ITEM[k][0], "[red]uninstall + remove config[/]")
        groups.append(Panel(t, title="[red]Remove[/]", border_style="red"))
    console.print(Group(*groups))
    if to_remove:
        console.print("[bold red]These items will be UNINSTALLED and their config removed.[/]")
    if not has_tty():
        return True
    console.print("[bold]Apply these changes? [y/N][/] ", end="")
    k = get_key()
    console.print(k)
    return k in ("y", "Y")


def main():
    # Pre-check whatever is already installed; the checkbox state is the
    # desired state. Checked = keep/install, unchecked = remove if present.
    installed = {k for k in MENU_KEYS if detect(k)}

    if not has_tty():
        # Non-interactive: install everything missing, remove nothing.
        keep = set(MENU_KEYS)
        to_install, _ = plan(installed, keep)
        console.print("[yellow]No interactive terminal; installing all missing items.[/]")
        if to_install and confirm_apply(to_install, []):
            do_apply(installed, keep)
        else:
            console.print("[green]Nothing to install.[/]")
        return

    selected = set(installed)
    while True:
        action = selector(selected)
        if action == "quit":
            console.print("Bye.")
            return
        if action == "install":  # "Review & Apply"
            console.clear()
            to_install, to_remove = plan(installed, selected)
            if not to_install and not to_remove:
                console.print("[green]No changes — current selection matches what's installed.[/]")
                console.print("[dim]press any key[/]")
                get_key()
                continue
            if confirm_apply(to_install, to_remove):
                do_apply(installed, selected)
                return
            # declined -> back to the selector


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
