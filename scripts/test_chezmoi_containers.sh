#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"
CHEZMOI_TEST_FILTER="${CHEZMOI_TEST_FILTER:-}"
CHEZMOI_TEST_VERSION="${CHEZMOI_TEST_VERSION:-2.72.0}"

command -v "$CONTAINER_ENGINE" >/dev/null 2>&1 || {
	printf 'Container engine not found: %s\n' "$CONTAINER_ENGINE" >&2
	exit 1
}

# Externals are pre-cloned into containers from this machine's live external
# clones (mounted read-only), so containers need no GitHub credentials or
# proxy. Requires one prior `chezmoi apply` on this machine.
EXTERNAL_CLONES=(
	"zsh:$HOME/.config/zsh"
	"nvim:$HOME/.config/nvim"
	"firefox:$HOME/.config/firefox"
	"llm-wiki:$HOME/.config/ai/llm-wiki"
)
for item in "${EXTERNAL_CLONES[@]}"; do
	dir=${item#*:}
	[ -d "$dir/.git" ] || {
		printf 'External clone missing: %s — run chezmoi apply first\n' "$dir" >&2
		exit 1
	}
done

# The disposable source is a locked clone of Git HEAD. Refuse to silently test
# stale committed config when deployable source paths have local changes.
while IFS= read -r status_line; do
	path=${status_line:3}
	case "$path" in
	README.md | AGENTS.md | CLAUDE.md | scripts/*) ;;
	*)
		printf 'Commit or stash deployable source change before testing: %s\n' "$path" >&2
		exit 1
		;;
	esac
done < <(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)

images=(
	"ubuntu-24.04|ubuntu:24.04||work|workstation"
	"debian-12|debian:12-slim||personal|workstation"
	# The official Arch image has no arm64 manifest; OrbStack emulates amd64.
	"arch|archlinux:latest|linux/amd64|work|home-server"
)

tests_run=0
for item in "${images[@]}"; do
	IFS='|' read -r name image platform profile role <<<"$item"
	if [[ -n "$CHEZMOI_TEST_FILTER" && "$name" != "$CHEZMOI_TEST_FILTER" ]]; then
		continue
	fi
	((tests_run += 1))

	docker_args=(run --rm)
	if [[ -n "$platform" ]]; then
		docker_args+=(--platform "$platform")
	fi
	docker_args+=(
		--name "dotfiles-chezmoi-$name"
		--volume "$REPO_ROOT:/workspace:ro"
		--env "TEST_PROFILE=$profile"
		--env "TEST_ROLE=$role"
		--env "CHEZMOI_TEST_VERSION=$CHEZMOI_TEST_VERSION"
		--entrypoint /bin/bash
	)
	for item in "${EXTERNAL_CLONES[@]}"; do
		docker_args+=(--volume "${item#*:}:/ext/${item%%:*}:ro")
	done

	printf '\n===== %s (%s%s, profile=%s, role=%s) =====\n' \
		"$name" "$image" "${platform:+, $platform}" "$profile" "$role"

	# shellcheck disable=SC2016 # payload variables expand inside the container
	"$CONTAINER_ENGINE" "${docker_args[@]}" "$image" -lc '
set -Eeuo pipefail
on_error() {
  printf "FAILED at container payload line %s\n" "${BASH_LINENO[0]}" >&2
}
trap on_error ERR

step() {
  printf -- "--- %s ---\n" "$*"
}

retry() {
  local attempt=1 max=3
  until "$@"; do
    if ((attempt >= max)); then return 1; fi
    printf "retrying failed command (%s/%s)\n" "$attempt" "$max" >&2
    sleep "$attempt"
    ((attempt += 1))
  done
}

retry_logged() {
  local log=$1
  shift
  if ! retry "$@" >"$log" 2>&1; then
    tail -n 80 "$log" >&2
    return 1
  fi
}

step "install runtime packages"
if command -v apt-get >/dev/null 2>&1; then
  retry_logged /tmp/apt-update.log apt-get -qq update
  retry_logged /tmp/apt-install.log env DEBIAN_FRONTEND=noninteractive \
    apt-get -qq install -y --no-install-recommends \
    ca-certificates curl git openssh-client zsh
elif command -v pacman >/dev/null 2>&1; then
  # pacman 7 syscall sandboxing cannot nest under OrbStack amd64 emulation.
  sed -i "s/^#DisableSandboxSyscalls/DisableSandboxSyscalls/" /etc/pacman.conf
  retry_logged /tmp/pacman.log pacman -Syu --needed --noconfirm --quiet \
    ca-certificates curl git openssh zsh
else
  echo "unsupported package manager" >&2
  exit 1
fi

step "install pinned chezmoi"
case "$(uname -m)" in
  x86_64) chezmoi_arch=amd64 ;;
  aarch64|arm64) chezmoi_arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
archive=/tmp/chezmoi.tar.gz
retry curl -fsSL -o "$archive" \
  "https://github.com/twpayne/chezmoi/releases/download/v$CHEZMOI_TEST_VERSION/chezmoi_${CHEZMOI_TEST_VERSION}_linux_${chezmoi_arch}.tar.gz"
tar -xzf "$archive" -C /usr/local/bin chezmoi
version_line=$(chezmoi --version)
[[ "$version_line" == "chezmoi version v$CHEZMOI_TEST_VERSION,"* ]]
printf "%s\n" "$version_line"

TEST_USER=chezmoi-test
TEST_HOME=/home/$TEST_USER
useradd --create-home --shell /bin/bash "$TEST_USER"

as_user() {
  runuser -u "$TEST_USER" -- env \
    HOME="$TEST_HOME" USER="$TEST_USER" LOGNAME="$TEST_USER" \
    PATH="/usr/local/bin:/usr/bin:/bin" "$@"
}

as_user git config --global --add safe.directory "*"
step "clone and initialize chezmoi source"
as_user chezmoi init --no-tty \
  --guess-repo-url=false \
  --promptDefaults \
  --promptString "Host profile (work|personal)=$TEST_PROFILE" \
  --promptString "Machine role (workstation|home-server)=$TEST_ROLE" \
  --promptString "Firefox profile dir name (macOS)=test.default-release" \
  file:///workspace

SOURCE="$TEST_HOME/.local/share/chezmoi"
[[ -d "$SOURCE/.git" ]]

# Pre-clone .chezmoiexternal.toml repos from the mounted live clones so
# chezmoi apply exercises its existing-repo path (pull — chezmoi never
# re-clones an existing directory) with no GitHub access at all. The firefox
# clone must already carry the branch pinned by .chezmoiexternal.toml
# clone.args.
step "pre-clone external repos from mounted live clones"
as_user mkdir -p "$TEST_HOME/.config" "$TEST_HOME/.config/ai"
as_user git clone --quiet /ext/zsh "$TEST_HOME/.config/zsh"
as_user git clone --quiet /ext/nvim "$TEST_HOME/.config/nvim"
as_user git clone --quiet --branch custom /ext/firefox "$TEST_HOME/.config/firefox"
as_user git clone --quiet /ext/llm-wiki "$TEST_HOME/.config/ai/llm-wiki"
for repo in zsh nvim firefox ai/llm-wiki; do
	[[ -d "$TEST_HOME/.config/$repo/.git" ]]
done

# hermes holds git-crypt ciphertext and containers have no GPG key, so ignore
# that external entirely instead of cloning a useless locked repo.
printf "\n# Container test: skip hermes external (git-crypt credentials)\n.hermes\n" >>"$SOURCE/.chezmoiignore"

# Enumerate effective attributes for every tracked file. Each git-crypt file in
# the locked clone must be ciphertext before its exact target is test-ignored.
step "validate and ignore locked git-crypt targets"
ENCRYPTED_TARGETS=/tmp/chezmoi-encrypted-targets
TRACKED_PATHS=/tmp/chezmoi-tracked-paths
: >"$ENCRYPTED_TARGETS"
as_user git -C "$SOURCE" ls-files -z >"$TRACKED_PATHS"
printf "\n# Container test: skip locked git-crypt targets\n" >>"$SOURCE/.chezmoiignore"
encrypted_count=0
while IFS= read -r -d "" source_path; do
  attribute=$(as_user git -C "$SOURCE" check-attr filter -- "$source_path")
  [[ "${attribute##*: }" == git-crypt ]] || continue
  header=$(od -An -tx1 -N10 "$SOURCE/$source_path" | tr -d " \n")
  [[ "$header" == "00474954435259505400" ]] || {
    printf "git-crypt source is not locked ciphertext: %s\n" "$source_path" >&2
    exit 1
  }
  target=$(as_user chezmoi target-path "$SOURCE/$source_path")
  relative="${target#"$TEST_HOME"/}"
  printf "%s\n" "$relative" >>"$SOURCE/.chezmoiignore"
  # An encrypted target can be re-included by a ! negation elsewhere in
  # .chezmoiignore (e.g. !.trae/traecli.toml), which would defeat the
  # appended ignore and deploy ciphertext — drop such lines.
  grep -vF "!$relative" "$SOURCE/.chezmoiignore" >"$SOURCE/.chezmoiignore.tmp" \
    && mv "$SOURCE/.chezmoiignore.tmp" "$SOURCE/.chezmoiignore"
  printf "%s\n" "$target" >>"$ENCRYPTED_TARGETS"
  ((encrypted_count += 1))
done <"$TRACKED_PATHS"
((encrypted_count > 0))
printf "validated %s locked git-crypt files\n" "$encrypted_count"
chown "$TEST_USER:$TEST_USER" "$SOURCE/.chezmoiignore"

step "apply and verify"
as_user chezmoi apply --no-tty
as_user chezmoi verify

# Core rendered files and source-mode symlinks. dot_zshenv.tmpl is
# git-crypt encrypted, so a locked clone cannot render ~/.zshenv — assert it
# stays undeployed; the loop at the bottom re-checks every locked target.
[[ ! -e "$TEST_HOME/.zshenv" && ! -L "$TEST_HOME/.zshenv" ]]
[[ -f "$TEST_HOME/.ssh/config" && ! -L "$TEST_HOME/.ssh/config" ]]
[[ -f "$TEST_HOME/.gitconfig" && ! -L "$TEST_HOME/.gitconfig" ]]
# External repos are real clones, not symlinks into the source checkout.
[[ -d "$TEST_HOME/.config/zsh/.git" && -f "$TEST_HOME/.config/zsh/env" ]]
[[ -d "$TEST_HOME/.config/nvim/.git" && -f "$TEST_HOME/.config/nvim/init.lua" ]]
[[ -d "$TEST_HOME/.config/firefox/.git" ]]
[[ "$(as_user git -C "$TEST_HOME/.config/firefox" branch --show-current)" == "custom" ]]
[[ -d "$TEST_HOME/.config/ai/llm-wiki/.git" ]]
[[ "$(readlink "$TEST_HOME/.config/git/config")" == "$SOURCE/dot_config/git/config" ]]
[[ "$(readlink "$TEST_HOME/.cargo/config.toml")" == "$SOURCE/dot_cargo/config.toml" ]]
[[ "$(readlink "$TEST_HOME/.condarc")" == "$SOURCE/dot_condarc" ]]
# Linux loaders must contain their exact shared/local includes and no OrbStack.
grep -Fx "Include ~/.ssh/config.local" "$TEST_HOME/.ssh/config" >/dev/null
grep -Fx "Include ~/.config/ssh/config" "$TEST_HOME/.ssh/config" >/dev/null
! grep -Fxi "Include ~/.orbstack/ssh/config" "$TEST_HOME/.ssh/config"
grep -Fx "    path = ~/.config/git/config" "$TEST_HOME/.gitconfig" >/dev/null
grep -Fx "    path = ~/.gitconfig.local" "$TEST_HOME/.gitconfig" >/dev/null
as_user ssh -G localhost >/dev/null 2>&1
as_user git config --global --includes --get-all \
  url.git@github.com:.insteadof >/dev/null
# HOST_PROFILE/ZDOTDIR rendering lived in dot_zshenv.tmpl, which is
# git-crypt encrypted and thus cannot render from a locked clone; the
# hostProfile data path is still asserted via ~/.local/zshrc below.

if [[ "$TEST_PROFILE" == work ]]; then
  [[ -L "$TEST_HOME/.local/zshrc" ]]
  [[ "$(readlink "$TEST_HOME/.local/zshrc")" == "$TEST_HOME/.config/zsh/work.linux.zsh" ]]
  grep -Fx "    path = ~/.config/git/work.config" "$TEST_HOME/.gitconfig" >/dev/null
else
  [[ ! -e "$TEST_HOME/.local/zshrc" && ! -L "$TEST_HOME/.local/zshrc" ]]
  ! grep -Fx "    path = ~/.config/git/work.config" "$TEST_HOME/.gitconfig" >/dev/null
fi

# Private source attributes and Linux platform exclusions.
[[ "$(stat -c %a "$TEST_HOME/.ssh")" == 700 ]]
[[ "$(stat -c %a "$TEST_HOME/.ssh/config")" == 600 ]]
[[ "$(stat -c %a "$TEST_HOME/.gitconfig")" == 600 ]]
for target in \
  "$TEST_HOME/.aerospace.toml" \
  "$TEST_HOME/.config/aerospace" \
  "$TEST_HOME/.config/iterm2" \
  "$TEST_HOME/.config/sioyek" \
  "$TEST_HOME/.config/sketchybar" \
  "$TEST_HOME/.config/skhd" \
  "$TEST_HOME/.config/wm" \
  "$TEST_HOME/.config/yabai" \
  "$TEST_HOME/.gnupg/gpg-agent.conf" \
  "$TEST_HOME/.local/bin"; do
  [[ ! -e "$target" && ! -L "$target" ]]
done
for service in adguard-home bt emby karakeep pihole; do
  target="$TEST_HOME/.config/$service"
  if [[ "$TEST_ROLE" == workstation ]]; then
    [[ ! -e "$target" && ! -L "$target" ]]
  else
    [[ -f "$target/docker-compose.yml" ]]
  fi
done

# No locked git-crypt target may be deployed.
while IFS= read -r target; do
  [[ ! -e "$target" && ! -L "$target" ]] || {
    printf "encrypted target was deployed: %s\n" "$target" >&2
    exit 1
  }
done <"$ENCRYPTED_TARGETS"

# The second apply must start clean and produce no verbose action/diff output.
step "repeat apply and verify idempotence"
[[ -z "$(as_user chezmoi diff)" ]]
[[ -z "$(as_user chezmoi status)" ]]
second_output=$(as_user chezmoi apply --no-tty --verbose 2>&1)
[[ -z "$second_output" ]] || {
  printf "second apply was not silent:\n%s\n" "$second_output" >&2
  exit 1
}
as_user chezmoi verify
[[ -z "$(as_user chezmoi diff)" ]]
[[ -z "$(as_user chezmoi status)" ]]

printf "chezmoi init/apply passed for %s/%s (%s)\n" "$TEST_PROFILE" "$TEST_ROLE" "$(. /etc/os-release; echo "$PRETTY_NAME")"
'
done

if ((tests_run == 0)); then
	printf 'No test image matched CHEZMOI_TEST_FILTER=%s\n' "$CHEZMOI_TEST_FILTER" >&2
	exit 2
fi

printf '\nAll Linux chezmoi container tests passed.\n'
