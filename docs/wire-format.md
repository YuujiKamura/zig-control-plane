# CP Wire Format — Pact

**Status:** authoritative for the Control-Plane (CP) named-pipe protocol
spoken between `ghostty-win` (Zig server, this repo + the WinUI3 apprt
wrapper) and `deckpilot` (Go client at `pipe/`).

**Pact discipline:** any change to the wire format MUST land here first.
Both sides MUST update fixture-replay tests in lockstep:

- Server side: `vendor/zig-control-plane/src/wire_format_test.zig`
  (this submodule).
- Client side: `deckpilot/pipe/wire_format_fixture_test.go` (vendored
  copy of `wire-format-fixtures.txt`).

A field rename or new variant on TAIL/HISTORY without updating the
fixture file is a CI failure.

This is the **first increment** — only `TAIL` is pinned with fixtures
this round. Other verbs are listed by name as TBD; see the Lane C audit
brief at `~/.agents/scratch/cp-wire-format-audit-2026-05-05.md` for the
full request/response table the future increments will lift from.

---

## 1. Envelope conventions

- **Transport:** Windows named pipe at
  `\\.\pipe\ghostty-<session>-<pid>`. Message-mode pipe; one request
  produces one response, both `\n`-terminated.
- **Termination:** every line ends with a single `\n` byte. The vendor
  server never emits `\r\n`; the deckpilot client tolerates both via
  `TrimRight(..., "\r\n")` (`pipe/client.go:83`).
- **Field separator:** `|`. Field contents on the server side are run
  through `protocol.escapeField` (`src/protocol.zig:234-245`), which
  replaces `|`, `\n`, `\r` with a single space. Note: `<session>` itself
  is currently NOT escaped — see drift hotspot below.
- **Encoding:** ASCII for headers; INPUT / RAW_INPUT / PASTE payloads
  are base64 (StdEncoding, padded). Multi-line response bodies (TAIL,
  HISTORY, CAPTURE_PANE) carry raw UTF-8 buffer bytes after the header
  line.
- **Prefix grammar (success / error / envelope tokens):**

  | Prefix | Meaning | Where |
  |--------|---------|-------|
  | `OK\|` | success, generic verbs | CAPABILITIES, CAPTURE_PANE, NEW_TAB, BGTRACE_STATE, daemon-IPC SHOW/LIST/VERSION/HOOK |
  | `ACK\|` | success, mutating verb acknowledged | CLOSE_TAB, SWITCH_TAB, FOCUS, MSG |
  | `QUEUED\|` | success, write enqueued, returns cmd_id for ACK_POLL | INPUT, RAW_INPUT, PASTE, SEND_KEYS |
  | `ERR\|` | error response | any verb |
  | `BUSY\|` | apprt-injected backpressure (sub-prefix of `ERR\|`) | apprt overlay only |
  | `RATE_LIMITED\|` | reserved (per-client token bucket); not currently emitted on CP wire |
  | `PONG\|` | success of PING | PING |
  | `TAIL\|` | success header line of TAIL multi-line response | TAIL |
  | `HISTORY\|` | success header line of HISTORY multi-line response | HISTORY |
  | `STATE\|` | success of STATE | STATE |
  | `LIST_TABS\|` | success header of LIST_TABS multi-line | LIST_TABS |
  | `TAB\|` | per-tab line within LIST_TABS response | LIST_TABS |
  | `SUBSCRIBE_OK\|` | success of SUBSCRIBE | SUBSCRIBE |
  | `UNSUBSCRIBE_OK` | success of UNSUBSCRIBE (no separator) | UNSUBSCRIBE |
  | `stale:` | wire envelope wrapping a TAIL/HISTORY response served from snapshot cache while renderer is locked | apprt overlay only on TAIL / HISTORY |

  All wire prefixes here are at offset 0 of the response. The `stale:`
  envelope is a byte-prefix on the entire response (header line +
  buffer bytes), not on individual fields.

---

## 2. Drift hotspots — load-bearing notes

These three discrepancies were identified by the Lane C audit
(2026-05-05). Document them so they don't re-bite.

### 2a. `stale:` prefix is overloaded across two unrelated layers

There are two completely different things wearing the same textual
prefix:

1. **Server CP wire envelope (this doc, this protocol).** The apprt
   wrapper at `src/apprt/winui3/control_plane.zig:564-569` prepends
   `stale:<age_ms>|` to a cached TAIL or HISTORY response when the
   renderer is locked and a snapshot is available. Gated by
   `isStalePrefixSafeCommand` (currently TAIL + HISTORY only). The
   inner response keeps its full normal shape, including its own
   `TAIL|<session>|<linecount>\n` header line.
