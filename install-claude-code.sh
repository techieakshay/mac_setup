#!/usr/bin/env bash
#
# Interactive Claude Code installer for macOS.
# Installs Claude Code and configures PATH; optionally runs doctor and login.
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
  "native|Native installer (recommended, auto-updates)|native"
  "brew-stable|Homebrew — stable channel|brew-stable"
  "brew-latest|Homebrew — latest channel|brew-latest"
  "npm|npm global (requires Node.js)|npm"
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

  header "Homebrew is required for this install method"
  read -rp "Install Homebrew now? [Y/n]: " answer
  answer="${answer:-Y}"
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    error "Homebrew is required. Run ./install-homebrew.sh or use the native installer."
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

ensure_node() {
  if command -v node &>/dev/null && command -v npm &>/dev/null; then
    success "Node.js found: $(node --version)"
    return 0
  fi

  warn "Node.js is required for npm install."
  read -rp "Install Node.js via install-nvm.sh? [Y/n]: " answer
  answer="${answer:-Y}"
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    error "Node.js is required. Run ./install-nvm.sh or use the native installer."
    exit 1
  fi

  local script_dir nvm_script
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  nvm_script="${script_dir}/install-nvm.sh"

  if [[ -f "$nvm_script" ]]; then
    bash "$nvm_script"
  else
    error "install-nvm.sh not found. Install Node.js manually."
    exit 1
  fi

  export NVM_DIR="${NVM_DIR:-${HOME}/.nvm}"
  # shellcheck disable=SC1091
  [[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"

  if ! command -v npm &>/dev/null; then
    error "npm still not found after Node install. Open a new terminal and re-run."
    exit 1
  fi
}

claude_installed() {
  command -v claude &>/dev/null
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

find_claude_bin_dir() {
  local dir
  if command -v claude &>/dev/null; then
    dir="$(dirname "$(command -v claude)")"
    echo "$dir"
    return 0
  fi

  local candidates=(
    "${HOME}/.local/bin"
    "${HOME}/.claude/bin"
    "/opt/homebrew/bin"
    "/usr/local/bin"
  )
  for dir in "${candidates[@]}"; do
    if [[ -x "${dir}/claude" ]]; then
      echo "$dir"
      return 0
    fi
  done
  return 1
}

profile_has_path_entry() {
  local file="$1" dir="$2"
  [[ -f "$file" ]] && grep -Fq "$dir" "$file"
}

configure_claude_path() {
  local bin_dir
  bin_dir="$(find_claude_bin_dir 2>/dev/null || true)"
  if [[ -z "$bin_dir" ]]; then
    warn "Could not locate claude binary to configure PATH."
    return 1
  fi

  if [[ ":${PATH}:" == *":${bin_dir}:"* ]]; then
    success "Claude Code already on PATH: ${bin_dir}"
    return 0
  fi

  local profile updated=false block
  block=$(cat <<EOF

# Claude Code
export PATH="${bin_dir}:\$PATH"
EOF
)

  while IFS= read -r profile; do
    [[ -z "$profile" ]] && continue
    if profile_has_path_entry "$profile" "$bin_dir"; then
      info "PATH already configured in ${profile}"
      continue
    fi
    info "Adding Claude Code to PATH in ${profile}"
    printf '%s\n' "$block" >> "$profile"
    updated=true
  done < <(shell_profiles)

  export PATH="${bin_dir}:${PATH}"

  if [[ "$updated" == true ]]; then
    success "Shell profile updated — ${bin_dir} added to PATH."
  fi
}

select_source() {
  header "Select Claude Code install method"
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

select_native_channel() {
  header "Native installer channel"
  echo "  1) latest  (default — newest features)"
  echo "  2) stable  (~1 week behind, fewer regressions)"
  echo "  m) Enter version manually (e.g. 2.1.89)"
  echo

  local choice
  while true; do
    read -rp "Enter choice [1/2/m] (default: 1): " choice
    choice="${choice:-1}"
    case "$choice" in
      1) NATIVE_CHANNEL="latest"; success "Channel: latest"; return ;;
      2) NATIVE_CHANNEL="stable"; success "Channel: stable"; return ;;
      [Mm])
        read -rp "Enter version: " manual
        manual="$(echo "$manual" | xargs)"
        [[ -z "$manual" ]] && { warn "Version cannot be empty."; continue; }
        NATIVE_CHANNEL="$manual"
        success "Version: ${NATIVE_CHANNEL}"
        return
        ;;
      *)
        warn "Invalid choice."
        ;;
    esac
  done
}

install_claude_native() {
  select_native_channel

  header "Installing Claude Code (native)"
  info "Official installer from https://claude.ai/install.sh"

  if [[ "$NATIVE_CHANNEL" == "latest" ]]; then
    curl -fsSL https://claude.ai/install.sh | bash
  else
    curl -fsSL https://claude.ai/install.sh | bash -s "$NATIVE_CHANNEL"
  fi

  success "Native installation complete."
}

