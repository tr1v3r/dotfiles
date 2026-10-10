# macOS window-manager profiles

AeroSpace and yabai are alternatives, not a stack. The `use` helper stops the
other backend before starting the selected one and reloads the matching
SketchyBar profile.

The two bars are intentionally independent:

- `~/.config/sketchybar/profiles/aerospace.lua`
- `~/.config/sketchybar/profiles/yabai.lua`

The root `sketchybarrc` is only a dispatcher (SbarLua; see
`dot_config/sketchybar/README.md` for its dependencies). The runtime selection
is stored in `~/.config/wm/active` (host-local state, not part of the
repository).

## Install

```sh
brew install --cask nikitabobko/tap/aerospace
brew install asmvik/formulae/yabai asmvik/formulae/skhd jq
brew install FelixKratz/formulae/sketchybar FelixKratz/formulae/borders
brew install lua switchaudio-osx nowplaying-cli
brew install --cask font-sketchybar-app-font
```

Grant Accessibility permission to AeroSpace, yabai, and skhd when macOS
prompts. skhd also requires Secure Keyboard Entry to be disabled. The yabai
configuration deliberately avoids scripting-addition-only features, so SIP can
remain enabled during the comparison.

## Switch

```sh
~/.config/wm/use aerospace
~/.config/wm/use yabai
~/.config/wm/use off
~/.config/wm/use status
```

Both profiles use equivalent Colemak bindings for a fair comparison:
`n/e/u/i` means left/down/up/right, `Alt+1..9` changes workspace, and
`Alt+Shift+1..9` moves the window and follows it.

AeroSpace won the comparison and is the boot default: `start-at-login = true`
in `~/.aerospace.toml` makes AeroSpace register its own login item. Selecting
yabai installs/enables its launchd services; selecting AeroSpace or `off`
stops and uninstalls the yabai/skhd services so they cannot both start at the
next login. To switch back to yabai, set `start-at-login = false` first,
otherwise both backends launch after the next reboot.

## SketchyBar is opt-in

The bar only runs when `~/.config/wm/bar.enable` exists. Without the file
`use` never auto-starts it, and the yabai layout tiles windows 8px below the
menu bar (`external_bar off`, `top_padding 1`). To show the bar:

```sh
touch ~/.config/wm/bar.enable
brew services start sketchybar
yabai --restart-service   # re-reads yabairc layout for the bar
```

Already-running windows can stay at the old coordinates until they are
re-laid-out — switching spaces or toggling a window's float
(`alt+space/d` in skhd) snaps it back.

To hide it again:

```sh
rm ~/.config/wm/bar.enable
brew services stop sketchybar
yabai --restart-service
```

`bar.enable` is host-local state like `active`, not part of the repository.
AeroSpace's `gaps.outer.top` is static — `~/.aerospace.toml` documents the
value to use with and without the bar.
