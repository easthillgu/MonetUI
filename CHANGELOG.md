# Changelog

This file is used verbatim as the CurseForge release changelog (see `.pkgmeta`).
Update the top section before tagging a new release.

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
