```
 _____ ____  _       _____      _
|_   _|  _ \/ |_   _|___ / _ __( )___
  | | | |_) | \ \ / / |_ \| '__|// __|
  | | |  _ <| |\ V / ___) | |    \__ \
  |_| |_| \_\_| \_/ |____/|_| |_| \___|
```

# dotfiles

Personal dotfiles monorepo, **chezmoi-managed**. Supports macOS plus Ubuntu,
Debian, and Arch Linux, with Linux home-server support and Colemak optimization.

## Highlights

- **chezmoi with `mode = "symlink"`** — targets are symlinks into the source
  repo; edit a file anywhere, it's the same file
- **Region-aware** mirrors, proxies, and AI endpoints — auto-detected, manually overridable
- **git-crypt** encrypted secrets — sensitive files encrypted at rest in the repo
- **Cross-distribution bootstrap** — Homebrew on macOS, APT on Ubuntu/Debian, and pacman on Arch
- **Self-hosted service stacks** — Docker Compose for DNS, media, bookmarks, and downloads
- **Submodule-based configs** — `.zsh/`, `.nvim/`, and `.hermes/` live in their own repos

## Repository Structure

The checkout is the chezmoi **source** dir (`~/.local/share/chezmoi` after
`chezmoi init`):

- `dot_config/` → `~/.config/` — all XDG configs, plus the service stacks and `deploy/`
- `.zsh/`, `.nvim/`, `.hermes/` — independent submodules mapped to their runtime locations
- `dot_zshenv.tmpl`, `dot_condarc`, `dot_cargo/`, `dot_gnupg/` → home-level dotfiles
- `scripts/`, `*.md` — repo-only; encrypted `age/` and `secrets/` live under `dot_config/`
- `.chezmoiignore` — per-machine exclusions (`machineRole`: `workstation` vs `home-server`)

## New Machine Bootstrap

Prerequisites: install `chezmoi` and `git` so the source repository can be cloned.
Then run the complete bootstrap flow:

```bash
# 1. clone via chezmoi + answer the questionnaire (host profile, machine role)
chezmoi init git@github.com:tr1v3r/dotfiles.git

cd ~/.local/share/chezmoi

# 2. install system packages when the machine is not provisioned yet. This is
#    explicit so chezmoi apply stays non-root and headless-safe.
./scripts/init.sh

# Linux-only optional package groups:
./scripts/init.sh --with-zsh      # one optional group
./scripts/init.sh --with-all      # Zsh + Go + Rust + ranger

# 3. unlock encrypted files (requires the GPG key) — BEFORE first apply
#    The base package bootstrap above includes git-crypt.
git-crypt unlock

# 4. deploy everything (never starts package installation)
chezmoi apply
```

The responsibilities are intentionally separated:

```text
chezmoi init -> scripts/init.sh -> git-crypt unlock -> chezmoi apply
clone source    install packages   decrypt secrets    deploy configuration
```

`scripts/` is part of the chezmoi source repository but is excluded from target
deployment by `.chezmoiignore`. Package installation is therefore explicit and
repeatable; `chezmoi apply` stays usable without root, a TTY, or package-manager
network access. After pulling bootstrap changes, rerun `./scripts/init.sh` manually.

## Linux bootstrap tests

Run the same installation twice in clean Ubuntu 24.04, Debian 12, and Arch
containers, then verify the expected commands. On arm64 hosts, the official Arch
image runs as linux/amd64 under the container engine's emulation:

```bash
# Package bootstrap: real install plus sudo/idempotence checks.
./scripts/test_linux_containers.sh
BOOTSTRAP_TEST_FILTER=arch ./scripts/test_linux_containers.sh

# Chezmoi: locked local clone, init/apply/verify, profiles, roles, and idempotence.
# Every tracked file with an effective git-crypt filter must be ciphertext and skipped.
./scripts/test_chezmoi_containers.sh
CHEZMOI_TEST_FILTER=debian-12 ./scripts/test_chezmoi_containers.sh
```

The chezmoi matrix uses work/workstation on Ubuntu, personal/workstation on
Debian, and work/home-server on Arch. It pins chezmoi v2.72.0 and resolves all
submodules from the mounted local repositories, so only package and release
downloads need network access. The clone intentionally tests committed HEAD and
refuses to run when deployable source paths have uncommitted changes.

The bootstrap does not replace package mirrors, perform Debian/Ubuntu system
upgrades, clone configuration into root's home, or change the login shell. On
Linux, use `./scripts/init.sh --help` for optional groups, dry-run, and retry controls.

## Notes

- **Encrypted paths**: see `.gitattributes` (`secrets/**`, `dot_config/ssh/config`,
  `dot_config/git/work.config`, `dot_config/aerc/accounts.conf`, various `*.env`).
- **Editing**: non-template targets are symlinks — edit in place. Templates
  (`*.tmpl`) are rendered copies; edit them with `chezmoi edit <target>`.
- **Submodules**: `.zsh/`, `.nvim/`, and `.hermes/` are separate repos
  with their own docs — edit and commit there, then bump the pointer here.
- **SSH layering**: chezmoi renders `~/.ssh/config`; machine-local overrides live in
  unmanaged `~/.ssh/config.local`, macOS also includes OrbStack, and shared hosts
  remain in the encrypted `~/.config/ssh/config`.
- **Git layering**: shared URL rewrites and the global ignore live under
  `~/.config/git/`; identity, trust, and machine hooks stay in unmanaged
  `~/.gitconfig.local`, included last so they can override shared defaults.
- **Zsh machine profile**: chezmoi maps `hostProfile` plus the operating system to
  `~/.local/zshrc` (`work.mac`, `work.linux`, or personal macOS `air.mac`).
- **Service stacks** deploy only with `machineRole = "home-server"`.

## License

GPL — see headers in individual files.
