# NOTICE

## FFXIPort

FFXIPort 1.1.0 — Copyright (C) 2026 wildthing.

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, **version 3 only** (SPDX: `GPL-3.0-only`). It is
distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See [LICENSE](LICENSE) for the full text.

## Non-affiliation and trademarks

FFXIPort is an unofficial, independent fan project. It is **not** affiliated
with, endorsed by, sponsored by or supported by:

* Square Enix Holdings Co., Ltd. or Square Enix Co., Ltd.;
* the XI: Forever Offline project;
* the LandSandBoat project or the Darkstar project;
* the Ashita project;
* BG-Wiki.

FINAL FANTASY is a registered trademark of Square Enix Holdings Co., Ltd.
FINAL FANTASY XI, Vana'diel and the names of in-game places, items and
features are trademarks or works of Square Enix. They are used only to
describe what the software interoperates with. All other names belong to
their respective owners. FFXIPort contains no Square Enix game files, assets
or client data. Display names of zones and key items are read from the
player's own game client at runtime.

## Third-party material

| Material | Where | Rights |
|----------|-------|--------|
| Factual destination data from LandSandBoat: Home Point index, group, fee multiplier, position and zone (`homepoint.lua`); zone ids and names, teleport ids, spell and key item ids (used to generate `catalog_data.lua`); same-city table derived from LSB conquest regions and zone types | `server/modules/custom/late/fpxport.lua`, `client/FFXIPort/ffxiport/catalog_data.lua` | LandSandBoat / Darkstar Dev Teams, GPL-3.0(-or-later). Used under that license; no LSB code is copied. |
| LandSandBoat API usage (function names, signatures, module loader conventions) | server module, tests | Interoperability with LandSandBoat (GPL-3.0). |
| Ashita v4 API usage (events, `AshitaCore`, settings library, ImGui bindings) | client | Interoperability with Ashita. No Ashita code is included. |
| Home Point location suffixes (E / A / M) | `client/FFXIPort/ffxiport/homepoint_suffix_data.lua` | Designations originally taken from BG-Wiki's "Home Point" page (per that file's header). The project owner later checked all 35 by hand against what FINAL FANTASY XI itself displays. **Rights question still open, see below.** |
| GNU GPL v3 text | `LICENSE` | © Free Software Foundation; verbatim copying permitted. |

## Open release questions (not cleared)

These have **not** been legally cleared and are listed as open questions,
not as assurances:

1. **BG-Wiki data.** `homepoint_suffix_data.lua` holds 35 single-letter
   location designations (E = entrance/exit, A = Auction House, M = Mog
   House). Its header names BG-Wiki's "Home Point" page as the source
   originally consulted. Before the 1.1.0 release the project owner checked
   **all 35 designations by hand against what is displayed in FINAL FANTASY
   XI** and found them to match. That verification confirms the facts. It
   does **not** establish legal or database-rights clearance for the
   BG-Wiki-derived compilation: BG-Wiki's content licence and any database
   rights have still not been reviewed. The data is presentation only (it adds
   "E", "A" or "M" after some Home Point names) and could be removed without
   affecting travel.
2. **Trademarks.** The project name "FFXIPort" and the use of game names in
   documentation and the UI are nominative and descriptive, but have not been
   reviewed for trademark issues.
3. **Game names in data.** Runic Portal labels (e.g. "Azouph Isle Staging
   Point") and zone enum names are short factual identifiers. Their status
   under Square Enix's rights has not been reviewed.
4. **LandSandBoat licence wording.** The factual data reproduced from
   LandSandBoat is used under GPL-3.0. Whether LSB distributes those files as
   "GPL-3.0-only" or "-or-later" was not checked file by file. Either is
   compatible with FFXIPort's GPL-3.0-only.
5. **Earlier versions.** FFXIPort versions before 1.1.0 had a historical
   connection to Driftwood/dwport through the previous server module and
   protocol. 1.1.0 replaces those parts and the catalogue generation (see
   docs/PROVENANCE-M8.md and docs/CATALOGUE.md). Some unchanged client files
   (UI, settings, zone tracking) are the project's existing independent code,
   kept as they were. Their history is in the project's earlier provenance
   records, which are not part of this package.