2. **Daemon SHOW status field (a different protocol, daemon IPC, not
   covered by this doc).** Lives in `daemon/ipc.go:292-302`
   `composeShowStatus`. Prepends `stale:` to the *status enum value*
   inside the response when fresh read failed. The daemon IPC SHOW
   reply is `OK|<base64content>|<status>\n` so `stale:` here is purely
   a status-field tag, not a wire envelope.

These are independent. A change to either one MUST NOT silently apply
to the other. The CP-server stale envelope is the only `stale:` this
doc governs.

### 2b. Apprt error envelopes drop the `<session>` field

The vendor lib's `protocol.formatError` always emits 3 fields:
`ERR|<session>|<code>\n`. The apprt wrapper at
`src/apprt/winui3/control_plane.zig:478, 487, 504, 515, 520, 574`
emits 2-field shapes: `ERR|BUSY|renderer_locked\n`,
`ERR|BUSY|input_queue_full\n`, `ERR|BUSY|data_lane_full\n`,
`ERR|TIMEOUT|ui_thread_busy\n`, `ERR|internal_error\n`. So an `ERR|`
line on the wire may have either 2 or 3 pipe-separated fields
depending on which layer produced it.

Today both shapes resolve correctly through the deckpilot
`pipe.IsError` + `pipe.ClassifyBusy` keyword path. A naïve
`strings.Split(resp, "|")` indexer would mis-read the 2-field shape.
**Until both layers converge on a single shape, clients MUST classify
errors by keyword scan, not by field index.**

This document records the implementation as it stands. The divergence
is flagged here rather than fixed in this round.

### 2c. `CAPABILITIES` apprt short-circuit drops `WAIT_DRAIN`

The vendor lib's `protocol.formatCapabilities` advertises
`writes=INPUT,RAW_INPUT,PASTE,SEND_KEYS,ACK_POLL,WAIT_DRAIN`
(`src/protocol.zig:255-261`). The apprt wrapper at
`src/apprt/winui3/control_plane.zig:461-465` short-circuits
`CAPABILITIES` with a hardcoded
`writes=INPUT,RAW_INPUT,PASTE,SEND_KEYS,ACK_POLL` (no `WAIT_DRAIN`).
Both implementations actually support WAIT_DRAIN, so the divergence
is purely advertised-vs-supported. A client gating behaviour on the
advertised list silently loses WAIT_DRAIN against the WinUI3 build.

---

## 3. TAIL — pinned this increment

### 3a. Request shape

```
TAIL\n                 — default, lines=20, active tab
TAIL|<lines>\n         — explicit line count, active tab
TAIL|<lines>|<tab>\n   — explicit lines and tab target
TAIL|<tab>\n           — default lines, explicit tab (when first field is not a number)
```

`<tab>` is either an integer index (e.g. `2`) or `id=<tabid>` (e.g.
`id=t_001`).

Source: `src/protocol.zig:107-116` (parser),
`pipe/client.go:240` deckpilot caller emits `TAIL|<lines>\n`.

### 3b. Fresh success response shape

Multi-line. First line is the header; the remainder is raw UTF-8
viewport bytes:

```
TAIL|<session>|<linecount>\n<buffer bytes...>
```

- `<session>` is the session name as set at apprt init.
- `<linecount>` is the count of `\n`-terminated lines plus 1 if the
  trailing byte is not `\n` (`src/main.zig:296-302`).
- `<buffer bytes>` is the last `<lines>` lines of the active tab's
  viewport, exactly as produced by `utils.sliceLastLines`.

Source anchors:
- `src/main.zig:280-304` — `.tail` arm of `handleRequestInner`.
- `src/protocol.zig:281-283` — `formatTail` returns
  `std.fmt.allocPrint("TAIL|{s}|{d}\n{s}", ...)`.

Client behaviour: deckpilot reads until pipe EOF
(`pipe/client.go:86-102`); `pipe.StripTailHeader` discards the first
`\n`-terminated line and returns the rest (`pipe/protocol.go:145-153`).

### 3c. Stale variant response shape

Apprt overlay only. Emitted when:
1. `isStalePrefixSafeCommand` returns true for the verb (TAIL,
   HISTORY).
2. `last_renderer_locked` is set on the apprt control-plane state.
3. The snapshot cache has a published snapshot for the verb.

```
stale:<age_ms>|TAIL|<session>|<linecount>\n<buffer bytes...>
```

