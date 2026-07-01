#!/usr/bin/env bash
#
# Interactive Flutter installer for macOS.
# Installs Flutter and configures PATH; optionally runs flutter doctor.
#
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC}  $*"; }
success() { echo -e "${GREEN}✔${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
error()   { echo -e "${RED}✖${NC}  $*" >&2; }
header()  { echo -e "\n${BOLD}${CYAN}$*${NC}\n"; }

FLUTTER_HOME="${FLUTTER_HOME:-${HOME}/flutter}"
MAX_VERSIONS=20

SOURCES=(
  "brew|Homebrew (recommended)|brew"
  "git|Git clone (stable channel)|git"
)

# ── Helpers ───────────────────────────────────────────────────────────────────
require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    error "This script is intended for macOS only."
    exit 1
  fi
}

ensure_homebrew() {
  if command -v brew &>/dev/null; then
    success "Homebrew found: $(brew --version | head -1)"
    return 0
  fi

  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  if command -v brew &>/dev/null; then
    success "Homebrew found: $(brew --version | head -1)"
    return 0
  fi

  header "Homebrew is required for the recommended install"
  read -rp "Install Homebrew now? [Y/n]: " answer
  answer="${answer:-Y}"
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    error "Homebrew is required. Run ./install-homebrew.sh or use the Git install option."
    exit 1
  fi

  local script_dir brew_script
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  brew_script="${script_dir}/install-homebrew.sh"

  if [[ -x "$brew_script" ]]; then
    bash "$brew_script" --yes
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi

  if ! command -v brew &>/dev/null; then
    error "Homebrew installation finished but 'brew' is not in PATH."
    exit 1
  fi
  success "Homebrew installed."
}

flutter_installed() {
  command -v flutter &>/dev/null
}

detect_flutter_home() {
  if command -v flutter &>/dev/null; then
    local bin
    bin="$(command -v flutter)"
    echo "$(cd "$(dirname "$bin")/.." && pwd)"
    return 0
  fi
  if [[ -x "${FLUTTER_HOME}/bin/flutter" ]]; then
    echo "$FLUTTER_HOME"
    return 0
  fi
  return 1
}

profile_has_flutter() {
  local file="$1"
  [[ -f "$file" ]] && grep -Fq 'flutter/bin' "$file"
}

shell_profiles() {
  local shell_name profiles=()
  shell_name="$(basename "${SHELL:-/bin/zsh}")"
  case "$shell_name" in
    zsh) profiles=("$HOME/.zprofile" "$HOME/.zshrc") ;;
    bash) profiles=("$HOME/.bash_profile" "$HOME/.bashrc") ;;
    *) profiles=("$HOME/.profile") ;;
  esac
  printf '%s\n' "${profiles[@]}"
}

configure_flutter_path() {
  local flutter_root="$1"
  local profile updated=false block

  block=$(cat <<EOF

# Flutter
export FLUTTER_HOME="${flutter_root}"
export PATH="\${FLUTTER_HOME}/bin:\$PATH"
EOF
)

  while IFS= read -r profile; do
    [[ -z "$profile" ]] && continue
    if profile_has_flutter "$profile"; then
      info "Flutter already configured in ${profile}"
      continue
    fi
    info "Adding Flutter to ${profile}"
    printf '%s\n' "$block" >> "$profile"
    updated=true
  done < <(shell_profiles)

  export FLUTTER_HOME="$flutter_root"
  export PATH="${FLUTTER_HOME}/bin:${PATH}"

  if [[ "$updated" == true ]]; then
    success "Shell profile updated with Flutter PATH."
  fi
}

select_source() {
  header "Select Flutter install source"
  local i=1 ids=() names=()

  for entry in "${SOURCES[@]}"; do
    IFS='|' read -r id name _ <<< "$entry"
    ids+=("$id")
    names+=("$name")
    echo "  ${i}) ${name}"
    ((i++)) || true
  done
  echo

  local choice
  while true; do
    read -rp "Enter choice [1-${#ids[@]}] (default: 1): " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ids[@]} )); then
      SELECTED_SOURCE="${ids[$((choice-1))]}"
      SELECTED_SOURCE_NAME="${names[$((choice-1))]}"
      success "Selected: ${SELECTED_SOURCE_NAME}"
      return
    fi
    warn "Invalid choice."
  done
}

