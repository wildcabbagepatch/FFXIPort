# FFXIPort 1.2.0 — consolidated in-game acceptance checklist

**Status:** this checklist was used on 1.2.0-rc.2. The owner reported that
rc.2 works in game, including the three themes, UI scaling, the expansion
filter, favourite stars, the floating button without its outer panel and its
click/drag behaviour, per-character UI settings and existing travel, and
approved it as the basis for 1.2.0. 1.2.0 differs from rc.2 only in the
version number and documentation. The boxes below are left blank for future
testers; no per-item record is reproduced here.

Setup: test server with the 1.2.0 `fpxport.lua` (old `ffxiport.lua`
disabled), client from `FFXIPort-1.2.0.zip`, two characters A and B.
Record pass / fail + note per item. Screenshots of each theme at 70 %, 100 %
and 200 % are helpful for review.

## 0. rc.2 fixes (check these first)
- [ ] **Floating button:** in Classic, Squad and Crimson, only the rounded "FFXIPort" button is visible: no dark panel, frame or margin around it. Button colours match the theme.
- [ ] The whole visible button reacts to clicks and drags; a click opens/closes the window; a drag never opens/closes it.
- [ ] Button size follows the UI scale at 70 %, 100 % and 200 %; still no panel around it.
- [ ] **Character switch without reload:** A enables the button and drags it somewhere; switch to B (no `/addon reload`). B shows its **own** saved position (or the default if B never moved it), not A's. Switch back: A's position again.
- [ ] Logout to character select and log back in: positions and visibility are each character's own.
- [ ] **Pre-login:** load the addon at the login screen / before a character is in, open `/port`, pick a different theme (and scale). Log in with a character whose saved theme differs: the **character's saved** theme and scale appear. Log out and in again: unchanged.
- [ ] Other Ashita addons' windows look unchanged while the floating button is shown.

## 1. Upgrade and startup
- [ ] `/addon load FFXIPort` prints `FFXIPort 1.2.0 loaded.`; sync completes ("Synchronized.").
- [ ] An existing 1.1.0 character opens in **Classic**, 100 %, All expansions, no floating button, and looks the same as in 1.1.0.
- [ ] Existing favourites, payment method and chat level are still there.
- [ ] Zone change → one automatic re-sync. `/port`, `/port status`, `/port catalog`, `/port chat …` work as before.
- [ ] Map-server log: no `CONFIG ERROR`, no `CURRENCY INCIDENT`.

## 2. Themes
- [ ] Three dots at the top right of the window (not on the title bar); the close [x] still works.
- [ ] Hovering a dot shows "Classic theme" / "Squad theme" / "Crimson theme"; the active dot has a ring.
- [ ] Clicking switches the whole window immediately: background, panels, text, buttons, tabs, rows, row selection, separators, Teleport button, stars, status colours.
- [ ] Squad resembles the XI: Forever Offline Squad window (navy, gold headings, gold active tab, rounded frames).
- [ ] Crimson is dark with muted burgundy accents; nothing glaring.
- [ ] Green "Available", red "Locked" and warnings stay readable in every theme.
- [ ] Other Ashita addons' windows keep their own look while FFXIPort is open in each theme.
- [ ] Theme is remembered after `/addon reload FFXIPort` and differs per character (A Squad, B Crimson).

## 3. UI scale
- [ ] **UI** button → popover with `-`, `+`, `100%`; steps of 10 % between 70 % and 200 %.
- [ ] At 70 %, 100 % and 200 %: **text** gets smaller/larger (not only spacing), and so do buttons, tabs, rows, stars, dots and the checkbox.
- [ ] No clipped or overlapping controls at each scale; controls move to a new line when the window is narrow.
- [ ] Window resizing still works at each scale; the minimum size grows with the scale.
- [ ] `/port status` line "UI:" says "text scaling: yes". (If it says NO, note the message.)
- [ ] Scale is remembered after reload and per character.

## 4. Expansion filter
- [ ] Combo at the right of the status line: All / Original / Rise of the Zilart / Chains of Promathia / Treasures of Aht Urhgan.
- [ ] Each choice shows only that expansion's destinations, in the usual order; tab titles show counts.
- [ ] Combined with a search term and "Only what I can use", only rows matching all three are shown.
- [ ] Favorites tab follows the filter; favourites themselves are unchanged after returning to All.
- [ ] An empty result shows a message, no error. The choice is remembered per character.

## 5. Favourite star
- [ ] Outline star = not a favourite; filled star = favourite; hover shows a preview and tooltip.
- [ ] Clicking toggles and does not select the row; Favorites tab updates; survives reload.
- [ ] Star looks right in all three themes and at 70 %, 100 %, 200 %.

## 6. Floating button
- [ ] Off by default. **UI** → Floating button on: a small "FFXIPort" button appears.
- [ ] Click opens / closes the main window; typing in chat is not interrupted (no focus steal).
- [ ] Drag moves it; it stays there after reload; position is per character; a drag does not open/close the window.
- [ ] **Reset position** brings it back; turning the option off removes it completely.
- [ ] It follows the theme and the UI scale.

## 7. Server prices (operator)
- [ ] Default prices unchanged: 1,000 gil / 100 CP (HP, SG, Gate Crystal), 1,000 gil / 100 IS (Runic Portal); same city free.
- [ ] Change e.g. Home Points to 1,500 gil / 150 CP, restart the map server: after `/port sync` the window shows the new prices; a trip charges exactly that.
- [ ] With the window still showing an old price, Teleport → "The price has changed", nothing charged, prices refresh.
- [ ] Enter an invalid value (e.g. `amount = -5`), restart: the log shows `[fpxport] CONFIG ERROR prices.H …`; Home Points keep 1,000 / 100; other categories unaffected.
- [ ] `sameCityFree = false`: a same-city trip costs the normal price. Restore the defaults afterwards.
- [ ] Not enough funds → refused, nothing charged. Locked destination → cannot travel.

## 8. Travel regression
- [ ] One trip each with gil and with CP; one same-city free trip. Optional but recommended: one Runic Portal trip with Imperial Standing (never tested in game so far).
- [ ] Quiet mode: one "Accepted - travelling" line per trip, no `#fpx1` lines, no command echo.
