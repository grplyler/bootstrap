#!/usr/bin/env bash
# basics.sh - bootstrap helper for fresh Linux and macOS boxes.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/grplyler/bootstrap/master/basics.sh | bash
#   # or, to pre-answer the optional-package menu:
#   curl -fsSL ... | bash -s -- --yes git rust go
#
# Prompts (whiptail checklist) for every item; nothing installs unless picked:
#   zsh, oh-my-zsh, powerlevel10k, meslo-font,
#   git, build-essential, rust, go, nodejs, openssh-server, tmux, docker, podman,
#   eza (aliased to ls), zoxide,
#   burnit (USB image writer), wizard (pretty launcher) -> installed to ~/.local/bin.

set -euo pipefail

# ----- helpers -------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Where to fetch the python tools from when running via `curl | bash`.
RAW_BASE="https://raw.githubusercontent.com/grplyler/bootstrap/master"
# Directory this script lives in (empty when piped through stdin).
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

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

# ----- detect package manager ---------------------------------------------

PM=""
if [ "$OS" = "macos" ]; then
  PM="brew"
  if ! need_cmd brew; then
    log "Installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for this session (Apple Silicon vs Intel paths).
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

pm_update() {
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

pm_install() {
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

pm_install_cask() {
  # macOS-only; no-op elsewhere.
  [ "$PM" = "brew" ] || return 0
  [ "$#" -eq 0 ] && return 0
  brew install --cask "$@"
}

# Map logical package names to per-distro package names.
pkg_name() {
  local logical="$1"
  case "$logical:$PM" in
    git:*)               echo git ;;
    curl:*)              echo curl ;;
    zsh:*)               echo zsh ;;
    fontconfig:brew)     echo "" ;;  # macOS handles fonts natively
    fontconfig:*)        echo fontconfig ;;
    ca-certificates:apk) echo ca-certificates ;;
    ca-certificates:brew) echo "" ;;
    ca-certificates:*)   echo ca-certificates ;;

    build-essential:brew)   echo "" ;;  # Xcode CLT handled separately
    build-essential:apt)    echo build-essential ;;
    build-essential:dnf)    echo "@Development Tools" ;;
    build-essential:yum)    echo "@Development Tools" ;;
    build-essential:pacman) echo base-devel ;;
    build-essential:zypper) echo "patterns-devel-base-devel_basis" ;;
    build-essential:apk)    echo build-base ;;

    rust:brew)   echo rust ;;
    rust:pacman) echo rust ;;
    rust:*)      echo "" ;;  # installed via rustup below

    go:brew)   echo go ;;
    go:apt)    echo golang-go ;;
    go:dnf)    echo golang ;;
    go:yum)    echo golang ;;
    go:pacman) echo go ;;
    go:zypper) echo go ;;
    go:apk)    echo go ;;

    nodejs:brew)   echo node ;;
    nodejs:apt)    echo nodejs ;;
    nodejs:dnf)    echo nodejs ;;
    nodejs:yum)    echo nodejs ;;
    nodejs:pacman) echo nodejs ;;
    nodejs:zypper) echo nodejs ;;
    nodejs:apk)    echo nodejs ;;

    openssh-server:brew)   echo "" ;;  # ships with macOS; enable via systemsetup
    openssh-server:apt)    echo openssh-server ;;
    openssh-server:dnf)    echo openssh-server ;;
    openssh-server:yum)    echo openssh-server ;;
    openssh-server:pacman) echo openssh ;;
    openssh-server:zypper) echo openssh ;;
    openssh-server:apk)    echo openssh ;;

    tmux:*) echo tmux ;;

    docker:brew)   echo "" ;;  # cask, handled separately
    docker:apt)    echo docker.io ;;
    docker:dnf)    echo docker ;;
    docker:yum)    echo docker ;;
    docker:pacman) echo docker ;;
    docker:zypper) echo docker ;;
    docker:apk)    echo docker ;;

    podman:*) echo podman ;;

    eza:*)    echo eza ;;

    zoxide:*) echo zoxide ;;

    python3:brew)   echo python ;;
    python3:pacman) echo python ;;
    python3:*)      echo python3 ;;

    pip:brew)   echo "" ;;  # bundled with brew python
    pip:apt)    echo python3-pip ;;
    pip:dnf)    echo python3-pip ;;
    pip:yum)    echo python3-pip ;;
    pip:pacman) echo python-pip ;;
    pip:zypper) echo python3-pip ;;
    pip:apk)    echo py3-pip ;;

    *) echo "" ;;
  esac
}