fetch_flutter_versions() {
  if ! command -v git &>/dev/null; then
    return 1
  fi
  git ls-remote --tags https://github.com/flutter/flutter.git 2>/dev/null \
    | grep -oE 'refs/tags/[0-9]+\.[0-9]+\.[0-9]+$' \
    | sed 's|refs/tags/||' \
    | awk '!seen[$0]++' \
    | tail -n "$MAX_VERSIONS" \
    | tail -r
}

select_flutter_version() {
  header "Select Flutter version (Git install only)"
  info "Homebrew installs the current stable release."

  local -a versions=()
  while IFS= read -r v; do
    [[ -n "$v" ]] && versions+=("$v")
  done < <(fetch_flutter_versions 2>/dev/null || true)

  if [[ ${#versions[@]} -eq 0 ]]; then
    SELECTED_FLUTTER_VERSION="stable"
    info "Using stable channel (could not fetch tag list)."
    return
  fi

  echo "  1) stable (recommended)"
  local i=2
  for v in "${versions[@]}"; do
    echo "  ${i}) Flutter ${v}"
    ((i++)) || true
  done
  echo "  m) Enter version/tag manually (e.g. 3.24.5, stable, beta)"
  echo

  local choice
  while true; do
    read -rp "Enter choice [1-${i}/m] (default: 1): " choice
    choice="${choice:-1}"

    if [[ "$choice" =~ ^[Mm]$ ]]; then
      read -rp "Enter Flutter version or channel: " manual
      manual="$(echo "$manual" | xargs)"
      [[ -z "$manual" ]] && { warn "Version cannot be empty."; continue; }
      SELECTED_FLUTTER_VERSION="$manual"
      success "Selected: Flutter ${SELECTED_FLUTTER_VERSION}"
      return
    fi

    if [[ "$choice" == "1" ]]; then
      SELECTED_FLUTTER_VERSION="stable"
      success "Selected: Flutter stable channel"
      return
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 2 && choice <= i - 1 )); then
      SELECTED_FLUTTER_VERSION="${versions[$((choice-2))]}"
      success "Selected: Flutter ${SELECTED_FLUTTER_VERSION}"
      return
    fi

    warn "Invalid choice."
  done
}

install_flutter_brew() {
  ensure_homebrew
  info "Updating Homebrew..."
  brew update --quiet 2>/dev/null || warn "brew update failed; continuing."

  header "Installing Flutter (Homebrew)"
  if brew list --cask flutter &>/dev/null 2>&1; then
    brew upgrade --cask flutter 2>/dev/null || true
  else
    brew install --cask flutter
  fi

  if ! flutter_installed; then
    local caskroom
    caskroom="$(brew --prefix)/Caskroom/flutter"
    if [[ -d "$caskroom" ]]; then
      FLUTTER_HOME="$(find "$caskroom" -maxdepth 2 -type d -name flutter 2>/dev/null | head -1)"
      FLUTTER_HOME="$(cd "${FLUTTER_HOME}/.." 2>/dev/null && pwd || echo "$FLUTTER_HOME")"
    fi
  else
    FLUTTER_HOME="$(detect_flutter_home || echo "$FLUTTER_HOME")"
  fi

  success "Flutter installed via Homebrew."
}

install_flutter_git() {
  if ! command -v git &>/dev/null; then
    error "git is required. Install Xcode Command Line Tools: xcode-select --install"
    exit 1
  fi

  select_flutter_version

  header "Installing Flutter (Git)"
  if [[ -d "${FLUTTER_HOME}/.git" ]]; then
    warn "Existing Flutter repo at ${FLUTTER_HOME}"
    read -rp "Update existing install? [Y/n]: " update
    update="${update:-Y}"
    if [[ "$update" =~ ^[Yy]$ ]]; then
      info "Fetching updates..."
      git -C "$FLUTTER_HOME" fetch --tags --depth 1 origin
      if [[ "$SELECTED_FLUTTER_VERSION" == "stable" || "$SELECTED_FLUTTER_VERSION" == "beta" || "$SELECTED_FLUTTER_VERSION" == "master" ]]; then
        git -C "$FLUTTER_HOME" checkout "$SELECTED_FLUTTER_VERSION"
        git -C "$FLUTTER_HOME" pull origin "$SELECTED_FLUTTER_VERSION"
      else
        git -C "$FLUTTER_HOME" checkout "tags/${SELECTED_FLUTTER_VERSION}" 2>/dev/null \
          || git -C "$FLUTTER_HOME" checkout "$SELECTED_FLUTTER_VERSION"
      fi
    fi
  else
    info "Cloning Flutter to ${FLUTTER_HOME}..."
    git clone https://github.com/flutter/flutter.git -b stable "$FLUTTER_HOME" --depth 1
    if [[ "$SELECTED_FLUTTER_VERSION" != "stable" ]]; then
      git -C "$FLUTTER_HOME" fetch --tags --depth 1 origin
      if [[ "$SELECTED_FLUTTER_VERSION" == "beta" || "$SELECTED_FLUTTER_VERSION" == "master" ]]; then
        git -C "$FLUTTER_HOME" checkout "$SELECTED_FLUTTER_VERSION"
      else
        git -C "$FLUTTER_HOME" checkout "tags/${SELECTED_FLUTTER_VERSION}" 2>/dev/null \
          || git -C "$FLUTTER_HOME" checkout "$SELECTED_FLUTTER_VERSION"
      fi
    fi
  fi

  success "Flutter cloned to ${FLUTTER_HOME}"
}

install_flutter() {
  if flutter_installed; then
    success "Flutter already installed: $(flutter --version 2>&1 | head -1)"
    read -rp "Reinstall/upgrade anyway? [y/N]: " reinstall
    reinstall="${reinstall:-N}"
    if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
      FLUTTER_HOME="$(detect_flutter_home || echo "$FLUTTER_HOME")"
      return 0
    fi
  fi

  case "$SELECTED_SOURCE" in
    brew) install_flutter_brew ;;
    git) install_flutter_git ;;
    *) error "Unknown source: ${SELECTED_SOURCE}"; exit 1 ;;
  esac
}

