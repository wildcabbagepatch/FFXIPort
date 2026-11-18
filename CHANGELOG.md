# Changelog

All notable changes to FFXIPort. Versions before 1.1.0 belong to the earlier
independent frontend and its previous server module (see
docs/PROVENANCE-M8.md); their history is kept in the project's earlier records.

## 1.2.0 — release

Changes since the published 1.1.0. The FPX/1 protocol, the destination
catalogue (193 destinations, catalogue version 7), travel rules and the
default prices are unchanged.

* **Themes:** Classic (default; identical to 1.1.0), Squad (dark navy with
  gold) and Crimson (dark with muted burgundy), switched with three dots at
  the top right of the window. Styling is scoped to FFXIPort's own windows.
* **UI scale 70 %–200 %** (text, buttons, tabs, rows, stars, spacing) from the
  new **UI** options popover. Header and footer controls wrap instead of
  overflowing.
* **Expansion filter:** All / Original / Rise of the Zilart / Chains of
  Promathia / Treasures of Aht Urhgan; combines with search and "Only what I
  can use".
* **Favourite star:** drawn outline/filled star with hover preview and tooltip.
* **Optional floating button** (off by default): just a rounded, themed
  button with no panel around it; click opens/closes FFXIPort, drag moves it.
* Theme, scale, filter, floating button and its position are **saved per
  character**. Choices made before login are session-only; each character's
  saved settings apply after login and after a character switch.
* **Server prices are configurable and validated** in `fpxport.lua`
  (`M.config.prices`, `sameCityFree`); invalid entries are logged as
  `CONFIG ERROR` and fall back to the default. Players cannot change prices.
* `/port status` shows the UI settings and whether text scaling works.
* Existing settings files and favourites load unchanged (new keys `theme`,
  `expansion`).

1.2.0 is functionally identical to 1.2.0-rc.2, which the owner accepted in
game; only the version number and documentation differ.

### 1.2.0-rc.2 — stabilization (local, not published)

Fixes after the first in-game test of rc.1. No new features; protocol,
prices, catalogue, filters, favourites, commands and the main window are
unchanged.

* **Floating button without outer panel:** only the compact, rounded FFXIPort
  button is visible, in its theme colours. The ImGui host window around it no
  longer draws a background, border, padding or minimum-size margin; the whole
  visible button is the click and drag area. Scoped to that window only.
* **Fix:** after switching characters without reloading the addon, the
  floating button could appear at the previous character's position. Each
  character now uses its own saved position (or the default). Runtime position
  and drag state are dropped on every login, logout and character switch.
* **Fix:** a theme (or scale, filter or floating-button choice) picked before
  login could override the character's saved setting after login. Choices made
  before login are now session-only until a character's settings load; then
  the character's saved settings apply and the pre-login choices are
  discarded, never saved.

### 1.2.0-rc.1 — release candidate (local, not published)

UI improvements and server price configuration. The FPX/1 protocol, the
destination catalogue, travel rules and the default prices are unchanged.

* **Themes:** Classic (default; identical to 1.1.0), Squad (dark navy with
  gold, after the XI: Forever Offline Squad window) and Crimson (dark with
  muted burgundy). Switched with three dots at the top right of the window and
  saved per character. All theme styling is scoped to FFXIPort's windows.
* **UI scale 70 %–200 %:** text (ImGui 1.92 `PushFont(font, size)`), buttons,
  tabs, rows, stars, padding and spacing; changed live from the new **UI**
  options popover; saved per character. Header and footer controls wrap
  instead of overflowing at small widths or large scales.
* **Expansion filter:** All / Original / Rise of the Zilart / Chains of
  Promathia / Treasures of Aht Urhgan; combines with search and "Only what I
  can use"; saved per character.
* **Favourite star:** drawn outline/filled star with hover preview and
  tooltip; no icon font needed.
* **Floating button (optional, off by default):** opens/closes FFXIPort,
  draggable, position saved per character, Reset position in the options.
* **Server prices are configurable and validated** (`M.config.prices`,
  `sameCityFree`). Invalid entries are logged as `CONFIG ERROR` and fall back
  to the category's default. A category can be made free (all amounts 0) or
  limited to one currency. Players cannot change prices.
* `/port status` shows the UI settings and whether text scaling works.
* New settings keys `theme` and `expansion`. Existing settings files and
  favourites load unchanged.

## 1.1.0 — public release (Milestone 8)

Replaces FFXIPort's whole communication layer with independently designed
parts:

* **New protocol FPX/1** (`docs/PROTOCOL-FPX1.md`) and **new server module
  `fpxport.lua`** (command `!fpx`). The previous server module (`ffxiport.lua`,
  `!ffxip`) and its protocol are superseded; there is no compatibility mode.
* **Prices:** Home Points, Survival Guides and Gate Crystal teleports cost
  1,000 gil or 100 Conquest Points; Runic Portals 1,000 gil or 100 Imperial
  Standing; travel within the same city is free.
* **Transactions:** a charge happens only after every check passes. Request
  ids plus a per-load session id prevent double charges. A failed move is
  refunded, and the refund is confirmed against the balance. Unclear outcomes
  are reported to the player and logged as `CURRENCY INCIDENT`.
* **Catalogue** regenerated from LandSandBoat sources by `tools/gen_catalog.lua`
  (catalogue version 7). The 193 destinations are unchanged.
* **Diagnostics:** `/port status` explains server id ranges vs. listed
  destinations and lists unlocked destinations outside the catalogue's
  Original–ToAU scope; after the first sync of a session a one-line warning
  appears if there are any.
* UI layout, Favorites, per-character settings, `/port` commands, automatic
  sync, Quiet Chat and echo suppression are unchanged.

### Release candidates leading to 1.1.0

* **rc.5:** live sync reception fixed. LSB fills the speaker field of server
  messages with the receiving character's own name, so frames are now trusted
  on channel 29 from an empty or own-name speaker. Frames now fit LSB's
  150-byte chat field (128-byte chunks). The trace shows the packet mode.
* **rc.4:** client session id in every request; the server replay cache is
  keyed by session id + request id, so request ids cannot collide after a
  quick addon reload.
* **rc.3:** final pricing; free same-city travel from LSB zone data; consistent
  travel outcomes (same-RID correction after a failed move, `UNSURE` code,
  confirmed refunds).
* **rc.2:** transaction hardening against currency-API, send and move
  failures; GPLv3 LICENSE; portable ZIP paths.
* **rc.1:** first Milestone 8 package: FPX/1, `fpxport.lua`, adapted client.

Per-file detail for each candidate: `docs/CHANGES-M8.md` (source distribution).