# ----- parse args ----------------------------------------------------------

PRESELECTED=()
NONINTERACTIVE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes|-y)
      NONINTERACTIVE=1
      shift
      while [ "$#" -gt 0 ]; do
        PRESELECTED+=("$1")
        shift
      done
      ;;
    --help|-h)
      sed -n '2,13p' "$0" 2>/dev/null || true
      exit 0
      ;;
    *)
      warn "Unknown arg: $1"
      shift
      ;;
  esac
done

# ----- ensure prereqs ------------------------------------------------------

log "Refreshing package index"
pm_update

PREREQS=()
case "$PM" in
  brew)    PREREQS+=(newt) ;;  # provides whiptail; curl/unzip ship with macOS
  apt)     PREREQS+=(curl ca-certificates fontconfig unzip whiptail) ;;
  dnf|yum) PREREQS+=(curl ca-certificates fontconfig unzip newt) ;;
  pacman)  PREREQS+=(curl ca-certificates fontconfig unzip libnewt) ;;
  zypper)  PREREQS+=(curl ca-certificates fontconfig unzip newt) ;;
  apk)     PREREQS+=(curl ca-certificates fontconfig unzip newt) ;;
esac
log "Installing prerequisites: ${PREREQS[*]}"
pm_install "${PREREQS[@]}"

# ----- optional package menu ----------------------------------------------

OPTIONAL=(
  zsh
  oh-my-zsh
  powerlevel10k
  meslo-font
  git
  build-essential
  rust
  go
  nodejs
  openssh-server
  tmux
  docker
  podman
  eza
  zoxide
  burnit
  wizard
)

declare -a SELECTED=()
if [ "$NONINTERACTIVE" -eq 1 ]; then
  SELECTED=("${PRESELECTED[@]:-}")
  if [ "${#SELECTED[@]}" -eq 1 ] && [ -z "${SELECTED[0]}" ]; then
    SELECTED=()
  fi
