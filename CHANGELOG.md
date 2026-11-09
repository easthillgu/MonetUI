# Changelog

This file is used verbatim as the CurseForge release changelog (see `.pkgmeta`).
Update the top section before tagging a new release.

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
