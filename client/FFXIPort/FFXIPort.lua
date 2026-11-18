--[[
* FFXIPort (independent frontend) - 1.2.0 (history: CHANGELOG.md)
* Project: XI: Forever Offline
* Copyright (C) 2026 wildthing
* SPDX-License-Identifier: GPL-3.0-only
* Licensed under the GNU General Public License v3.0 only; see LICENSE.
*
* Milestone 8: speaks only FPX/1 (docs/PROTOCOL-FPX1.md) with the fpxport
* server module. Sends `!fpx 1 <sid> <rid> SYNC`, reassembles and validates the
* server's frames (ffxiport/fpx.lua), keeps the last validated snapshot in
* the model, re-syncs automatically after login, load and zone changes,
* loads the generated destination catalog, keeps per-character settings,
* and shows a window with the destination tabs. Travel: the Teleport
* button -> travel.go() is the only place a GO request is ever queued (one
* trip at a time, never retried automatically).
*
* Never load this together with the existing FFXIPort addon: both use the
* addon name FFXIPort and the /port command.
--]]

addon.name    = 'FFXIPort';
addon.author  = 'wildthing';
addon.version = '1.2.0';
addon.desc    = 'FFXIPort independent frontend - travel, favourites, quiet chat.';
addon.link    = '';

require('common');

local chat     = require('chat');
local protocol = require('ffxiport.fpx'); -- Milestone 8: FPX/1 replaces the former protocol module
local model    = require('ffxiport.model');
local zone     = require('ffxiport.zone');
local syncctl  = require('ffxiport.sync');
local catalog  = require('ffxiport.catalog');
local config   = require('ffxiport.config');
local theme    = require('ffxiport.ui.theme');
local rows     = require('ffxiport.ui.rows');
local window   = require('ffxiport.ui.window');
local travel   = require('ffxiport.travel');
local chatlog  = require('ffxiport.chatlog');
local echo     = require('ffxiport.echo');

syncctl.init(protocol, model, zone);
catalog.load();
config.init(catalog); -- after the catalog: favourites are pruned against it
travel.init({ catalog = catalog, model = model, config = config, protocol = protocol, zone = zone });
rows.init({ catalog = catalog, model = model, zone = zone, theme = theme, config = config });
window.init({
    catalog = catalog, model = model, config = config, syncctl = syncctl,
    protocol = protocol, zone = zone, theme = theme, rows = rows, travel = travel,
});

local app = {
    raw         = false, -- echo every received FPX frame
    zoneCount   = 0,
    tickError   = false,
    renderError = false,
};

-----------------------------------------------------------------------------
-- Output
-----------------------------------------------------------------------------

-- Raw printers (colours unchanged). All FFXIPort chat output goes through
-- chatlog.emit (Milestone 6B): out/good/bad/note(text, category) with NO
-- category mean 'explicit' (always shown), so anything not deliberately
-- classified stays visible.
local PRINT = {
    out  = function (text) print(chat.header(addon.name):append(chat.message(text))); end,
    good = function (text) print(chat.header(addon.name):append(chat.success(text))); end,
    bad  = function (text) print(chat.header(addon.name):append(chat.error(text))); end,
    note = function (text) print(chat.header(addon.name):append(chat.warning(text))); end,
};

chatlog.init(function () return config.get('chat_level'); end, PRINT);

local function out(text, category)  chatlog.emit(category or 'explicit', 'out', text); end
local function good(text, category) chatlog.emit(category or 'explicit', 'good', text); end
local function bad(text, category)  chatlog.emit(category or 'explicit', 'bad', text); end
local function note(text, category) chatlog.emit(category or 'explicit', 'note', text); end

local function usage()
    out('Usage: /port [open|close|hp|sg|sp|rp|fav|sync|status] | /port catalog [hp|sg|sp|rp|find <text>] | /port raw [on|off] | /port chat [quiet|normal|debug|trace on|off]   (alias /ffxiport)');
end

-----------------------------------------------------------------------------
-- Catalog diagnostics (/port catalog)
-----------------------------------------------------------------------------

local TAB_NAMES = { hp = 'Home Points', sg = 'Survival Guides', sp = 'Gate Crystals', rp = 'Runic Portals' };
local PREVIEW_ROWS = 12; -- rows printed by /port catalog <tab>; keeps chat readable