else
  if ! need_cmd whiptail; then
    warn "whiptail not available, selecting all items by default."
    SELECTED=("${OPTIONAL[@]}")
  else
    CHECKLIST_ARGS=()
    for p in "${OPTIONAL[@]}"; do
      CHECKLIST_ARGS+=("$p" "$p" "ON")
    done
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
      RAW=$(whiptail \
        --title "basics.sh - what to install" \
        --checklist "Space to toggle, Enter to confirm. Pick anything you want:" \
        24 70 ${#OPTIONAL[@]} \
        "${CHECKLIST_ARGS[@]}" \
        3>&1 1>&2 2>&3 </dev/tty >/dev/tty) || RAW=""
      # shellcheck disable=SC2206
      SELECTED=( $(echo "$RAW" | tr -d '"') )
    else
      warn "No TTY available, selecting all items by default."
      SELECTED=("${OPTIONAL[@]}")
    fi
  fi
fi

want() {
  local needle="$1"
  for s in "${SELECTED[@]:-}"; do
    [ "$s" = "$needle" ] && return 0
  done
  return 1
}

# Propagate dependencies: pulling in a higher-level item implies the lower-level ones.
add_selected() {
  local item="$1"
  if ! want "$item"; then
    SELECTED+=("$item")
    log "Auto-selecting dependency: $item"
  fi
}
if want powerlevel10k; then
  add_selected oh-my-zsh
fi
if want oh-my-zsh; then
  add_selected zsh
  add_selected git
fi
if want tmux; then
  : # tmux configured below; no extra deps
fi

log "Final selection: ${SELECTED[*]:-<none>}"

# ----- core: zsh + git -----------------------------------------------------

if want zsh; then
  # zsh ships with modern macOS as default; ensure installed regardless.
  log "Installing zsh"
  pm_install "$(pkg_name zsh)"
fi
if want git; then
  if ! need_cmd git; then
    log "Installing git"
    pm_install "$(pkg_name git)"
  fi
fi

# ----- target user (the human, not root via sudo) -------------------------

TARGET_USER="${SUDO_USER:-$USER}"

get_user_home() {
  local u="$1"
  if [ "$OS" = "macos" ]; then
    dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
  else
    getent passwd "$u" | cut -d: -f6
  fi
}

get_user_shell() {
  local u="$1"
  if [ "$OS" = "macos" ]; then
    dscl . -read "/Users/$u" UserShell 2>/dev/null | awk '{print $2}'
  else
    getent passwd "$u" | cut -d: -f7
  fi
}

TARGET_HOME=$(get_user_home "$TARGET_USER")
[ -z "$TARGET_HOME" ] && TARGET_HOME="$HOME"
log "Installing user-level pieces for: $TARGET_USER ($TARGET_HOME)"

run_as_user() {
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    sudo -u "$TARGET_USER" -H bash -c "$*"
  else
    bash -c "$*"
  fi
}

OMZ_DIR="$TARGET_HOME/.oh-my-zsh"
ZSHRC="$TARGET_HOME/.zshrc"

LOCAL_BIN="$TARGET_HOME/.local/bin"

# Ensure ~/.local/bin is on PATH for future shells.
ensure_local_bin_path() {
  run_as_user "mkdir -p '$LOCAL_BIN'"
  if [ ! -f "$ZSHRC" ]; then
    run_as_user "touch '$ZSHRC'"
  fi
  if ! grep -q '\.local/bin' "$ZSHRC" 2>/dev/null; then
    log "Adding ~/.local/bin to PATH in $ZSHRC"
    run_as_user "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> '$ZSHRC'"
  fi
}

# Install a python tool from tools/<name> into ~/.local/bin.
# Prefers a local copy (dev checkout); otherwise downloads from RAW_BASE.
install_tool() {
  local tool="$1"
  ensure_local_bin_path
  local dest="$LOCAL_BIN/$tool"
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/tools/$tool" ]; then
    log "Installing $tool -> $dest (from local checkout)"
    run_as_user "cp '$SCRIPT_DIR/tools/$tool' '$dest'"
  else
    log "Installing $tool -> $dest (from $RAW_BASE)"
    run_as_user "curl -fsSL '$RAW_BASE/tools/$tool' -o '$dest'"
  fi
  run_as_user "chmod +x '$dest'"
}

# ----- oh-my-zsh -----------------------------------------------------------

if want oh-my-zsh; then
  if [ -d "$OMZ_DIR" ]; then
    log "oh-my-zsh already installed at $OMZ_DIR"
  else
    log "Installing oh-my-zsh"
    run_as_user "RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\""
  fi
fi

# ----- powerlevel10k -------------------------------------------------------

if want powerlevel10k; then
  P10K_DIR="$OMZ_DIR/custom/themes/powerlevel10k"
  if [ -d "$P10K_DIR" ]; then
    log "powerlevel10k already present"
    run_as_user "git -C '$P10K_DIR' pull --ff-only || true"
  else
    log "Cloning powerlevel10k"
    run_as_user "git clone --depth=1 https://github.com/romkatv/powerlevel10k.git '$P10K_DIR'"
  fi

  if [ ! -f "$ZSHRC" ]; then
    run_as_user "touch '$ZSHRC'"
  fi
  if grep -q '^ZSH_THEME=' "$ZSHRC"; then
    if [ "$OS" = "macos" ]; then
      run_as_user "sed -i '' 's|^ZSH_THEME=.*|ZSH_THEME=\"powerlevel10k/powerlevel10k\"|' '$ZSHRC'"
    else
      run_as_user "sed -i 's|^ZSH_THEME=.*|ZSH_THEME=\"powerlevel10k/powerlevel10k\"|' '$ZSHRC'"
    fi
  else
    run_as_user "echo 'ZSH_THEME=\"powerlevel10k/powerlevel10k\"' >> '$ZSHRC'"
  fi
fi

# Force TERM=xterm-256color for any zsh install (helps p10k + tmux color rendering).
if want zsh; then
  if [ ! -f "$ZSHRC" ]; then
    run_as_user "touch '$ZSHRC'"
  fi
  if ! grep -q '^export TERM=xterm-256color' "$ZSHRC" 2>/dev/null; then
    run_as_user "echo 'export TERM=xterm-256color' >> '$ZSHRC'"
  fi
fi

# ----- MesloLGS Nerd Font --------------------------------------------------

if want meslo-font; then
  if [ "$OS" = "macos" ]; then
    FONT_DIR="$TARGET_HOME/Library/Fonts"
  else
    FONT_DIR="$TARGET_HOME/.local/share/fonts"
  fi
  log "Installing MesloLGS NF into $FONT_DIR"
  run_as_user "mkdir -p '$FONT_DIR'"
  FONT_BASE="https://github.com/romkatv/powerlevel10k-media/raw/master"
  for f in \
    "MesloLGS%20NF%20Regular.ttf" \
    "MesloLGS%20NF%20Bold.ttf" \
    "MesloLGS%20NF%20Italic.ttf" \
    "MesloLGS%20NF%20Bold%20Italic.ttf"; do
    dest_name=$(printf '%s' "$f" | sed 's/%20/ /g')
    if [ ! -f "$FONT_DIR/$dest_name" ]; then
      run_as_user "curl -fsSL '$FONT_BASE/$f' -o '$FONT_DIR/$dest_name'"
    fi
  done
  if [ "$OS" = "linux" ]; then
    run_as_user "fc-cache -f '$FONT_DIR' >/dev/null 2>&1 || true"
  fi
fi

# ----- default shell -------------------------------------------------------

if want zsh; then
  ZSH_BIN="$(command -v zsh || true)"
  if [ -n "$ZSH_BIN" ]; then
    CURRENT_SHELL=$(get_user_shell "$TARGET_USER")
    if [ "$CURRENT_SHELL" != "$ZSH_BIN" ]; then
      if ! grep -qx "$ZSH_BIN" /etc/shells 2>/dev/null; then
        log "Adding $ZSH_BIN to /etc/shells"
        echo "$ZSH_BIN" | $SUDO tee -a /etc/shells >/dev/null || warn "Could not edit /etc/shells."
      fi
      log "Setting default shell to $ZSH_BIN for $TARGET_USER"
      $SUDO chsh -s "$ZSH_BIN" "$TARGET_USER" || warn "chsh failed; set shell manually."
    fi
  fi
fi

# ----- optional packages ---------------------------------------------------

TO_INSTALL=()
TO_INSTALL_CASK=()
INSTALL_RUST=0
INSTALL_NODE_NODESOURCE=0
INSTALL_XCODE_CLT=0
INSTALL_BURNIT=0
INSTALL_WIZARD=0

for opt in "${SELECTED[@]:-}"; do
  case "$opt" in
    # Already handled above or not a distro pkg.
    zsh|git|oh-my-zsh|powerlevel10k|meslo-font) continue ;;
    burnit) INSTALL_BURNIT=1 ;;
    wizard) INSTALL_WIZARD=1 ;;
    rust)
      name=$(pkg_name rust)
      if [ -n "$name" ]; then
        TO_INSTALL+=("$name")
      else
        INSTALL_RUST=1
      fi
      ;;
    nodejs)
      if [ "$PM" = "apt" ]; then
        INSTALL_NODE_NODESOURCE=1
      else
        name=$(pkg_name nodejs)
        [ -n "$name" ] && TO_INSTALL+=("$name")
      fi
      ;;
    build-essential)
      if [ "$OS" = "macos" ]; then
        INSTALL_XCODE_CLT=1
      else
        name=$(pkg_name build-essential)
        [ -n "$name" ] && TO_INSTALL+=("$name")
      fi
      ;;
    docker)
      if [ "$OS" = "macos" ]; then
        TO_INSTALL_CASK+=(docker)
      else
        name=$(pkg_name docker)
        [ -n "$name" ] && TO_INSTALL+=("$name")
      fi
      ;;
    openssh-server)
      # macOS: ships in-box; enabled later via systemsetup.
      if [ "$OS" != "macos" ]; then
        name=$(pkg_name openssh-server)
        [ -n "$name" ] && TO_INSTALL+=("$name")
      fi
      ;;
    *)
      name=$(pkg_name "$opt")
      [ -n "$name" ] && TO_INSTALL+=("$name")
      ;;
  esac
