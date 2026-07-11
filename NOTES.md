# NOTES.md

Keywork API pain points and bugs found while building the shell.
Fix these in `../keywork`, then simplify here.

## Open

- **Seats without pointer capability crash window creation.** On headless
  sway (`WLR_BACKENDS=headless`, no input devices) keywork dies with
  `wl_seat.get_pointer called when no pointer capability has existed` and
  `window bar:HEADLESS-1: creation failed: error.DispatchFailed`. Pointer
  binding should follow `wl_seat.capabilities` instead of being assumed.

## Resolved

- **`require` needed a LUA_PATH bootstrap.** Both `bin/keywork-shell` and
  `make run` exported `LUA_PATH` so `require("shell.*")` could resolve.
  Fixed in keywork: the script's directory is prepended to `package.path`
  (`<dir>/?.lua;<dir>/?/init.lua`). The entry point moved to `lua/init.lua`
  so `lua/` is the module root, and the bootstrap is gone.
- **SVG icons lost `<use>`-cloned shapes.** Even with the right file
  resolved, GNOME's Files icon rendered with one drawer handle instead
  of three: the icon draws one handle and clones the rest with
  `<use xlink:href>`, which nanosvg silently drops (librsvg-based
  launchers like fuzzel render it fully). Fixed in keywork `e1e8eee4`:
  a text-level pass expands each resolvable `<use>` into a
  `<g transform>` clone of its target before rasterizing.

- **App icons resolved to their symbolic variants.** GNOME Files showed
  the grey symbolic cabinet instead of its full-color icon. index.theme
  parsing let `Size=` clobber an already-parsed `MinSize=`/`MaxSize=`
  (hicolor writes MinSize before Size), so `hicolor/scalable/apps`
  collapsed to range [128, 256], launcher-sized lookups skipped it, and
  the `-symbolic` name fallback in `symbolic/apps` won. Fixed in keywork
  `e9abe79e`: MinSize/MaxSize are optionals that default to Size at use
  time, making the parse order-independent (with regression test
  "scalable directory size range survives any key order").

- **Tab couldn't be bound as a shortcut.** `shortcutKeyForInput` mapped
  `.tab` to null unconditionally, so the launcher's actions menu had no
  key to open it. Fixed in keywork: plain tab is a bindable `ShortcutKey`
  (`tab = "..."` in `kw.shortcuts`); unbound tab still falls through to
  focus traversal and shift-tab always keeps reverse traversal (with
  regression test "bound tab fires its shortcut instead of traversal").

- **Auto-sized popups didn't resize when their content changed.** The Wi-Fi
  menu rebuilt with newly discovered rows, but its `xdg_popup` retained the
  height measured when it opened and clipped them. Fixed in keywork: dirty
  parent-owned popup content is remeasured and size changes are applied with
  `xdg_popup.reposition`.
- **Clicking parent-window empty space didn't dismiss anchored popups.**
  Fixed in keywork: a press on the parent surface outside every live
  popup's anchor calls the popups' `on_close` and consumes the press
  (macOS menu semantics — the click never activates what's beneath).
  Presses on the anchor still pass through so its gesture toggles.
- **Popups were CPU-backend only.** `runner.zig` hard-gated popups to the
  shm backend and `PopupManager` was hard-typed to it. Fixed in keywork:
  `PopupManager` is generic over the backend, the vulkan backend gained
  `createPopup` (the xdg_popup plumbing was already shared in window.zig),
  and the gate is now `@hasDecl(Backend, "createPopup")`. Verified live:
  popup renders in its own Vulkan swapchain. The *multi-window* host
  (`windows = function(ctx)`) was shm-only at the time but has since
  gained Vulkan too (verified live in keywork-files).
- **Popup surfaces cleared to opaque theme background.** Rounded menu
  corners showed opaque squares: layer-shell windows get
  `setFrameBackground(transparent)` but popup runtimes in
  [runner.zig](../keywork/src/app/runner.zig) `createPopup` didn't. Fixed in
  keywork — popups now clear transparent and content paints its own
  background.
- **Hover highlight lost on rebuild while pointer rests on target.** Any
  full rebuild (clock tick, status update) rewrote hovered clickables with
  their base background: `updateElementTreeScoped`'s `.clickable` branch in
  [model.zig](../keywork/src/ui/model.zig) passed the raw child instead of
  `clickableStyledChild(...)` like the build path does. Fixed in keywork
  (with regression test "clickable keeps hover background through tree
  update"); highlight now survives rebuilds until the pointer moves off.
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
