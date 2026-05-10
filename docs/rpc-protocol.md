# LociiGhost RPC Protocol

Wire format between the SwiftUI app and `lociighostd`.

## Transport

- **Unix domain socket** at `~/Library/Application Support/LociiGhost/lociighost.sock`
- Permissions `0600` (owner-only)
- Both sides speak **line-delimited JSON** — exactly one JSON object per line, terminated by `\n`
- No length prefix, no framing other than newlines
- No HTTP, no WebSocket, no TLS — same-machine, same-user IPC only

## Message format

JSON-RPC 2.0 (https://www.jsonrpc.org/specification). Three message shapes:

### 1. Request (client → daemon)

```json
{"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {}}
```

`id` may be any JSON number or string. `params` is optional.

### 2. Response (daemon → client)

Success:
```json
{"jsonrpc": "2.0", "id": 1, "result": {"pong": true, "version": "0.1.0"}}
```

Error:
```json
{"jsonrpc": "2.0", "id": 1, "error": {"code": -32601, "message": "Method not found: foo"}}
```

### 3. Notification (either direction, no `id`)

```json
{"jsonrpc": "2.0", "method": "event.position_update", "params": {"lat": 25.04, "lng": 121.56}}
```

When the client sends a notification (no `id`), the daemon never replies, even on error.
When the daemon sends a notification, it's always an event push — method name starts with `event.`.

## Error codes

Standard JSON-RPC plus domain-specific:

| Code | Meaning |
|---|---|
| -32700 | Parse error (malformed JSON) |
| -32600 | Invalid request (not an object, missing method) |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |
| -32000..-32099 | Domain errors (device not found, tunnel failed, etc.) |

## Methods (Phase 0)

| Method | Params | Returns | Notes |
|---|---|---|---|
| `ping` | none | `{pong, version, time}` | Liveness check |
| `daemon.info` | none | `{version, python, socket}` | Diagnostics |
| `daemon.shutdown` | none | `{ok: true}` | Graceful exit |

Phase 1+ will add `device.*`, `location.*`, `tunnel.*`, `routing.*`, see plan.

## Idle behaviour (load-bearing)

When no client is connected and no simulation is in progress:

- Daemon main loop is blocked in `accept()` — kernel-level wait, **0% CPU**.
- No timers, no heartbeat, no watchdog.
- Client must not poll. State changes arrive as `event.*` notifications.

This is enforced by code-level rule: any feature that would require a fixed-rate
loop must instead be expressed as an event-driven state machine.

## Versioning

- `daemon.info` returns the daemon's semver. The client should refuse to connect
  to a daemon with a different MAJOR version.
- Adding new methods is non-breaking. Adding new fields to result objects is
  non-breaking (clients must ignore unknown fields).
- Renaming or removing methods or fields is breaking — bump MAJOR.
