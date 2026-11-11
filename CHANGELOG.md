# Changelog

This file is used verbatim as the CurseForge release changelog (see `.pkgmeta`).
Update the top section before tagging a new release.

## 0.13.5 (2026-11-11)

- Chat input: new idle state with three modes (Settings -> Skins -> "input box
  idle state"): Fade (new default -- dims to 25% after 3 s idle, back to full on
  focus), Hide (the previous auto-hide behavior) and Always shown. Switching
  takes effect immediately, no reload needed.
- Chat tabs: fixed a regression where clicking a tab focused the input box
  instead of switching windows (introduced together with the fade mode; the
  input box now yields every click on the tab strip, including while typing).
- Settings panel: dropdown rows now use the same chevron artwork as the rest of
  the UI instead of a font glyph.
- Old-style dropdown menus: submenu arrows are now skinned with the same
  chevron (the last batch of stock Blizzard art in the coverage ledger).
- Sliders: skinned everywhere, including lazily created windows (e.g. the
  Blizzard chat opacity slider).
- Bags & Bank: the title-row tool buttons (Sort / Deposit All / Slot
  Management) are now compact icon-only buttons.
- World map: the close button is now actually skinned (the previous global
  name does not exist on this client).
- Gossip: the "Goodbye" button is now skinned (it sits two levels deep, past
  the one-level deep scan).

## 0.13.4 (2026-11-11)

- Chat frame: the outer plate is now exactly as tall as the minimap, with its
  top edge on the minimap's top edge. The tab row and the input box moved out of
  the frame body and now ride on the top border.
- Chat frame: tabs and input box share that strip. While the input box has focus
  it is raised above the tabs (and its own backdrop raised with it); when focus
  is lost it drops back and hides again.
- Chat frame: tab backdrop, input box backdrop and the frame plate now use one
  shared opacity and one shared border strength, so the tab block no longer
  reads as a solid slab next to a hollow frame. Blizzard's own dark plate plus
  its eight border textures on the chat frame are faded out too -- they were
  stacking roughly 0.25 extra opacity on top of ours, which is why the frame
  body looked denser than the tabs sitting on it.
- Chat frame: the native menu / channel / minimize buttons, the "quick join"
  social button and the text-to-speech button now follow the same show/hide
  rhythm as the tabs, so nothing is left floating beside the frame when idle.
  They are click-through while hidden and fade back in together with the tabs
  when you hover the chat frame.
- Chat input: fixed the channel color and the hidden backdrop not taking effect
  in game (an internal call used a dot call on a colon method, so it always
  evaluated to nothing).
- TOC: the version file is deployed along with the code again, so the in-game
  version number matches the release.

## 0.13.3 (2026-11-11)

- Chat tabs: tabs now fade in only while the chat frame is hovered and fade
  out two seconds after the mouse leaves, so the tab row no longer takes space
  when idle. The fade duration is configurable.
- Chat tabs: tab text uses three configurable colors (unselected / selected /
  unread-flash) instead of a single border color.
- Chat input: the edit box border follows the active chat channel color
  (say / party / guild / channel N) and updates immediately when you switch.
- Chat input: the box can auto-hide (on by default). It folds away when idle
  and pops up in the top band when you press Enter or click the chat frame; it
  can be turned off from the options panel. When auto-hide is off, the box can
  sit either at the top or at Blizzard's native bottom position.
- Chat windows: dynamically created temporary windows (numbered above 10, e.g.
  whispers opened in a new window) are now skinned like the main windows.
- Tweaks: removed a settings entry for a loot-range option that no longer
  exists.

## 0.13.2 (2026-11-10)

- Tooltips: fixed tooltips occasionally appearing on top of the minimap when
  "above minimap" anchoring was selected. Blizzard re-anchors GameTooltip on
  every show, so the anchor is now read back each frame and reclaimed whenever
  another writer touched it. A temporarily unavailable minimap panel pins the
  tooltip to absolute screen coordinates instead of following the cursor.
