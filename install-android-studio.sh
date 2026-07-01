#!/usr/bin/env bash
#
# Interactive Android Studio + SDK installer for macOS.
# Installs Android Studio and/or SDK command-line tools and configures ANDROID_HOME.
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

ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Library/Android/sdk}}"
ANDROID_SDK_ROOT="$ANDROID_HOME"

SOURCES=(
  "studio|Android Studio + SDK (recommended)|studio"
  "sdk|SDK Command Line Tools only|sdk"
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

android_studio_installed() {
  [[ -d "/Applications/Android Studio.app" ]] \
    || brew list --cask android-studio &>/dev/null 2>&1
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

profile_has_android_sdk() {
  local file="$1"
  [[ -f "$file" ]] && grep -Fq 'ANDROID_HOME' "$file"
}

configure_android_sdk_path() {
  local sdk_root="$1"
  local profile updated=false block

  block=$(cat <<EOF

# Android SDK
export ANDROID_HOME="${sdk_root}"
export ANDROID_SDK_ROOT="${sdk_root}"
export PATH="\${ANDROID_HOME}/platform-tools:\${ANDROID_HOME}/emulator:\${ANDROID_HOME}/cmdline-tools/latest/bin:\${PATH}"
EOF
)

  while IFS= read -r profile; do
    [[ -z "$profile" ]] && continue
    if profile_has_android_sdk "$profile"; then
      info "Android SDK already configured in ${profile}"
      continue
    fi
    info "Adding Android SDK to ${profile}"
    printf '%s\n' "$block" >> "$profile"
    updated=true
  done < <(shell_profiles)

  export ANDROID_HOME="$sdk_root"
  export ANDROID_SDK_ROOT="$sdk_root"
  export PATH="${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator:${ANDROID_HOME}/cmdline-tools/latest/bin:${PATH}"

  mkdir -p "$sdk_root"

  if [[ "$updated" == true ]]; then
    success "Shell profile updated with ANDROID_HOME and PATH."
  else
    success "Android SDK PATH configuration already present."
  fi
}

select_source() {
  header "Select install option"
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

install_android_studio() {
  ensure_homebrew
  info "Updating Homebrew..."
  brew update --quiet 2>/dev/null || warn "brew update failed; continuing."

  header "Installing Android Studio"
  if android_studio_installed; then
    info "Android Studio already installed — upgrading if available..."
    brew upgrade --cask android-studio 2>/dev/null || true
  else
    brew install --cask android-studio
  fi
  success "Android Studio installed."
}

install_sdk_cmdline_tools() {
  ensure_homebrew
  info "Updating Homebrew..."
  brew update --quiet 2>/dev/null || warn "brew update failed; continuing."

  header "Installing Android SDK Command Line Tools"
  mkdir -p "$ANDROID_HOME"

  if brew list --cask android-commandlinetools &>/dev/null 2>&1; then
    brew upgrade --cask android-commandlinetools 2>/dev/null || true
  else
    brew install --cask android-commandlinetools
  fi

  # Homebrew cask may install cmdline-tools; ensure latest/ layout for sdkmanager
  local brew_sdk
  brew_sdk="$(brew --prefix)/share/android-commandlinetools"
  if [[ -d "$brew_sdk/cmdline-tools" && ! -d "${ANDROID_HOME}/cmdline-tools/latest" ]]; then
    mkdir -p "${ANDROID_HOME}/cmdline-tools"
    if [[ -d "$brew_sdk/cmdline-tools/latest" ]]; then
      ln -sf "$brew_sdk/cmdline-tools/latest" "${ANDROID_HOME}/cmdline-tools/latest" 2>/dev/null || true
    fi
  fi

  success "SDK command-line tools installed."
}

find_sdkmanager() {
  local candidates=(
    "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager"
    "${ANDROID_HOME}/cmdline-tools/bin/sdkmanager"
    "${ANDROID_HOME}/tools/bin/sdkmanager"
  )
  local path
  for path in "${candidates[@]}"; do
    if [[ -x "$path" ]]; then
      echo "$path"
      return 0
    fi
  done
  if command -v sdkmanager &>/dev/null; then
    command -v sdkmanager
    return 0
  fi
  return 1
}

bootstrap_cmdline_tools() {
  [[ -x "$(find_sdkmanager 2>/dev/null || true)" ]] && return 0

  header "Bootstrapping SDK command-line tools"
  local url zip tmpdir
  url="https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip"
  zip="$(mktemp -t cmdline-tools.XXXXXX.zip)"
  tmpdir="$(mktemp -d)"

  info "Downloading command-line tools from Google..."
  curl -fsSL "$url" -o "$zip"
  unzip -q "$zip" -d "$tmpdir"

  mkdir -p "${ANDROID_HOME}/cmdline-tools"
  rm -rf "${ANDROID_HOME}/cmdline-tools/latest"
  mv "${tmpdir}/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest"
  rm -f "$zip"
  rm -rf "$tmpdir"

  success "Command-line tools bootstrapped to ${ANDROID_HOME}/cmdline-tools/latest"
}

accept_licenses() {
  local sdkmanager
  sdkmanager="$(find_sdkmanager)" || return 1

  header "Accepting Android SDK licenses"
  info "You may need to type 'y' to accept each license."
  yes | "$sdkmanager" --licenses || "$sdkmanager" --licenses
  success "SDK licenses accepted."
}

install_sdk_packages() {
  local sdkmanager
  sdkmanager="$(find_sdkmanager)" || {
    warn "sdkmanager not found — open Android Studio once to finish SDK setup."
    return 1
  }

  header "Install SDK packages (optional)"
  echo "  1) Essential only          (platform-tools)"
  echo "  2) Standard Android dev    (platform-tools, build-tools, platform API 35)"
  echo "  3) Enter packages manually (sdkmanager syntax)"
  echo "  4) Skip"
  echo

  local choice packages
  while true; do
    read -rp "Enter choice [1-4] (default: 2): " choice
    choice="${choice:-2}"
    case "$choice" in
      1) packages="platform-tools"; break ;;
      2) packages="platform-tools build-tools;35.0.0 platforms;android-35"; break ;;
      3)
        read -rp "Enter sdkmanager packages (space-separated): " packages
        packages="$(echo "$packages" | xargs)"
        [[ -z "$packages" ]] && { warn "No packages entered."; continue; }
        break
        ;;
      4)
        info "Skipped SDK package installation."
        return 0
        ;;
      *)
        warn "Invalid choice. Enter 1-4."
        ;;
    esac
  done

  accept_licenses || warn "License step incomplete — package install may fail."

  header "Installing SDK packages"
  info "Running: sdkmanager ${packages}"
  # shellcheck disable=SC2086
  "$sdkmanager" $packages
  success "SDK packages installed."
}