done

if [ "${#TO_INSTALL[@]}" -gt 0 ]; then
  log "Installing optional packages: ${TO_INSTALL[*]}"
  pm_install "${TO_INSTALL[@]}"
fi

if [ "${#TO_INSTALL_CASK[@]}" -gt 0 ]; then
  log "Installing casks: ${TO_INSTALL_CASK[*]}"
  pm_install_cask "${TO_INSTALL_CASK[@]}"
fi

if [ "$INSTALL_XCODE_CLT" -eq 1 ]; then
  if ! xcode-select -p >/dev/null 2>&1; then
    log "Installing Xcode Command Line Tools (GUI prompt will appear)"
    xcode-select --install || warn "xcode-select --install failed; run manually."
  else
    log "Xcode Command Line Tools already installed"
  fi
fi

if [ "$INSTALL_NODE_NODESOURCE" -eq 1 ]; then
  log "Installing Node.js LTS via NodeSource"
  curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash -
  pm_install nodejs
fi

if [ "$INSTALL_RUST" -eq 1 ]; then
  log "Installing Rust via rustup"
  run_as_user "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --no-modify-path"
  run_as_user "grep -q 'cargo/env' '$TARGET_HOME/.zshrc' 2>/dev/null || echo '[ -f \"\$HOME/.cargo/env\" ] && . \"\$HOME/.cargo/env\"' >> '$TARGET_HOME/.zshrc'"
