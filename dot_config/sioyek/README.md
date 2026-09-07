# Sioyek configuration

Sioyek on macOS reads `prefs_user.config` and `keys_user.config` from inside
`/Applications/Sioyek.app/Contents/MacOS/`. Chezmoi deploys the real files here
and `run_onchange_after_link-sioyek-config.sh.tmpl` repairs symlinks when either
config hash changes or the app bundle is replaced.

## Install (NOT via brew)

The homebrew cask was disabled on 2026-09-01 (the 2.0.0 build fails the
Gatekeeper check) and ships Intel-only. Sioyek is installed manually from the
official arm64 build — currently the `sioyek3-alpha0` prerelease, the only
official Apple Silicon build:

```sh
curl -fsSL -o /tmp/sioyek.zip \
  https://github.com/ahrm/sioyek/releases/download/sioyek3-alpha0/sioyek-release-mac-arm.zip
unzip -q /tmp/sioyek.zip -d /tmp/sioyek3
hdiutil attach -nobrowse -readonly -mountpoint /tmp/sioyek3/mnt /tmp/sioyek3/build/sioyek.dmg
cp -Rp /tmp/sioyek3/mnt/sioyek.app /Applications/Sioyek.app
xattr -dr com.apple.quarantine /Applications/Sioyek.app
hdiutil detach /tmp/sioyek3/mnt
```

`scripts/init_mac.sh` does the same on a fresh machine. The CLI wrapper is
chezmoi-managed at `dot_local/bin/sioyek` → `~/.local/bin/sioyek` (already on
PATH; ignored on non-darwin hosts). The build is adhoc-signed and
curl-downloaded files carry no quarantine attribute, so the `xattr` line is a
safety net; global Gatekeeper and SIP stay enabled. Databases (highlights,
bookmarks) live in `~/Library/Application Support/sioyek` and survive app
replacements; the bundle symlinks are repaired by `chezmoi apply`.

## Bindings

Bindings add a Colemak navigation layer (`n/e/u/i`) plus uppercase quick
movement (`N/E/U/I`: smart left, screen down, screen up, smart right). Search
results use `,`/`.` for previous/next. Display controls use a mnemonic `z`
prefix: `zc` toggles Tokyo Night paper colors and `zp` toggles the portal
helper window.
