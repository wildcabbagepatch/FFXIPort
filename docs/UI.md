# FFXIPort window: themes, scale, filters and options (1.2.0)

The window keeps its five tabs (Home Points, Survival Guides, Gate Crystals,
Runic Portals, Favorites), search, "Only what I can use", automatic sync,
the Teleport footer and all `/port` commands. 1.2.0 adds a few small,
contextual controls and no new tabs or extra windows.

```
┌ FFXIPort ──────────────────────────────────────────────────────── [x] ┐
│ [Refresh] [Search all tabs......] [ ] Only what I can use   ● ● ●  UI │
│ Synchronized.                                    [All expansions   ▾] │
│ ┌ Home Points │ Survival Guides │ Gate Crystals │ Runic Portals │ Fav ┐│
│ │ ☆  Southern San d'Oria #1 (E)            Original     Available    ││
│ │ ★  Bastok Mines #1 (A)                   Original     Available    ││
│ …                                                                    │
│ Selected: …   Pay with: (•) Gil ( ) Conquest Points   You have: …    │
│ [Teleport - 1,000 gil]  The server checks the unlock and your balance.│
└──────────────────────────────────────────────────────────────────────┘
```

## Controls

| Control | Where | What it does | Saved |
|---------|-------|--------------|-------|
| Three dots (gold, blue, crimson) | top right of the window content (not the title bar, so the close button is unaffected) | Switch the whole theme immediately: Classic, Squad, Crimson. The active dot has a ring; hovering shows the name. | per character |
| **UI** button | right of the dots | Opens a small options popover (below). | – |
| Expansion filter | right end of the status line | All expansions, Original, Rise of the Zilart, Chains of Promathia, Treasures of Aht Urhgan. | per character |
| Star | first column of every row | Outline = not a favourite, filled = favourite; click toggles; hover previews and shows a tooltip. | per character (as in 1.1.0) |
| Floating button | anywhere on screen (optional) | A compact, rounded "FFXIPort" button in the theme's button colours, with no panel or frame around it (rc.2). Click opens/closes FFXIPort; drag to move (a press that moves less than 4 px counts as a click). | on/off and position per character |

### Options popover ("UI")

* **UI scale:** `-` / `+` in 10 % steps from 70 % to 200 %; `100%` resets.
  The change applies immediately.
* **Floating button:** on/off (off by default). **Reset position** puts it
  back at the default spot (top-left area of the screen).
* Shows the active theme name, and a red notice if text scaling is not
  possible in this client (see *Limitations*).

## Themes

| Theme | Look | Notes |
|-------|------|-------|
| **Classic** (default) | the original brown/gold FFXIPort colours | Identical to 1.1.0 at 100 %: same colours and the game's own title bar, with no rounding or border changes. Upgrading players see no difference until they pick another theme. |
| **Squad** | dark navy / blue-grey (`#11131B` background, `#1C1E29` panels, `#2B3041` buttons), restrained gold headings (`#E3BD66`), light text (`#E6EBF2`, `#949CAD`, `#757D8C`), gold-filled active tab, slightly rounded frames with thin borders | After the XI: Forever Offline Squad window (see *Design references*). |
| **Crimson** | dark warm grey with muted burgundy accents, rose headings, burgundy title bar | Understated; no bright red backgrounds. |

Each theme sets window and panel backgrounds, text levels, buttons, tabs,
table rows, row selection, separators, borders, the Teleport button, the
star, and the success/error colours. All of it is pushed for FFXIPort's own
windows only and popped afterwards; Ashita's global ImGui style and other
addons are not changed.

## UI scale

The scale changes the **interface**, not the window. The window stays freely
resizable as before; its minimum size grows with the scale (480 × 300 at
100 %).

* **Text:** Ashita v4 ships Dear ImGui 1.92 (`addons/libs/imgui.lua`:
  "based on version: 1.92.3"). In 1.92, `SetWindowFontScale` no longer
  exists; instead `PushFont(font, size)` sets the size of the following text.
  FFXIPort pushes the current font at `base size × scale` around its own
  windows. Frame heights, row heights, checkboxes, tabs and the star are all
  measured from the font size, so they scale with it.
* **Spacing:** window padding, frame padding, item spacing, cell padding,
  rounding, the search field width and other FFXIPort pixel values use the
  same factor.
* **Layout:** header and footer controls move to the next line when the line
  is too narrow (small windows, large scales) instead of overflowing.

## Expansion filter

Uses the catalogue's expansion of each destination's zone (Original, Rise of
the Zilart, Chains of Promathia, Treasures of Aht Urhgan). It is applied
**after** search and "Only what I can use" (all three must match), keeps the
existing order, works on every tab including Favorites, and never changes
unlocks or favourites. When a filter is active, the tab titles show the number
of matching rows. Empty results show "No destinations match." (or the usual
empty-Favorites hint).

## Settings and compatibility

New per-character keys in the existing settings file (alias
`ffxiport_independent`): `theme` (classic), `expansion` (all). The `scale`,
`button`, `button_x` and `button_y` keys already existed in 1.1.0 and are
now used. Existing files load unchanged; missing keys get the defaults above;
invalid values are corrected on load (for example scale 999 → 200, unknown
theme → Classic) without errors. Favourites are untouched.

Before a character is logged in, changes to theme, scale, filter or the
floating button apply for the session only (the settings library refuses
writes then). As soon as a character's settings are loaded, that character's
saved values apply and the pre-login choices are discarded; they are never
saved to any character (rc.2). Switching characters without reloading the
addon also drops the previous character's unsaved floating-button position and
any drag in progress, so every character sees its own saved position or the
default (rc.2).

### Floating button rendering (rc.2)

The button lives in a tiny ImGui window. For that window only, FFXIPort sets
`NoBackground` and pushes a transparent window background, zero window
padding, zero window border and a 1 × 1 minimum size, so the window shrinks
to the button and nothing around it is drawn. The button keeps the theme's
button colours and text and gets a 4 px rounding (scaled). These pushes are
popped after the window, so the main window and other addons are unchanged.

## Design references

The Squad theme was matched to screenshots of XI: Forever Offline's Squad
window, which the project owner supplied locally (`design-references/`), and
to the colour values stated by the owner. The reference Lua file was consulted
for colour values only. No code, rendering function or event handler was
copied, and FFXIPort has no dependency on Squad. The reference files are
excluded by `.gitignore` and are not part of any FFXIPort package.

## Limitations

* **In-game status.** The owner accepted this UI in game on 1.2.0-rc.2
  (identical to 1.2.0 apart from the version): all three themes, UI scaling,
  the expansion filter, favourite stars, the floating button (no outer panel;
  click and drag) and per-character settings. The automated UI tests use a
  *recording* ImGui mock (what FFXIPort asks ImGui to do), not rendering.
* **Text scaling depends on Ashita's binding.** If `PushFont(font, size)` is
  not available at runtime, FFXIPort keeps working: sizes and spacing still
  scale, text stays at the normal size, and the options popover and
  `/port status` say so.
* The floating button stays where it was put. If the game resolution shrinks,
  use **Reset position**.