fi

# ----- python tools: burnit + wizard --------------------------------------

if [ "$INSTALL_BURNIT" -eq 1 ] || [ "$INSTALL_WIZARD" -eq 1 ]; then
  if ! need_cmd python3; then
    log "Installing python3"
    pm_install "$(pkg_name python3)"
  fi
fi

if [ "$INSTALL_BURNIT" -eq 1 ]; then
  install_tool burnit
  log "burnit installed. Run: burnit /path/to/image.iso"
fi

if [ "$INSTALL_WIZARD" -eq 1 ]; then
  # wizard uses Rich; it self-installs via pip on first run, so make sure pip exists.
  PIP_PKG="$(pkg_name pip)"
  if [ -n "$PIP_PKG" ] && ! run_as_user "python3 -m pip --version" >/dev/null 2>&1; then
    log "Installing pip (for wizard's Rich UI)"
    pm_install "$PIP_PKG"
  fi
  install_tool wizard
  log "wizard installed. Run: wizard"
fi

# ----- eza alias + zoxide init in .zshrc -----------------------------------

if want eza || want zoxide; then
  if [ ! -f "$ZSHRC" ]; then
    run_as_user "touch '$ZSHRC'"
  fi
fi

if want eza; then
  if ! grep -q "alias ls='eza" "$ZSHRC" 2>/dev/null; then
    log "Aliasing ls -> eza in $ZSHRC"
    run_as_user "echo \"alias ls='eza --group-directories-first'\" >> '$ZSHRC'"
    run_as_user "echo \"alias ll='eza -l --group-directories-first'\" >> '$ZSHRC'"
    run_as_user "echo \"alias la='eza -la --group-directories-first'\" >> '$ZSHRC'"
  fi
fi

if want zoxide; then
  if ! grep -q 'zoxide init zsh' "$ZSHRC" 2>/dev/null; then
    log "Adding zoxide init to $ZSHRC"
    run_as_user "echo 'eval \"\$(zoxide init zsh)\"' >> '$ZSHRC'"
  fi
fi

# ----- enable sshd if installed -------------------------------------------

if want openssh-server; then
  if [ "$OS" = "macos" ]; then
    log "Enabling Remote Login (sshd) on macOS"
    $SUDO systemsetup -setremotelogin on >/dev/null 2>&1 || warn "Could not enable Remote Login; grant Full Disk Access to your terminal or enable in System Settings > General > Sharing."
  elif need_cmd systemctl; then
    SVC="ssh"
    case "$PM" in
      dnf|yum|pacman|zypper|apk) SVC="sshd" ;;
    esac
    log "Enabling $SVC service"
    $SUDO systemctl enable --now "$SVC" || warn "Could not enable $SVC; check service name."
  else
    warn "No systemd detected; start sshd manually."
  fi
fi

# ----- enable + group docker if installed ---------------------------------

if want docker; then
  if [ "$OS" = "macos" ]; then
    log "Docker Desktop installed. Launch it once to start the daemon: open -a Docker"
  else
    if need_cmd systemctl; then
      log "Enabling docker service"
      $SUDO systemctl enable --now docker || warn "Could not enable docker service."
    fi
    if [ "$TARGET_USER" != "root" ]; then
      log "Adding $TARGET_USER to docker group (log out + back in to take effect)"
      $SUDO usermod -aG docker "$TARGET_USER" || warn "Failed to add user to docker group."
    fi
  fi
