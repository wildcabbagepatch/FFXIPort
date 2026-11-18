# Changelog

All notable changes to FFXIPort. Versions before 1.1.0 belong to the earlier
independent frontend and its previous server module (see
docs/PROVENANCE-M8.md); their history is kept in the project's earlier records.

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
