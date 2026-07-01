#!/usr/bin/env bash
#
# Interactive Maven installer for macOS.
# Supports Apache Maven and Maven Daemon (mvnd) via Homebrew.
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

# id | display name | brew base formula | is_cask (0/1)
VENDORS=(
  "maven|Apache Maven|maven|0"
  "mvnd|Maven Daemon (mvnd)|mvnd|0"
)

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
  echo "Maven on macOS is best installed via Homebrew."
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

check_java() {
  if command -v java &>/dev/null; then
    success "Java found: $(java -version 2>&1 | head -1)"
    return 0
  fi

  warn "Java was not found on PATH. Maven requires a JDK to run."
  echo
  read -rp "Install Java first? [Y/n]: " answer
  answer="${answer:-Y}"
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    local script_dir java_script
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    java_script="${script_dir}/install-java.sh"
    if [[ -f "$java_script" ]]; then
      bash "$java_script"
    else
      error "install-java.sh not found. Install Java manually, then re-run."
      exit 1
    fi
  else
    warn "Continuing without Java — Maven will not work until a JDK is installed."
  fi
}

fetch_maven_releases() {
  local xml
  if ! xml=$(curl -fsSL --connect-timeout 10 \
    "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/maven-metadata.xml" 2>/dev/null); then
    return 1
  fi

  # Stable releases only (exclude alpha, beta, rc, milestones)
  echo "$xml" \
    | grep -o '<version>[^<]*</version>' \
    | sed 's/<[^>]*>//g' \
    | grep -viE 'alpha|beta|rc|M[0-9]' \
    | awk '!seen[$0]++' \
    | tail -r
}

fetch_maven_latest() {
  fetch_maven_releases | head -1
}

brew_has_formula() {
  local formula="$1"
  brew info --formula "$formula" &>/dev/null
}