fi

# ----- tmux + TPM + catppuccin --------------------------------------------

if want tmux; then
  log "Setting up tmux config + plugins"

  TMUX_CONF="$TARGET_HOME/.tmux.conf"
  TMUX_PLUGIN_DIR="$TARGET_HOME/.config/tmux/plugins"
  TPM_DIR="$TARGET_HOME/.tmux/plugins/tpm"

  if [ -f "$TMUX_CONF" ] && [ ! -f "$TMUX_CONF.bak" ]; then
    log "Backing up existing ~/.tmux.conf to ~/.tmux.conf.bak"
    run_as_user "cp '$TMUX_CONF' '$TMUX_CONF.bak'"
  fi

  run_as_user "mkdir -p '$TMUX_PLUGIN_DIR/catppuccin' '$TMUX_PLUGIN_DIR/tmux-plugins' '$TARGET_HOME/.tmux/plugins'"

  if [ ! -d "$TMUX_PLUGIN_DIR/catppuccin/tmux" ]; then
    run_as_user "git clone --depth=1 -b v2.1.3 https://github.com/catppuccin/tmux.git '$TMUX_PLUGIN_DIR/catppuccin/tmux'"
  else
    run_as_user "git -C '$TMUX_PLUGIN_DIR/catppuccin/tmux' pull --ff-only || true"
  fi

  if [ ! -d "$TMUX_PLUGIN_DIR/tmux-plugins/tmux-cpu" ]; then
    run_as_user "git clone --depth=1 https://github.com/tmux-plugins/tmux-cpu.git '$TMUX_PLUGIN_DIR/tmux-plugins/tmux-cpu'"
  else
    run_as_user "git -C '$TMUX_PLUGIN_DIR/tmux-plugins/tmux-cpu' pull --ff-only || true"
  fi

  if [ ! -d "$TMUX_PLUGIN_DIR/tmux-plugins/tmux-battery" ]; then
    run_as_user "git clone --depth=1 https://github.com/tmux-plugins/tmux-battery.git '$TMUX_PLUGIN_DIR/tmux-plugins/tmux-battery'"
  else
    run_as_user "git -C '$TMUX_PLUGIN_DIR/tmux-plugins/tmux-battery' pull --ff-only || true"
  fi

  if [ ! -d "$TPM_DIR" ]; then
    run_as_user "git clone --depth=1 https://github.com/tmux-plugins/tpm.git '$TPM_DIR'"
  else
    run_as_user "git -C '$TPM_DIR' pull --ff-only || true"
  fi

  if [ ! -f "$TMUX_CONF" ]; then
    run_as_user "cat > '$TMUX_CONF'" <<'TMUX_EOF'
# ~/.tmux.conf

# Options to make tmux more pleasant
set -g mouse on
set -g default-terminal "tmux-256color"

# Configure the catppuccin plugin
set -g @catppuccin_flavor "mocha"
set -g @catppuccin_window_status_style "rounded"

# Load catppuccin
run ~/.config/tmux/plugins/catppuccin/tmux/catppuccin.tmux
# For TPM, instead use `run ~/.tmux/plugins/tmux/catppuccin.tmux`

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
# Or, if using TPM, just run TPM

# Initialize TPM (keep at the bottom of tmux.conf)
run '~/.tmux/plugins/tpm/tpm'
TMUX_EOF
  else
    log "~/.tmux.conf exists - leaving untouched (backup at ~/.tmux.conf.bak if changed)"
  fi
fi

# ----- done ----------------------------------------------------------------

log "Done."
if want zsh; then
  log "Next: log out + back in (or run 'zsh')."
fi
if want powerlevel10k; then
  log "Run 'p10k configure' to finish the prompt wizard."
fi
if want meslo-font; then
  log "Set your terminal font to 'MesloLGS NF'."
fi
if [ "$OS" = "macos" ] && want docker; then
  log "macOS: launch Docker Desktop once ('open -a Docker') to start the daemon."
fi
if want burnit || want wizard; then
  log "Tools installed to ~/.local/bin (added to PATH in .zshrc; open a new shell)."
fi
if want wizard; then
  log "Launch the menu with: wizard"
fi
