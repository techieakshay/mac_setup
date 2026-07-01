#!/usr/bin/env bash
#
# Interactive pyenv + Python installer for macOS.
# Installs pyenv, configures shell PATH, and installs a selected Python version.
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

PYENV_ROOT="${PYENV_ROOT:-${HOME}/.pyenv}"
MAX_VERSIONS=20

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

pyenv_installed() {
  command -v pyenv &>/dev/null
}

load_pyenv() {
  export PYENV_ROOT
  export PATH="${PYENV_ROOT}/bin:${PATH}"
  if command -v pyenv &>/dev/null; then
    eval "$(pyenv init -)"
  fi
}

profile_has_pyenv() {
  local file="$1"
  [[ -f "$file" ]] && grep -Fq 'pyenv init' "$file"
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

configure_pyenv_path() {
  local profile updated=false block

  block=$(cat <<'EOF'

# pyenv (Python version manager)
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
EOF
)

  while IFS= read -r profile; do
    [[ -z "$profile" ]] && continue
    if profile_has_pyenv "$profile"; then
      info "pyenv already configured in ${profile}"
      continue
    fi
    info "Adding pyenv to ${profile}"
    printf '%s\n' "$block" >> "$profile"
    updated=true
  done < <(shell_profiles)

  if [[ "$updated" == true ]]; then
    success "Shell profile updated with PYENV_ROOT and PATH setup."
  else
    success "pyenv PATH configuration already present."
  fi
}

install_pyenv() {
  header "Installing pyenv"
  info "Installing build dependencies..."
  brew install pyenv openssl readline sqlite3 xz zlib 2>/dev/null || brew install pyenv
  success "pyenv installed: $(pyenv --version)"
}

fetch_python_versions() {
  load_pyenv 2>/dev/null || true

  if command -v pyenv &>/dev/null; then
    pyenv install --list 2>/dev/null \
      | grep -E '^[[:space:]]*3\.[0-9]+\.[0-9]+$' \
      | sed 's/^[[:space:]]*//' \
      | awk '!seen[$0]++' \
      | tail -n "$MAX_VERSIONS" \
      | tail -r
    return 0
  fi

  git ls-remote --tags https://github.com/python/cpython 2>/dev/null \
    | grep -oE 'refs/tags/v3\.[0-9]+\.[0-9]+$' \
    | sed 's|refs/tags/v||' \
    | awk '!seen[$0]++' \
    | tail -n "$MAX_VERSIONS" \
    | tail -r
}

normalize_python_version() {
  local v="$1"
  v="$(echo "$v" | xargs)"
  v="${v#v}"
  v="${v#python-}"
  echo "$v"
}

select_python_version() {
  header "Select Python version"
  info "Querying available versions (top ${MAX_VERSIONS})..."

  local -a versions=()
  while IFS= read -r v; do
    [[ -n "$v" ]] && versions+=("$v")
  done < <(fetch_python_versions 2>/dev/null || true)

  if [[ ${#versions[@]} -eq 0 ]]; then
    versions=("3.12.7" "3.11.10" "3.10.15")
    warn "Could not fetch version list — showing common defaults."
  fi

  local i=1
  for v in "${versions[@]}"; do
    echo "  ${i}) Python ${v}"
    ((i++)) || true
  done
  echo "  m) Enter version manually (e.g. 3.12.7, 3.11.9)"
  echo

  local choice
  while true; do
    read -rp "Enter choice [1-${#versions[@]}/m] (default: 1): " choice
    choice="${choice:-1}"

    if [[ "$choice" =~ ^[Mm]$ ]]; then
      read -rp "Enter Python version: " manual
      manual="$(normalize_python_version "$manual")"
      if [[ -z "$manual" ]]; then
        warn "Version cannot be empty."
        continue
      fi
      if [[ ! "$manual" =~ ^3\.[0-9]+\.[0-9]+([a-z0-9]+)?$ ]]; then
        warn "Expected format like 3.12.7 — continuing anyway."
      fi
      SELECTED_PYTHON_VERSION="$manual"
      success "Selected: Python ${SELECTED_PYTHON_VERSION}"
      return
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#versions[@]} )); then
      SELECTED_PYTHON_VERSION="${versions[$((choice-1))]}"
      success "Selected: Python ${SELECTED_PYTHON_VERSION}"
      return
    fi

    # Accept version string directly (e.g. 3.12.7)
    choice="$(normalize_python_version "$choice")"
    if [[ "$choice" =~ ^3\.[0-9] ]]; then
      SELECTED_PYTHON_VERSION="$choice"
      success "Selected: Python ${SELECTED_PYTHON_VERSION}"
      return
    fi

    warn "Invalid choice. Enter 1-${#versions[@]}, m, or a version like 3.12.7."
  done
}

install_python() {
  header "Installing Python ${SELECTED_PYTHON_VERSION}"
  load_pyenv

  if ! command -v pyenv &>/dev/null; then
    error "pyenv command not available in this shell."
    exit 1
  fi

  info "Running: pyenv install ${SELECTED_PYTHON_VERSION}"
  info "This may take a few minutes (compiles from source)..."
  pyenv install -s "$SELECTED_PYTHON_VERSION"

  info "Setting global Python version..."
  pyenv global "$SELECTED_PYTHON_VERSION"
  pyenv rehash

  success "Python installation complete."
}

verify_install() {
  header "Verification"
  load_pyenv

  if command -v pyenv &>/dev/null; then
    success "pyenv: $(pyenv --version)"
  else
    warn "pyenv not loaded — open a new terminal or run: source ~/.zshrc"
  fi

  if command -v python &>/dev/null; then
    success "python: $(python --version 2>&1)"
    command -v pip &>/dev/null && success "pip:    $(pip --version 2>&1 | head -1)"
    echo
    info "Python binary: $(command -v python)"
  else
    warn "python not found on PATH in this shell."
  fi

  echo
  info "PYENV_ROOT: ${PYENV_ROOT}"
  echo
  info "If pyenv/python are not available yet, run:"
  echo "  source ~/.zprofile && source ~/.zshrc"
  echo "  # or open a new terminal window"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║    macOS pyenv + Python Installer        ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"

  require_macos
  ensure_homebrew

  info "Updating Homebrew formulae..."
  brew update --quiet 2>/dev/null || warn "brew update failed; continuing."

  if pyenv_installed; then
    success "pyenv already installed: $(pyenv --version 2>/dev/null || echo unknown)"
  else
    echo
    read -rp "Install pyenv? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      info "Installation cancelled."
      exit 0
    fi
    install_pyenv
  fi

  configure_pyenv_path
  load_pyenv

  select_python_version

  echo
  read -rp "Proceed with Python installation? [Y/n]: " confirm
  confirm="${confirm:-Y}"
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "Python installation skipped. pyenv is configured — run 'pyenv install <version>' later."
    verify_install
    exit 0
  fi

  install_python
  verify_install

  success "Done! pyenv and Python ${SELECTED_PYTHON_VERSION} are installed."
}

main "$@"
