#!/usr/bin/env bash
#
# Interactive Java installer for macOS.
# Supports OpenJDK, Amazon Corretto, Eclipse Temurin, Azul Zulu, and Oracle JDK via Homebrew.
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

# ── Vendor definitions ────────────────────────────────────────────────────────
# id | display name | brew base formula | is_cask (0/1)
VENDORS=(
  "openjdk|OpenJDK (Homebrew)|openjdk|0"
  "corretto|Amazon Corretto|corretto|0"
  "temurin|Eclipse Temurin (Adoptium)|temurin|0"
  "zulu|Azul Zulu|zulu|0"
  "oracle|Oracle JDK|oracle-jdk|1"
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

  # Try known install locations before prompting
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
  echo "Java on macOS is best installed via Homebrew."
  echo
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
    info "Running install-homebrew.sh..."
    bash "$brew_script" --yes
  else
    info "Installing Homebrew (you may be prompted for your password)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -x /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
  fi

  if ! command -v brew &>/dev/null; then
    error "Homebrew installation finished but 'brew' is not in PATH."
    echo "Run ./install-homebrew.sh or add brew to your shell profile, then re-run."
    exit 1
  fi
  success "Homebrew installed."
}

fetch_adoptium_releases() {
  local json
  if ! json=$(curl -fsSL --connect-timeout 10 "https://api.adoptium.net/v3/info/available_releases" 2>/dev/null); then
    return 1
  fi
  # Parse available_releases array with basic tools (no jq dependency)
  echo "$json" | grep -oE '[0-9]+' | sort -un
}

