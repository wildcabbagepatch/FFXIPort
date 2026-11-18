-- FFXIPort catalogue: hand-maintained facts that LandSandBoat does not record.
-- Used by tools/gen_catalog.lua. GPL-3.0-only, (C) 2026 wildthing.
--
-- Written for the 1.1.0 release from general knowledge of Final Fantasy XI zone
-- history (the expansion in which each zone was introduced). It does not come
-- from any earlier FFXIPort server module, protocol, generator input file or
-- generated catalogue. The generator later compared its output with the
-- previous catalogue purely as verification; see docs/CATALOGUE.md.
--
-- LandSandBoat has no zone -> expansion table: Home Point NPCs are tagged
-- `soa` in almost every zone (Home Point travel arrived in that era), and
-- Survival Guide NPCs carry only the `survival_guide` tag. So the catalogue
-- scope and the expansion labels have to be stated here explicitly.
return {
    -- Product scope: destinations in zones of these expansions are listed.
    -- (FFXIPort targets XI: Forever Offline's Original - Treasures of Aht
    -- Urhgan content. Destinations in later-expansion zones are not listed;
    -- the client reports any unlocked ones it cannot show, see /port catalog.)
    scope = { base = true, roz = true, cop = true, toau = true },

    -- Zone id -> expansion in which the zone was introduced.
    -- base = Original, roz = Rise of the Zilart, cop = Chains of Promathia,
    -- toau = Treasures of Aht Urhgan, wotg = Wings of the Goddess ("[S]"
    -- zones), soa = Seekers of Adoulin, later = after Seekers of Adoulin.
    zoneExpansion = {
        -- Chains of Promathia
        [2] = 'cop', [4] = 'cop', [5] = 'cop', [7] = 'cop', [9] = 'cop', [11] = 'cop', [12] = 'cop',
        [24] = 'cop', [25] = 'cop', [26] = 'cop', [27] = 'cop', [28] = 'cop', [29] = 'cop', [30] = 'cop',
        [33] = 'cop', [34] = 'cop', [35] = 'cop',
        -- Treasures of Aht Urhgan
        [48] = 'toau', [50] = 'toau', [51] = 'toau', [52] = 'toau', [53] = 'toau', [54] = 'toau',
        [61] = 'toau', [62] = 'toau', [65] = 'toau', [68] = 'toau', [72] = 'toau', [79] = 'toau',
        -- Wings of the Goddess (past Vana'diel, "[S]")
        [80] = 'wotg', [81] = 'wotg', [82] = 'wotg', [83] = 'wotg', [84] = 'wotg', [87] = 'wotg',
        [88] = 'wotg', [89] = 'wotg', [90] = 'wotg', [91] = 'wotg', [94] = 'wotg', [95] = 'wotg',
        [96] = 'wotg', [97] = 'wotg', [98] = 'wotg', [136] = 'wotg', [137] = 'wotg', [138] = 'wotg',
        [155] = 'wotg', [164] = 'wotg', [171] = 'wotg', [175] = 'wotg',
        -- Original: outdoor areas
        [100] = 'base', [102] = 'base', [103] = 'base', [104] = 'base', [105] = 'base', [106] = 'base',
        [108] = 'base', [109] = 'base', [110] = 'base', [111] = 'base', [112] = 'base', [115] = 'base',
        [117] = 'base', [118] = 'base', [119] = 'base', [120] = 'base', [126] = 'base', [127] = 'base',
        -- Original: dungeons and strongholds
        [141] = 'base', [142] = 'base', [143] = 'base', [145] = 'base', [147] = 'base', [149] = 'base',
        [151] = 'base', [158] = 'base', [161] = 'base', [162] = 'base', [166] = 'base', [167] = 'base',
        [169] = 'base', [172] = 'base', [184] = 'base', [190] = 'base', [191] = 'base', [192] = 'base',
        [193] = 'base', [195] = 'base', [196] = 'base', [197] = 'base', [198] = 'base', [200] = 'base',
        [204] = 'base',
        -- Original: cities and towns
        [230] = 'base', [231] = 'base', [232] = 'base', [234] = 'base', [235] = 'base', [236] = 'base',
        [237] = 'base', [238] = 'base', [239] = 'base', [240] = 'base', [241] = 'base', [243] = 'base',
        [244] = 'base', [245] = 'base', [246] = 'base', [248] = 'base', [249] = 'base',
        -- Rise of the Zilart
        [113] = 'roz', [114] = 'roz', [121] = 'roz', [122] = 'roz', [123] = 'roz', [124] = 'roz',
        [125] = 'roz', [128] = 'roz', [130] = 'roz', [153] = 'roz', [154] = 'roz', [159] = 'roz',
        [160] = 'roz', [173] = 'roz', [174] = 'roz', [176] = 'roz', [178] = 'roz', [205] = 'roz',
        [208] = 'roz', [212] = 'roz', [213] = 'roz', [247] = 'roz', [250] = 'roz', [252] = 'roz',
        -- Seekers of Adoulin and later
        [256] = 'soa', [257] = 'soa', [261] = 'soa', [262] = 'soa', [263] = 'soa', [265] = 'soa',
        [266] = 'soa', [267] = 'soa', [276] = 'soa', [281] = 'later',
    },

    -- Gate Crystal tab: display order and crystal names. Ids, zones and key
    -- items come from LSB (scripts/enum/magic.lua, data/enums/key_item.yaml,
    -- scripts/globals/teleports.lua); the order keeps the established UI order.
    gateCrystals = {
        { crystal = 'Holla', spell = 'TELEPORT_HOLLA', keyItem = 'holla_gate_crystal',   tele = 'HOLLA' },
        { crystal = 'Dem',   spell = 'TELEPORT_DEM',   keyItem = 'dem_gate_crystal',     tele = 'DEM'   },
        { crystal = 'Mea',   spell = 'TELEPORT_MEA',   keyItem = 'mea_gate_crystal',     tele = 'MEA'   },
        { crystal = 'Altep', spell = 'TELEPORT_ALTEP', keyItem = 'altepa_gate_crystal',  tele = 'ALTEP' },
        { crystal = 'Yhoat', spell = 'TELEPORT_YHOAT', keyItem = 'yhoator_gate_crystal', tele = 'YHOAT' },
        { crystal = 'Vahzl', spell = 'TELEPORT_VAHZL', keyItem = 'vahzl_gate_crystal',   tele = 'VAHZL' },
    },

    -- Runic Portal staging points (in-game location names). Ids and zones come
    -- from LSB xi.teleport.runic_portal and xi.teleport.destination[*_SP].
    runicPortals = {
        [1] = { tele = 'AZOUPH_SP',  label = 'Azouph Isle Staging Point' },
        [2] = { tele = 'DVUCCA_SP',  label = 'Dvucca Isle Staging Point' },
        [3] = { tele = 'MAMOOL_SP',  label = 'Mamool Ja Staging Point' },
        [4] = { tele = 'HALVUNG_SP', label = 'Halvung Staging Point' },
        [5] = { tele = 'ILRUSI_SP',  label = 'Ilrusi Atoll Staging Point' },
        [6] = { tele = 'NYZUL_SP',   label = 'Nyzul Isle Staging Point' },
    },
}
