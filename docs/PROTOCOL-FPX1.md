# FPX/1 — FFXIPort Exchange Protocol, version 1

Status: **Frozen for Milestone 8** (design fixed before any FFXIPort client
source or Phoenix/LSB source was examined in this workspace).
License: GPL-3.0-only. Copyright (C) 2026 wildthing.

## 0. Design provenance

This protocol was designed in a fresh, empty workspace exclusively from the
functional requirements written in the Milestone 8 task statement. No
Driftwood/dwport source, no legacy FFXIPort protocol code, no previous FFXIPort
server module, and no historical protocol specification or fixture was opened
while designing it. See `docs/CLEANROOM.md` for the access log.

Section 7 ("Transport binding") deliberately names only *kinds* of
capabilities (a server-side chat command, a server-to-player system message).
The concrete Phoenix/LSB API calls are bound in the server module after
reading the authoritative Phoenix/LSB source, without changing sections 1–6.

## 1. Goals and non-goals

Goals

* Synchronise, in one atomic snapshot: unlock status for the four travel
  categories, server-computed prices, and the character's currency balances.
* Request travel to one destination with an explicit payment method and an
  explicit *expected price* so that the server never charges an amount the
  player did not see.
* Correlate every response to exactly one request; survive fragmented,
  delayed, duplicated, malformed and out-of-order delivery.
* Bound every buffer, length, count and wait.

Non-goals: Outpost, Voidwatch, Unity, Recall or any other travel network;
compatibility with any earlier FFXIPort or third-party protocol; encryption
(the transport is a private server channel between one player and the server).

## 2. Vocabulary