fetch_brew_versions() {
  local base="$1"
  local versions=()

  # Unversioned "latest" formula
  if brew info --formula "$base" &>/dev/null; then
    versions+=("latest")
  fi

  # Versioned formulae like openjdk@21, temurin@17, etc.
  while IFS= read -r formula; do
    [[ -z "$formula" ]] && continue
    local ver="${formula#${base}@}"
    if [[ "$ver" != "$formula" && "$ver" =~ ^[0-9]+$ ]]; then
      versions+=("$ver")
    fi
  done < <(brew search --formula "^${base}@" 2>/dev/null || true)

  if [[ ${#versions[@]} -eq 0 ]]; then
    return 1
  fi

  # Sort numeric versions descending; keep "latest" first
  {
    echo "latest"
    printf '%s\n' "${versions[@]}" | grep -v '^latest$' | sort -rn
  } | awk '!seen[$0]++'
}

get_latest_lts() {
  local json lts
  json=$(curl -fsSL --connect-timeout 10 "https://api.adoptium.net/v3/info/available_releases" 2>/dev/null) || return 1
  lts=$(echo "$json" | grep -o '"most_recent_lts"[[:space:]]*:[[:space:]]*[0-9]*' | grep -oE '[0-9]+$')
  [[ -n "$lts" ]] && echo "$lts"
}

resolve_formula() {
  local base="$1" version="$2" is_cask="$3"

  if [[ "$is_cask" == "1" ]]; then
    echo "$base"
    return
  fi

  if [[ "$version" == "latest" ]]; then
    echo "$base"
  else
    echo "${base}@${version}"
  fi
}

formula_to_java_home() {
  local formula="$1"
  local prefix

  if brew info --cask "$formula" &>/dev/null 2>&1; then
    prefix=$(brew --prefix --cask "$formula" 2>/dev/null || true)
  else
    prefix=$(brew --prefix "$formula" 2>/dev/null || true)
  fi

  if [[ -z "$prefix" || ! -d "$prefix" ]]; then
    return 1
  fi

  # Homebrew openjdk layouts vary by version
  if [[ -d "${prefix}/libexec/openjdk.jdk/Contents/Home" ]]; then
    echo "${prefix}/libexec/openjdk.jdk/Contents/Home"
  elif [[ -d "${prefix}/Contents/Home" ]]; then
    echo "${prefix}/Contents/Home"
  else
    echo "$prefix"
  fi
}

print_java_home_snippet() {
  local java_home="$1"
  cat <<EOF

${BOLD}Add to your shell profile (~/.zshrc or ~/.bash_profile):${NC}

  export JAVA_HOME="${java_home}"
  export PATH="\$JAVA_HOME/bin:\$PATH"

Then run:  source ~/.zshrc   (or restart your terminal)

EOF
}

# ── Menus ─────────────────────────────────────────────────────────────────────
select_vendor() {
  header "Select Java distribution"
  local i=1
  local ids=() names=()

  for entry in "${VENDORS[@]}"; do
    IFS='|' read -r id name _ _ <<< "$entry"
    ids+=("$id")
    names+=("$name")
    echo "  ${i}) ${name}"
    ((i++)) || true
  done
  echo

  local choice
  while true; do
    read -rp "Enter choice [1-${#ids[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ids[@]} )); then
      SELECTED_VENDOR="${ids[$((choice-1))]}"
      SELECTED_VENDOR_NAME="${names[$((choice-1))]}"
      success "Selected: ${SELECTED_VENDOR_NAME}"
      return
    fi
    warn "Invalid choice. Enter a number between 1 and ${#ids[@]}."
  done
}

lookup_vendor() {
  local id="$1"
  for entry in "${VENDORS[@]}"; do
    IFS='|' read -r vid vname vbase vcask <<< "$entry"
    if [[ "$vid" == "$id" ]]; then
      VENDOR_BASE="$vbase"
      VENDOR_CASK="$vcask"
      return 0
    fi
  done
  return 1
}

select_version() {
  lookup_vendor "$SELECTED_VENDOR"

  header "Available versions — ${SELECTED_VENDOR_NAME}"
  info "Querying available versions..."

  local -a versions=()
  local adoptium_lts latest_lts=""

  latest_lts=$(get_latest_lts 2>/dev/null || true)
  [[ -n "$latest_lts" ]] && info "Latest LTS (industry): Java ${latest_lts}"

  if [[ "$VENDOR_CASK" == "1" ]]; then
    versions=("latest")
    echo "  Oracle JDK is installed as the latest release via Homebrew cask."
  else
    while IFS= read -r v; do
      [[ -n "$v" ]] && versions+=("$v")
    done < <(fetch_brew_versions "$VENDOR_BASE" 2>/dev/null || true)

    # Enrich with Adoptium releases if brew search returned little
    if [[ ${#versions[@]} -le 1 ]]; then
      while IFS= read -r v; do
        [[ -n "$v" ]] && versions+=("$v")
      done < <(fetch_adoptium_releases 2>/dev/null || true)
    fi

    # Deduplicate; keep "latest" first (if available), then numeric versions descending
    local -a sorted=() numeric=() has_latest=false
    for v in "${versions[@]}"; do
      if [[ "$v" == "latest" ]]; then
        has_latest=true
      elif [[ "$v" =~ ^[0-9]+$ ]]; then
        numeric+=("$v")
      fi
    done
    [[ "$has_latest" == true ]] && sorted+=("latest")
    while IFS= read -r v; do
      [[ -n "$v" ]] && sorted+=("$v")
    done < <(printf '%s\n' "${numeric[@]}" | sort -run | awk '!seen[$0]++')
    versions=("${sorted[@]}")
  fi

  if [[ ${#versions[@]} -eq 0 ]]; then
    error "Could not determine available versions for ${SELECTED_VENDOR_NAME}."
    echo "Try: brew search ${VENDOR_BASE}"
    exit 1
  fi

  local i=1
  for v in "${versions[@]}"; do
    local label="$v"
    if [[ "$v" == "latest" ]]; then
      label="latest (recommended)"
    elif [[ "$v" == "$latest_lts" ]]; then
      label="${v} (current LTS)"
    fi
    echo "  ${i}) Java ${label}"
    ((i++)) || true
  done
  echo

  local choice
  while true; do
    read -rp "Enter choice [1-${#versions[@]}] (default: 1): " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#versions[@]} )); then
      SELECTED_VERSION="${versions[$((choice-1))]}"
      success "Selected: Java ${SELECTED_VERSION}"
      return
    fi
    warn "Invalid choice."
  done
}

install_java() {
  lookup_vendor "$SELECTED_VENDOR"
  local formula
  formula=$(resolve_formula "$VENDOR_BASE" "$SELECTED_VERSION" "$VENDOR_CASK")

  header "Installing ${SELECTED_VENDOR_NAME} — Java ${SELECTED_VERSION}"
  info "Formula/cask: ${formula}"

  if [[ "$VENDOR_CASK" == "1" ]]; then
    info "Running: brew install --cask ${formula}"
    brew install --cask "$formula"
  else
    info "Running: brew install ${formula}"
    brew install "$formula"

    # Symlink unversioned openjdk for system-wide access (Homebrew recommendation)
    if [[ "$VENDOR_BASE" == "openjdk" || "$VENDOR_BASE" == "temurin" ]]; then
      info "Linking ${formula} for system Java wrappers..."
      brew link --overwrite "$formula" 2>/dev/null || warn "Could not link ${formula} (may already be linked)."
    fi
  fi

  success "Installation complete."
}

verify_install() {
  local formula
  lookup_vendor "$SELECTED_VENDOR"
  formula=$(resolve_formula "$VENDOR_BASE" "$SELECTED_VERSION" "$VENDOR_CASK")

  header "Verification"
  local java_home=""
  java_home=$(formula_to_java_home "$formula" 2>/dev/null || true)

  if [[ -n "$java_home" && -x "${java_home}/bin/java" ]]; then
    success "JAVA_HOME: ${java_home}"
    echo
    "${java_home}/bin/java" -version 2>&1 | sed 's/^/  /'
    print_java_home_snippet "$java_home"
  elif command -v java &>/dev/null; then
    success "java found on PATH:"
    java -version 2>&1 | sed 's/^/  /'
    if [[ -n "$java_home" ]]; then
      print_java_home_snippet "$java_home"
    fi
  else
    warn "java binary not found on PATH yet."
    if [[ -n "$java_home" ]]; then
      print_java_home_snippet "$java_home"
    else
      echo "Try: brew info ${formula}"
    fi
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║       macOS Java Installer               ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"

  require_macos
  ensure_homebrew

  info "Updating Homebrew formulae..."
  brew update --quiet 2>/dev/null || warn "brew update failed; continuing with cached formulae."

  select_vendor
  select_version

  echo
  read -rp "Proceed with installation? [Y/n]: " confirm
  confirm="${confirm:-Y}"
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "Installation cancelled."
    exit 0
  fi

  install_java
  verify_install

  success "Done! ${SELECTED_VENDOR_NAME} (Java ${SELECTED_VERSION}) is installed."
}

main "$@"

