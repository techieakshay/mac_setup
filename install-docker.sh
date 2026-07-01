#!/usr/bin/env bash
#
# Interactive Docker installer for macOS.
# Installs Docker Desktop or Colima + Docker CLI; optionally verifies with hello-world.
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

SOURCES=(
  "desktop|Docker Desktop (recommended)|desktop"
  "colima|Colima + Docker CLI (lightweight)|colima"
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

docker_cli_installed() {
  command -v docker &>/dev/null
}

docker_daemon_running() {
  docker info &>/dev/null 2>&1
}

select_source() {
  header "Select Docker install source"
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

install_docker_desktop() {
  ensure_homebrew
  info "Updating Homebrew..."
  brew update --quiet 2>/dev/null || warn "brew update failed; continuing."

  header "Installing Docker Desktop"
  if brew list --cask docker &>/dev/null 2>&1; then
    brew upgrade --cask docker 2>/dev/null || true
  else
    brew install --cask docker
  fi
  success "Docker Desktop installed."
}

install_colima() {
  ensure_homebrew
  info "Updating Homebrew..."
  brew update --quiet 2>/dev/null || warn "brew update failed; continuing."

  header "Installing Colima + Docker CLI"
  brew install colima docker docker-compose
  success "Colima and Docker CLI installed."
}

install_docker() {
  if docker_cli_installed; then
    success "Docker CLI found: $(docker --version 2>&1 | head -1)"
    read -rp "Reinstall/upgrade anyway? [y/N]: " reinstall
    reinstall="${reinstall:-N}"
    if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
      return 0
    fi
  fi

  case "$SELECTED_SOURCE" in
    desktop) install_docker_desktop ;;
    colima) install_colima ;;
    *) error "Unknown source: ${SELECTED_SOURCE}"; exit 1 ;;
  esac
}

start_docker() {
  header "Starting Docker"

  if [[ "$SELECTED_SOURCE" == "desktop" ]]; then
    if docker_daemon_running; then
      success "Docker daemon is already running."
      return 0
    fi

    info "Launching Docker Desktop..."
    open -a Docker 2>/dev/null || open -a "Docker Desktop" 2>/dev/null || {
      warn "Could not open Docker Desktop automatically."
      info "Open Docker Desktop from Applications, then re-run: docker info"
      return 1
    }

    info "Waiting for Docker daemon to start (up to 90s)..."
    local i
    for (( i=1; i<=45; i++ )); do
      if docker_daemon_running; then
        success "Docker daemon is running."
        return 0
      fi
      sleep 2
    done
    warn "Docker daemon did not start in time. Open Docker Desktop manually."
    return 1
  fi

  if [[ "$SELECTED_SOURCE" == "colima" ]]; then
    if docker_daemon_running; then
      success "Docker daemon is already running."
      return 0
    fi

    info "Starting Colima..."
    colima start

    if docker_daemon_running; then
      success "Colima is running."
    else
      warn "Colima started but docker info failed. Try: colima status"
      return 1
    fi
  fi
}

configure_docker() {
  header "Configure Docker (optional)"
  echo "  1) Start Docker daemon"
  echo "  2) Run test container (hello-world)"
  echo "  3) Start daemon + run hello-world"
  echo "  4) Skip configuration"
  echo

  local choice
  while true; do
    read -rp "Enter choice [1-4] (default: 3): " choice
    choice="${choice:-3}"
    case "$choice" in
      1)
        start_docker
        return
        ;;
      2)
        if ! docker_daemon_running; then
          warn "Docker daemon is not running. Start it first (option 1 or 3)."
          return 1
        fi
        info "Running: docker run hello-world"
        docker run --rm hello-world
        success "Docker test container ran successfully."
        return
        ;;
      3)
        start_docker || return 1
        if docker_daemon_running; then
          info "Running: docker run hello-world"
          docker run --rm hello-world
          success "Docker is configured and working."
        fi
        return
        ;;
      4)
        info "Skipped configuration."
        print_docker_next_steps
        return
        ;;
      *)
        warn "Invalid choice. Enter 1-4."
        ;;
    esac
  done
}

print_docker_next_steps() {
  cat <<EOF

${BOLD}Next steps:${NC}

EOF
  if [[ "$SELECTED_SOURCE" == "desktop" ]]; then
    cat <<EOF
  • Open Docker Desktop from Applications
  • Verify: docker info
  • Test:   docker run hello-world

EOF
  else
    cat <<EOF
  • Start:  colima start
  • Stop:   colima stop
  • Verify: docker info
  • Test:   docker run hello-world

EOF
  fi
}

verify_install() {
  header "Verification"

  if docker_cli_installed; then
    success "$(docker --version 2>&1 | head -1)"
    docker compose version &>/dev/null && success "$(docker compose version 2>&1 | head -1)"
    echo
    info "Docker binary: $(command -v docker)"
  else
    warn "docker CLI not found on PATH."
  fi

  if docker_daemon_running; then
    success "Docker daemon is running."
    docker info 2>/dev/null | grep -E 'Server Version|Operating System|CPUs|Total Memory' | sed 's/^/  /' || true
  else
    warn "Docker daemon is not running."
    print_docker_next_steps
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║        macOS Docker Installer              ║${NC}"
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

  install_docker
  verify_install

  echo
  read -rp "Configure Docker now (start daemon / test)? [Y/n]: " configure_now
  configure_now="${configure_now:-Y}"
  if [[ "$configure_now" =~ ^[Yy]$ ]]; then
    configure_docker
    verify_install
  fi

  success "Done! Docker is installed."
}

main "$@"