- Anchors: fixed target-of-target placement, and fixed windows drifting to the
  screen edge when a module such as the minimap or quest tracker is disabled.
  Hidden anchor panels now fall back to the correct parent and self-heal.
- Startup: a new Init layer aligns the default chat frame's bottom edge with
  the action bar by saving a separate Edit Mode layout named "MonetUI".
  Blizzard presets and existing custom layouts are never modified; check with
  `/mui init status|run`.
- Currency: gold is always tracked by default; other currencies are opt-in via
  the right-click watch list and its suggestions. The bag title row now draws a
  compact icon plus a short amount (e.g. `35g`) with full values on hover, so
  many tracked currencies still fit. Toggle with `/mui bags currency icons on|off`.
- Category bags: fixed the B key failing to close the bags after enabling
  "show currencies on backpack" in Blizzard's own options.
- Info bar: the durability block is now hover-only and shows average durability;
  clicking it no longer opens the character panel.
- Release builds no longer ship developer diagnostics or dev-only slash
  commands. Local and repository builds keep them.
- Addon version is now read from the TOC instead of being hard-coded.

## 0.13.1 (2026-11-09)

- Group frames: fixed a fallback bug that could make the frames disappear when
  their anchor panel was hidden or not yet laid out. Anchors now fall back to
  absolute screen coordinates with the correct parent, and self-heal when the
  resulting frame would land off-screen.
- Position correction: only the **raid** frame is anchored to the left of the
  minimap panel (14-unit gap, vertically centered). The **party** frame keeps
  its original screen position. `/mui groupframes minimap` now moves the raid
  frame only; `/mui groupframes defaults|reset` restores both;
  `/mui groupframes status` writes an anchor / visibility report to
  `MonetUIDB.groupReport`. Saved positions matching the old 0.13.0 default are
  migrated once; player-dragged positions are never overwritten.
- Category bags: added a "Sort" button to the "free space" title row
  (`C_Container.SortBags`, skipped in restricted windows), also available as
  `/mui bags sort`. The title row now stays visible even when every slot is full,
  and the watched currencies give way to the button.
- Note: the 0.13.0 entry below about *both* party and raid frames sitting left of
  the minimap is superseded by this release.

## 0.13.0 (2026-11-09)

- Info bar currency block: a fully customizable watch list. Pick currencies by
  right-clicking the block (or via `/mui infobar currency ...`), with three
  sources (backpack-flagged / custom / all), a 1-8 display cap with `+N`
  overflow, an optional zero-value switch, and compact number formatting.
  The list comes from the same character-panel currency tab data and is
  resolved by currency ID, with per-ID fallbacks when categories are collapsed.
- Category bags: the "free space" title row now shows the same watched
  currencies, auto-fitted to the available width and kept clear of the bank
  buttons. Toggle with `/mui bags currency on|off` (default on).
- Party and raid frames now sit to the left of the minimap panel, vertically
  centered with a 14-unit gap; group anchors accept named frames and fall back
  to absolute coordinates. `/mui groupframes minimap` snaps them back.
  *(Superseded by 0.13.1: only the raid frame is anchored there, and the
  fallback could make frames disappear.)*

## 0.12.0 (2026-11-08)

- Initial public release for WoW Forever (Interface 16001 / game version 1.60.1).
- Zone-driven Monet-inspired palette: 33 precisely sampled zones, offline color
  sources prioritized as official map art > wuxianwow trip captures > in-game screenshots.
- LibMonetColor-1.0 derives edge / ambient / highlight / neutral tones at runtime,
  with smooth transitions between zones and parent-map inheritance fallback.
- Modular frames and skins: unit, group and boss frames, self-drawn action bars,
  bags, nameplates, minimap, cooldowns, quest tracker, info bar, tooltips,
  window skins and more.
- Every module can be toggled independently and fully reverts to the Blizzard default.
- No hard dependencies (LibStub embedded); `/mui` slash commands; MIT licensed.
