#!/usr/bin/env bash
#
# Interactive nvm + Node.js installer for macOS.
# Installs nvm, configures shell PATH, and installs a selected Node version.
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

NVM_DIR="${NVM_DIR:-${HOME}/.nvm}"
MAX_VERSIONS=20

# ── Helpers ───────────────────────────────────────────────────────────────────
require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    error "This script is intended for macOS only."
    exit 1
  fi
}

require_dependencies() {
  local missing=()
  for cmd in curl git; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    success "Dependencies found: curl, git"
    return 0
  fi

  warn "Missing: ${missing[*]}"
  if ! xcode-select -p &>/dev/null; then
    header "Xcode Command Line Tools required"
    read -rp "Install Command Line Tools now? [Y/n]: " answer
    answer="${answer:-Y}"
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      xcode-select --install || true
      info "Complete the GUI installer, then press Enter to continue."
      read -r
    fi
  fi

  for cmd in curl git; do
    command -v "$cmd" &>/dev/null || {
      error "'${cmd}' is required. Install Xcode Command Line Tools: xcode-select --install"
      exit 1
    }
  done
}

fetch_nvm_version() {
  curl -fsSL --connect-timeout 10 \
    "https://api.github.com/repos/nvm-sh/nvm/releases/latest" \
    | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"v[^"]*"' \
    | grep -o 'v[0-9.]*' \
    | head -1
}

nvm_installed() {
  [[ -s "${NVM_DIR}/nvm.sh" ]]
}