| Term     | Meaning |
|----------|---------|
| Request  | One line sent by the client to the server. |
| Response | One logical message from the server, carried by 2–17 *frames*. |
| Frame    | One server-to-client chat line carrying part of a response. |
| RID      | Request identifier: 4 lowercase hex digits, `0001`–`ffff`. `0000` is reserved for "uncorrelatable". |
| SID      | Client session identifier (RC4): 12 lowercase hex digits, new on every addon load and every client session reset (§3.3). |
| Category | `H` Home Points, `S` Survival Guides, `G` Gate Crystals, `R` Runic Portals. |
| Dest id  | Non-negative decimal integer identifying a destination *within* a category (§5.4). |
| Currency | `g` gil, `c` conquest points (the character's current nation), `i` Imperial Standing. |

Character set: every byte on the wire is printable ASCII `0x21`–`0x7E` or a
single space `0x20` used only as a field separator. The characters `%`, `"`,
`\` and `|` are never emitted (they are avoided because chat/format paths may
treat them specially).

## 3. Requests (client → server)

```
REQUEST = "!fpx" SP VER SP SID SP RID SP OP *(SP ARG)
VER     = 1*2DIGIT                 ; this document: "1"
SID     = 12HEXDIG-lower           ; client session id (RC4, §3.3)
RID     = 4HEXDIG-lower            ; never "0000"
OP      = "SYNC" / "GO"
```

Limits: whole line ≤ 96 bytes; ≤ 8 space-separated tokens; tokens never empty.

### 3.1 SYNC

`!fpx 1 <sid> <rid> SYNC` — no arguments. Requests a full snapshot (§4.3). There is
no partial sync: snapshots are always complete so the client can replace its
state atomically.

### 3.2 GO

`!fpx 1 <sid> <rid> GO <cat> <dest> <cur> <amount>`

| Arg      | Grammar | Meaning |
|----------|---------|---------|
| `cat`    | `H` / `S` / `G` / `R` | category |
| `dest`   | `1*3DIGIT` | dest id (§5.4) |
| `cur`    | `g` / `c` / `i` / `f` | payment method; `f` = "I expect this trip to be free" |
| `amount` | `1*9DIGIT` | the price the client displayed; must be `0` when `cur` is `f` |

The server executes the trip **only if** the price it computes at that moment
for (`cat`, `dest`, `cur`) equals `amount`. Otherwise it answers
`E PRICE` with the current offer and charges nothing.

### 3.3 Session identifier (RC4 amendment)

RIDs alone are not unique across addon loads: a reloaded client restarts its
RID sequence and could repeat a RID the server has cached from the previous
load. So every request carries the client session id `SID`:

* The client creates a new SID on every addon load and every session reset
  (logout / character change). The first 8 hex digits are the low 32 bits of
  the client's millisecond clock; the last 4 are random. Two loads in the same
  process therefore differ unless they happen within the same millisecond, and
  even then the random part decides.
* The server's replay cache (§8.2) is keyed by **SID + RID**. The same SID and
  RID is a retransmission and is replayed, never re-executed. A different SID
  with the same RID is a new request and is executed normally.
* Rate limits and the travel cooldown remain **per character**, across all
  sessions, so a reload cannot bypass them.
* Responses are unchanged: frames carry only the RID, and the client correlates
  within its own session.
* A request without a valid SID (e.g. from an RC1–RC3 client) is answered
  `E BADREQ`. RC1–RC3 were never released, so no version bump was made.

## 4. Responses (server → client)

### 4.1 Frame grammar

```
FRAME   = "#fpx" VER SP RID SP SEQ "/" TOTAL SP DATA
SEQ     = 1*2DIGIT    ; 0..TOTAL
TOTAL   = 1*2DIGIT    ; 1..16  (number of body frames)
DATA    = 1*128VCHAR  ; no spaces (RC5: was 180)
```

* Frame `0` is the **header**: `DATA = KIND "," LEN "," SUM`
  * `KIND` — `S` snapshot, `T` travel accepted, `E` error.
  * `LEN`  — decimal byte length of the reassembled body (1–2048).
  * `SUM`  — Adler-32 of the body, 8 lowercase hex digits.
* Frames `1..TOTAL` carry consecutive body chunks; the body is their
  concatenation in SEQ order. Each chunk is 1–128 bytes.
* Whole frame line ≤ 150 bytes. (RC5: LSB's 0x017 chat packet holds at most
  150 message bytes and truncates longer ones. With a 17-byte prefix and 128-byte
  chunks a frame is ≤ 145 bytes, and the 2048-byte body maximum fits in 16 frames.)

A response is **complete** exactly when the header and all `TOTAL` body
frames for the same (`VER`, `RID`) are present, the concatenated length equals
`LEN`, and the Adler-32 equals `SUM`. Only then is the body parsed.

The server sends the header first and chunks in order, but the client must
not rely on it.

### 4.2 Body grammar

```
BODY  = PAIR *(";" PAIR)
PAIR  = KEY "=" VALUE
KEY   = 1*8(ALPHA / DIGIT)
VALUE = *(VCHAR except ";" and "=")
```

Keys are unique within a body. Unknown keys are ignored (minor extensions
inside version 1). Every body contains `v=1`.

### 4.3 Snapshot (`KIND = S`)

| Key | Required | Value |
|-----|----------|-------|
| `v`  | yes | `1` |
| `ch` | yes | character id (decimal) the snapshot belongs to |
| `z`  | yes | current zone id (decimal) |
| `g`  | yes | gil balance |
| `cp` | yes | conquest points of the current nation |
| `is` | yes | Imperial Standing |
| `uH` `uS` `uG` `uR` | yes | unlock bitmaps, §5.1 |
| `pH` `pS` `pG` `pR` | yes | category default offers, §5.2 |
| `xH` `xS` `xG` `xR` | no  | per-destination offer overrides, §5.3 |
| `ok` | yes | `1` if travel is currently permitted from here, else `0.<CODE>` (§6) |

### 4.4 Travel accepted (`KIND = T`)

| Key | Value |
|-----|-------|
| `v`   | `1` |
| `c`   | category |
| `d`   | dest id |
| `pay` | what was charged: `f0`, `g<n>`, `c<n>`, `i<n>` |
| `g` `cp` `is` | balances **after** the charge |

The server sends `T` *before* moving the character. The client must expect
the zone change that follows. `T` is **provisional** (§4.6).

### 4.5 Error (`KIND = E`)

| Key | Required | Value |
|-----|----------|-------|
| `v` | yes | `1` |
| `e` | yes | error code (§6) |
| `sv` | for `VERSION` | highest protocol version the server speaks |
| `need` | for `FUNDS`, `PRICE` | the server's current offer list for that destination (§5.2) |
| `g` `cp` `is` | optional | current balances (always unchanged by a refused request) |

### 4.6 Final travel outcome and correction (RC3 amendment)

Each `GO` request id has exactly one **final** outcome:

| Final response | Meaning |
|----------------|---------|
| `T` | Travel accepted, and the character was moved (or started zoning). |
| `E INTERNAL` | Travel did not happen and nothing remains charged: either nothing was taken, or a refund was made **and confirmed** by re-reading the balance. |
| `E UNSURE` | Travel failed, and the server could not establish the payment and/or movement outcome. A currency incident was logged; reconciliation is required. |
| any other `E` | Refused before charging (§6). |

Correction rule: because `T` is sent before the move, a move that then fails
is followed **immediately**, in the same server tick, by an `E INTERNAL` or
`E UNSURE` for the **same request id**. That later `E` supersedes the `T`.
The server sends at most one correction, and only when the character was not
moved, so it is never sent across a zone change.

* The server's replay cache always holds the final outcome. A repeated request
  id receives the correction, not the superseded `T`.
* The client keeps a request id that ended in `T` open for corrections for
  `CORRECTION_MS` (6 s) after `T` completes, or until the zone change starts.
  A `T` it has accepted must not be reported as completed before that window
  has passed or a zone change has been observed.
* A client that receives `E UNSURE`, or cannot establish the final outcome
  (no response, an invalid response, `T` without the expected zone change),
  must report the outcome as **uncertain** and must not claim success or a refund.

## 5. Data encodings

### 5.1 Unlock bitmap

`u<cat> = COUNT ":" HEX` where `COUNT` is the number of destination ids
(`0..COUNT-1`) and `HEX` has exactly `ceil(COUNT/4)` lowercase hex digits.
Digit `j` (0-based, left to right) encodes ids `4j..4j+3`; id `4j+k` is
unlocked iff bit value `2^k` is set in that digit. Padding bits above
`COUNT-1` must be zero.

### 5.2 Offer list

An offer list says which payment methods are acceptable and what each costs:

```
OFFERS = OFFER *("+" OFFER)
OFFER  = "f" "0" / ("g" / "c" / "i") 1*9DIGIT / "n" "0"
```

* `f0` — free (no other offer may appear with it).
* `n0` — not purchasable (no other offer may appear with it).
* Each currency appears at most once.

### 5.3 Overrides

`x<cat> = ENTRY *("." ENTRY)`, `ENTRY = DEST "~" OFFERS`.
An override fully replaces the category default for that destination.
At most 128 entries per category.

### 5.4 Destination ids

* `H` — the server's native home-point index (the index the server uses for
  its home-point unlock record), 0-based.
* `S` — the server's native survival-guide index, 0-based.
* `G` — protocol-fixed: `0` Holla, `1` Dem, `2` Mea, `3` Vahzl, `4` Yhoat,
  `5` Altep.
* `R` — the server's native runic-portal index, 0-based.

The exact native numbering is recorded in the server module and in the
client catalogue mapping; it is not re-derivable from this document alone.

Binding against upstream LandSandBoat (recorded after Phase A, see §11):
`uH` COUNT = 122 (ids 0–121; id 67 has no destination and is never unlocked),
`uS` COUNT = 98 (survival-guide menu ids 0–97; ids without a guide stay 0),
`uG` COUNT = 6, `uR` COUNT = 7 (ids 1–6; id 0 unused). A client must accept
any COUNT ≤ 256 and treat ids beyond COUNT as locked.

## 6. Error / state codes

| Code      | Meaning | Charged? |
|-----------|---------|----------|
| `VERSION` | request version unsupported | never |
| `BADREQ`  | malformed request | never |
| `BADDEST` | unknown category or destination id | never |
| `LOCKED`  | destination not unlocked for this character | never |
| `PAYMENT` | payment method not accepted for this destination | never |
| `PRICE`   | `amount` differs from the server's current price | never |
| `FUNDS`   | insufficient balance | never |
| `STATE`   | character state forbids travel (dead, engaged, in event, mounted-chocobo, etc.) | never |
| `ZONE`    | travel not allowed from the current zone/instance | never |
| `HERE`    | already at that destination's zone and position area | never |
| `BUSY`    | rate limit or cooldown | never |
| `INTERNAL`| server-side failure; travel did not happen and nothing remains charged (not taken, or refund confirmed) | no (net) |
| `UNSURE`  | server-side failure after validation; payment and/or movement could not be established; currency incident logged (RC3) | unknown |

Invariant: **the server deducts currency only after every check has passed,
and moves the character immediately after the deduction in the same server
tick.** After a deduction, `E INTERNAL` is sent only once the refund has been
confirmed by re-reading the balance; otherwise `E UNSURE` is sent and a
currency incident is logged. The server never guesses a refund. Details:
`docs/SERVER-MODULE.md` § Transaction hardening. (RC2 hardening; RC3 added
`UNSURE` and the §4.6 correction rule. The frame and body grammar are unchanged.)

## 7. Transport binding

* Requests are delivered as a server-side chat command entered by the client
  (the leading `!` command prefix of the server's command system).
* Frames are delivered as system-type messages the server prints to that one
  player only. The client accepts frames only from message modes that cannot
  be produced by another player's chat.
* The client suppresses display of its own outgoing request lines and of all
  incoming frames (except in Debug chat mode).

## 8. Reliability rules

### 8.1 Client

| Rule | Value |
|------|-------|
| Outstanding SYNC requests | ≤ 1 (a new one supersedes the old RID) |
| Outstanding GO requests   | ≤ 1 (a second GO while one is pending is refused locally) |
| SYNC timeout / retries    | 5 s; up to 2 retries, each with a **new** RID |
| GO timeout / retries      | 8 s; **never retried**; outcome reported as "unknown", then a SYNC is issued |
| Correction window after `T` | 6 s, or until a zone change starts (§4.6) |
| Assembly slots            | ≤ 4 RIDs in flight; oldest evicted |
| Frames per response       | ≤ 17 (header + 16) |
| Frame line length         | ≤ 150 bytes, else dropped |
| Body length               | ≤ 2048 bytes, else response discarded |
| RID generation            | sequential mod 65535 starting at a random value; skips `0000` |

Handling:

* **Fragmented** — frames are buffered per RID until complete (§4.1).
* **Out of order** — frames are stored by SEQ; order of arrival is irrelevant.
* **Duplicate frame** — identical duplicate ignored; conflicting duplicate
  (same SEQ, different DATA or TOTAL) discards the whole assembly.
* **Delayed / stale** — a completed response whose RID is not the current
  outstanding RID for its operation is discarded silently.
* **Malformed** — any grammar, length, count or checksum violation discards
  the assembly; the request's timeout then drives retry/abort.
* **Wrong character** — a snapshot whose `ch` differs from the logged-in
  character's id is discarded.
* **Version mismatch** — a frame whose `VER` is not `1`, or an `E VERSION`
  response, stops automatic sync and shows a mismatch notice.
* **Atomic application** — the snapshot is parsed and fully validated into a
  new table, which then replaces the current state in a single assignment.
  On any failure the previous state is kept unchanged.

### 8.2 Server

| Rule | Value |
|------|-------|
| Request line                   | ≤ 96 bytes, ≤ 8 tokens |
| Replay cache                   | last 8 (SID, RID) pairs per character, 30 s (keyed by SID + RID since RC4) |
| SYNC rate                      | ≤ 6 per 10 s per character, else `E BUSY` |
| GO cooldown                    | 5 s after an accepted GO, else `E BUSY` |
| Response body                  | ≤ 2048 bytes |

* A request whose SID and RID are both in the replay cache is **not** executed
  again; the cached frames are re-sent verbatim. This makes client
  retransmission of the same request harmless, including for GO. A new client
  session (different SID) is never answered from another session's entry (§3.3).
* A request that cannot be parsed far enough to yield a valid RID is answered
  with RID `0000`, `E BADREQ`.
* Version mismatch is answered with `E VERSION` and `sv=1`, framed as version 1.

## 9. Examples (illustrative values)

Request: `!fpx 1 018f2c4a9e01 3a07 SYNC`

```
#fpx1 3a07 0/2 S,231,5c1e4a2b
#fpx1 3a07 1/2 v=1;ch=21828;z=243;g=152000;cp=3100;is=4200;uH=104:ffff...
#fpx1 3a07 2/2 ...;pH=g1000+c100;pS=g1000+c100;pG=g1000+c100;pR=g1000+i100;xH=0~f0.1~f0;ok=1
```

Request: `!fpx 1 018f2c4a9e01 3a08 GO R 2 i 100`

```
#fpx1 3a08 0/1 T,40,0e2f0b11
#fpx1 3a08 1/1 v=1;c=R;d=2;pay=i100;g=152000;cp=3100;is=4100
```

Insufficient funds:

```
#fpx1 3a09 0/1 E,30,...
#fpx1 3a09 1/1 v=1;e=FUNDS;need=g1000+c100;g=12
```

## 11. Transport binding (LandSandBoat, recorded after Phase A)

Read from upstream LandSandBoat `base` (`src/map/command_handler.cpp`,
`src/map/packets/c2s/0x0b5_chat_std.cpp`, `modules/module_utils.lua`):

* Chat beginning with `!` is passed to the command handler; a handled command
  is not broadcast. The client sends `/say !fpx …`.
* `cmdprops.parameters = 's'` (single `s`) passes the whole remaining line as
  one string; the module tokenises it itself. `permission = 0`.
* Frames are sent with `player:printToPlayer(frame, 29)` (channel
  `SYSTEM_3`, no explicit speaker).
* **Speaker field (RC5, corrected after the first in-game test):** LSB's
  `GP_SERV_COMMAND_CHAT_STD` puts the **receiving character's own name** into
  the 15-byte `sName` field when no sender is given
  (`src/map/packets/s2c/0x017_chat_std.cpp`: `sender.empty() ? PChar->getName() : sender`).
  RC1–RC4 assumed an empty speaker and so rejected every live frame.
* The client trusts a `#fpx` chat line as a server frame only when **all** hold:
  packet `0x017`; `Kind` (byte `0x04`) is 29 (`SYSTEM_3`); `sName` is empty or
  exactly (case-sensitive) the logged-in character's name. If that name is not
  known, own-name frames are not trusted. The usual framing, RID and Adler-32
  checks then apply. Other players' chat always carries their own name and a
  chat `Kind` (say, shout, tell, party, linkshell, …), never 29 from the
  player's own name.
* Trusted frames are blocked from the chat log, including stale or malformed
  ones on the trusted channel. Anything else is left untouched and stays visible.
* Packet layout used by the client: `0x04` Kind, `0x05` Attr, `0x06` Data
  (u16), `0x08` sName[15], `0x17` Mes (≤ 150 bytes; it may fill the packet
  without a terminating NUL, so the client reads up to 150 bytes and stops at
  the first NUL).

## 10. Differences from any earlier design

None of the message names, sigils, framing, checksum, id scheme or error codes
above were taken from an earlier FFXIPort or Driftwood/dwport protocol; the
author had no access to them in this workspace. Old-format messages are not
recognised and no fallback exists.
