# Performance and Director impact

A Control4 driver's real cost is not CPU. It is **blocking round trips to
Director**: every `SendToProxy`, `UpdateProperty`, `FireEvent`, `SetVariable`,
`AddVariable` and timer call waits on Director, and Composer Pro and the app
share that capacity. This page records what the driver costs, measured, and
what was done about it.

Reproduce every number with:

```bash
lua5.4 tests/profile_director_calls.lua                 # Info log level
PERF_LOG=Debug lua5.4 tests/profile_director_calls.lua  # Debug
```

The harness counts calls exactly. CPU is this machine's, not a controller's:
use it to compare versions, not as absolute time.

## What it costs (v42)

| Event | Director calls | CPU (this machine) |
| --- | --- | --- |
| Heartbeat (null frame) | 0 (one ACK on the socket) | 0.03 ms |
| Zone open **or** close | 4 (2 zone-state notifies, 1 programming event; +1 socket ACK) | ~0.1 ms |
| Arm / disarm event | ~7 (state notifies, 2 variables, recent activity) | ~0.1 ms |
| Trouble start + restore | ~10 | ~0.2 ms |
| Driver load | 36 blocking calls on a 40-zone install (zone list follows on a timer) | n/a |

- **CPU is a non-issue.** A zone event costs roughly a tenth of a millisecond
  of Lua.
- **Memory is flat.** 20,000 zone events leave the heap where it started:
  the de-duplication set is bounded (128 entries, 5-minute window), the
  receive buffer is drained per frame, and nothing accumulates per event.
- **There is no polling.** The driver is event-driven. Panel traffic is
  handled when it arrives; the only recurring work is a 15-second link
  watchdog (one repeating timer, not one per frame).
- **Logging is free at the default level.** Zone open/close writes no log line
  at Info, structurally. At Debug every frame logs about four lines, which is
  what Debug is for.

## Found and fixed in v48

Measured with the v47 review's profiler (35 zones, 11 motion, one partition).

| Scenario | v47 | v48 |
| --- | --- | --- |
| Full arm/disarm cycle | 85 calls, 14 log lines | **69 calls, 11 lines** |
| Panel arm event when the state is already known | 20 | **14** |
| Panel disarm event | 11 | **6** |
| Disconnect | 24 | **14** |
| Reconnect | 59 | **49** |
| 20 reconnects during an exit delay (refresh 2 s), then idle | 21 live timers | **1** |

**1. The exit-delay refresh timer leaked.** A reconnect or a Partitions Config
edit during an exit delay replaced the partition state without cancelling the
countdown, so its repeating refresh timer (Exit Delay Refresh Seconds above 0)
kept firing about 1,800 times an hour until the driver reloaded. Resetting
partition state now cancels every countdown first.

**2. Recent Activity was rewritten on every Info line.** That was most of the
property writes in an arm/disarm cycle. It is now written once per burst, on a
2-second timer.

**3. An unchanged state was re-sent.** The partition proxy is now told only
when what it would show changes (the exit-delay remaining time counts as a
change, so the refresh still works). A proxy GET_CURRENT_STATE is always
answered. Driver variables are written only when their value changes, and a
repeated "System Key Status" or retry line goes to Debug.

Still open from the review, and cheap enough to leave for now: the first
connection after a load re-publishes the zone list once (75 calls); a rename
re-publishes the whole list rather than one zone; the watchdog wakes every
15 s (no Director work).

## Found and fixed in v42

**1. Hidden diagnostic properties were written on every zone event.**
`Last Event Type/Qualifier/Zone/Partition` and `Last Zone Number/Name/
Partition` are hidden unless Log Level is Debug, yet a zone open/close wrote
2.5 of them on average. That was **more than the useful work**: a zone
open+close pair cost 13 Director calls, 5 of them property writes nobody could
see. On a house with motion sensors that is hundreds of pointless round trips
a day, arriving in bursts, each one a property redraw for anyone with Composer
open. They are now written on zone events only when Debug is on. Rare events
(alarms, arm/disarm, troubles) still write them unconditionally, so "what was
the last alarm" is answerable without turning Debug on first.

| | Zone open+close pair |
| --- | --- |
| v41 | 13 calls (5 of them property writes) |
| v42 | **8 calls** |

**2. Every arm and disarm left a stale timer running.** Each operation armed a
5-second reply timer that was not cancelled when the panel answered, so it
fired later, found nothing waiting, and did nothing: a wasted timer round trip
and callback per operation. The timer is now retired with the operation.

## Left alone, on purpose

**Zone State Reporting defaults to `Partition + Panel`.** Half the proxy calls
on a zone event are `PANEL_ZONE_STATE`, which field testing showed drives
neither the History list nor the zone list. Setting it to `Partition only`
would drop a zone event from 4 calls to 3. It is not the default because the
Security *Panel* proxy might still use that notification somewhere this
installation has not exercised, and an incorrect default costs more than the
call it saves. It is a one-click change if you want it.

**Zone events still fire a programming event each.** That is the feature.
Programming that does not use `Zone Opened` / `Zone Closed` pays for them
anyway; use **Quiet Zones** on detectors that only ever generate noise.

## Not known

**What a Director round trip actually costs on your controller.** The "0.4 s
per call" once used to size the load-time work came from a single observation
and was extrapolated across many versions. Every driver load now logs

```
init timing: variables Nms, visibility Nms, proxies Nms, zones Nms, TOTAL Nms
```

which is the measurement. If TOTAL is small the load-time work is not worth
further effort; if it is large, the per-phase split says where to cut.

## Guardrails

- The load callback has a **call budget** (40) enforced by a regression test,
  so the next feature cannot quietly re-create the Composer freeze.
- A zone event has a **write-count test**: no hidden diagnostic property may
  be written on the zone path when Debug is off.
- Re-run the profile harness after any change that touches an event path and
  compare against the table above.
