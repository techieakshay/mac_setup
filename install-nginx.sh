#!/usr/bin/env bash
#
# Interactive nginx installer for macOS.
# Installs nginx via Homebrew and optionally starts it as a background service.
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

  header "Homebrew is required but not installed"
  read -rp "Install Homebrew now? [Y/n]: " answer
  answer="${answer:-Y}"
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    error "Homebrew is required. Run ./install-homebrew.sh or visit https://brew.sh"
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

nginx_installed() {
  command -v nginx &>/dev/null
}

nginx_prefix() {
  brew --prefix nginx 2>/dev/null || brew --prefix
}

nginx_config_dir() {
  echo "$(nginx_prefix)/etc/nginx"
}

nginx_running() {
  brew services list 2>/dev/null | grep -q '^nginx[[:space:]]*started' || pgrep -x nginx &>/dev/null
}

install_nginx() {
  ensure_homebrew
  info "Updating Homebrew formulae..."
  brew update --quiet 2>/dev/null || warn "brew update failed; continuing."

  header "Installing nginx"
  if nginx_installed && brew list nginx &>/dev/null; then
    info "nginx already installed — upgrading if needed..."
    brew upgrade nginx 2>/dev/null || brew install nginx
  else
    brew install nginx
  fi
  success "nginx installed."
}

configure_service() {
  header "Start nginx (optional)"

  if nginx_running; then
    success "nginx is already running."
    return 0
  fi

  echo "  1) Start as background service   (brew services start nginx)"
  echo "  2) Start in foreground (testing) (nginx)"
  echo "  3) Skip"
  echo

  local choice
  while true; do
    read -rp "Enter choice [1-3] (default: 3): " choice
    choice="${choice:-3}"

    case "$choice" in
      1)
        info "Starting nginx via Homebrew services..."
        brew services start nginx
        success "nginx started. It will restart automatically at login."
        return 0
        ;;
      2)
        header "Foreground nginx"
        info "Press Ctrl+C to stop."
        nginx
        return 0
        ;;
      3)
        info "Skipped starting nginx."
        return 0
        ;;
      *)
        warn "Invalid choice. Enter 1, 2, or 3."
        ;;
    esac
  done
}

print_next_steps() {
  local config_dir prefix
  config_dir="$(nginx_config_dir)"
  prefix="$(nginx_prefix)"

  cat <<EOF

${BOLD}Next steps:${NC}

  Config:     ${config_dir}/nginx.conf
  Sites:      ${config_dir}/servers/ (if present)
  Logs:       ${prefix}/var/log/nginx/
  Test config: nginx -t
  Reload:      nginx -s reload

  Homebrew nginx listens on port 8080 by default (port 80 requires sudo).
  Open: http://localhost:8080

  Start/stop:
    brew services start nginx
    brew services stop nginx
    brew services restart nginx

  Docs: https://nginx.org/en/docs/

EOF
}

verify_install() {
  header "Verification"

  if nginx_installed; then
    success "$(nginx -v 2>&1)"
    echo
    info "Binary: $(command -v nginx)"
    info "Config: $(nginx_config_dir)/nginx.conf"

    if nginx -t 2>/dev/null; then
      success "Configuration test passed."
    else
      warn "Configuration test failed. Check $(nginx_config_dir)/nginx.conf"
    fi

    if nginx_running; then
      success "nginx is running."
    else
      info "nginx is not running."
    fi
  else
    warn "nginx not found on PATH."
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║        macOS nginx Installer             ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"

  require_macos

  if nginx_installed; then
    success "nginx already installed: $(nginx -v 2>&1)"
    read -rp "Reinstall/upgrade anyway? [y/N]: " reinstall
    reinstall="${reinstall:-N}"
    if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
      verify_install
      read -rp "Start or configure nginx now? [y/N]: " configure_now
      configure_now="${configure_now:-N}"
      [[ "$configure_now" =~ ^[Yy]$ ]] && configure_service
      print_next_steps
      success "Done!"
      exit 0
    fi
  fi

  echo
  read -rp "Proceed with installation? [Y/n]: " confirm
  confirm="${confirm:-Y}"
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "Installation cancelled."
    exit 0
  fi

  install_nginx
  verify_install

  echo
  read -rp "Start nginx now? [y/N]: " configure_now
  configure_now="${configure_now:-N}"
  if [[ "$configure_now" =~ ^[Yy]$ ]]; then
    configure_service
    verify_install
  fi

  print_next_steps
  success "Done! nginx is ready."
}

main "$@"
