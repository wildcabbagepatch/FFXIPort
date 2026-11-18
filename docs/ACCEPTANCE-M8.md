# Milestone 8 — consolidated in-game acceptance checklist (RC3)

Setup: test server with `fpxport.lua` installed and the previous
`ffxiport.lua` **disabled**; the client from this package; character A
(several unlocks, ≥ 5,000 gil, ≥ 500 CP, ≥ 500 IS) and character B (few
unlocks). First pass in `/port chat debug`, travel items again in `quiet`.
Note gil / CP / IS before and after every trip.

## 1. Install and transport
- [ ] Map-server log: `fpxport` loaded, no Lua errors, old module not loaded.
- [ ] `/addon load FFXIPort` prints `FFXIPort 1.1.0 loaded.`; no `protocol.lua` in the addon folder.
- [ ] `!fpx 1 0123456789ab 0001 SYNC` typed in /say is not broadcast to nearby players (second client if possible).
- [ ] Debug mode shows `frame: #fpx1 …` in FFXIPort output; raw `#fpx1` lines never appear in the chat log.
- [ ] `/port status`: frames > 0, responses > 0, **foreign = 0**, checksum = 0, snapshot character id = A; no "Last frame-like chat ignored" line.
- [ ] `/port chat trace on` + `/port sync`: no `0x017 mode 29 from <own name> "#fpx1 …"` trace lines (accepted frames are not traced as ordinary chat), and the sync completes in about a second.
- [ ] Another player typing `#fpx1 …` in say or tell: the line stays visible and `/port status` counts it as foreign (reason `mode`).

## 2. Synchronization, catalogue, settings
- [ ] Login: one initial sync about 2 s after arrival. `/addon reload`: one sync. Each zone change: one re-sync.
- [ ] Switch to B: A's data cleared, B's unlocks shown.
- [ ] `/addon reload FFXIPort` twice within a second, then change gil (e.g. buy an item) and `/port sync`: the window shows the **new** balance. Then travel right after another quick double reload: the trip happens and is charged exactly once.
- [ ] Tabs: Home Points 104, Survival Guides 77, Gate Crystals 6, Runic Portals 6; unlocks match the in-game menus.
- [ ] Favorites and payment method survive `/addon reload` and are per character.

## 3. Prices (owner-confirmed)
- [ ] Home Point / Survival Guide / Gate Crystal outside the current city: `1,000 gil`, or `100 CP` with CP selected.
- [ ] Runic Portal: `1,000 gil`, or `100 IS` with Imperial Standing selected.
- [ ] Same price for near and far Home Points; no change with Rhapsody in White or the Captain Wildcat Badge.
- [ ] Each paid trip deducts exactly the shown amount, once, in the chosen currency.

## 4. Free same-city travel
- [ ] In San d'Oria, Bastok, Windurst or Jeuno: Home Points of the **same** city show `Free`; trip deducts nothing.
- [ ] From **Chateau d'Oraguille** to a San d'Oria Home Point: `Free`. From **Heavens Tower** to a Windurst Home Point: `Free`.
- [ ] A Survival Guide in the same city: `Free`.
- [ ] Same city with 0 gil and 0 CP: trip still works.
- [ ] To another city and to any outside destination: `1,000 gil` / `100 CP`.

## 5. Refusals (nothing deducted in any case)
- [ ] Not enough funds → "Not enough funds … Current price: 1,000 gil or 100 CP".
- [ ] Engaged / in combat → STATE; in a BCNM or instance → ZONE.
- [ ] Two trips within 5 s → "still settling" locally or BUSY.
- [ ] Change a price in `M.config`, reload the module, travel with the old price shown → PRICE refusal, prices refresh.

## 6. Outcomes and failure handling
- [ ] Successful cross-zone trip: quiet shows one "Accepted - travelling (paid …)"; normal also shows "Travel complete (zone change finished)".
- [ ] Same-zone Home Point move (e.g. Ru'Aun Gardens #1 → #3): "Travel complete (move within the same zone)" after a few seconds.
- [ ] Stop the module / rename the command, press Refresh → "retrying once" then "The server did not answer"; no endless retries.
- [ ] Start a trip and log out at once → outcome "unknown", resolved by the next sync; balances correct.
- [ ] After all tests, the map-server log contains **no** `CURRENCY INCIDENT`, and the balance totals match the trips taken.
- [ ] (Optional, staging only) Force a failing `setPos` with a test override. The client must show "failed … refund confirmed" with the balance restored, or, if the refund fails, "UNCERTAIN" plus a `CURRENCY INCIDENT`. It must never show "Travel complete".

## 7. Chat and commands
- [ ] `/port chat quiet|normal|debug` persists per character; the `<Name> : !fpx …` echo is hidden only in quiet.
- [ ] Chat from other players starting with `#fpx` is not hidden and does not affect FFXIPort.
- [ ] `/port`, `/port open|close|hp|sg|sp|rp|fav|sync|status`, `/port catalog …`, `/port raw on|off`, `/port chat …`, `/ffxiport` behave as before.

Record pass / fail + note per item.
