# Destination catalogue (`catalog_data.lua`)

## What the numbers mean

`/port status` in 1.1.0-rc.5 printed, for example, "Home Points: 3 of 122
unlocked". The second number was **not** a number of destinations. It was the
length of the server's unlock bitmap, i.e. the size of the server's id range
(PROTOCOL-FPX1.md §5.1):

| Category | Server id range | Real server destinations (upstream LSB) | Listed by FFXIPort | Not listed |
|----------|-----------------|------------------------------------------|--------------------|------------|
| Home Points | 122 (ids 0–121) | 121 (id 67, Al Zahbi, has no position in LSB) | 104 | 17: Adoulin and Seekers-of-Adoulin areas (44–51, 109, 110, 116), Wings-of-the-Goddess "[S]" areas (68–70, 111, 113), Leafallia (112) |
| Survival Guides | 98 (menu ids 0–97) | 98 | 77 | 21: Wings-of-the-Goddess "[S]" areas (77–96) and Eastern Adoulin (97) |
| Gate Crystals | 6 | 6 | 6 | – |
| Runic Portals | 7 (ids 0–6; id 0 unused) | 6 | 6 | – |

Since 1.1.0 the status line reads "N unlocked on the server; catalogue lists
M (server id range R)".

## Is anything eligible silently omitted?

* **Within the catalogue's scope, no.** Every LSB Home Point, Survival Guide,
  Gate Crystal and Runic Portal in an Original, Rise of the Zilart, Chains of
  Promathia or Treasures of Aht Urhgan zone is listed. This is checked
  mechanically: the regenerated catalogue has exactly the same 193 rows as
  before, and `tools/verify_catalog_vs_lsb.lua` matches every row to LSB.
* **Outside the scope, yes, by design.** Destinations in Wings of the Goddess,
  Seekers of Adoulin and later zones are not listed. They are not "eligible"
  for a ToAU-era catalogue. A server with those expansions enabled *could* let
  a character unlock them. The server would then report them, and the client
  would still not list them.
  * **Change in 1.1.0:** such unlocks are no longer silent. After the first sync
    of a session the client prints a warning with their number, and `/port status`
    lists their ids.
* **Compatibility problem?** None at protocol level. The server accepts travel
  to any unlocked destination. The client simply offers no button for ids
  outside its catalogue. Whether XI: Forever Offline enables Wings of the
  Goddess or Seekers of Adoulin content has **not been verified**. If it does,
  a future version can widen `scope` in `tools/catalog_facts.lua` and
  regenerate. That needs expansion labels and UI decisions for those areas, so
  it was not done automatically.

## How the catalogue is generated (1.1.0)

`tools/gen_catalog.lua <lsb_root>` writes `client/FFXIPort/ffxiport/catalog_data.lua`
from these inputs only:

| Data | Source |
|------|--------|
| Zone ids and enum names | LSB `data/enums/zone.yaml` |
| Home Points: index, zone, city group, "#n", existence | LSB `scripts/globals/homepoint.lua` (entries at 0,0,0 are treated as non-existent) |
| Survival Guides: menu id, zone, unlock word/bit | LSB `scripts/globals/teleports/survival_guide_map.lua` |
| Gate Crystals: spell id, key item, zone | LSB `scripts/enum/magic.lua`, `data/enums/key_item.yaml`, `scripts/globals/teleports.lua` |
| Runic Portals: id, zone | LSB `xi.teleport.runic_portal`, `scripts/globals/teleports.lua` (`*_SP`) |
| Same-city table | `server/modules/custom/late/fpxport.lua` `cityGroupOfZone`, generated from LSB by `tools/gen_city_groups.lua` |
| Catalogue scope, zone → expansion labels, Gate Crystal display order, Runic Portal labels | `tools/catalog_facts.lua`, hand-maintained (LSB does not record these, see below) |

LSB has no zone-to-expansion table. Its Home Point NPCs are tagged `soa` in
almost every zone (Home Point teleport arrived in that era), and Survival
Guide NPCs carry only the `survival_guide` tag. So the scope (Original–ToAU)
and the per-zone expansion labels are stated explicitly in
`tools/catalog_facts.lua`. They were written for 1.1.0 from general knowledge
of FFXI zone history, not from any earlier FFXIPort file.

**Verification against the previous catalogue** (comparison only; not an
input): all 193 rows are identical in id, zone, number, group, unlock bit, key
item, crystal, label and order, and all 112 zone expansion labels agree. The
only difference is the `city` table: Al Zahbi (48) is no longer mapped to the
Aht Urhgan city and The Colosseum (71) is. This follows the LSB-derived rule
in `docs/SERVER-MODULE.md`. The table is used only by the catalogue's
self-check, never for pricing (the server decides prices).

## History (preserved)

The catalogue shipped up to 1.1.0-rc.5 (version 6) was produced by an earlier
generator (`tools/gen_catalog.ps1`, not part of this workspace). Its header
listed the earlier FFXIPort server module (`server/modules/custom/late/ffxiport.lua`)
among its inputs, alongside LSB files and a hand-maintained zone-expansion
list. Since 1.1.0 (catalogue version 7) the distributed catalogue is
regenerated without that module, as described above. The previous version is
recorded here and in `docs/CLEANROOM.md`; it was not erased from history.

`homepoint_suffix_data.lua` (the E/A/M location suffixes shown next to some
Home Points) is unchanged. Its header names BG-Wiki's "Home Point" page as the
source originally consulted. Before the 1.1.0 release the project owner checked
all 35 designations by hand against what FINAL FANTASY XI displays, and they
match. The legal and database-rights question about the BG-Wiki-derived data
remains open; see NOTICE.md.
