#!/usr/bin/env bash
#
# Interactive setup launcher for macOS.
# Pick what to install and the matching installer script runs.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# id | label | script filename | aliases (space-separated)
INSTALLERS=(
  "brew|Homebrew (package manager)|install-homebrew.sh|homebrew brew"
  "java|Java (OpenJDK, Corretto, Temurin, Zulu, Oracle)|install-java.sh|jdk openjdk"
  "maven|Maven (Apache Maven, Maven Daemon)|install-maven.sh|mvn mvnd"
  "nvm|nvm + Node.js|install-nvm.sh|node npm nodejs"
  "python|pyenv + Python|install-python.sh|py python3 pip"
  "aws|AWS CLI|install-aws-cli.sh|awscli amazon"
  "cloudflared|cloudflared (Cloudflare Tunnel)|install-cloudflared.sh|cloudflare tunnel cf"
  "nginx|nginx (web server / reverse proxy)|install-nginx.sh|webserver proxy"
  "flutter|Flutter SDK|install-flutter.sh|dart"
  "docker|Docker (Desktop or Colima)|install-docker.sh|container compose"
  "android|Android Studio + SDK|install-android-studio.sh|android-studio sdk adb"
  "claude|Claude Code CLI|install-claude-code.sh|claude-code anthropic"
)

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    error "This setup is intended for macOS only."
    exit 1
  fi
}

print_banner() {
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║         macOS Setup Installer            ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
}

print_menu() {
  header "What would you like to install?"
  local i=1
  for entry in "${INSTALLERS[@]}"; do
    IFS='|' read -r _ label script _ <<< "$entry"
    local status=""
    if [[ ! -x "${SCRIPT_DIR}/${script}" ]]; then
      status=" ${YELLOW}(missing)${NC}"
    fi
    echo -e "  ${i}) ${label}${status}"
    ((i++)) || true
  done
  echo
  echo "  q) Quit"
  echo
  echo "Tip: enter a number, name, or alias (e.g. brew, flutter, claude)"
}

normalize_input() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | xargs
}

find_installer_index() {
  local input="$1"
  local i=0 idx=""

  for entry in "${INSTALLERS[@]}"; do
    IFS='|' read -r id label script aliases <<< "$entry"
    if [[ "$input" == "$id" || "$input" == "${script%.sh}" ]]; then
      idx="$i"
      break
    fi
    for alias in $aliases; do
      if [[ "$input" == "$alias" ]]; then
        idx="$i"
        break 2
      fi
    done
    ((i++)) || true
  done

  if [[ -n "$idx" ]]; then
    echo "$idx"
    return 0
  fi

  if [[ "$input" =~ ^[0-9]+$ ]]; then
    local num="$input"
    if (( num >= 1 && num <= ${#INSTALLERS[@]} )); then
      echo "$((num - 1))"
      return 0
    fi
  fi

  return 1
}

run_installer() {
  local index="$1"
  local entry id label script
  entry="${INSTALLERS[$index]}"
  IFS='|' read -r id label script _ <<< "$entry"

  local script_path="${SCRIPT_DIR}/${script}"
  if [[ ! -f "$script_path" ]]; then
    error "Installer not found: ${script_path}"
    return 1
  fi
  if [[ ! -x "$script_path" ]]; then
    warn "Making ${script} executable..."
    chmod +x "$script_path"
  fi

  header "Running: ${label}"
  bash "$script_path"
}

prompt_choice() {
  local input idx

  while true; do
    read -rp "Enter choice: " input
    input="$(normalize_input "$input")"

    case "$input" in
      q|quit|exit)
        return 1
        ;;
    esac

    if idx=$(find_installer_index "$input" 2>/dev/null); then
      run_installer "$idx"
      return 0
    fi

    warn "Unknown choice: '${input}'. Try a number, brew, flutter, claude, or q to quit."
  done
}

main() {
  print_banner
  require_macos

  while true; do
    print_menu

    if ! prompt_choice; then
      echo
      info "Goodbye."
      exit 0
    fi

    echo
    read -rp "Install something else? [y/N]: " again
    again="$(normalize_input "${again:-N}")"
    if [[ ! "$again" =~ ^(y|yes)$ ]]; then
      echo
      success "All done."
      exit 0
    fi
    echo
  done
}

main "$@"
