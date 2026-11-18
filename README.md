# FFXIPort 1.1.0

FFXIPort is a travel addon for **XI: Forever Offline**. It shows a window with
every Home Point, Survival Guide, Gate Crystal teleport and Runic Portal
your character can use, and lets you travel to them with one click: from
anywhere, paid with gil, Conquest Points or Imperial Standing, and free
within the same city.

It has two parts that work together:

* an **Ashita v4 addon** (the window and `/port` commands), and
* a **server module** (`fpxport.lua`) for the XI: Forever Offline /
  LandSandBoat-based server. It checks unlocks, prices and payment, and moves
  the character.

> **Independent project.** FFXIPort is an unofficial, independent fan project.
> It is not affiliated with, endorsed by or sponsored by Square Enix, the
> XI: Forever Offline project, the LandSandBoat project, the Ashita project or
> BG-Wiki. FINAL FANTASY is a registered trademark of Square Enix Holdings
> Co., Ltd. See [NOTICE.md](NOTICE.md).

## Features

* Five tabs: **Home Points** (104), **Survival Guides** (77), **Gate
  Crystals** (6), **Runic Portals** (6) and **Favorites**.
* Search across all tabs; filter to destinations you can use.
* Unlocks, prices and your gil / CP / Imperial Standing come from the server
  and refresh automatically after login, after reloading the addon and after
  every zone change.
* Server-authoritative pricing. The price shown is the price charged; if it
  changed in the meantime, the trip is refused and nothing is charged.
* Favorites and settings (tab, payment method, chat level, window scale) are
  saved per character.
* Quiet chat: by default FFXIPort hides its own protocol traffic and command
  echoes and prints one line per trip.
* Location hints after some Home Point names: **E** (entrance/exit),
  **A** (Auction House), **M** (Mog House). All 35 were checked by hand against
  what FINAL FANTASY XI displays. They were originally compiled with the help
  of BG-Wiki (see NOTICE.md).

## Prices

| Destination | Gil | Alternative |
|-------------|----:|------------:|
| Home Point | 1,000 gil | 100 Conquest Points |
| Survival Guide | 1,000 gil | 100 Conquest Points |
| Gate Crystal teleport | 1,000 gil | 100 Conquest Points |
| Runic Portal | 1,000 gil | 100 Imperial Standing |
| **Within the same city** (e.g. Southern → Northern San d'Oria, Chateau d'Oraguille → Port San d'Oria, Heavens Tower → Windurst Woods) | **free** | **free** |

Choose the payment method in the window footer ("Pay with:"). Conquest Points
are those of your current nation. The server operator sets prices in
`fpxport.lua`.

## Requirements

* **Client:** Windows with FINAL FANTASY XI and **Ashita v4**.
* **Server:** an **XI: Forever Offline** (Phoenix / LandSandBoat-based) server
  where you can install a Lua module. FFXIPort 1.1.0 was tested in game on
  XI: Forever Offline. The exact Ashita and server builds used were not
  recorded (see [Known limitations](#known-limitations)).
* Both parts must come from the **same FFXIPort release**. 1.1.0 speaks only the
  FPX/1 protocol and does not work with the previous FFXIPort server module.

## Installation

Short version below; full steps in [INSTALL.md](INSTALL.md).

1. **Server:** copy `server/modules/custom/late/fpxport.lua` into the server's
   `modules/custom/late/` folder and list it in `modules/init.txt`.
   **Disable the previous FFXIPort server module** (`custom/late/ffxiport.lua`)
   if you had it. If `init.txt` loads the whole folder, removing a line is not
   enough; move the old file out of `modules/` (see INSTALL.md). Restart the
   map server.
2. **Client:** copy the `FFXIPort` folder from `client/` into
   `Ashita/addons/`, replacing any older FFXIPort folder completely. Then type
   `/addon load FFXIPort` in game.

## Usage

| Command | What it does |
|---------|--------------|
| `/port` | Open or close the window |
| `/port open` / `/port close` | Open / close the window |
| `/port hp` · `sg` · `sp` · `rp` · `fav` | Open the window on a tab (Home Points, Survival Guides, Gate Crystals, Runic Portals, Favorites) |
| `/port sync` | Refresh unlocks, prices and balances now (same as the **Refresh** button) |
| `/port status` | Diagnostics: sync state, counts, balances, last trip |
| `/port catalog [hp\|sg\|sp\|rp\|find <text>]` | Inspect the destination catalogue |
| `/port chat quiet\|normal\|debug` | How much FFXIPort prints (saved per character; default quiet) |
| `/port chat trace on\|off` | Temporary read-only chat trace for troubleshooting |
| `/port raw on\|off` | Echo every protocol frame (troubleshooting) |
| `/ffxiport …` | Same as `/port …` |

To travel: select a destination, choose how to pay, press **Teleport**. Locked
destinations are shown but cannot be used. Star a destination to add it to
**Favorites**.

## Troubleshooting

| Symptom | What to check |
|---------|---------------|
| Window says "Waiting for sync"; `/port status` shows a timeout | Is `fpxport.lua` installed and listed in `init.txt`? Any errors in the map-server log? Is the old `ffxiport.lua` disabled? |
| "The server could not read an FFXIPort request" | Client and server are from different releases. Install both from the same package. |
| "Server protocol version mismatch" | Same cause. Automatic sync stops until both parts match. |
| Lines starting with `#fpx1` appear in chat | `/port status` should show "foreign: 0". If it doesn't, run `/port chat trace on` and `/port sync`, then report the trace; it shows the packet mode and sender. |
| "Travel refused: The price has changed" | Prices were refreshed. Check the new price and try again; nothing was charged. |
| "Payment/travel outcome UNCERTAIN" | Check your gil / CP / IS. The server logged a `CURRENCY INCIDENT` for the operator; please report it. |
| "N unlocked destination(s) are outside this catalogue's … scope" | Your character unlocked destinations from expansions after Treasures of Aht Urhgan, which 1.1.0 does not list. `/port status` shows their ids. |

## Known limitations

* **Runic Portal travel and Imperial Standing payment have not been tested in
  game.** Tested in game on XI: Forever Offline: client/server communication,
  automatic and zone re-synchronization, free same-city travel, paid travel
  with gil and with Conquest Points, and hiding of protocol messages. Which
  destination categories were used in those trips was not recorded. Every
  category is covered by automated tests.
* Destinations in Wings of the Goddess, Seekers of Adoulin and later zones are
  not listed ([docs/CATALOGUE.md](docs/CATALOGUE.md)).
* Works only with the `fpxport.lua` server module of the same release.
* The window is not covered by automated tests (its layout is unchanged in 1.1.0).

## License

FFXIPort is free software, licensed GPL-3.0-only. See [LICENSE](LICENSE).
Copyright (C) 2026 wildthing. The server module contains factual destination
data from LandSandBoat (GPL-3.0). Third-party notices, trademarks and open
questions are in [NOTICE.md](NOTICE.md); provenance is in
[docs/PROVENANCE-M8.md](docs/PROVENANCE-M8.md).

The complete source, including tests, generators and design documents, is
published as the **source distribution** of each release.
