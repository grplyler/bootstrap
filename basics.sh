#!/usr/bin/env bash
# basics.sh - bootstrap helper for fresh Linux boxes.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/basics.sh | bash
#   # or, to pre-answer the optional-package menu:
#   curl -fsSL ... | bash -s -- --yes git rust go
#
# Always installs: zsh, oh-my-zsh, powerlevel10k, MesloLGS Nerd Font.
# Prompts (whiptail checklist) for: git, build-essential, rust, go, nodejs, openssh-server.

set -euo pipefail

# ----- helpers -------------------------------------------------------------

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  need_cmd sudo || die "Run as root or install sudo."
  SUDO="sudo"
fi

# ----- detect package manager ---------------------------------------------

PM=""
if   need_cmd apt-get; then PM="apt"
elif need_cmd dnf;     then PM="dnf"
elif need_cmd yum;     then PM="yum"
elif need_cmd pacman;  then PM="pacman"
elif need_cmd zypper;  then PM="zypper"
elif need_cmd apk;     then PM="apk"
else die "No supported package manager found (apt/dnf/yum/pacman/zypper/apk)."
fi
log "Detected package manager: $PM"

pm_update() {
  case "$PM" in
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
    apt)    DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "$@" ;;
    dnf)    $SUDO dnf install -y "$@" ;;
    yum)    $SUDO yum install -y "$@" ;;
    pacman) $SUDO pacman -S --noconfirm --needed "$@" ;;
    zypper) $SUDO zypper --non-interactive install "$@" ;;
    apk)    $SUDO apk add "$@" ;;
  esac
}

# Map logical package names to per-distro package names.
pkg_name() {
  local logical="$1"
  case "$logical:$PM" in
    git:*)               echo git ;;
    curl:*)              echo curl ;;
    zsh:*)               echo zsh ;;
    fontconfig:*)        echo fontconfig ;;
    ca-certificates:apk) echo ca-certificates ;;
    ca-certificates:*)   echo ca-certificates ;;

    build-essential:apt)    echo build-essential ;;
    build-essential:dnf)    echo "@Development Tools" ;;
    build-essential:yum)    echo "@Development Tools" ;;
    build-essential:pacman) echo base-devel ;;
    build-essential:zypper) echo "patterns-devel-base-devel_basis" ;;
    build-essential:apk)    echo build-base ;;

    rust:pacman) echo rust ;;
    rust:*)      echo "" ;;  # installed via rustup below

    go:apt)    echo golang-go ;;
    go:dnf)    echo golang ;;
    go:yum)    echo golang ;;
    go:pacman) echo go ;;
    go:zypper) echo go ;;
    go:apk)    echo go ;;

    nodejs:apt)    echo nodejs ;;
    nodejs:dnf)    echo nodejs ;;
    nodejs:yum)    echo nodejs ;;
    nodejs:pacman) echo nodejs ;;
    nodejs:zypper) echo nodejs ;;
    nodejs:apk)    echo nodejs ;;

    openssh-server:apt)    echo openssh-server ;;
    openssh-server:dnf)    echo openssh-server ;;
    openssh-server:yum)    echo openssh-server ;;
    openssh-server:pacman) echo openssh ;;
    openssh-server:zypper) echo openssh ;;
    openssh-server:apk)    echo openssh ;;

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
      sed -n '2,10p' "$0" 2>/dev/null || true
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

PREREQS=(curl ca-certificates fontconfig)
case "$PM" in
  apt) PREREQS+=(unzip whiptail) ;;
  dnf|yum) PREREQS+=(unzip newt) ;;
  pacman)  PREREQS+=(unzip libnewt) ;;
  zypper)  PREREQS+=(unzip newt) ;;
  apk)     PREREQS+=(unzip newt) ;;
esac
log "Installing prerequisites: ${PREREQS[*]}"
pm_install "${PREREQS[@]}"

# ----- optional package menu ----------------------------------------------

OPTIONAL=(git build-essential rust go nodejs openssh-server)

declare -a SELECTED=()
if [ "$NONINTERACTIVE" -eq 1 ]; then
  SELECTED=("${PRESELECTED[@]:-}")
  # Drop possible empty placeholder element.
  if [ "${#SELECTED[@]}" -eq 1 ] && [ -z "${SELECTED[0]}" ]; then
    SELECTED=()
  fi
