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

## Raycast window management is not a third backend

Verified 2026-10-14 against AeroSpace 0.21.3-Beta and Raycast 2.8.0. The two are
different layers, not interchangeable backends and not a stack: AeroSpace is a
resident layout engine (it decides window geometry and keeps a workspace tree),
while a Raycast window command is a one-shot placement action with no state.

- AeroSpace: i3-style automatic tiling (tiles/accordion/floating, `join-with`,
  `balance-sizes`), its own workspaces plus cross-monitor rules and per-app
  `on-window-detected` callbacks, a full CLI/IPC surface, uniform `gaps`, SIP left
  enabled. In exchange it takes over every window (dialog and utility windows need
  rules), draws no focus cue of its own (hence `~/.config/borders/bordersrc`), keeps
  native-fullscreen windows out of the focus graph, and hides other workspaces'
  windows off-screen — see the leak note below.
- Raycast: zero-config and discoverable (type "left half" instead of learning a
  keymap), no second resident WM process beyond the launcher already running, and
  halves/thirds/quarters/center plus "restore previous position", with extensions
  such as Window Layouts that re-apply a whole arrangement. What it cannot do is
  tile automatically, keep workspaces (only native Spaces), move focus by
  direction, express per-app rules, add gaps, or act as a stable scriptable IPC
  surface. macOS' own tiling shortcuts cover its basic cases for free.
- Running both: AeroSpace is running, so a tiled window moved by Raycast snaps back
  on the next layout refresh. Raycast window commands only mean something on
  floating windows or when AeroSpace is off (`~/.config/wm/use off`). Do not bind
  them to `Alt+<direction>` — AeroSpace owns those.

Verdict: keep Raycast as the launcher; it earns no window-management configuration
on this machine. (`dot_config/raycast/` tracks only AI providers and one
AppleScript, which matches.)

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

## Known AeroSpace limitations

See [Hidden workspace windows leaking onto a neighboring display](aerospace-hidden-window-leak.md)
for an anonymized reproduction, display-arrangement workaround, and the
limits of the diagnosis.
