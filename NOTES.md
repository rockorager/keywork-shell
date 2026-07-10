# NOTES.md

Keywork API pain points and bugs found while building the shell.
Fix these in `../keywork`, then simplify here.

## Open

- **Cursor set inside a popup grab sticks after the pointer leaves (sway).**
  With a hand cursor shown over a menu row, moving the pointer out of the
  popup onto dead space left the hand visible. Not fixable client-side:
  sway only honors `cursor_shape.set_shape` from the *currently focused*
  pointer client with the current enter serial, so resetting on
  `wl_pointer.leave` is ignored by design, and during an xdg_popup grab
  sway keeps displaying the last client-set cursor over dead space.
  Compositor-side (sway/wlroots) gap; consider reporting upstream.
  Sidestepped entirely instead: keywork clickables now default to the
  arrow cursor (`3cfca56e7718`), matching macOS, where the pointing hand
  is reserved for hyperlinks and menus/buttons/menu-bar extras keep the
  arrow (hover highlight is the affordance). Link-like widgets opt in
  with `cursor = "pointer"` on `kw.gesture`/`kw.chip`.

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
- **`kw.expanded` + `vertical_align` centers against the wrong height.**
  A box inside a tight flexible fit aligns its child while shrink-wrapped,
  then [layout.zig](../keywork/src/ui/layout.zig) `setMainExtent` (tight-fit
  branch, ~L513) inflates the box rect afterwards without re-aligning the
  child — so `expanded(container({ vertical_align = "center" }))` renders
  content top-aligned with the slack at the bottom. This made the whole bar
  row sit ~2px high. Partially fixed in keywork: the bar's
  `expanded(container)` case now centers correctly (pixel-verified in the
  shell). Kept open until the general case is done.

- **Seats without pointer capability crash window creation.** On headless
  sway (`WLR_BACKENDS=headless`, no input devices) keywork dies with
  `wl_seat.get_pointer called when no pointer capability has existed` and
  `window bar:HEADLESS-1: creation failed: error.DispatchFailed`. Pointer
  binding should follow `wl_seat.capabilities` instead of being assumed.

## Heads-up (not bugs)

- **Keywork dropped its bundled phosphor icon theme** (`ebbd9e82`): icon
  names now resolve through standard XDG lookup (Adwaita by default), so
  only freedesktop names work — e.g. `object-select` (check),
  `network-wireless-encrypted` (lock). Bare phosphor names like `check`
  and `lock` render as the missing-icon box.

## Resolved

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
  popup renders in its own Vulkan swapchain. Note: the *multi-window* host
  (`windows = function(ctx)`) is still shm-only — separate gap.
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