else
  if ! need_cmd whiptail; then
    warn "whiptail not available, installing all optional packages by default."
    SELECTED=("${OPTIONAL[@]}")
  else
    # Build checklist args: TAG ITEM STATUS ...
    CHECKLIST_ARGS=()
    for p in "${OPTIONAL[@]}"; do
      CHECKLIST_ARGS+=("$p" "$p" "ON")
    done
    # whiptail needs a real terminal; route through /dev/tty so this works under `curl | bash`.
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
      RAW=$(whiptail \
        --title "basics.sh - optional packages" \
        --checklist "Space to toggle, Enter to confirm:" \
        20 60 ${#OPTIONAL[@]} \
        "${CHECKLIST_ARGS[@]}" \
        3>&1 1>&2 2>&3 </dev/tty >/dev/tty) || RAW=""
      # whiptail prints `"pkg1" "pkg2" ...`; strip quotes.
      # shellcheck disable=SC2206
      SELECTED=( $(echo "$RAW" | tr -d '"') )
    else
      warn "No TTY available, installing all optional packages by default."
      SELECTED=("${OPTIONAL[@]}")
    fi
  fi
fi

log "Optional selection: ${SELECTED[*]:-<none>}"

# ----- always: zsh ---------------------------------------------------------

log "Installing zsh + git (needed for oh-my-zsh)"
pm_install "$(pkg_name zsh)" "$(pkg_name git)"

# ----- target user (the human, not root via sudo) -------------------------

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[ -z "$TARGET_HOME" ] && TARGET_HOME="$HOME"
log "Installing user-level pieces for: $TARGET_USER ($TARGET_HOME)"

run_as_user() {
  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    sudo -u "$TARGET_USER" -H bash -c "$*"
  else
    bash -c "$*"
  fi
}

# ----- oh-my-zsh -----------------------------------------------------------

OMZ_DIR="$TARGET_HOME/.oh-my-zsh"
if [ -d "$OMZ_DIR" ]; then
  log "oh-my-zsh already installed at $OMZ_DIR"
else
  log "Installing oh-my-zsh"
  run_as_user "RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\""
fi

# ----- powerlevel10k -------------------------------------------------------

P10K_DIR="$OMZ_DIR/custom/themes/powerlevel10k"
if [ -d "$P10K_DIR" ]; then
  log "powerlevel10k already present"
  run_as_user "git -C '$P10K_DIR' pull --ff-only || true"
else
  log "Cloning powerlevel10k"
  run_as_user "git clone --depth=1 https://github.com/romkatv/powerlevel10k.git '$P10K_DIR'"
fi

# Point .zshrc at powerlevel10k.
ZSHRC="$TARGET_HOME/.zshrc"
if [ -f "$ZSHRC" ]; then
  if grep -q '^ZSH_THEME=' "$ZSHRC"; then
    run_as_user "sed -i 's|^ZSH_THEME=.*|ZSH_THEME=\"powerlevel10k/powerlevel10k\"|' '$ZSHRC'"
  else
    run_as_user "echo 'ZSH_THEME=\"powerlevel10k/powerlevel10k\"' >> '$ZSHRC'"
  fi
  # Force TERM=xterm-256color so p10k icons/colors render correctly.
  if ! grep -q '^export TERM=xterm-256color' "$ZSHRC"; then
    run_as_user "echo 'export TERM=xterm-256color' >> '$ZSHRC'"
  fi
fi

# ----- MesloLGS Nerd Font --------------------------------------------------

FONT_DIR="$TARGET_HOME/.local/share/fonts"
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
run_as_user "fc-cache -f '$FONT_DIR' >/dev/null 2>&1 || true"

# ----- default shell -------------------------------------------------------

ZSH_BIN="$(command -v zsh || true)"
if [ -n "$ZSH_BIN" ]; then
  CURRENT_SHELL=$(getent passwd "$TARGET_USER" | cut -d: -f7)
  if [ "$CURRENT_SHELL" != "$ZSH_BIN" ]; then
    log "Setting default shell to $ZSH_BIN for $TARGET_USER"
    $SUDO chsh -s "$ZSH_BIN" "$TARGET_USER" || warn "chsh failed; set shell manually."
  fi
fi

# ----- optional packages ---------------------------------------------------

want() {
  local needle="$1"
  for s in "${SELECTED[@]:-}"; do
    [ "$s" = "$needle" ] && return 0
  done
  return 1
}

# Resolve distro packages for selected items.
TO_INSTALL=()
INSTALL_RUST=0
INSTALL_NODE_NODESOURCE=0

for opt in "${SELECTED[@]:-}"; do
  case "$opt" in
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

# ----- enable sshd if installed -------------------------------------------

if want openssh-server; then
  if need_cmd systemctl; then
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

# ----- done ----------------------------------------------------------------

log "Done."
log "Next: log out + back in (or run 'zsh') and complete the p10k configure wizard."
log "Set your terminal font to 'MesloLGS NF'."
