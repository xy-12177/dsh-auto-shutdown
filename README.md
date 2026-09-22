# dsh-auto-shutdown

DeepSeek Harness plugin: **shut the DSH instance down as soon as the web UI disconnects.**

## How it works

Every browser page keeps one WebSocket mux open at `/api/remote.mux` and pumps the
`$events` logical stream for the whole page lifetime. The host
`ctx.typertGateway.remoteEventClients` map holds one entry per live `$events` stream and
removes it the moment the socket closes. This plugin polls that map and, when it reaches
zero UI clients, requests a graceful instance exit through the launcher's `ctx.appExit`
(the same channel `--help` and SDK stdin-EOF use; the launcher disposes the tree and
force-exits after 5s at most).

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
    disconnectGraceMs: 2000
```

## Caveats

- A browser **tab reload** briefly drops the WebSocket. The `5000` default covers that
  gap; with `disconnectGraceMs: 0` the instance exits if a poll lands inside it.
- Dead tabs (machine sleep, hard network drop) are detected via the mux heartbeat
  (2s ping, 2 missed pongs), so detection can take a few seconds in that case.
- Multiple tabs: any live tab keeps the instance alive.