The inner `TAIL|<session>|<linecount>\n<buffer bytes>` is byte-for-byte
the same shape as the fresh response — `stale:<age_ms>|` is a strict
byte-prefix.

Source anchors:
- `src/apprt/winui3/cp_snapshot_cache.zig:278-292` — prepend logic.
- `src/apprt/winui3/control_plane.zig:564-569` — gating on
  `last_renderer_locked` + cache hit.
- `src/apprt/winui3/control_plane.zig:1280-1283` — TAIL/HISTORY
  whitelist in `isStalePrefixSafeCommand`.

Client pact: deckpilot's `pipe.IsError` MUST classify a `stale:N|TAIL|...`
response as not-error (no `ERR|` prefix). `pipe.StripTailHeader` MUST
unwrap it (the first `\n` separates the `stale:N|TAIL|<session>|<n>`
header from the buffer body, just like fresh).

### 3d. Error variants

All emitted as `ERR|<session>|<code>\n` (3 fields, vendor lib) unless
otherwise noted. Codes:

- `NO_TABS` — no tabs available (`src/main.zig:283`).
- `SNAPSHOT_FAILED` — provider's `captureSnapshot` returned false
  (`src/main.zig:289`).
- `INTERNAL_ERROR` — caught at the `handleRequest` outer layer.

Apprt-overlay error envelopes (2 fields, no session — see drift 2b):

- `ERR|BUSY|renderer_locked\n`
- `ERR|BUSY|input_queue_full\n`
- `ERR|BUSY|data_lane_full\n`
- `ERR|TIMEOUT|ui_thread_busy\n`
- `ERR|internal_error\n`

---

## 4. Other verbs — TBD this round

Not pinned with fixtures in this increment. See Lane C audit brief
section 1a for the full request/response table. To be picked up in
follow-up increments:

- PING — TBD; not pinned in this increment, see Lane C brief.
- CAPABILITIES — TBD; pin with fixture covering the apprt vs vendor
  divergence (drift 2c).
- STATE — TBD; not pinned in this increment, see Lane C brief.
- HISTORY — TBD; same shape family as TAIL, will reuse the TAIL
  fixture machinery.
- INPUT / RAW_INPUT / PASTE / SEND_KEYS — TBD.
- ACK_POLL / WAIT_DRAIN — TBD.
- SUBSCRIBE / UNSUBSCRIBE — TBD; note the `SUBSCRIBE_OK|status`
  literal-vs-requested-topic discrepancy (audit drift 2d).
- NEW_TAB / CLOSE_TAB / SWITCH_TAB / FOCUS — TBD.
- LIST_TABS / CAPTURE_PANE / WAIT_FOR / PANE_PID / CURSOR_POS /
  PANE_TITLE — TBD.
- BGTRACE_STATE — TBD; ad-hoc D3D11 diagnostic.
- MSG — TBD; vestigial, returns PING-shaped ACK (audit drift 2e).
- AGENT_STATUS / SET_AGENT — deprecated, return
  `ERR|<session>|deprecated\n`.
- PERSIST — does NOT exist; if a future caller assumes it, that's a
  spec-vs-impl drift to surface here first.

---

## 5. Fixture file format

Companion file: `docs/wire-format-fixtures.txt`. Plain text, one
fixture per block separated by lines containing only `===`. Each
block:

```
# verb: TAIL — variant: fresh
>>> TAIL\n
<<< TAIL|test-session|1\nuser@host:~$ \n
```

- `>>>` line: literal request bytes. `\n` is shown as the two-byte
  escape sequence for readability; the parser converts it back to a
  single newline byte before dispatch.
- `<<<` line: literal response bytes, same `\n` convention.
- Lines starting with `#` are human-readable notes; the parser
  ignores them.
- Blank lines within a block are tolerated.

The Zig server-side test (`src/wire_format_test.zig`) loads this file
via `@embedFile`, parses it with a tiny state machine, and for each
block feeds the request line into `ControlPlane.handleRequest` (with a
mock provider) and asserts that the produced response matches the
expected response bytes exactly. For the stale/BUSY variants — which
require the apprt overlay rather than the vendor lib alone — the test
synthesises the response directly via `formatTail` + the documented
`stale:` envelope rules and asserts the format helpers produce the
expected bytes.

The Go client-side test
(`deckpilot/pipe/wire_format_fixture_test.go`) loads a vendored copy
of the same fixtures file and feeds each `<<<` response into
`pipe.IsError`, `pipe.StripTailHeader`, and `pipe.ClassifyBusy` to
assert the documented client classification holds.
