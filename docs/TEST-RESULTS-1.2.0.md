# Test results — FFXIPort 1.2.0

All runs below were executed in this workspace on Windows 11 against the
final 1.2.0 sources. Raw outputs are in `tests/results/`, one file per runtime
and suite, written by the same runs. 1.2.0 differs from the approved
1.2.0-rc.2 only in the version string (`FFXIPort.lua`) and documentation;
the sections on rc.2 below describe the tests added in that candidate.

| Runtime | Installed via |
|---------|---------------|
| LuaJIT 2.1.1720049189 | winget `DEVCOM.LuaJIT` |
| Lua 5.4.6 | winget `DEVCOM.Lua` |

## Executed

| Suite | What it exercises | LuaJIT 2.1 | Lua 5.4.6 |
|-------|-------------------|-----------|-----------|
| `tests/server/test_fpxport.lua` | server module vs LSB API mocks: FPX/1, prices, same-city, transactions, replay, fault injection, **configurable prices (new)** | **78 passed, 0 failed** | **78 passed, 0 failed** |
| `tests/client/test_client.lua` | client end-to-end against the real server module over realistic 0x017 packets; **custom server prices in the client preview (new)** | **70 passed, 0 failed** | **70 passed, 0 failed** |
| `tests/client/test_ui.lua` | window, rows, theme and widgets against a **recording ImGui mock** (rc.2: +13 tests for the three fixes) | **40 passed, 0 failed** | **40 passed, 0 failed** |
| `tests/client/test_addon_smoke.lua` | real `FFXIPort.lua` with Ashita stubs: load, sync, commands, status, unload | **9 passed, 0 failed** | **9 passed, 0 failed** |
| Compile check (`loadfile`) of all 31 Lua files (client, server, tests, tools) | syntax | 0 errors | 0 errors |
| `tools/verify_catalog_vs_lsb.lua` | catalogue ↔ server ↔ upstream LSB | 193 rows, 0 mismatches | not run |
| `tools/gen_city_groups.lua … .` | same-city table ↔ LSB | 24 zones, 0 mismatches | not run |
| `tools/gen_catalog.lua` | regenerated catalogue is byte-identical to the shipped one | identical | not run |

The three tool checks above (which need an upstream LandSandBoat checkout) were last run on rc.1 and not re-run since: the server module, catalogue and tools of 1.2.0 are byte-identical to rc.1 and rc.2 (SHA-256 compared file by file with the rc.1 and rc.2 source archives). The four suites and the compile check were re-run on 1.2.0.

## rc.2 regression tests (`test_ui.lua`, mocked ImGui)

* **No visible host window:** in Classic, Squad and Crimson at 70 / 100 / 200 %, the floating-button window has `NoBackground` and `NoTitleBar`, a transparent `WindowBg`, zero padding, zero border and a 1 × 1 minimum size, and contains only the button. The button keeps the theme's button colour, text colour and a rounding greater than zero.
* The host-window style is not applied to the main window (normal background, no `NoBackground`), and all stacks are balanced.
* **Click vs. drag:** click toggles; a drag release never toggles; a later click toggles again; a press that moves less than the 4 px threshold counts as a click.
* **The reported character-switch sequence, without an addon reload:** A drags and saves; switching to B shows B's saved position, C shows the default, and back to A shows A's. B's file is untouched.
* A drag in progress during a character switch is discarded and never saved to either character.
* Logout → login restores the character's visibility and position.
* **The reported pre-login sequence:** a theme picked before login is replaced by the character's saved theme (and scale) at login and is not saved. Pre-login scale, filter, floating-button and drag choices do not leak either.
* A new character gets Classic, not the pre-login choice. Changes after login are saved to that character only. Favourites and saved settings survive the pre-login session.
* **Layer checks:** an override left in place is ignored while a character is logged in (even without the switch callback), and a saved drag position is read back from the settings (no lingering runtime position).

Mutation check for rc.2 (scratch copy): restoring the rc.1 behaviour of
`window.lua` makes 9 UI tests fail, reproducing both reported bugs. Removing
each fix layer alone makes 1–2 tests fail. Removing the host-window style or
the `NoBackground` flag makes the no-background test fail.

## Coverage of the requested areas

