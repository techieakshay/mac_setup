#!/usr/bin/env bash
#
# Interactive cloudflared installer for macOS.
# Installs cloudflared via Homebrew and optionally sets up a Cloudflare Tunnel.
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

CLOUDFLARED_DIR="${HOME}/.cloudflared"

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

cloudflared_installed() {
  command -v cloudflared &>/dev/null
}

install_cloudflared() {
  ensure_homebrew
  info "Updating Homebrew formulae..."
  brew update --quiet 2>/dev/null || warn "brew update failed; continuing."

  header "Installing cloudflared"
  if cloudflared_installed && brew list cloudflared &>/dev/null; then
    info "cloudflared already installed — upgrading if needed..."
    brew upgrade cloudflared 2>/dev/null || brew install cloudflared
  else
    brew install cloudflared
  fi
  success "cloudflared installed."
}

tunnel_logged_in() {
  [[ -f "${CLOUDFLARED_DIR}/cert.pem" ]]
}

configure_tunnel() {
  header "Configure Cloudflare Tunnel (optional)"

  mkdir -p "$CLOUDFLARED_DIR"

  echo "  1) Login to Cloudflare          (cloudflared tunnel login)"
  echo "  2) Create a named tunnel        (cloudflared tunnel create)"
  echo "  3) List existing tunnels"
  echo "  4) Run quick tunnel (try/test)  (cloudflared tunnel --url http://localhost:8080)"
  echo "  5) Skip configuration"
  echo

  local choice
  while true; do
    read -rp "Enter choice [1-5] (default: 5): " choice
    choice="${choice:-5}"

    case "$choice" in
      1)
        header "Cloudflare login"
        info "A browser window will open to authenticate with Cloudflare."
        cloudflared tunnel login
        if tunnel_logged_in; then
          success "Logged in — certificate saved to ${CLOUDFLARED_DIR}/cert.pem"
        else
          warn "Login may not have completed. cert.pem not found."
        fi
        ;;
      2)
        if ! tunnel_logged_in; then
          warn "Not logged in yet. Run option 1 first."
          continue
        fi
        local tunnel_name
        read -rp "Enter tunnel name: " tunnel_name
        tunnel_name="$(echo "$tunnel_name" | xargs)"
        if [[ -z "$tunnel_name" ]]; then
          warn "Tunnel name cannot be empty."
          continue
        fi
        info "Creating tunnel: ${tunnel_name}"
        cloudflared tunnel create "$tunnel_name"
        success "Tunnel '${tunnel_name}' created."
        print_tunnel_next_steps "$tunnel_name"
        return
        ;;
      3)
        header "Existing tunnels"
        cloudflared tunnel list 2>/dev/null || warn "No tunnels found or not logged in."
        ;;
      4)
        local port
        read -rp "Local URL port [8080]: " port
        port="${port:-8080}"
        header "Quick tunnel"
        info "Starting temporary tunnel to http://localhost:${port}"
        warn "Press Ctrl+C to stop. This is for testing only."
        cloudflared tunnel --url "http://localhost:${port}"
        return
        ;;
      5)
        info "Skipped tunnel configuration."
        print_tunnel_next_steps
        return
        ;;
      *)
        warn "Invalid choice. Enter 1-5."
        ;;
    esac

    echo
    read -rp "Configure something else? [y/N]: " again
    again="${again:-N}"
    if [[ ! "$again" =~ ^[Yy]$ ]]; then
      print_tunnel_next_steps
      return
    fi
    echo
    echo "  1) Login to Cloudflare"
    echo "  2) Create a named tunnel"
    echo "  3) List existing tunnels"
    echo "  4) Run quick tunnel (try/test)"
    echo "  5) Skip / done"
    echo
  done
}

print_tunnel_next_steps() {
  local tunnel_name="${1:-}"
  cat <<EOF

${BOLD}Next steps:${NC}

  Config directory: ${CLOUDFLARED_DIR}

  1. Create ~/.cloudflared/config.yml with ingress rules, e.g.:

     tunnel: ${tunnel_name:-<tunnel-name>}
     credentials-file: ${CLOUDFLARED_DIR}/${tunnel_name:-<tunnel-id>}.json

     ingress:
       - hostname: app.example.com
         service: http://localhost:8080
       - service: http_status:404

  2. Route DNS:  cloudflared tunnel route dns ${tunnel_name:-<tunnel-name>} app.example.com
  3. Run tunnel: cloudflared tunnel run ${tunnel_name:-<tunnel-name>}

  Docs: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/

EOF
}

verify_install() {
  header "Verification"

  if cloudflared_installed; then
    success "$(cloudflared --version 2>&1 | head -1)"
    echo
    info "Binary: $(command -v cloudflared)"
    info "Config: ${CLOUDFLARED_DIR}/"

    if tunnel_logged_in; then
      success "Cloudflare login certificate found."
    fi

    if cloudflared tunnel list &>/dev/null 2>&1; then
      echo
      info "Tunnels:"
      cloudflared tunnel list 2>/dev/null | sed 's/^/  /' || true
    fi
  else
    warn "cloudflared not found on PATH."
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║     macOS cloudflared Installer          ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"

  require_macos

  if cloudflared_installed; then
    success "cloudflared already installed: $(cloudflared --version 2>&1 | head -1)"
    read -rp "Reinstall/upgrade anyway? [y/N]: " reinstall
    reinstall="${reinstall:-N}"
    if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
      verify_install
      read -rp "Configure tunnel now? [y/N]: " configure_now
      configure_now="${configure_now:-N}"
      [[ "$configure_now" =~ ^[Yy]$ ]] && configure_tunnel
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

  install_cloudflared
  verify_install

  echo
  read -rp "Configure Cloudflare Tunnel now? [y/N]: " configure_now
  configure_now="${configure_now:-N}"
  if [[ "$configure_now" =~ ^[Yy]$ ]]; then
    configure_tunnel
    verify_install
  fi

  success "Done! cloudflared is ready."
}

main "$@"