fetch_brew_versions() {
  local base="$1"
  local versions=()

  if brew info --formula "$base" &>/dev/null; then
    versions+=("latest")
  fi

  while IFS= read -r formula; do
    [[ -z "$formula" ]] && continue
    local ver="${formula#${base}@}"
    if [[ "$ver" != "$formula" && "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
      versions+=("$ver")
    fi
  done < <(brew search --formula "^${base}@" 2>/dev/null || true)

  if [[ ${#versions[@]} -eq 0 ]]; then
    return 1
  fi

  {
    echo "latest"
    printf '%s\n' "${versions[@]}" | grep -v '^latest$'
  } | awk '!seen[$0]++'
}


resolve_formula() {
  local base="$1" version="$2"

  if [[ "$version" == "latest" ]]; then
    echo "$base"
    return
  fi

  # Homebrew may expose major.minor pins like maven@3.9
  local major_minor="${version%.*}"
  for candidate in "${base}@${version}" "${base}@${major_minor}"; do
    if brew_has_formula "$candidate"; then
      echo "$candidate"
      return
    fi
  done

  echo "$base"
}

maven_download_url() {
  local version="$1"
  local major="${version%%.*}"
  local filename="apache-maven-${version}-bin.tar.gz"
  local base="https://dlcdn.apache.org/maven/maven-${major}/${version}/binaries/${filename}"
  echo "$base"
}

maven_install_dir() {
  local version="$1"
  echo "${HOME}/.local/share/maven/apache-maven-${version}"
}

install_maven_from_apache() {
  local version="$1"
  local url archive tmpdir dest home
  url="$(maven_download_url "$version")"
  archive="/tmp/apache-maven-${version}-bin.tar.gz"
  dest="$(maven_install_dir "$version")"

  info "Downloading Maven ${version} from Apache..."
  info "URL: ${url}"

  if ! curl -fsSL --connect-timeout 30 -o "$archive" "$url"; then
    # Older releases may only be on archive.apache.org
    url="https://archive.apache.org/dist/maven/maven-${version%%.*}/${version}/binaries/apache-maven-${version}-bin.tar.gz"
    info "Retrying from archive: ${url}"
    curl -fsSL --connect-timeout 30 -o "$archive" "$url"
  fi

  tmpdir="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmpdir"
  rm -f "$archive"

  home="$(find "$tmpdir" -maxdepth 1 -type d -name 'apache-maven-*' | head -1)"
  if [[ -z "$home" ]]; then
    error "Could not extract Maven archive."
    rm -rf "$tmpdir"
    exit 1
  fi

  mkdir -p "$(dirname "$dest")"
  rm -rf "$dest"
  mv "$home" "$dest"
  rm -rf "$tmpdir"

  INSTALLED_MAVEN_HOME="$dest"
  success "Installed to ${dest}"
}

print_maven_home_snippet() {
  local maven_home="$1"
  cat <<EOF

${BOLD}Add to your shell profile (~/.zshrc or ~/.bash_profile):${NC}

  export M2_HOME="${maven_home}"
  export MAVEN_HOME="${maven_home}"
  export PATH="\${MAVEN_HOME}/bin:\$PATH"

Then run:  source ~/.zshrc   (or restart your terminal)

EOF
}

# ── Menus ─────────────────────────────────────────────────────────────────────
select_vendor() {
  header "Select Maven distribution"
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
  local upstream_latest=""

  if [[ "$SELECTED_VENDOR" == "maven" ]]; then
    upstream_latest=$(fetch_maven_latest 2>/dev/null || true)
    [[ -n "$upstream_latest" ]] && info "Latest stable (Apache): Maven ${upstream_latest}"

    brew_has_formula "$VENDOR_BASE" && versions+=("latest")

    while IFS= read -r v; do
      [[ -n "$v" ]] && versions+=("$v")
    done < <(fetch_maven_releases 2>/dev/null || true)
  else
    while IFS= read -r v; do
      [[ -n "$v" ]] && versions+=("$v")
    done < <(fetch_brew_versions "$VENDOR_BASE" 2>/dev/null || true)
    [[ ${#versions[@]} -eq 0 ]] && versions=("latest")
  fi

  # Deduplicate while preserving order (latest first, then newest stable releases)
  local -a sorted=()
  while IFS= read -r v; do
    [[ -n "$v" ]] && sorted+=("$v")
  done < <(printf '%s\n' "${versions[@]}" | awk '!seen[$0]++')
  versions=("${sorted[@]}")

  if ((${#versions[@]} > MAX_VERSIONS)); then
    versions=("${versions[@]:0:MAX_VERSIONS}")
    info "Showing ${MAX_VERSIONS} most recent versions."
  fi

  if [[ ${#versions[@]} -eq 0 ]]; then
    error "Could not determine available versions for ${SELECTED_VENDOR_NAME}."
    exit 1
  fi

  local i=1
  for v in "${versions[@]}"; do
    local label="$v" suffix=""
    if [[ "$v" == "latest" ]]; then
      if [[ -n "$upstream_latest" ]]; then
        label="latest via Homebrew (currently ~${upstream_latest})"
      else
        label="latest (recommended)"
      fi
    elif brew_has_formula "${VENDOR_BASE}@${v}" || brew_has_formula "${VENDOR_BASE}@${v%.*}"; then
      suffix=" (Homebrew)"
    elif [[ "$SELECTED_VENDOR" == "maven" ]]; then
      suffix=" (Apache download)"
    fi
    echo "  ${i}) Maven ${label}${suffix}"
    ((i++)) || true
  done
  echo

  local choice
  while true; do
    read -rp "Enter choice [1-${#versions[@]}] (default: 1): " choice
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#versions[@]} )); then
      SELECTED_VERSION="${versions[$((choice-1))]}"
      success "Selected: Maven ${SELECTED_VERSION}"
      return
    fi
    warn "Invalid choice."
  done
}

should_install_via_brew() {
  local version="$1"
  local base="$2"

  [[ "$version" == "latest" ]] && return 0

  local major_minor="${version%.*}"
  brew_has_formula "${base}@${version}" && return 0
  brew_has_formula "${base}@${major_minor}" && return 0

  return 1
}

install_maven() {
  lookup_vendor "$SELECTED_VENDOR"
  INSTALLED_MAVEN_HOME=""

  header "Installing ${SELECTED_VENDOR_NAME} — ${SELECTED_VERSION}"

  if [[ "$SELECTED_VENDOR" == "maven" ]] && ! should_install_via_brew "$SELECTED_VERSION" "$VENDOR_BASE"; then
    install_maven_from_apache "$SELECTED_VERSION"
    success "Installation complete."
    return
  fi

  local formula
  formula=$(resolve_formula "$VENDOR_BASE" "$SELECTED_VERSION")
  info "Formula: ${formula}"
  info "Running: brew install ${formula}"
  brew install "$formula"
  success "Installation complete."
}

verify_install() {
  lookup_vendor "$SELECTED_VENDOR"

  header "Verification"
  local cmd="mvn"
  [[ "$SELECTED_VENDOR" == "mvnd" ]] && cmd="mvnd"

  if [[ -n "${INSTALLED_MAVEN_HOME:-}" && -x "${INSTALLED_MAVEN_HOME}/bin/${cmd}" ]]; then
    success "MAVEN_HOME: ${INSTALLED_MAVEN_HOME}"
    echo
    "${INSTALLED_MAVEN_HOME}/bin/${cmd}" --version 2>&1 | sed 's/^/  /'
    print_maven_home_snippet "$INSTALLED_MAVEN_HOME"
  elif command -v "$cmd" &>/dev/null; then
    success "${cmd} found on PATH:"
    "$cmd" --version 2>&1 | sed 's/^/  /'
  else
    local formula prefix
    formula=$(resolve_formula "$VENDOR_BASE" "$SELECTED_VERSION")
    prefix=$(brew --prefix "$formula" 2>/dev/null || true)
    if [[ -n "$prefix" && -x "${prefix}/bin/${cmd}" ]]; then
      success "Installed at: ${prefix}/bin/${cmd}"
      "${prefix}/bin/${cmd}" --version 2>&1 | sed 's/^/  /'
      echo
      info "Add to PATH if needed:"
      echo "  export PATH=\"${prefix}/bin:\$PATH\""
    else
      warn "${cmd} not found on PATH yet."
      echo "Try: brew info ${formula}"
    fi
  fi

  if ! command -v java &>/dev/null; then
    echo
    warn "Java is still not on PATH. Maven needs a JDK — run ./install-java.sh"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║       macOS Maven Installer              ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"

  require_macos
  ensure_homebrew
  check_java

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

  install_maven
  verify_install

  success "Done! ${SELECTED_VENDOR_NAME} (${SELECTED_VERSION}) is installed."
}

main "$@"