configure_flutter() {
  header "Configure Flutter (optional)"
  echo "  1) Run flutter doctor"
  echo "  2) Precache Flutter artifacts (flutter precache)"
  echo "  3) Enable macOS desktop support"
  echo "  4) Skip configuration"
  echo

  local choice
  while true; do
    read -rp "Enter choice [1-4] (default: 1): " choice
    choice="${choice:-1}"
    case "$choice" in
      1)
        header "flutter doctor"
        flutter doctor -v || warn "flutter doctor reported issues — see output above."
        return
        ;;
      2)
        info "Running flutter precache..."
        flutter precache
        success "Precache complete."
        return
        ;;
      3)
        flutter config --enable-macos-desktop
        success "macOS desktop support enabled."
        flutter doctor
        return
        ;;
      4)
        info "Skipped configuration."
        return
        ;;
      *)
        warn "Invalid choice. Enter 1-4."
        ;;
    esac
  done
}

verify_install() {
  header "Verification"

  if flutter_installed; then
    success "$(flutter --version 2>&1 | head -1)"
    echo
    info "Flutter binary: $(command -v flutter)"
    info "FLUTTER_HOME: ${FLUTTER_HOME:-$(detect_flutter_home 2>/dev/null || echo unknown)}"
  else
    warn "flutter not found on PATH."
    info "Try: source ~/.zshrc"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║       macOS Flutter Installer            ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"

  require_macos
  select_source

  echo
  read -rp "Proceed with installation? [Y/n]: " confirm
  confirm="${confirm:-Y}"
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "Installation cancelled."
    exit 0
  fi

  install_flutter

  local flutter_root
  flutter_root="$(detect_flutter_home 2>/dev/null || echo "$FLUTTER_HOME")"
  configure_flutter_path "$flutter_root"

  verify_install

  echo
  read -rp "Run Flutter setup (doctor/precache)? [Y/n]: " configure_now
  configure_now="${configure_now:-Y}"
  if [[ "$configure_now" =~ ^[Yy]$ ]]; then
    configure_flutter
    verify_install
  fi

  success "Done! Flutter is installed."
}

main "$@"
