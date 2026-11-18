# Test results — FFXIPort 1.1.0

The implementer executed every run below in this workspace on Windows 11. Raw
outputs are in `tests/results/`, one file per runtime and suite, written by
the same runs that produced the numbers here.

| Runtime | Installed via |
|---------|---------------|
| LuaJIT 2.1.1720049189 | winget `DEVCOM.LuaJIT` |
| Lua 5.4.6 | winget `DEVCOM.Lua` |

## Executed

| Suite | LuaJIT 2.1 | Lua 5.4.6 |
|-------|-----------|-----------|
| `tests/server/test_fpxport.lua` (server module vs LSB API mocks, incl. fault injection) | **68 passed, 0 failed** | **68 passed, 0 failed** |
| `tests/client/test_client.lua` (client end-to-end against the real server module; since RC5 every frame passes through `fpx.onPacket` as a realistic 0x017 packet) | **69 passed, 0 failed** | **69 passed, 0 failed** |
| `tests/client/test_addon_smoke.lua` (real addon entry point with Ashita stubs: load, sync over 0x017 packets, `/port status`, `/port catalog`, `/port sync`, other commands, chat, unload) | **9 passed, 0 failed** | **9 passed, 0 failed** |
| `tools/gen_catalog.lua` + comparison with the previous catalogue (verification only) | **193 rows identical; 112 zone labels identical; city table: 2 intended differences (48 out, 71 in)** | not run |
| `tools/verify_catalog_vs_lsb.lua` (catalogue ↔ server ↔ upstream LSB) | **193 rows, 0 mismatches** | not run |
| `tools/gen_city_groups.lua … .` (module city table ↔ LSB-derived) | **24 zones, 0 mismatches** | not run |
| Compile check of every shipped `.lua` file (`loadfile`) | all compile | all compile |
| Both suites re-run from the extracted release ZIP | done after packaging; reported in the release report (it postdates this file) | same |

Mutation check (scratch copy, not shipped; confirms the new tests detect
regressions):

| Deliberate defect | Result |
|-------------------|--------|
| Client: no correction window after `T` (RC3 run) | client suite: 3 tests fail |
| Server: every refund treated as confirmed (RC3 run) | server suite: 4 tests fail |
| Server: same-city rule disabled (RC3 run) | server suite: 7 tests fail |
| Server: replay cache keyed by RID only, the RC3 behaviour (RC4 run) | server: 3 fail; client: 2 fail |
| Client: constant session id and `os.time()` RID seed (RC4 run) | client: 4 fail (server suite unaffected, as expected) |
| Client: RC4 sender rule (only an empty speaker trusted), the in-game failure (RC5 run) | client: 46 fail |
| Server: RC4 chunk size 180 (RC5 run) | server: 3 fail; client: 43 fail (frames truncated at 150 bytes by the packet fixture, as LSB does) |
| Client: any speaker trusted on mode 29 (RC5 run) | client: 2 fail |

Earlier reviews reported their own Lua 5.4 runs of RC1/RC2. Those runs were
the reviewer's; they are not repeated or claimed here.

## In-game results reported by the owner (XI: Forever Offline, 1.1.0-rc.5)

Confirmed in game: FPX/1 communication; automatic synchronization; zone
re-synchronization; free same-city travel; paid travel with gil; payment with
Conquest Points; protocol messages hidden from chat. **Not** tested in game:
Runic Portal travel, Imperial Standing payment, refusal and failure paths,
rapid reloads. The destination categories used in the paid trips were not
recorded.

## RC5 coverage (live 0x017 reception)

The cause was confirmed from LSB source, not assumed:
`GP_SERV_COMMAND_CHAT_STD` writes `sender.empty() ? PChar->getName() : sender`
into `sName`, so `printToPlayer(frame, 29)` arrives with the player's own name.
The packet `Kind` is the channel passed by the module (29). `Mes` is capped at 150
bytes.

Fixtures (`tests/lib/packets.lua`) build packets exactly like that constructor.
They cover: valid frames with the local character name (the observed in-game
case, e.g. "Tuna") through a full sync, all frames blocked from chat;
empty-sender frames; wrong sender; case-different sender; wrong channel (say,
shout, tell, party, linkshell, system 1/2, …); unknown local name;
out-of-order and duplicated packets; wrong request id (blocked as noise,
never applied); bad checksum (rejected, nothing applied); malformed or
forged-looking frame text; ordinary chat (other players, own say, server
notices on channel 29) never blocked; a 150-byte message without NUL; every
frame of a fully unlocked snapshot ≤ 150 bytes; travel end to end through the
packet handler.

