#!/usr/bin/env bash
# Installs Neovim + everything this config needs on macOS / Linux, then clones and bootstraps it.
#
# Idempotent: only installs what is missing.
#   - Neovim (>= 0.12), git, curl, unzip, a C compiler + make, ripgrep, fd, Node.js + npm,
#     tree-sitter CLI, .NET SDK 10, JetBrainsMono Nerd Font
#   macOS: Homebrew. Linux: apt / dnf / pacman / zypper (with sudo) for system packages;
#   Neovim, tree-sitter, .NET and the font go to your home dir when the distro version is missing/old.
# Then clones the config to ~/.config/nvim (if not already there) and installs plugins,
# treesitter parsers and Mason tools headlessly.
#
# Usage: ./install.sh [--repo URL] [--skip-bootstrap]

set -euo pipefail

REPO_URL=""
SKIP_BOOTSTRAP=0
DEFAULT_REPO_URL="https://github.com/CypheronX/kickstart.nvim.git"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
LOCAL_BIN="$HOME/.local/bin"
DOTNET_DIR="$HOME/.dotnet"
RC_MARKER="# added by kickstart.nvim install.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_URL="$2"; shift 2 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

step() { printf '\033[36m==> %s\033[0m\n' "$*"; }
ok() { printf '    %s\n' "$*"; }
has() { command -v "$1" >/dev/null 2>&1; }

OS="$(uname -s)"
case "$(uname -m)" in
  x86_64|amd64) ARCH=x86_64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

SUDO=""
if [ "$(id -u)" -ne 0 ] && has sudo; then SUDO="sudo"; fi

mkdir -p "$LOCAL_BIN"
export PATH="$LOCAL_BIN:$DOTNET_DIR:$PATH"

# Add a line to the shell startup files once (bash, zsh, and login shells)
add_to_rc() {
  local line="$1"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    if [ -f "$rc" ] || [ "$rc" = "$HOME/.profile" ]; then
      grep -qxF "$line" "$rc" 2>/dev/null || printf '\n%s\n%s\n' "$RC_MARKER" "$line" >>"$rc"
    fi
  done
}

