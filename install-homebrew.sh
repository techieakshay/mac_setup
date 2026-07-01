#!/usr/bin/env bash
#
# Install Homebrew on macOS and configure shell PATH.
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

BREW_APPLE_SILICON="/opt/homebrew/bin/brew"
BREW_INTEL="/usr/local/bin/brew"

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    error "This script is intended for macOS only."
    exit 1
  fi
}

detect_brew() {
  if command -v brew &>/dev/null; then
    echo "$(command -v brew)"
    return 0
  fi
  if [[ -x "$BREW_APPLE_SILICON" ]]; then
    echo "$BREW_APPLE_SILICON"
    return 0
  fi
  if [[ -x "$BREW_INTEL" ]]; then
    echo "$BREW_INTEL"
    return 0
  fi
  return 1
}

ensure_xcode_cli_tools() {
  if xcode-select -p &>/dev/null; then
    success "Xcode Command Line Tools found."
    return 0
  fi

  header "Xcode Command Line Tools required"
  warn "Homebrew needs Apple's Command Line Tools (compiler, git, etc.)."
  echo
  read -rp "Install Command Line Tools now? [Y/n]: " answer
  answer="${answer:-Y}"
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    error "Command Line Tools are required. Run: xcode-select --install"
    exit 1
  fi

  info "Opening Command Line Tools installer..."
  xcode-select --install || true

  echo
  info "Complete the GUI installer, then press Enter to continue."
  read -r

  if ! xcode-select -p &>/dev/null; then
    error "Command Line Tools still not detected. Install them and re-run this script."
    exit 1
  fi
  success "Command Line Tools installed."
}

load_brew_shellenv() {
  local brew_bin="$1"
  if [[ -x "$brew_bin" ]]; then
    # shellcheck disable=SC1091
    eval "$("$brew_bin" shellenv)"
  fi
}

profile_has_brew_shellenv() {
  local file="$1"
  [[ -f "$file" ]] && grep -Fq 'brew shellenv' "$file"
}

add_brew_to_profile() {
  local brew_bin="$1"
  local shellenv_line="eval \"\$($brew_bin shellenv)\""

  # macOS recommends .zprofile for login shells; also update .zshrc / .bash_profile
  local -a profiles=()
  local shell_name
  shell_name="$(basename "${SHELL:-/bin/zsh}")"

  case "$shell_name" in
    zsh) profiles=("$HOME/.zprofile" "$HOME/.zshrc") ;;
    bash) profiles=("$HOME/.bash_profile" "$HOME/.bashrc") ;;
    *) profiles=("$HOME/.profile") ;;
  esac

  local profile updated=false
  for profile in "${profiles[@]}"; do
    if [[ -f "$profile" ]] && profile_has_brew_shellenv "$profile"; then
      info "Homebrew already configured in ${profile}"
      continue
    fi

    info "Adding Homebrew to ${profile}"
    {
      echo ""
      echo "# Homebrew"
      echo "$shellenv_line"
    } >> "$profile"
    updated=true
  done

  if [[ "$updated" == true ]]; then
    success "Shell profile updated. New terminals will have brew on PATH."
  fi
}

verify_brew() {
  header "Verification"
  if ! command -v brew &>/dev/null; then
    error "'brew' is not on PATH in this shell."
    return 1
  fi

  success "$(brew --version | head -1)"
  info "Prefix: $(brew --prefix)"
  info "Running brew update..."
  brew update --quiet || warn "brew update failed (network or permissions)."

  echo
  success "Homebrew is ready to use."
  echo
  echo "Example commands:"
  echo "  brew search wget"
  echo "  brew install wget"
  echo "  brew install --cask google-chrome"
}

install_homebrew() {
  header "Installing Homebrew"
  info "This uses the official installer from https://brew.sh"
  info "You may be prompted for your macOS password."
  echo

  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

main() {
  local auto_yes=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes) auto_yes=true; shift ;;
      -h|--help)
        echo "Usage: $(basename "$0") [-y|--yes]"
        echo "  -y, --yes   Skip confirmation prompts"
        exit 0
        ;;
      *) error "Unknown option: $1"; exit 1 ;;
    esac
  done

  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║       macOS Homebrew Installer           ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"

  require_macos

  local existing_brew=""
  if existing_brew=$(detect_brew 2>/dev/null); then
    load_brew_shellenv "$existing_brew"
    header "Homebrew already installed"
    success "$(brew --version | head -1)"
    info "Location: ${existing_brew}"

    read -rp "Re-run verification/update anyway? [y/N]: " rerun
    rerun="${rerun:-N}"
    if [[ ! "$rerun" =~ ^[Yy]$ ]]; then
      info "Nothing to do."
      exit 0
    fi
    verify_brew
    exit 0
  fi

  ensure_xcode_cli_tools

  if [[ "$auto_yes" != true ]]; then
    echo
    read -rp "Install Homebrew? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      info "Installation cancelled."
      exit 0
    fi
  fi

  install_homebrew

  local brew_bin=""
  if [[ -x "$BREW_APPLE_SILICON" ]]; then
    brew_bin="$BREW_APPLE_SILICON"
  elif [[ -x "$BREW_INTEL" ]]; then
    brew_bin="$BREW_INTEL"
  else
    error "Homebrew install finished but the brew binary was not found."
    echo "See https://docs.brew.sh/Installation for manual setup."
    exit 1
  fi

  load_brew_shellenv "$brew_bin"
  add_brew_to_profile "$brew_bin"
  verify_brew

  echo
  info "If 'brew' is not found in this terminal, run:"
  echo "  source ~/.zprofile   # or restart your terminal"
}

main "$@"