local function unlockText(u)
    if u == true then return 'unlocked'; end
    if u == false then return 'locked'; end
    return 'waiting for sync';
end

local function catalogLine(row, unlocked)
    local extra = '';

    if row.tab == 'hp' then
        extra = string.format('  zone %d  city %s', row.zone, row.group ~= 0 and tostring(row.group) or '-');
    elseif row.tab == 'sg' then
        extra = string.format('  zone %d  bit %d:%d', row.zone, row.sgGroup, row.sgIndex);
    elseif row.tab == 'sp' then
        extra = string.format('  -> %s  needs: %s', catalog.destination(row), tostring(catalog.requirement(row)));
    elseif row.tab == 'rp' then
        extra = string.format('  -> %s', catalog.destination(row));
    end

    return string.format('%s %3d  %s%s  [%s]  %s', row.tab, row.id, catalog.name(row), extra,
        catalog.expansionLabel(row.exp), unlockText(unlocked));
end

local function printCatalog(sub, rest)
    local loaded, err = catalog.loaded();

    if not loaded then
        bad('Catalog not loaded: ' .. tostring(err));
        return;
    end

    if sub == 'hp' or sub == 'sg' or sub == 'sp' or sub == 'rp' then
        local items = catalog.withUnlocks(sub, model.hasData() and model or nil);
        local shown = math.min(#items, PREVIEW_ROWS);

        out(string.format('%s (%d):', TAB_NAMES[sub], #items));

        for i = 1, shown do
            out('  ' .. catalogLine(items[i].row, items[i].unlocked));
        end

        if #items > shown then
            out(string.format('  ... %d more. Use /port catalog find <text> to inspect specific destinations.', #items - shown));
        end

        return;
    end

    if sub == 'find' then
        local q = rest or '';
        local n = 0;

        out(string.format('Search "%s" (normalised "%s"):', q, catalog.normalize(q)));

        for _, tab in ipairs(catalog.tabs()) do
            for _, item in ipairs(catalog.filter(tab, { text = q, model = model.hasData() and model or nil })) do
                n = n + 1;

                if n <= 40 then
                    out('  ' .. catalogLine(item.row, item.unlocked));
                end
            end
        end

        out(string.format('%d match(es)%s', n, n > 40 and ' (first 40 shown)' or ''));
        return;
    end

    -- Summary.
    local ok, problems = catalog.verify();

    if ok then
        good(string.format('Catalog version %s: verify OK.', tostring(catalog.version())));
    else
        bad('Catalog verify FAILED:');

        for i = 1, math.min(#problems, 8) do
            bad('  - ' .. problems[i]);
        end
    end

    local c     = catalog.counts();
    local parts = {};

    for _, tab in ipairs(catalog.tabs()) do
        local text = string.format('%s %d', tab, c[tab]);

        if model.hasData() then
            local on = 0;

            for _, item in ipairs(catalog.withUnlocks(tab, model)) do
                if item.unlocked == true then on = on + 1; end
            end

            text = text .. string.format(' (%d usable)', on);
        end

        parts[#parts + 1] = text;
    end

    out('Rows: ' .. table.concat(parts, '   ') .. (model.hasData() and '' or '   (unlocks: waiting for sync)'));

    local ns = catalog.nameStats();

    out(string.format('Client names: zones %d/%d, key items %d/%d from the client; %d non-ASCII; fallbacks retried every %d s.',
        ns.zonesResolved, ns.zones, ns.keyItemsResolved, ns.keyItems, ns.nonAscii, catalog.RETRY_MS / 1000));

    if #ns.unresolved > 0 then
        note(string.format('%d name(s) using a fallback:', #ns.unresolved));

        for i = 1, math.min(#ns.unresolved, 10) do
            note('  ' .. ns.unresolved[i]);
        end
    end
end

local function seconds(ms)
    if type(ms) ~= 'number' then
        return '?';
    end

    return string.format('%.1f s', ms / 1000);
end

local function balanceText(v)
    if v == nil then return '?'; end
    if v < 0 then return 'unreadable'; end
    return tostring(v);
end

local function countSet(set)
    local n = 0;

    for _ in pairs(set or {}) do
        n = n + 1;
    end

    return n;
end

local function offerText(list)
    if list == nil then
        return '?';
    end

    local parts = {};

    for _, o in ipairs(list) do
        parts[#parts + 1] = o.cur .. tostring(o.amount);
    end

    return table.concat(parts, '+');
end

-- Prints what an FPX/1 sync response contained. Used for valid and invalid
-- results; an invalid one is labelled as such and is never committed.
-- category: chatlog category of these lines (nil = explicit, e.g. from
-- /port status, which also runs inside chatlog.explicit).
local function printDetails(result, category)
    local st = result.staged;

    out(string.format('Request %s   frames: %d   protocol: %s   time: %s',
        tostring(result.rid), result.frames or 0, protocol.NAME, seconds(result.elapsed)), category);

    if st == nil then
        return;
    end

    out(string.format('Character %s   zone %s   travel here: %s',
        tostring(st.ch), tostring(st.zone), st.travelBlock and ('blocked (' .. st.travelBlock .. ')') or 'allowed'), category);

    for _, cat in ipairs({ 'H', 'S', 'G', 'R' }) do
        local o = st.offers[cat];
        local over = countSet(o.over);

        -- st.counts[cat] is the size of the server's id range (bitmap length,
        -- PROTOCOL-FPX1.md §5.1), NOT a number of destinations: e.g. 122 Home
        -- Point ids (0-121, one unused) and 7 Runic Portal ids (1-6, 0 unused).
        local tab = protocol.CAT_TO_TAB[cat];
        out(string.format('%s: %d unlocked on the server; catalogue lists %d (server id range %d)   price %s%s',
            TAB_NAMES[tab], countSet(st.unlock[cat]), #catalog.rows(tab), st.counts[cat] or 0, offerText(o.default),
            over > 0 and string.format(' (%d destination-specific)', over) or ''), category);
    end

    local missing = model.uncatalogued(catalog);

    if missing then
        for _, cat in ipairs({ 'H', 'S', 'G', 'R' }) do
            if #missing[cat] > 0 then
                note(string.format('%s unlocked but not in this catalogue (outside its Original-ToAU scope): ids %s',
                    TAB_NAMES[protocol.CAT_TO_TAB[cat]], table.concat(missing[cat], ',')), category);
            end
        end
    end

    local b = st.balances;

    if b then
        out(string.format('Balances: gil %s   IS %s   CP %s', balanceText(b.gil), balanceText(b.is), balanceText(b.cp)), category);
    end
end

local function printReasons(result, category)
    local reasons = result.reasons or {};

    for i = 1, math.min(#reasons, 8) do
        bad('  - ' .. reasons[i], category);
    end

    if #reasons > 8 then
        bad(string.format('  ... and %d more', #reasons - 8), category);
    end
end

-----------------------------------------------------------------------------
-- The five diagnostic states (plus send failure)
-----------------------------------------------------------------------------

local function describeState(state)
    if state == 'idle' then
        return 'No sync requested yet.';
    elseif state == 'queued' then
        return 'Command queued but not yet sent' .. ((zone.inProgress() or zone.isZoning()) and ' (waiting for the zone change to finish).' or '.');
    elseif state == 'sent' then
        return 'Command sent, awaiting response.';
    elseif state == 'receiving' then
        return 'Response arriving.';
    elseif state == 'timeout' then
        return 'No response received before timeout.';
    elseif state == 'invalid' then
        return 'Response received but invalid or incomplete.';
    elseif state == 'ok' then
        return 'Complete and valid synchronization.';
    elseif state == 'send_failed' then
        return 'Command could not be sent.';
    end

    return 'Unknown state: ' .. tostring(state);
end

local function timeoutTail()
    local c = syncctl.status();

    if c.retryAt ~= nil then
        return ' Retrying once in 5 s.';
    elseif c.want then
        return ' A zone re-sync follows.';
    end

    return ' Use /port sync to try again.';
end

-- origin: 'manual' | 'auto' | 'retry' | 'startup' (7A) | 'server' (unsolicited reply).
-- What is shown at which chat level comes from chatlog.syncPlan (6B):
-- failures always; a manual success is one line only while the window is
-- closed (its status line shows it otherwise); details only in debug.
local AUTO_LABEL = { auto = 'Zone re-', retry = 'Retry ', startup = 'Initial ' };

local function reportState(state, result, origin)
    local automatic = (AUTO_LABEL[origin] ~= nil);
    local plan = chatlog.syncPlan(state, origin, window.isOpen());

    if state == 'queued' or state == 'sent' then
        if plan.main ~= nil then
            out(describeState(state), plan.main);
        end
    elseif state == 'receiving' then
        return; -- shown by /port status; avoids chat noise
    elseif state == 'ok' then
        if automatic then
            good(string.format('%ssync: complete and valid (%d frames, %s).',
                AUTO_LABEL[origin], result.frames or 0, seconds(result.elapsed)), plan.main);
            return;
        end

        good(describeState(state), plan.main);
        printDetails(result, plan.detail);
        good('Response complete and checksummed.', plan.detail);
    elseif state == 'invalid' then
        bad(describeState(state) .. ' Not committed; previous data kept.', plan.main);
        printReasons(result, plan.reasons);

        if not automatic then
            printDetails(result, plan.detail);
        end
    elseif state == 'timeout' then
        bad(describeState(state) .. string.format(' (%s after send)', seconds(result and result.elapsed)) .. timeoutTail(), plan.main);
    elseif state == 'send_failed' then
        bad(describeState(state), plan.main);
        printReasons(result, plan.reasons);
    end
end

-- 1.1.0: never omit unlocked destinations silently. Once per session, say
-- how many unlocked server destinations this catalogue cannot list.
local uncataloguedReported = false;

local function reportUncatalogued()
    if uncataloguedReported then
        return;
    end

    local missing = model.uncatalogued(catalog);

    if missing == nil then
        return;
    end

    uncataloguedReported = true;
    local n = #missing.H + #missing.S + #missing.G + #missing.R;

    if n > 0 then
        note(string.format("%d unlocked destination(s) are outside this catalogue's Original-ToAU scope and are not listed (Home Points %d, Survival Guides %d). /port status shows the ids.",
            n, #missing.H, #missing.S), 'warning');
    end
end

syncctl.handlers.onReport = function (state, result, origin)
    reportState(state, result, origin);

    if state == 'ok' then
        pcall(reportUncatalogued);
    end

    -- 6B trace (read-only): the sync line really left.
    if state == 'sent' then
        local _, req = protocol.syncState();
        chatlog.traceSent(protocol.buildSync(req and req.rid or '????'), protocol.now());
    end

    -- Travel may lift an "unknown outcome" block, but only for a locally
    -- requested sync that was queued after the outcome became unknown and
    -- actually sent (travel.onSyncReport). This still does not prove an old
    -- reply can no longer arrive.
    local _, req = protocol.syncState();
    travel.onSyncReport(state, origin, req);
end;
protocol.handlers.onSyncState = syncctl.onSyncState;
protocol.canSend = function () return not zone.inProgress(); end;

-- Milestone 7A: "a character is in the world". Polled by syncctl.tick only
-- while the session's initial sync is still pending; every signal must
-- agree, any error means not ready (sync.lua). The settings library's own
-- login flag (also what per-character saving uses) must be set, the client
-- must report login status 2 (as Ashita's settings library checks on
-- load), not be zoning, and know a zone and the character's name.
syncctl.isReady = function ()
    if not config.persistable() or zone.inProgress() or zone.isZoning() then
        return false;
    end

    local mm = AshitaCore:GetMemoryManager();

    if mm:GetPlayer():GetLoginStatus() ~= 2 then
        return false;
    end

    local party = mm:GetParty();
    local zid   = party:GetMemberZone(0);
    local name  = party:GetMemberName(0);

    return type(zid) == 'number' and zid > 0 and type(name) == 'string' and name ~= '';
end;

-- Protocol warnings (version mismatch, server could not read a request,
-- handler errors) stay visible at every chat level.
protocol.handlers.onWarn = function (text)
    note(text, 'protocol.warn');
end;

-- Informational protocol events (discarded/stale frames, classified by
-- fpx.lua, not by text): shown only in debug.
protocol.handlers.onInfo = function (kind, text)
    note(text, 'protocol.info');
end;

-- Milestone 5B: travel learns when its request really left / failed to.
protocol.handlers.onSent = function (tag, line, t)
    travel.onSent(tag, line, t);
    chatlog.traceSent(line, t); -- 6B trace (read-only)
end;
protocol.handlers.onSendFailed = function (tag, err) travel.onSendFailed(tag, err); end;
protocol.handlers.onExpired    = function (tag, line, t) travel.onExpired(tag, line, t); end;

-- Milestone 6B.1: expect the chat echo of a line FFXIPort is about to hand
-- to QueueCommand (before the call: the echo can arrive synchronously).
protocol.handlers.onBeforeDispatch = echo.onBeforeDispatch;
protocol.handlers.onDispatchFailed = echo.onDispatchFailed;

-- Travel reports: problems (bad) always shown; a successful trip shows one
-- line (accepted, with the server's payment text) in quiet mode.
travel.handlers.onReport = function (text, isBad)
    local category = chatlog.travelCategory(isBad, travel.state());

    if isBad then bad(text, category); else good(text, category); end
end;

-- Milestone 8: travel responses are correlated by request id in fpx.lua and
-- delivered only for the current trip; travel.lua applies them.
protocol.handlers.onTravel = function (result) travel.onResponse(result); end;

-- Travel asks for a refresh after an unknown outcome or a price/lock refusal.
travel.handlers.onNeedSync = function (reason)
    if not protocol.isBusy() then
        syncctl.request('auto', protocol.now());
    end
end;

-- The logged-in character's server id, so a snapshot for another character
-- (e.g. a late reply across a character switch) is rejected.
protocol.localServerId = function ()
    return AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0);
end;

-- Server frames are blocked from the chat log; they are shown only in
-- Debug chat mode or with /port raw on.
protocol.handlers.onRecord = function (line)
    if app.raw then
        out('raw: ' .. line);
    else
        note('frame: ' .. line, 'protocol.info');
    end
end;

-----------------------------------------------------------------------------
-- Commands
-----------------------------------------------------------------------------

local function requestSync()
    local ok, state = syncctl.request('manual', protocol.now());

    if not ok then
        note('A sync is already in progress: ' .. describeState(state), 'warning');
    elseif zone.inProgress() then
        note('Zone change in progress: the request will be sent once it has finished.', 'warning');
    end
end

local function ago(t, now)
    if type(t) ~= 'number' then
        return 'never';
    end

    return seconds(now - t) .. ' ago';
end

local function zoneText(id)
    return id == nil and '?' or tostring(id);
end

local function printZoneAndModel(now)
    local z = zone.status();
    local c = syncctl.status();

    out(string.format('Zone: %s   zoning flag: %s   zone changes completed: %d   character: %s',
        zoneText(z.zone), z.zoning and 'yes' or 'no', z.completed, z.character or '?'));

    local ep = z.episode;

    if ep then
        note(string.format('Zone change IN PROGRESS: started %s, arrived: %s, from %s, signals: %s (sending held)',
            ago(ep.startedAt, now), ep.arrived and 'yes' or 'no', zoneText(ep.fromZone), ep.causes));
    end

    if z.last then
        out(string.format('Last zone change: %s -> %s, completed %s, took %s%s%s',
            zoneText(z.last.fromZone), zoneText(z.last.toZone), ago(z.last.at, now), seconds(z.last.duration),
            z.last.logout and ', after login' or '', z.last.viaFallback and ', via fallback' or ''));
    end

    out(string.format('Auto re-sync: %s   pending: %s   retry: %s   last action: %s',
        c.answered and 'armed' or 'waiting for first answered sync',
        c.want and ('yes, since ' .. ago(c.wantSince, now)) or 'no',
        c.retryAt and ('in ' .. seconds(c.retryAt - now)) or (c.retryUsed and 'used' or 'available'),
        c.lastAction));
    out(string.format('Initial sync (this session): %s', c.startup == 'pending'
        and (c.readySince and ('waiting, ready since ' .. ago(c.readySince, now)) or 'waiting for login/zone readiness')
        or (c.startup == 'requested' and 'requested automatically' or 'covered by another request')));
    out(string.format('Requests: startup %d, manual %d, auto %d, retry %d   results: ok %d, invalid %d, timeout %d   zone re-syncs skipped: %d   fallback releases: %d',
        c.counts.startup, c.counts.manual, c.counts.auto, c.counts.retry, c.counts.ok, c.counts.invalid, c.counts.timeout, c.counts.skipped, c.counts.fallback));

    local counts = model.counts();

    if counts then
        good(string.format('Model: data from %s (revision %d, %s)   hp %d unlocked   sg %d unlocked   gate crystals %d/%d   portals %d/%d',
            ago(model.committedAt(), now), model.revision(), tostring(model.catalog()),
            counts.hp, counts.sg, counts.sp, counts.spTotal, counts.rp, counts.rpTotal));
        out(string.format('Model balances: gil %s   IS %s   CP %s   (updated %s)',
            balanceText(model.balance('gil')), balanceText(model.balance('is')), balanceText(model.balance('cp')),
            ago(model.balancesAt(), now)));
    else
        out('Model: no validated data yet (waiting for sync).');
    end

    local st = model.status();

    if st.text then
        local line = 'Status line: ' .. st.text;

        if st.bad then bad(line); else good(line); end
    end
end

local function printStatus()
    local now   = protocol.now();
    local state = protocol.syncState();
    local s     = protocol.stats();
    local c     = protocol.committed();

    out('State: ' .. describeState(state));
    out(string.format('Chat packets: %d   frames: %d   responses: %d   stale: %d   malformed: %d   duplicates: %d   conflicts: %d   checksum: %d   foreign: %d   queued lines: %d   zone enter packets: %d',
        s.packets, s.frames, s.responses, s.stale, s.malformed, s.duplicates, s.conflicts, s.checksum, s.foreign,
        protocol.queueLength(), app.zoneCount));

    local lf = protocol.lastForeign();

    if lf then
        note(string.format('Last frame-like chat ignored: %s (mode %s, sender "%s").', lf.reason, tostring(lf.mode), tostring(lf.sender)));
    end

    local mm = protocol.versionMismatch();

    if mm then
        bad(string.format('Protocol version mismatch: client %s, server %s. Automatic sync is stopped.', protocol.NAME, tostring(mm.server)));
    end

    printZoneAndModel(now);

    local cs = config.status();
    out(string.format('Settings: %s   %s   tab %s, only usable %s, favourites %d, scale %d%%   last check (%s): %d fixed, %d pruned   switches %d, saves %d   window %s',
        tostring(cs.path), cs.loggedIn and 'saving per character' or 'not logged in (not saved)',
        tostring(config.get('tab')), tostring(config.get('only_usable')), cs.favourites, config.get('scale'),
        tostring(cs.lastCheck.at), cs.lastCheck.fixed, cs.lastCheck.pruned, cs.switches, cs.saves,
        window.isOpen() and 'open' or 'closed'));

    -- 1.2.0 UI preferences and whether text scaling works in this client.
    local bx, by = config.buttonPos();
    out(string.format('UI: theme %s, scale %d%% (text scaling: %s), expansion filter %s, floating button %s%s',
        tostring(window.pref('theme')), tonumber(window.pref('scale')) or 100,
        theme.fontScaling == true and 'yes' or (theme.fontScaling == false and ('NO - ' .. tostring(theme.fontError)) or 'not drawn yet'),
        tostring(window.pref('expansion')), window.pref('button') == true and 'on' or 'off',
        bx and string.format(' at %d,%d', bx, by) or ''));

    local ts = travel.status();
    out(string.format('Travel: %s%s   session %d   last: %s',
        ts.state, ts.trip and (' (' .. ts.trip.tag .. ' rid ' .. tostring(ts.trip.rid) .. ' ' .. tostring(ts.trip.command) .. ')') or '',
        ts.gen, tostring(ts.last)));

    if ts.reconcile then
        bad(string.format('Trip rid %s needs reconciliation (%s ago): %s %s', tostring(ts.reconcile.rid),
            ago(ts.reconcile.at, now), ts.reconcile.text, travel.RECONCILE_TEXT));
    end

    if c then
        good('Committed snapshot available (' .. tostring(c.protocol) .. ', character ' .. tostring(c.ch) .. ').');
    else
        out('No committed sync.');
    end

    local r = protocol.lastResult();

    if r and (r.status == 'ok' or r.status == 'invalid') then
        out('Last result: ' .. r.status);
        printReasons(r);
        printDetails(r);
    elseif r then
        out('Last result: ' .. r.status);
    end
end

-- /port chat [quiet|normal|debug] | /port chat trace [on|off]   (Milestone 6B)
local function chatCommand(arg, arg2)
    if arg == '' then
        local tr = chatlog.traceStatus();
        local es = echo.stats();
        out(string.format('Chat level: %s (quiet | normal | debug).   Trace: %s.', chatlog.level(), tr.on and 'on' or 'off'));
        out(string.format('Command echoes (6B.1): %s, hidden in quiet only; expected %d, matched %d, hidden %d, expired %d, pending %d.',
            echo.enabled and 'on' or 'off', es.expected, es.matched, es.hidden, es.expired, echo.pendingCount()));
    elseif chatlog.LEVELS[arg] ~= nil then
        if config.set('chat_level', arg) or config.get('chat_level') == arg then
            out('Chat level: ' .. arg .. ' (saved for this character).');
        else
            note('The chat level could not be saved (no character logged in).');
        end
    elseif arg == 'trace' then
        local on = arg2 == 'on' or (arg2 ~= 'off' and not chatlog.traceStatus().on);

        chatlog.setTrace(on);

        if on then
            out('Trace on (this session only): for 5 s after each FFXIPort command, chat lines are listed as "trace:". Read-only: nothing is blocked or changed.');
        else
            out('Trace off.');
        end
    else
        usage();
    end
end

ashita.events.register('command', 'ffxiport_command', function (e)
    local args = e.command:args();

    if #args == 0 then
        return;
    end

    local cmd = string.lower(args[1]);

    if cmd ~= '/port' and cmd ~= '/ffxiport' then
        return;
    end

    e.blocked = true;

    local sub = string.lower(args[2] or '');

    -- Milestone 4: /port toggles the window (it used to request a sync);
    -- /port sync is the explicit manual sync.
    if sub == '' then
        window.toggle();
    elseif sub == 'open' then
        window.open();
    elseif sub == 'close' then
        window.close();
    elseif sub == 'hp' or sub == 'sg' or sub == 'sp' or sub == 'rp' or sub == 'fav' then
        window.open(sub);
    elseif sub == 'sync' then
        requestSync();
    elseif sub == 'status' then
        chatlog.explicit(printStatus); -- user-requested: shown at every chat level
    elseif sub == 'catalog' then
        chatlog.explicit(printCatalog, string.lower(args[3] or ''), #args >= 4 and table.concat(args, ' ', 4) or '');
    elseif sub == 'raw' then
        local v = string.lower(args[3] or '');

        if v == 'on' then
            app.raw = true;
        elseif v == 'off' then
            app.raw = false;
        else
            app.raw = not app.raw;
        end

        out('Raw frame echo: ' .. (app.raw and 'on' or 'off'));
    elseif sub == 'chat' then
        chatlog.explicit(chatCommand, string.lower(args[3] or ''), string.lower(args[4] or ''));
    else
        usage();
    end
end);

-----------------------------------------------------------------------------
-- Events
-----------------------------------------------------------------------------

-- Logout or a different character: drop the old character's data and the
-- session's "answered" flag; anything queued or in flight is discarded.
local function newSession(reason)
    uncataloguedReported = false; -- 1.1.0: report again for the next character
    travel.reset();          -- cancels an unsent trip, new generation (5B)
    protocol.reset();
    model.clear();
    syncctl.resetSession();
    window.resetSelection(); -- selections are session-only (Milestone 5A)
    window.resetCharacterState(); -- rc.2: no UI state carries over to the next character
    chatlog.setTrace(false); -- the diagnostic trace is session-only (6B); drops held lines; chat_level is kept
    echo.clear();            -- 6B.1: no expected echo survives a logout or character switch
    note('Session reset (' .. reason .. '): previous sync data cleared.', 'session');
end

zone.handlers.onWarn      = function (text) note(text, 'protocol.warn'); end;
zone.handlers.onLogout    = function () newSession('logout'); end;
zone.handlers.onCharacter = function (name) newSession('character changed'); end;
zone.handlers.onComplete  = function (info)
    if info.viaFallback then
        note('Zone change released after 60 s without a confirmed arrival; no automatic sync. Use /port sync if needed.', 'warning');
    end

    syncctl.onZoneComplete(info, protocol.now());
end;

window.handlers.onError = function (text)
    bad('The FFXIPort window was closed after a render error (reported once): ' .. text, 'error');
end;

-- Character switch / login / logout (settings library): show the new
-- character's tab and drop cached row lists.
config.onChange(function ()
    rows.clearCache();

    if window.isOpen() then
        window.open();
    end
end);

ashita.events.register('load', 'ffxiport_load', function ()
    protocol.reset();
    out('FFXIPort ' .. addon.version .. ' loaded. /port opens the window, /port sync synchronizes.');
end);

ashita.events.register('unload', 'ffxiport_unload', function ()
    travel.reset();
    window.close();
    window.resetSelection();
    protocol.canSend = nil;
    protocol.reset();
    model.clear();
    zone.reset();
    syncctl.resetSession();
    echo.clear(); -- 6B.1
end);

ashita.events.register('packet_in', 'ffxiport_packet_in', function (e)
    if e.id == 0x000A or e.id == 0x000B then
        if e.id == 0x000A then
            app.zoneCount = app.zoneCount + 1;
        end

        zone.onPacket(e, protocol.now());
        return;
    end

    local handled = protocol.onPacket(e);

    -- 6B trace (read-only, only while tracing): other 0x017 chat packets.
    -- Never touches e.blocked or the packet data.
    if not handled and e.id == 0x0017 and chatlog.traceStatus().on then
        pcall(function ()
            -- RC5: same reader as the protocol, and the mode is shown too.
            local mode, name, msg = protocol.readChat(e.data_modified);
            chatlog.traceSeen('packet', string.format('0x017 mode %s from %s', tostring(mode), tostring(name)), msg, protocol.now());
        end);
    end
end);

-- 6B.1: the local character's name, needed to verify a command echo.
-- Zone packets first (set on 0x000A), else the party list slot 0. nil when
-- unknown: then no echo can match and every line stays visible.
local function localName()
    local name = zone.status().character;

    if type(name) == 'string' and name ~= '' then
        return name;
    end

    local ok, n = pcall(function ()
        return AshitaCore:GetMemoryManager():GetParty():GetMemberName(0);
    end);

    return (ok and type(n) == 'string' and n ~= '') and n or nil;
end

-- RC5: LSB fills the speaker of server system messages with the receiving
-- character's own name, so FPX frames are trusted only from that name (or an
-- empty speaker) on the SYSTEM_3 channel.
protocol.localName = localName;

-- Incoming chat text.
--   6B.1: hides ONLY the exact echo "<own name> : <command>" of a command
--   FFXIPort itself just dispatched (see ffxiport/echo.lua), and only in
--   quiet mode. Nothing is matched when no expectation is pending, so all
--   other chat is never inspected for hiding. Errors keep the line visible.
--   6B trace (read-only): lists the line while tracing, marked when hidden.
-- text_out and packets are never blocked.
ashita.events.register('text_in', 'ffxiport_text_in', function (e)
    local hide, entry = false, nil;

    if echo.pendingCount() > 0 then
        local ok, h, en = pcall(function ()
            -- Original text first (other addons may prefix e.g. a timestamp
            -- to message_modified), then the modified text. Each field is
            -- read on its own so a missing one cannot abort the other.
            local texts = {};

            for _, key in ipairs({ 'message', 'message_modified' }) do
                local okField, v = pcall(function () return e[key]; end);

                if okField and type(v) == 'string' then
                    texts[#texts + 1] = v;
                end
            end

            return echo.filter(texts, localName(), chatlog.level(), protocol.now());
        end);

        if ok then
            hide, entry = (h == true), en;
        end
    end

    if chatlog.traceStatus().on then
        pcall(function ()
            local detail = 'mode ' .. tostring(e.mode_modified);

            if entry ~= nil then
                detail = detail .. (hide and ' [echo, hidden]' or ' [echo, shown: not quiet]');
            end

            chatlog.traceSeen('text_in', detail, e.message_modified, protocol.now());
        end);
    end

    if hide then
        e.blocked = true;
    end
end);

ashita.events.register('text_out', 'ffxiport_text_out', function (e)
    if not chatlog.traceStatus().on then
        return;
    end

    pcall(function ()
        chatlog.traceSeen('text_out', '', e.message_modified, protocol.now());
    end);
end);

local function step(label, fn, t)
    local ok, err = pcall(fn, t);

    if not ok and not app.tickError then
        app.tickError = true;
        bad(label .. ' tick error (reported once): ' .. tostring(err), 'error');
    end
end

ashita.events.register('d3d_present', 'ffxiport_present', function ()
    local t = protocol.now();

    step('Zone', zone.tick, t);       -- zone state first, so the send gate is current
    step('Travel', travel.tick, t);   -- before protocol: expired/zone-cancelled trips are removed before any dispatch
    step('Protocol', protocol.tick, t);
    step('Sync', syncctl.tick, t);

    -- The window renders last, under its own pcall: it never delays or
    -- breaks the ticks above.
    local ok, err = pcall(window.render, t);

    if not ok and not app.renderError then
        app.renderError = true;
        bad('Window render error (reported once): ' .. tostring(err), 'error');
    end
end);
