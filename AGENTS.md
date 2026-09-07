# AGENTS.md

Guidance for coding agents working in this repository. `CLAUDE.md` is a symlink
to this file, so Claude Code and other tools share this single copy.

## Repository Overview

Personal dotfiles monorepo (git user: `tr1v3r`; main branch `master`, active
work on `dev`), **managed by chezmoi**. The git checkout lives at
`~/.local/share/chezmoi` — this is the only source of truth. `~/.config` and
the home-level dotfiles it deploys are **targets**: with `mode = "symlink"`
most files there are symlinks into the source repo, so editing a target file
edits the repo directly. Only `.tmpl` templates are rendered copies — edit
those with `chezmoi edit <target>`.

`~/.config/.git.retired` is the frozen `gitdir` of the old in-place checkout
(renamed 2026-08-29 during cleanup; its `dev` history matches `dotfiles.git`
at `ca94b4f` — nothing unique). It is a rollback hatch only; safe to delete
once stable. `~/.config/CLAUDE.md → AGENTS.md` is a local pair, deliberately
NOT chezmoi-managed (see `.chezmoiignore`) — keep it in sync manually with the
source-root `AGENTS.md`. Everything else in `~/.config` is deployed symlinks
plus host-local, untracked state (caches, app data) — normal and not part of
the repo.

## Critical: git-crypt encrypted files

This repo uses **git-crypt**. Paths in `.gitattributes` (all under `dot_config/`) are encrypted at rest in git:

`dot_config/secrets/**`, `dot_config/age/keys.txt`, `dot_config/age/keys-pq.txt`, `dot_config/ssh/config`,
`dot_config/aerc/accounts.conf`, `dot_config/git/work.config`,
`dot_config/deploy/k8s/mysql/deploy-mysql-singleton.yaml`,
`dot_config/deploy/k8s/redis/redis-config.yaml`,
`dot_config/iterm2/com.googlecode.iterm2.plist`,
`dot_config/adguard-home/conf/**`, `dot_config/pihole/.pihole.env`,
`dot_config/emby/.env`, `dot_config/karakeep/.env`,
`dot_config/himalaya/config.toml`, `dot_config/ortie/config.toml`.

- After a fresh clone: `git-crypt unlock` (once per clone) before any
  `chezmoi apply`, otherwise chezmoi would deploy ciphertext.
- Never paste secret values into plaintext. New secrets go under `dot_config/secrets/**`
  or become git-crypt-encrypted paths.
- If a file shows as binary/ciphertext, the clone is locked — unlock it, don't
  overwrite with plaintext.

## Source layout (curated root)

There is **no whitelist `.gitignore` anymore** — the root contains exactly
what is tracked:

```
~/.local/share/chezmoi/
├── .zsh/ .nvim/ .hermes/ # submodules, hidden from chezmoi (dot-prefix), dir-symlinked
├── dot_config/          # → ~/.config/ (all XDG configs, service stacks, deploy/)
├── dot_zshenv.tmpl      # → ~/.zshenv (renders HOST_PROFILE from chezmoi data)
├── private_dot_gitconfig.tmpl # → ~/.gitconfig loader; .gitconfig.local stays local
├── dot_local/           # → ~/.local/ (machine-profile Zsh link)
├── dot_condarc          # → ~/.condarc
├── dot_cargo/           # → ~/.cargo/
├── dot_gnupg/           # → ~/.gnupg/ (gpg-agent.conf is a darwin/linux template)
├── private_dot_ssh/     # → ~/.ssh/ loader; config.local remains host-local
├── scripts/             # bootstrap scripts — NOT deployed (see .chezmoiignore)
├── .chezmoi.toml.tmpl   # init questionnaire → hostProfile / machineRole / firefoxProfile
├── .chezmoiignore       # per-machine exclusions (template)
└── .chezmoiscripts/     # post-apply platform hooks (package bootstrap is explicit)
```

## Bootstrap (new machine)

