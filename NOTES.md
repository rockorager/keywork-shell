# NOTES.md

Keywork API pain points and bugs found while building the shell.
Fix these in `../keywork`, then simplify here.

## Open

- **No `loop.listen` in the Lua socket API.** `keywork.loop` exposes
  `connect` only ([socket.zig](../keywork/src/lua/socket.zig)); listen/accept
  exist in Zig but aren't exported. Not blocking the shell — control IPC went
  over D-Bus instead (`bus:request_name` + `bus:export`, see `lua/shell/ipc.lua`),
  which the API already supports well — but a Lua app still can't host a plain
  unix socket server.
- **Removed theme tokens fail silently.** After keywork `7e84d0aa` moved theme
  tokens to Radix scales, old lookups like `theme.radius.md` return nil and
  widgets quietly render without radius (square selection highlight in the
  launcher) instead of raising or warning. Consider making `resolve_theme`
  (or widget option parsing) warn on nil/unknown style tokens so API breaks
  surface loudly.

## Resolved

- **Resolved theme drops the font-size scale.** Fixed in keywork `7e84d0aa`:
  `resolve_theme` now returns `font_size`. The launcher footer hints use
  `theme.font_size[1]`.
- **`kw.chip` has no component theme.** Fixed in keywork `7e84d0aa`: chips
  read metrics/colors from `theme.components.chip` (explicit options win).
  The bar defines its chip design once in `colors.lua` (`palette.chip_theme`)
  and call sites only pass what differs.
- **`--script=` swallows app args.** Fixed in keywork `708a6ac1`:
  `keywork --script=foo.lua bar` now lands `bar` in the Lua `arg` table.
  `bin/keywork-shell` already passed `"$@"` through; no change needed here.