load_nvm() {
  export NVM_DIR
  # shellcheck disable=SC1091
  [[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"
}

profile_has_nvm() {
  local file="$1"
  [[ -f "$file" ]] && grep -Fq 'NVM_DIR' "$file" && grep -Fq 'nvm.sh' "$file"
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

configure_nvm_path() {
  local profile updated=false block

  block=$(cat <<'EOF'

# nvm (Node Version Manager)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
EOF
)

  while IFS= read -r profile; do
    [[ -z "$profile" ]] && continue
    if profile_has_nvm "$profile"; then
      info "nvm already configured in ${profile}"
      continue
    fi
    info "Adding nvm to ${profile}"
    printf '%s\n' "$block" >> "$profile"
    updated=true
  done < <(shell_profiles)

  if [[ "$updated" == true ]]; then
    success "Shell profile updated with NVM_DIR and PATH setup."
  else
    success "nvm PATH configuration already present."
  fi
}

install_nvm() {
  local nvm_version install_url
  nvm_version=$(fetch_nvm_version 2>/dev/null || echo "v0.40.5")
  install_url="https://raw.githubusercontent.com/nvm-sh/nvm/${nvm_version}/install.sh"

  header "Installing nvm ${nvm_version}"
  info "URL: ${install_url}"

  export NVM_DIR
  curl -fsSL "$install_url" | bash

  if ! nvm_installed; then
    error "nvm installation failed — ${NVM_DIR}/nvm.sh not found."
    exit 1
  fi
  success "nvm installed to ${NVM_DIR}"
}

fetch_node_versions() {
  local json
  if ! json=$(curl -fsSL --connect-timeout 10 "https://nodejs.org/dist/index.json" 2>/dev/null); then
    return 1
  fi

  if command -v python3 &>/dev/null; then
    printf '%s' "$json" | python3 -c '
import json, sys
limit = int(sys.argv[1])
data = json.load(sys.stdin)
for item in data[:limit]:
    version = item["version"].lstrip("v")
    lts = item.get("lts")
    if lts and lts is not True:
        print(f"{version}\t{lts}")
    elif lts:
        print(f"{version}\tLTS")
    else:
        print(version)
' "$MAX_VERSIONS"
    return 0
  fi

  echo "$json" \
    | grep -o '"version":"v[^"]*"' \
    | sed 's/"version":"v//;s/"//' \
    | head -n "$MAX_VERSIONS"
}

select_node_version() {
  header "Select Node.js version"
  info "Querying available versions (top ${MAX_VERSIONS})..."

  local -a versions=() lts_labels=()
  local line version lts

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == *$'\t'* ]]; then
      version="${line%%$'\t'*}"
      lts="${line#*$'\t'}"
    else
      version="$line"
      lts=""
    fi
    versions+=("$version")
    lts_labels+=("$lts")
  done < <(fetch_node_versions 2>/dev/null || true)

  if [[ ${#versions[@]} -eq 0 ]]; then
    versions=("lts/*" "node")
    lts_labels=("recommended LTS" "latest release")
    warn "Could not fetch version list — showing nvm defaults."
  fi

  local i=1
  for idx in "${!versions[@]}"; do
    local label="${versions[$idx]}"
    if [[ -n "${lts_labels[$idx]:-}" && "${lts_labels[$idx]}" != "False" && "${lts_labels[$idx]}" != "false" ]]; then
      label="${label} (LTS: ${lts_labels[$idx]})"
    fi
    echo "  ${i}) Node ${label}"
    ((i++)) || true
  done
  echo "  m) Enter version manually (e.g. 22.14.0, lts/*, v20.11.0)"
  echo

  local choice
  while true; do
    read -rp "Enter choice [1-${#versions[@]}/m] (default: 1): " choice
    choice="${choice:-1}"

    if [[ "$choice" =~ ^[Mm]$ ]]; then
      read -rp "Enter Node.js version: " manual
      manual="$(echo "$manual" | xargs)"
      if [[ -z "$manual" ]]; then
        warn "Version cannot be empty."
        continue
      fi
      manual="${manual#v}"
      SELECTED_NODE_VERSION="$manual"
      success "Selected: Node ${SELECTED_NODE_VERSION}"
      return
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#versions[@]} )); then
      SELECTED_NODE_VERSION="${versions[$((choice-1))]}"
      success "Selected: Node ${SELECTED_NODE_VERSION}"
      return
    fi

    # Accept a version string directly (e.g. 20.11.0, lts/iron)
    if [[ "$choice" =~ [0-9] || "$choice" == lts/* || "$choice" == node ]]; then
      choice="${choice#v}"
      SELECTED_NODE_VERSION="$choice"
      success "Selected: Node ${SELECTED_NODE_VERSION}"
      return
    fi

    warn "Invalid choice. Enter 1-${#versions[@]}, m, or a version string."
  done
}

install_node() {
  header "Installing Node.js ${SELECTED_NODE_VERSION}"
  load_nvm

  if ! command -v nvm &>/dev/null; then
    error "nvm command not available in this shell."
    exit 1
  fi

  info "Running: nvm install ${SELECTED_NODE_VERSION}"
  nvm install "$SELECTED_NODE_VERSION"

  info "Setting default Node version..."
  nvm alias default "$SELECTED_NODE_VERSION"
  nvm use default

  success "Node.js installation complete."
}

verify_install() {
  header "Verification"
  load_nvm

  if command -v nvm &>/dev/null; then
    success "nvm: $(nvm --version)"
  else
    warn "nvm not loaded in this shell — open a new terminal or run: source ~/.zshrc"
  fi

  if command -v node &>/dev/null; then
    success "node: $(node --version)"
    success "npm:  $(npm --version)"
    echo
    info "Node binary: $(command -v node)"
  else
    warn "node not found on PATH in this shell."
  fi

  echo
  info "NVM_DIR: ${NVM_DIR}"
  echo
  info "If nvm/node are not available yet, run:"
  echo "  source ~/.zprofile && source ~/.zshrc"
  echo "  # or open a new terminal window"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║     macOS nvm + Node.js Installer        ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"

  require_macos
  require_dependencies

  if nvm_installed; then
    success "nvm already installed at ${NVM_DIR}"
    load_nvm
    info "Current nvm version: $(nvm --version 2>/dev/null || echo unknown)"
  else
    echo
    read -rp "Install nvm? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      info "Installation cancelled."
      exit 0
    fi
    install_nvm
  fi

  configure_nvm_path
  load_nvm

  select_node_version

  echo
  read -rp "Proceed with Node.js installation? [Y/n]: " confirm
  confirm="${confirm:-Y}"
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "Node installation skipped. nvm is configured — run 'nvm install <version>' later."
    verify_install
    exit 0
  fi

  install_node
  verify_install

  success "Done! nvm and Node ${SELECTED_NODE_VERSION} are installed."
}

main "$@"
