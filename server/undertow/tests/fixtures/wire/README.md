# Golden wire fixtures

Raw frame transcripts captured from the **Gleam Floodgate** reference server by
`tools/Undertow.WireDiff` (`record` mode). These are the byte-level contract the
.NET Undertow implementation is held to. See `SOURCE.txt` for the exact source
commit and capture time. Captured from floodgate at Levee commit `2687b5f`
(> `22cf469`, so the second gap-closure landing — Engine.IO ping timeout,
op-history cap, idle eviction, `42["close"]`, signal targeting, per-document
sequencing — is baked in).

Transcript line prefixes: `>` sent to server, `<` received, `#` annotation.
Multi-socket scenarios label the socket (`>A` / `<B` / `<P`).

## Files

| File | Scenario |
|---|---|
| `rest-basics.txt` | `/health` (GET+HEAD), token-mint, create document, session, deltas, missing auth |
| `socketio-write-connect-op.txt` | Engine.IO open, `40` connect, write-mode `connect_document` (IConnected), `submitOp` → sequenced op |
| `socketio-read-nack.txt` | read-mode connect, `submitOp` → 403 nack |
| `socketio-auth-failures.txt` | expired token, bad signature → `connect_document_error` |
| `socketio-unicode.txt` | non-ASCII + `<&>` in `user.name` — raw UTF-8 on the wire, no `\uXXXX` escapes |
| `signals-broadcast-targeted-leave.txt` | 2 Socket.IO clients + 1 Phoenix client; legacy `{content}` broadcast signal (reaches **everyone incl. the sender**); v2 `contentBatches` signal targeting one client (reaches only that client, content keys re-sorted); disconnect → sequenced leave op |
| `phoenix-write-connect-op.txt` | two-phase join (`phx_reply` ok/empty), `connect_document` push, `submitOp` → op push, heartbeat on topic `phoenix`, `phx_leave`, `phx_close` |
| `phoenix-bad-vsn.txt` | `vsn=1.0.0` rejected before upgrade |

## Baseline conformance counts (Gleam Floodgate at `2687b5f`)

Recorded 2026-08-07 via `just test-floodgate-dual-mode`:

- Routerlicious suite: **38 passed**, 3 skipped, 1 todo
- Phoenix + cross-mode suite: **7 passed**

These are the counts Undertow must reproduce (Phases 5 and 7).

## Notable captured semantics

- `maxPayload` in the Engine.IO open, `maxMessageSize` in IConnected, and
  `serviceConfiguration.maxMessageSize` are all 16777216 — the single
  `FLOODGATE_MAX_FRAME_BYTES` value.
- The Fluid clientId **is** the Engine.IO `sid` (and the beryl socket id).
- IConnected claims omit `jti` and the user's `name` (signet's decoder keeps
  name in user properties, and the claims encoder emits only `id`).
- Join/leave ops have `clientId: null`, csn/rsn `-1`, `data` as a JSON *string*.
- Timestamps are `now_seconds() * 1000` — always ≡ 0 (mod 1000).
- v2 signal content objects come back key-sorted (`normalize_client_json`);
  legacy string signal content is passed through verbatim.
- A legacy broadcast signal is delivered to the sender too (plain `broadcast`,
  not `broadcast_from`).
