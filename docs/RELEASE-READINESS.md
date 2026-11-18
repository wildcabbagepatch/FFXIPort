# Release readiness — FFXIPort 1.1.0

Status: **ready for the owner's final review.** Nothing has been published,
pushed or deployed.

## 1. Verified by automated tests

Run under LuaJIT 2.1 and Lua 5.4.6 (exact counts in docs/TEST-RESULTS-M8.md
and tests/results/):

* FPX/1 framing, checksums, bounds, request/session ids, replay, stale and
  duplicate handling, version mismatch.
* Server: unlock checks for all four categories; the final prices for every
  category and currency; free same-city travel (including Chateau
  d'Oraguille and Heavens Tower); refusals never charge; transaction outcomes
  under injected failures of every player API (28-case fault matrix);
  replay and cooldown across sessions.
* Client: startup and zone re-sync, character switch, corrections and
  reconciliation, travel for all categories and currencies against the real
  server module, favourites persistence, Quiet Chat and echo suppression,
  0x017 reception with the in-game packet layout (own-name sender), frames
  hidden from chat.
* Addon entry point loaded and driven through its events and commands
  (smoke test with Ashita stubs).
* Catalogue regenerated from LSB sources; identical to the previous 193 rows;
  catalogue ↔ server ↔ LSB cross-check clean; same-city table matches LSB.
* All 28 Lua files (client, server, tests, tools) compile on both runtimes.
* The catalogue regenerates byte for byte from the same LSB inputs.

## 2. Verified in game (owner, XI: Forever Offline, 1.1.0-rc.5)

FPX/1 client/server communication; automatic synchronization; zone
re-synchronization; free same-city travel; paid gil travel; Conquest Point
payment; suppression of raw protocol messages from chat.

1.1.0 differs from rc.5 only in the regenerated catalogue (same rows), the
diagnostic texts and a once-per-session notice, and documentation. A short
re-check in game is still recommended (section 7).

## 3. Not verified

* **Runic Portal travel and Imperial Standing payment** (in game).
* Survival Guide and Gate Crystal travel in game (categories of the tested
  trips not recorded).
* In-game refusal paths (FUNDS, STATE, ZONE, PRICE), the correction/`UNSURE`
  path and rapid double reloads.
* The ImGui window rendering (unchanged code; not testable outside the game).
* Exact supported versions: the Ashita v4 build and the XI: Forever Offline /
  Phoenix server build used in testing were not recorded.
* Whether XI: Forever Offline enables Wings of the Goddess or Seekers of
  Adoulin content. If it does, players may have unlocked destinations that
  1.1.0 does not list. The client now reports them instead of omitting them
  silently.
* Phoenix-specific differences from upstream LandSandBoat. Generation and
  verification used upstream `base`; re-run `tools/gen_catalog.lua`,
  `tools/verify_catalog_vs_lsb.lua` and `tools/gen_city_groups.lua` against
  the Phoenix tree if available.
* ZIP extraction on Linux (entry names checked; extraction tested on Windows only).

## 4. Remaining technical blockers

None known that block a public release. Recommended, not blocking:
* a quick in-game pass of docs/ACCEPTANCE-M8.md §3, §5 and §6 with 1.1.0,
  ideally including one Runic Portal trip with Imperial Standing (then the
  README limitation can be narrowed);
* record the Ashita and server builds used, for the README's requirements.

## 5. Licensing and provenance concerns (open, not cleared)

1. **BG-Wiki-sourced Home Point suffixes** (`homepoint_suffix_data.lua`, 35
   single letters). **Factual verification done:** the owner checked all 35
   designations by hand against what FINAL FANTASY XI displays. **Still open:**
   BG-Wiki was the source originally consulted, and its licence and
   database-rights position has not been checked; the verification is not a
   legal clearance. Options: accept the remaining risk, document the in-game
   check as an independent re-derivation after legal advice, or remove the file
   (the UI then shows no suffix).
2. **Trademarks.** The product name "FFXIPort" and the game names used in the
   docs and UI have not been reviewed. A non-affiliation and trademark notice
   is included (README, NOTICE.md).
3. **Inherited client code.** Unchanged UI/settings/zone modules come from the
   project's earlier independent frontend. Their own provenance is in the
   project's earlier records (not part of this workspace). This release makes
   no new claims about them.
4. **Earlier releases.** Their connection to Driftwood/dwport is historical and
   documented; 1.1.0 replaces the protocol, server module and catalogue
   generation.
5. **LICENSE.** It is the canonical GPLv3 text from gnu.org (SHA-256
   `3972dc97…6986`). If the project's own LICENSE file differs, use the project's.

## 6. Recommended public version

**1.1.0** (the release candidates were 1.1.0-rc.1 … rc.5). The addon reports
`1.1.0`; the catalogue is version 7; the protocol is FPX/1.

## 7. Publishing instructions (manual, by the owner)

Source repository:
1. Create a new repository and add the contents of
   `FFXIPort-1.1.0-source.zip` (folder `FFXIPort-1.1.0-source/`) at its root.
   Do not add `release/` or any scratch files.
2. Check that `LICENSE`, `NOTICE.md` and `README.md` are at the root, then
   commit, for example "FFXIPort 1.1.0".
3. Tag the commit `v1.1.0` and push the branch and the tag yourself.
4. Optionally add the repository description: "Independent travel addon
   (Ashita v4) and server module for XI: Forever Offline. GPL-3.0-only.
   Not affiliated with Square Enix."

Downloadable release:
1. Create a release for tag `v1.1.0`.
2. Attach `FFXIPort-1.1.0.zip` (installation package),
   `FFXIPort-1.1.0-source.zip` (complete source) and both `.sha256` files.
3. Paste the 1.1.0 section of CHANGELOG.md as the release notes, plus the
   "Known limitations" from README.md.
4. Before publishing, decide on the open items in section 5 (especially
   BG-Wiki).

Before announcing: in game, on a server with the old module disabled, install
from the published `FFXIPort-1.1.0.zip` exactly as INSTALL.md says and do one
sync and one trip.