```bash
chezmoi init git@github.com:tr1v3r/dotfiles.git   # clone + answer the questionnaire
cd ~/.local/share/chezmoi
./scripts/init.sh                                  # explicit system packages; self-elevates on Linux
git-crypt unlock                                  # decrypt secrets (needs the GPG key)
(cd .hermes && git-crypt unlock)                  # submodule credentials, same GPG key
chezmoi apply                                     # deploy config; never installs packages
```

Package installation is deliberately explicit: `chezmoi apply` must remain usable
without root, a TTY, or package-manager network access.

Linux validation is split by responsibility: `scripts/test_linux_containers.sh`
tests real package bootstrap, while `scripts/test_chezmoi_containers.sh` clones a
locked repository and tests init/apply/verify/idempotence across Ubuntu, Debian,
and Arch. The latter enumerates effective Git attributes for every tracked file,
requires each git-crypt file to be ciphertext, ignores its exact target, and must
never deploy ciphertext. It tests committed HEAD and rejects dirty deployable
source paths instead of silently testing stale code.

## Submodules

See `.gitmodules`. After cloning: `git submodule update --init`. Known
submodules: `.zsh`, `.nvim` (whole-dir-symlinked to `~/.config/zsh` and
`~/.config/nvim` via `dot_config/symlink_*.tmpl`), `.hermes`
(whole-dir-symlinked to `~/.hermes` via `symlink_dot_hermes.tmpl`),
`dot_config/firefox` (custom branch), `dot_config/ai/llm-wiki`. The old
`ranger/plugins/{ranger_devicons,ranger-gpg}` submodules are **vendored**
(pinned commits, plain files now). `.hermes` keeps its credentials
(`.env`, `auth.json`) git-crypt-encrypted with the same GPG key — unlock it
once after cloning (see Bootstrap).

## Directory Map

**Shells / editors / CLI tools**: `zsh/` (submodule at `.zsh/`, has its own
CLAUDE.md/AGENTS.md), `nvim/` (submodule at `.nvim/`), `aerc/`, `himalaya/`,
`kitty/`, `iterm2/`, `tmux/`, `tmux-powerline/`, `ranger/`, `yazi/`,
`lazygit/`, `gnupg/`→promoted, `ssh/`, `git/`, `raycast/`, `neofetch/`,
`snipaste/`, `btop/` (replaced deprecated `bashtop/` 2026-08), `herdr/`,
`dsh/`, `.hermes/` (private Hermes Agent config submodule), `skills/`, `ai/`,
`ortie/` (ortie contains credentials — git-crypt encrypted).

**Self-hosted service stacks** (under `dot_config/`, each with a README):
`adguard-home/`, `pihole/`, `emby/`, `karakeep/`, `bt/`. Applied **only** on
machines whose `machineRole` is `home-server` (see `.chezmoiignore`).

**Infra / secrets**: `deploy/`, `secrets/`, `age/` (git-crypt-protected, under `dot_config/`),
`scripts/` (self-elevating package bootstrap and container tests, NOT deployed).

## Multi-machine model

Two independent axes, both answered at `chezmoi init`:

- `hostProfile` (`work` | `personal`) — rendered into `~/.zshenv` as
  `HOST_PROFILE`, selects work-only Git config, and maps `~/.local/zshrc` to the
  matching OS/profile file (`work.mac`, `work.linux`, or personal `air.mac`).
- `machineRole` (`workstation` | `home-server`) — gates service-stack
  deployment via `.chezmoiignore`.

Do not invent a third mechanism; extend these.

## Conventions

- Secrets via git-crypt (or 1Password CLI `op item get`) — never hardcoded.
- Prefer editing the submodule repos in place (`.zsh/`, `.nvim/`, `.hermes/`) and committing there, then bumping the pointer here.
- Rust-modern CLI tools are the default (`bat`, `rg`, `eza`, `fd`, `zoxide`).
- Dependabot alerts on the stale `master` default branch (default-branch switch pending).
