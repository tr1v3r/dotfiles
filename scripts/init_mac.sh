#!/usr/bin/env bash
set -Eeuo pipefail

# macOS bootstrap — installs packages only.
# Config deployment is handled by chezmoi (chezmoi init + git-crypt unlock + chezmoi apply).
# Idempotent: every step is skipped when its tool is already present,
# so this is safe to run on an already-provisioned machine.

abort() {
	echo "$1"
	exit 1
}

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
	cat <<'EOF'
Usage: ./scripts/init.sh

Install the complete macOS package set. Linux-only package-group options are not
supported on macOS. Configuration deployment is handled separately by chezmoi.
EOF
}

if (($#)); then
	case "$1" in
		-h|--help) usage; exit 0 ;;
		*) printf 'ERROR: Unknown macOS option: %s (use --help)\n' "$1" >&2; exit 2 ;;
	esac
fi

echo "Initializing macOS setup..."

# Homebrew (https://brew.sh/) — skipped when already installed
if have brew; then
	echo "Homebrew already installed, refreshing index..."
	brew update || echo "WARN: brew update failed (continuing with stale index)"
else
	echo "Installing Homebrew..."
	/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || abort "Failed to install Homebrew"
fi

# A fresh Apple Silicon install is not on PATH in the current process yet.
if ! have brew; then
	for brew_path in /opt/homebrew/bin/brew /usr/local/bin/brew; do
		if [[ -x "$brew_path" ]]; then
			eval "$("$brew_path" shellenv)"
			break
		fi
	done
fi
have brew || abort "Homebrew was installed but could not be added to PATH"

# Formulae (brew itself skips the ones already installed; go included)
# NOTE: per-package loop so one bad/renamed formula doesn't kill the rest.
echo "Installing packages via Homebrew..."
brew_packages=("python3" "neovim" "gpg" "paperkey" "zoxide" "tldr" "mpv" "autojump" "tmux" "wget" "lua" "tree" "sevenzip" "git-delta" "git-crypt" "fzf" "neofetch" "cmake" "highlight" "graphviz" "ffmpeg" "openssl" "sops" "figlet" "go" "switchaudio-osx" "nowplaying-cli" "uv")
for pkg in "${brew_packages[@]}"; do
	brew install "$pkg" || echo "WARN: brew install $pkg failed (continuing)"
done

# Casks — the homebrew/cask-fonts tap is deprecated; fonts live in homebrew/cask now
echo "Installing casks via Homebrew..."
brew_casks=("font-hack-nerd-font" "font-sketchybar-app-font" "skim")
for cask in "${brew_casks[@]}"; do
	brew install --cask "$cask" || echo "WARN: brew install --cask $cask failed (continuing)"
done

# Sioyek — NOT via brew: the 2.0.0 cask is disabled (fails Gatekeeper) and is
# Intel-only. Install the official arm64 build from GitHub releases instead;
# `chezmoi apply` then links ~/.config/sioyek into the app bundle.
if [ ! -d /Applications/Sioyek.app ]; then
	echo "Installing Sioyek (arm64, sioyek3-alpha0)..."
	sioyek_tmp="$(mktemp -d)"
	if curl -fsL -o "$sioyek_tmp/sioyek.zip" \
		https://github.com/ahrm/sioyek/releases/download/sioyek3-alpha0/sioyek-release-mac-arm.zip; then
		unzip -q "$sioyek_tmp/sioyek.zip" -d "$sioyek_tmp" \
			&& hdiutil attach -nobrowse -readonly -mountpoint "$sioyek_tmp/mnt" "$sioyek_tmp/build/sioyek.dmg" >/dev/null \
			&& cp -Rp "$sioyek_tmp/mnt/sioyek.app" /Applications/Sioyek.app \
			&& xattr -dr com.apple.quarantine /Applications/Sioyek.app \
			|| echo "WARN: Sioyek install failed (continuing)"
		hdiutil detach "$sioyek_tmp/mnt" >/dev/null 2>&1 || true
	else
		echo "WARN: failed to download Sioyek (continuing)"
	fi
	rm -rf "$sioyek_tmp"
fi

# Neovim LSP servers & formatter binaries — mason.nvim only manages DAP adapters,
# so the servers it used to install became system packages (see .nvim settings.lua
# lsp_deps note; clangd ships with Xcode CLT, gopls via `go install`).
echo "Installing nvim LSP servers & formatters..."
nvim_lsp_brews=("bash-language-server" "lua-language-server" "prettier" "shfmt" "stylua" "vint" "vscode-langservers-extracted")
for pkg in "${nvim_lsp_brews[@]}"; do
	brew install "$pkg" || echo "WARN: brew install $pkg failed (continuing)"
done

# pylsp deliberately does NOT come from brew: its plugins (black/ruff/rope) must
# share the server's environment, so it lives in an isolated uv tool venv.
# --system-certs keeps it working behind corporate MITM proxies.
if have uv; then
	echo "Installing pylsp (with black/ruff/rope) via uv tool..."
	uv tool install --system-certs --with python-lsp-black --with python-lsp-ruff --with pylsp-rope python-lsp-server \
		|| echo "WARN: uv tool install python-lsp-server failed (continuing)"
else
	echo "WARN: uv not found, skipping pylsp (run: uv tool install --system-certs --with python-lsp-black --with python-lsp-ruff --with pylsp-rope python-lsp-server)"
fi

# SBarLua — the Lua host sketchybar configs run on (installs ~/.local/share/sketchybar_lua/sketchybar.so)
if [ ! -e "$HOME/.local/share/sketchybar_lua/sketchybar.so" ] && have clang && have git; then
	echo "Building SBarLua..."
	sbarlua_dir="${TMPDIR:-/tmp}/SbarLua"
	rm -rf "$sbarlua_dir"
	if git clone --depth 1 https://github.com/FelixKratz/SbarLua "$sbarlua_dir"; then
		(cd "$sbarlua_dir" && make install) \
			|| echo "WARN: SBarLua build failed (sketchybar Lua config won't run)"
		rm -rf "$sbarlua_dir"
	else
		echo "WARN: failed to clone SBarLua (continuing)"
	fi
fi

# Go tools (go itself comes from brew above; no more legacy multi-version tarball zoo)
if have go; then
	echo "Installing Go tools..."
	go_tools=("github.com/jesseduffield/lazygit@latest" "github.com/rhysd/vim-startuptime@latest")
	for tool in "${go_tools[@]}"; do
		cmd="${tool##*/}"; cmd="${cmd%%@*}"
		if ! have "$cmd"; then
			go install "$tool" || abort "Failed to install $tool"
		fi
	done
else
	echo "WARN: go not found, skipping Go tools"
fi

# Rust toolchain — skipped when already installed
if ! have cargo; then
	echo "Installing Rust..."
	curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || abort "Failed to install Rust"
fi
if [[ -f "$HOME/.cargo/env" ]]; then
	# shellcheck source=/dev/null
	. "$HOME/.cargo/env"
fi
if have cargo; then
	echo "Installing Rust tools..."
	have ripgrep || cargo install ripgrep || abort "Failed to install ripgrep"
	have zoxide || cargo install zoxide || abort "Failed to install zoxide"
else
	echo "WARN: cargo not found, skipping Rust tools"
fi

# Python tools — ranger only when neither ranger nor yazi is present
if ! have ranger && ! have yazi; then
	echo "Installing Python tools..."
	pip3 install ranger-fm || echo "WARN: pip3 install ranger-fm failed (continuing)"
fi

echo "Config deployment is handled by chezmoi (chezmoi init + git-crypt unlock + chezmoi apply)."
echo "MacOS init done."