configure_android() {
  header "Configure Android (optional)"
  echo "  1) Install SDK packages via sdkmanager"
  echo "  2) Accept SDK licenses only"
  echo "  3) Open Android Studio"
  echo "  4) Skip configuration"
  echo

  local choice
  while true; do
    read -rp "Enter choice [1-4] (default: 1): " choice
    choice="${choice:-1}"
    case "$choice" in
      1)
        bootstrap_cmdline_tools || true
        install_sdk_packages
        return
        ;;
      2)
        bootstrap_cmdline_tools || true
        accept_licenses || warn "Could not accept licenses."
        return
        ;;
      3)
        if android_studio_installed; then
          info "Opening Android Studio..."
          open -a "Android Studio" 2>/dev/null || open "/Applications/Android Studio.app"
          info "Complete the setup wizard to download the full SDK."
        else
          warn "Android Studio is not installed."
        fi
        return
        ;;
      4)
        info "Skipped configuration."
        print_android_next_steps
        return
        ;;
      *)
        warn "Invalid choice. Enter 1-4."
        ;;
    esac
  done
}

print_android_next_steps() {
  cat <<EOF

${BOLD}Next steps:${NC}

  • SDK location: ${ANDROID_HOME}
  • Open Android Studio and run the setup wizard (first launch)
  • Verify: adb version
  • List SDK packages: sdkmanager --list
  • Flutter: run 'flutter doctor' to verify Android toolchain

EOF
}

verify_install() {
  header "Verification"

  if android_studio_installed; then
    success "Android Studio: installed"
  elif [[ "$SELECTED_SOURCE" == "studio" ]]; then
    warn "Android Studio app not found in /Applications."
  fi

  if [[ -d "$ANDROID_HOME" ]]; then
    success "ANDROID_HOME: ${ANDROID_HOME}"
  else
    warn "SDK directory not found yet: ${ANDROID_HOME}"
  fi

  if command -v adb &>/dev/null; then
    success "adb: $(adb version 2>&1 | head -1)"
    info "adb path: $(command -v adb)"
  else
    info "adb not on PATH yet — install platform-tools or open Android Studio."
  fi

  if sdkmanager_path="$(find_sdkmanager 2>/dev/null)"; then
    success "sdkmanager: ${sdkmanager_path}"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║   macOS Android Studio + SDK Installer   ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"

  require_macos
  select_source

  read -rp "SDK location [${ANDROID_HOME}]: " custom_sdk
  if [[ -n "$(echo "${custom_sdk:-}" | xargs)" ]]; then
    ANDROID_HOME="$(echo "$custom_sdk" | xargs)"
    ANDROID_SDK_ROOT="$ANDROID_HOME"
  fi

  echo
  read -rp "Proceed with installation? [Y/n]: " confirm
  confirm="${confirm:-Y}"
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "Installation cancelled."
    exit 0
  fi

  case "$SELECTED_SOURCE" in
    studio)
      install_android_studio
      install_sdk_cmdline_tools || bootstrap_cmdline_tools || true
      ;;
    sdk)
      install_sdk_cmdline_tools || true
      bootstrap_cmdline_tools || true
      ;;
  esac

  configure_android_sdk_path "$ANDROID_HOME"
  verify_install

  echo
  read -rp "Configure SDK packages / licenses now? [Y/n]: " configure_now
  configure_now="${configure_now:-Y}"
  if [[ "$configure_now" =~ ^[Yy]$ ]]; then
    configure_android
    verify_install
  fi

  success "Done! Android Studio / SDK setup complete."
}

main "$@"
