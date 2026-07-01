#!/usr/bin/env bash
#
# Interactive AWS CLI installer for macOS.
# Installs AWS CLI via Homebrew and optionally runs aws configure.
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

# id | display name | brew formula
SOURCES=(
  "brew|Homebrew (recommended)|awscli"
  "official|Official AWS installer (curl)|official"
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
    error "Homebrew is required for Homebrew install. Use the official AWS installer option instead."
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

aws_cli_installed() {
  command -v aws &>/dev/null
}

select_source() {
  header "Select AWS CLI install source"
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

install_aws_cli_brew() {
  ensure_homebrew
  info "Updating Homebrew formulae..."
  brew update --quiet 2>/dev/null || warn "brew update failed; continuing."

  header "Installing AWS CLI (Homebrew)"
  if aws_cli_installed && brew list awscli &>/dev/null; then
    info "awscli already installed via Homebrew — upgrading if needed..."
    brew upgrade awscli 2>/dev/null || brew install awscli
  else
    brew install awscli
  fi
  success "AWS CLI installed."
}

install_aws_cli_official() {
  header "Installing AWS CLI (Official AWS installer)"
  local tmpdir pkg
  tmpdir="$(mktemp -d)"
  pkg="${tmpdir}/AWSCLIV2.pkg"

  info "Downloading AWS CLI v2 for macOS..."
  curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "$pkg"

  info "Running installer (you may be prompted for your password)..."
  sudo installer -pkg "$pkg" -target /
  rm -rf "$tmpdir"
  success "AWS CLI installed."
}

install_aws_cli() {
  if aws_cli_installed; then
    success "AWS CLI already installed: $(aws --version 2>&1 | head -1)"
    read -rp "Reinstall/upgrade anyway? [y/N]: " reinstall
    reinstall="${reinstall:-N}"
    if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
      return 0
    fi
  fi

  case "$SELECTED_SOURCE" in
    brew) install_aws_cli_brew ;;
    official) install_aws_cli_official ;;
    *) error "Unknown source: ${SELECTED_SOURCE}"; exit 1 ;;
  esac
}

configure_aws_cli() {
  header "Configure AWS CLI (optional)"

  if [[ -f "${HOME}/.aws/credentials" || -f "${HOME}/.aws/config" ]]; then
    warn "Existing AWS config found in ~/.aws/"
    aws configure list 2>/dev/null | sed 's/^/  /' || true
    echo
    read -rp "Re-configure AWS CLI? [y/N]: " reconfig
    reconfig="${reconfig:-N}"
    if [[ ! "$reconfig" =~ ^[Yy]$ ]]; then
      info "Keeping existing configuration."
      return 0
    fi
  fi

  echo "  1) IAM access keys     (aws configure)"
  echo "  2) SSO                 (aws configure sso)"
  echo "  3) Skip configuration"
  echo

  local choice
  while true; do
    read -rp "Enter choice [1-3] (default: 3): " choice
    choice="${choice:-3}"
    case "$choice" in
      1)
        header "IAM access key setup"
        info "You will need: Access Key ID, Secret Access Key, default region, output format."
        aws configure
        success "AWS CLI configured with IAM credentials."
        return
        ;;
      2)
        header "AWS SSO setup"
        info "Follow the prompts — a browser window may open for SSO login."
        aws configure sso
        success "AWS CLI configured with SSO."
        return
        ;;
      3)
        info "Skipped configuration. Run 'aws configure' or 'aws configure sso' later."
        return
        ;;
      *)
        warn "Invalid choice. Enter 1, 2, or 3."
        ;;
    esac
  done
}

verify_install() {
  header "Verification"

  if aws_cli_installed; then
    success "$(aws --version 2>&1 | head -1)"
    echo
    if [[ -f "${HOME}/.aws/credentials" || -f "${HOME}/.aws/config" ]]; then
      info "Current configuration:"
      aws configure list 2>/dev/null | sed 's/^/  /' || true
    else
      info "No AWS credentials configured yet."
      echo "  Run: aws configure          # IAM access keys"
      echo "  Run: aws configure sso      # SSO"
    fi
    echo
    info "Config files: ~/.aws/credentials, ~/.aws/config"
  else
    warn "aws command not found on PATH."
    echo "Open a new terminal or check your install."
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║       macOS AWS CLI Installer            ║${NC}"
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

  install_aws_cli
  verify_install

  echo
  read -rp "Configure AWS CLI now? [y/N]: " configure_now
  configure_now="${configure_now:-N}"
  if [[ "$configure_now" =~ ^[Yy]$ ]]; then
    configure_aws_cli
    verify_install
  fi

  success "Done! AWS CLI is ready."
}

main "$@"