install_claude_brew() {
  local cask="claude-code"
  [[ "$SELECTED_SOURCE" == "brew-latest" ]] && cask="claude-code@latest"

  ensure_homebrew
  info "Updating Homebrew..."
  brew update --quiet 2>/dev/null || warn "brew update failed; continuing."

  header "Installing Claude Code (${cask})"
  if brew list --cask "$cask" &>/dev/null 2>&1; then
    brew upgrade --cask "$cask" 2>/dev/null || true
  else
    brew install --cask "$cask"
  fi
  success "Claude Code installed via Homebrew."
}

install_claude_npm() {
  ensure_node

  header "Installing Claude Code (npm)"
  warn "Do not use sudo with npm install."

  info "Running: npm install -g @anthropic-ai/claude-code@latest"
  npm install -g @anthropic-ai/claude-code@latest

  # Ensure npm global bin is on PATH
  local npm_prefix npm_bin
  npm_prefix="$(npm config get prefix 2>/dev/null || echo "${HOME}/.npm-global")"
  npm_bin="${npm_prefix}/bin"

  if [[ -d "$npm_bin" && ":${PATH}:" != *":${npm_bin}:"* ]]; then
    local profile
    while IFS= read -r profile; do
      if [[ -f "$profile" ]] && ! grep -Fq "$npm_bin" "$profile"; then
        info "Adding npm global bin to ${profile}"
        printf '\n# npm global\nexport PATH="%s:$PATH"\n' "$npm_bin" >> "$profile"
      fi
    done < <(shell_profiles)
    export PATH="${npm_bin}:${PATH}"
  fi

  success "Claude Code installed via npm."
}

install_claude_code() {
  if claude_installed; then
    success "Claude Code already installed: $(claude --version 2>&1 | head -1)"
    read -rp "Reinstall/upgrade anyway? [y/N]: " reinstall
    reinstall="${reinstall:-N}"
    if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
      return 0
    fi
  fi

  case "$SELECTED_SOURCE" in
    native) install_claude_native ;;
    brew-stable|brew-latest) install_claude_brew ;;
    npm) install_claude_npm ;;
    *) error "Unknown source: ${SELECTED_SOURCE}"; exit 1 ;;
  esac
}

configure_claude_code() {
  header "Configure Claude Code (optional)"
  echo "  1) Run claude doctor (check install + config)"
  echo "  2) Log in / authenticate (opens browser)"
  echo "  3) Doctor + login"
  echo "  4) Skip configuration"
  echo
  info "Requires a Claude Pro, Max, Team, Enterprise, or Console account."

  local choice
  while true; do
    read -rp "Enter choice [1-4] (default: 3): " choice
    choice="${choice:-3}"
    case "$choice" in
      1)
        claude doctor || warn "claude doctor reported issues — see output above."
        return
        ;;
      2)
        header "Claude Code login"
        info "A browser window will open to authenticate."
        info "Press Ctrl+C to cancel if needed."
        claude || warn "Login may not have completed."
        return
        ;;
      3)
        claude doctor || true
        echo
        header "Claude Code login"
        info "A browser window will open to authenticate."
        claude || warn "Login may not have completed."
        return
        ;;
      4)
        info "Skipped configuration."
        print_claude_next_steps
        return
        ;;
      *)
        warn "Invalid choice. Enter 1-4."
        ;;
    esac
  done
}

print_claude_next_steps() {
  cat <<EOF

${BOLD}Next steps:${NC}

  • Verify:  claude --version
  • Health:  claude doctor
  • Login:   claude          (browser auth — Pro/Max/Team/Enterprise/Console)
  • Start:   cd your-project && claude
  • Update:  claude update   (native install auto-updates in background)

  Docs: https://code.claude.com/docs/en/setup

EOF
}

verify_install() {
  header "Verification"

  configure_claude_path || true

  if claude_installed; then
    success "$(claude --version 2>&1 | head -1)"
    echo
    info "Binary: $(command -v claude)"
    claude doctor 2>/dev/null | head -15 | sed 's/^/  /' || true
  else
    warn "claude not found on PATH."
    info "Open a new terminal or run: source ~/.zshrc"
    print_claude_next_steps
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║      macOS Claude Code Installer         ║${NC}"
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

  install_claude_code
  verify_install

  echo
  read -rp "Configure Claude Code now (doctor / login)? [Y/n]: " configure_now
  configure_now="${configure_now:-Y}"
  if [[ "$configure_now" =~ ^[Yy]$ ]]; then
    configure_claude_code
    verify_install
  fi

  success "Done! Claude Code is installed."
}

main "$@"