**UI and settings** (`test_ui.lua`, mocked ImGui):
* Defaults: Classic, 100 %, All expansions, floating button hidden.
* Invalid stored values (theme, scale, expansion, button, position) corrected without errors.
* A 1.1.0 settings file without the new keys loads with defaults; favourites kept.
* Per-character isolation and reload of theme, scale, expansion, floating button and position.
* Classic pushes exactly the 1.1.0 colours and no title-bar colour.
* Dot clicks switch Classic ↔ Squad ↔ Crimson immediately (colours pushed at window begin) and save the choice.
* Every theme defines every colour the UI uses; text and status colours are readable on the background (luminance check).
* Dot tooltips; a single ring marks the active dot.
* Colour, style and font stacks are balanced after every frame in every theme, including after an injected render error.
* Options popover: `+`/`-`/`100%` change the scale live and stop at 70 and 200.
* `PushFont` sizes 9.1 / 13 / 26 at 70 / 100 / 200 %; minimum window size scales.
* Star and dots are sized from the font, so they scale with it.
* Layout: at 70 / 100 / 200 % and widths from the minimum up to 1600 px, with and without a search term (Clear button) and with a selected destination (footer), no control extends past the content width; controls wrap instead.
* When the font cannot be pushed, sizes still scale and the limitation is reported.
* Expansion filter: correct rows, order kept, AND-combined with search and usable-only; applies to Favorites without changing them; empty results.
* Expansion choice is saved per character, tab titles show counts, and unlock data is not modified.
* Star: outline when off, filled when on (10 triangles); click toggles and persists per character; hover preview and tooltip; a star click never selects the row.
* Floating button: enabled and disabled from the popover; a click toggles the main window, also while it is closed.
* Floating button drag: moves it and saves the position on release; the release after a drag does not toggle; the position is per character.
* Floating button window: NoFocusOnAppearing, NoNav, NoSavedSettings and NoTitleBar flags; follows scale and theme; Reset position.

**Server and travel:**
* Default prices.
* Custom prices: synchronised, charged, and shown in the client preview.
* A client with an old price is refused (PRICE) and nothing is charged.
* A currency removed from a category.
* A free category (all zero: no funds needed, no currency API call).
* `sameCityFree = false`.
* Invalid configurations rejected per category with a logged `CONFIG ERROR` and the default kept: negative, fractional, too large, NaN, string, disallowed currency for the category, duplicate currency, empty list, non-table, mixed free/paid, malformed entry. An invalid `sameCityFree` is rejected too.
* Same-city free travel; gil, CP and IS payments; insufficient funds; locked destinations; no deduction on refusals.
* No duplicate charges or unintended free travel (28-case fault matrix).
* FPX/1 request handling, session-scoped replay protection, stale and duplicate frames, version mismatch, 0x017 reception.

**General regression:** addon startup, automatic and zone re-sync, travel requests, Quiet Chat and echo suppression, existing commands, all four destination categories. All 1.1.0 tests are kept; one was adapted because a runtime price change now goes through `applyConfig()`.

## Mutation check (scratch copy, not shipped)

Each deliberate defect must make at least one test fail:

| Defect | Result |
|--------|--------|
| Header/footer controls never wrap | UI: 2 fail |
| Font never popped | UI: 20 fail |
| Font not scaled | UI: 3 fail |
| Expansion filter ignored | UI: 2 fail |
| Release after a drag toggles the window | UI: 1 fail |
| Price currency not validated | server: 1 fail |
| `sameCityFree` switch ignored | server: 1 fail |

## In-game acceptance (reported by the owner, 1.2.0-rc.2)

The owner reported that rc.2 works in game: the three themes (Classic, Squad,
Crimson), UI scaling, the expansion filter, favourite stars, the floating
button without its outer background and its click/drag behaviour,
per-character UI settings, and existing teleport functionality. These are
the owner's results; this workspace ran no game. The automated UI tests above
check what FFXIPort asks ImGui to draw, not how it looks.

## Not verified (needs the game or a live server)

* Changing prices on a real server and the restart behaviour.
* Runic Portal / Imperial Standing travel in game (still never tested in game).
* Mixed 1.1.0 / 1.2.0 client-server combinations (same protocol; not tested).