nvim_ok() {
  has nvim || return 1
  local v minor major
  v="$(nvim --version | head -n1 | sed 's/^NVIM v//')"
  major="${v%%.*}"; minor="$(echo "$v" | cut -d. -f2)"
  [ "$major" -gt 0 ] || [ "$minor" -ge 12 ]
}

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
if [ "$OS" = "Darwin" ]; then
  if ! has brew; then
    step "Installing Homebrew"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; else eval "$(/usr/local/bin/brew shellenv)"; fi
  fi
  # Homebrew needs the Xcode Command Line Tools, which also provide cc and make
  pkgs=()
  nvim_ok || pkgs+=(neovim)
  has git || pkgs+=(git)
  has rg || pkgs+=(ripgrep)
  has fd || pkgs+=(fd)
  has node || pkgs+=(node)
  has tree-sitter || pkgs+=(tree-sitter-cli)
  if [ ${#pkgs[@]} -gt 0 ]; then step "brew install ${pkgs[*]}"; brew install "${pkgs[@]}"; fi
  if nvim_ok; then ok "nvim found"; else brew upgrade neovim; fi
  if ! (has dotnet && [ -n "$(dotnet --list-sdks 2>/dev/null)" ]); then
    step "Installing .NET SDK"; brew install --cask dotnet-sdk
  else ok ".NET SDK found"; fi
  if ls "$HOME/Library/Fonts"/JetBrainsMonoNerdFont* /Library/Fonts/JetBrainsMonoNerdFont* >/dev/null 2>&1; then
    ok "JetBrainsMono Nerd Font found"
  else
    step "Installing JetBrainsMono Nerd Font"; brew install --cask font-jetbrains-mono-nerd-font
  fi

elif [ "$OS" = "Linux" ]; then
  if has apt-get; then
    PM="apt"; install_pkgs() { $SUDO apt-get update -y && $SUDO apt-get install -y "$@"; }
    CC_PKGS=(build-essential); FD_PKG=fd-find
  elif has dnf; then
    PM="dnf"; install_pkgs() { $SUDO dnf install -y "$@"; }
    CC_PKGS=(gcc make); FD_PKG=fd-find
  elif has pacman; then
    PM="pacman"; install_pkgs() { $SUDO pacman -S --needed --noconfirm "$@"; }
    CC_PKGS=(base-devel); FD_PKG=fd
  elif has zypper; then
    PM="zypper"; install_pkgs() { $SUDO zypper install -y "$@"; }
    CC_PKGS=(gcc make); FD_PKG=fd
  else
    echo "No supported package manager (apt, dnf, pacman, zypper) found." >&2; exit 1
  fi

  pkgs=()
  has git || pkgs+=(git)
  has curl || pkgs+=(curl)
  has unzip || pkgs+=(unzip)
  has tar || pkgs+=(tar)
  has gzip || pkgs+=(gzip)
  { has cc || has gcc; } && has make || pkgs+=("${CC_PKGS[@]}")
  has rg || pkgs+=(ripgrep)
  { has fd || has fdfind; } || pkgs+=("$FD_PKG")
  has node || pkgs+=(nodejs)
  has npm || pkgs+=(npm)
  has fc-cache || pkgs+=(fontconfig)
  if [ ${#pkgs[@]} -gt 0 ]; then step "$PM install ${pkgs[*]}"; install_pkgs "${pkgs[@]}"; fi
  # Debian/Ubuntu name the fd binary fdfind
  if ! has fd && has fdfind; then ln -sf "$(command -v fdfind)" "$LOCAL_BIN/fd"; fi

  # Neovim: distro packages are usually older than 0.12, so use the official release tarball
  if nvim_ok; then ok "nvim found"; else
    step "Installing Neovim (latest release) to ~/.local/opt/nvim"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/nvim.tar.gz" "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-$ARCH.tar.gz"
    rm -rf "$HOME/.local/opt/nvim" && mkdir -p "$HOME/.local/opt"
    tar -xzf "$tmp/nvim.tar.gz" -C "$tmp"
    mv "$tmp/nvim-linux-$ARCH" "$HOME/.local/opt/nvim"
    ln -sf "$HOME/.local/opt/nvim/bin/nvim" "$LOCAL_BIN/nvim"
    rm -rf "$tmp"
    hash -r
  fi

  # tree-sitter CLI (needed by nvim-treesitter to build parsers)
  if has tree-sitter; then ok "tree-sitter found"; else
    step "Installing tree-sitter CLI to ~/.local/bin"
    ts_arch=x64; [ "$ARCH" = "arm64" ] && ts_arch=arm64
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/ts.zip" "https://github.com/tree-sitter/tree-sitter/releases/latest/download/tree-sitter-cli-linux-$ts_arch.zip"
    unzip -q -o "$tmp/ts.zip" -d "$tmp"
    install -m 755 "$tmp/tree-sitter" "$LOCAL_BIN/tree-sitter"
    rm -rf "$tmp"
  fi

  # .NET SDK via Microsoft's dotnet-install script (works on every distro, no root)
  if has dotnet && [ -n "$(dotnet --list-sdks 2>/dev/null)" ]; then ok ".NET SDK found"; else
    step "Installing .NET SDK 10 to ~/.dotnet"
    curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel 10.0 --install-dir "$DOTNET_DIR"
    add_to_rc "export DOTNET_ROOT=\"\$HOME/.dotnet\""
    add_to_rc "export PATH=\"\$HOME/.dotnet:\$HOME/.dotnet/tools:\$PATH\""
  fi
  export DOTNET_ROOT="${DOTNET_ROOT:-$DOTNET_DIR}"

  # Nerd Font
  if fc-list 2>/dev/null | grep -qi "JetBrainsMono Nerd"; then ok "JetBrainsMono Nerd Font found"; else
    step "Installing JetBrainsMono Nerd Font to ~/.local/share/fonts"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/font.zip" "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip"
    mkdir -p "$HOME/.local/share/fonts/JetBrainsMonoNerdFont"
    unzip -q -o "$tmp/font.zip" -d "$HOME/.local/share/fonts/JetBrainsMonoNerdFont"
    fc-cache -f >/dev/null 2>&1 || true
    rm -rf "$tmp"
  fi

  add_to_rc "export PATH=\"\$HOME/.local/bin:\$PATH\""
else
  echo "Unsupported OS: $OS (use install.ps1 on Windows)" >&2; exit 1
fi

nvim_ok || { echo "Neovim >= 0.12 still not available" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
if [ -z "$REPO_URL" ]; then
  REPO_URL="$DEFAULT_REPO_URL"
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -d "$script_dir/.git" ]; then
    REPO_URL="$(git -C "$script_dir" remote get-url origin 2>/dev/null || echo "$DEFAULT_REPO_URL")"
  fi
fi

if [ -d "$CONFIG_DIR/.git" ]; then
  ok "config already at $CONFIG_DIR (not touching it; git pull to update)"
else
  if [ -e "$CONFIG_DIR" ]; then
    backup="$CONFIG_DIR.bak-$(date +%Y%m%d-%H%M%S)"
    step "Backing up existing $CONFIG_DIR to $backup"
    mv "$CONFIG_DIR" "$backup"
  fi
  step "Cloning $REPO_URL to $CONFIG_DIR"
  mkdir -p "$(dirname "$CONFIG_DIR")"
  git clone "$REPO_URL" "$CONFIG_DIR"
fi

# ---------------------------------------------------------------------------
# Plugins, parsers, language servers
# ---------------------------------------------------------------------------
if [ "$SKIP_BOOTSTRAP" -eq 0 ]; then
  step "Bootstrapping plugins, treesitter parsers and language servers (takes a few minutes)"
  nvim --headless "+luafile $CONFIG_DIR/scripts/bootstrap.lua" ||
    echo "Bootstrap reported problems; open nvim and run :checkhealth" >&2
fi

echo
printf '\033[32mDone. Open a new shell (so PATH updates apply) and run: nvim\033[0m\n'
printf '\033[32mSet your terminal font to "JetBrainsMono Nerd Font" for icons.\033[0m\n'
