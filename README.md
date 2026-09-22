# dsh-auto-shutdown

DeepSeek Harness plugin: **shut the DSH instance down once the web UI stays
disconnected past a short grace period.**

## How it works

Every browser page keeps one WebSocket mux open at `/api/remote.mux` and pumps the
`$events` logical stream for the whole page lifetime. The host
`ctx.typertGateway.remoteEventClients` map holds one entry per live `$events` stream;
the entry goes away when that stream ends. This plugin polls the map and, once it has
seen zero entries for `disconnectGraceMs`, requests a graceful instance exit through the
launcher's `ctx.appExit` (the same channel `--help` and SDK stdin-EOF use).

`ctx.appExit` is `createProcessShutdown().shutdown(code)`: it arms a 5s force-exit timer
and disposes the tree, but when dispose **succeeds** that timer is cleared and only
`process.exitCode` is set — the process then exits solely when the event loop drains,
which nothing guarantees. The force-exit happens only if dispose times out or rejects.
This plugin therefore arms its own `unref()`'d `process.exit(0)` fallback (8s) *before*
calling `appExit(0)`; the fallback is deliberately not cleared on dispose, because the
tree disposal triggered by `appExit` disposes this plugin too.

## Install

```
cd D:\deepseek harness\dsh-auto-shutdown
dsh plugin --profile web add .
```

Then restart `dsh web`. The watchdog starts disarmed (no UI connected yet) and arms on
the first UI connection.

## Config (override in your profile's cordis.patch.yml or --patch overlay)

| key | default | meaning |
| --- | --- | --- |
| `enabled` | `true` | master switch |
| `pollMs` | `1000` | UI-presence sampling interval |
| `disconnectGraceMs` | `5000` | zero-UI persistence before exit; covers a tab reload or a brief machine sleep (set `0` to exit on the first poll observing the disconnect) |
| `requireEverConnected` | `true` | arm only after the UI connected at least once (never-connected boots like `--no-open` are never killed); set `false` to also exit when no UI ever connects |

Example patch overlay:

```yaml
- id: auto-shutdown
  config:
    disconnectGraceMs: 30000
```

## Caveats

- A browser **tab reload** briefly drops the WebSocket. The `5000` default covers that
  gap; with `disconnectGraceMs: 0` the instance exits if a poll lands inside it.
- Dead tabs (machine sleep, hard network drop) are detected via the mux heartbeat
  (2s ping, 2 missed pongs), so detection can take a few seconds in that case.
- **An entry tracks one `$events` stream, not one page**, and the map can be emptied
  with every page still open: if the forwarded event source is deregistered or errors
  out, the gateway ends all queued clients at once — and after an error no new `$events`
  stream can be opened at all, so the count stays at zero.
- Multiple tabs: any live tab keeps the instance alive — but only while every live tab
  still owns a live `$events` stream (see the previous point).