## RC4 coverage (request-id reuse)

**Server:** requests without a valid session id (RC3 shape, uppercase, short)
are refused with `BADREQ`. A SYNC with an equal RID from a new session returns
the changed balance, while the old session still replays its own entry. A GO
with an equal RID from a new session is refused as `BUSY` inside the 5 s
cooldown (not answered with the old `T`), and after the cooldown, but still
inside the 30 s replay window, executes as a new trip charged once. A colliding
RID with a different destination and a changed balance is answered for the new
request. A same-session retransmission is still replayed without a second
charge. The rate limit is shared across sessions.

**Client:** two fresh loads of `fpx.lua` in the same `os.time()` second get
different session ids. `reset()` changes the session id. End to end against the
server, after a simulated reload with a forced equal RID: SYNC shows the new
balance; GO travels to the new destination, charged exactly once, with the
model balance updated. A same-session retransmission of a GO line is replayed
without a charge.

## RC3 coverage

**Transaction (server):** normal paid trip; normal free trip; failure before
deduction; currency API raising before / after applying the debit; refund
after a raised debit failing; unreadable balance after a raised debit;
post-charge balance read failing; response send failing; `setPos` failing
before movement (T then same-RID `E INTERNAL`, refund confirmed); `setPos`
raising after the move took effect / while zoning there (T stands, no
refund); unreadable move state (`UNSURE`); refund raising (`UNSURE`, no
"refunded" notice); refund unverifiable (`UNSURE`); refund raising after
crediting (balance proves it, `INTERNAL`); free trip whose move fails;
replay of successful, corrected and failed request ids; CP and IS variants;
incident context fields and log line; a 28-case fault matrix checking that
the final cached outcome is consistent (moved ⇒ `T` and exactly the price,
unmoved charge ⇒ `UNSURE` + incident, otherwise a final `E`).

**Transaction (client):** correction `E INTERNAL` after `T` → failed, refund
confirmed, balance restored, never "complete"; correction `E UNSURE` →
uncertain + reconcile record kept after refresh; `E UNSURE` without `T`;
unreadable correction → uncertain; lost correction for a cross-zone trip →
uncertain, never success; same-zone destination completes only after the
correction window; duplicate `T` in the window changes nothing; a correction
after the zone change started is ignored; plus the existing timeout,
no-retry, zoning, stale-reply and duplicate-request tests.

**Pricing:** exact confirmed prices per category and currency (8
combinations); same price for every Home Point; no key-item price changes;
wrong payment method per category; expected-price mismatch; insufficient
funds for gil, CP and IS; locked destinations; no deduction on refusals.

**Same-city:** city table (Chateau, Heavens Tower in; Al Zahbi, Kazham, West
Ronfaure out); snapshot `f0` for same-city Home Points and Survival Guides;
free trip with zero balances and no currency API call; Chateau and Heavens
Tower as origins; different city and outside destinations paid; paying for
a free trip refused; unlock and state checks still apply; client shows
`Free`; client quote equals the server offer for every catalogue Home
Point, Gate Crystal and Runic Portal in every method.

**Retained:** startup sync, zone changes and character switching,
valid/invalid responses, request ids and stale responses, duplicates,
timeouts and retries, all categories, favourites persistence, Quiet Chat and
echo suppression, protocol version mismatch, bounds.

## Not executed / unverified

* **Everything in-game.** There was no Ashita client, FFXI client or Phoenix map
  server. RC5 is based on the owner's in-game evidence (own-name speaker,
  foreign count) and the LSB packet source. Confirm in game that frames now
  have mode 29 and are accepted. Unverified: the 0x017 packet layout and mode 29 with an empty
  speaker; `/say !fpx` handling without broadcast; `QueueCommand` and the echo
  format; `GetMemberServerId(0)`; real `setPos`/zoning and the timing of the
  correction relative to `T`; whether `getZone(true)` reports the destination
  while zoning (the move-state check depends on it).
* **Phoenix compatibility**, including the XI: Forever Offline module loader,
  and whether Phoenix's Home Point groups, regions and zone types equal
  upstream LSB. Re-run both tools against the Phoenix tree.
* **ImGui UI rendering.**
* **Linux extraction** of the ZIP (no Linux host); the entry names were checked.
* **Session id clock source in-game:** the session id uses `ashita.time.clock().ms`.
  Uniqueness across reloads relies on that clock advancing between loads (as a
  millisecond clock does); the random part covers a repeat. Not observed in
  the real client.
