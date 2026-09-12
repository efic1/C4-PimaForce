# Changelog

Driver versions are a single integer in `<version>` (and `DRIVER_VERSION` in
`driver.lua`, which the tests check for drift). Composer Pro only offers an
update when the version is **higher** than the installed one.

Note that changes to properties or `<capabilities>` are static device
metadata; those updates generally need a Director restart, while Lua-only
changes hot-reload.

---

## v40 — the BOOL variables never worked

- **Fixed: `PANEL_CONNECTED`, `EVENTS_ENABLED` and `PARTITION_n_ARMED` have
  been failing every write since v30.** Director's variable API takes strings
  only — it rejects a Lua boolean with *"strValue should be a string"* — and
  all three were being set with real booleans. The `pcall` around the write
  kept the driver up, and until v32 made variable failures loud there was
  nothing in the log to say so either. For nine versions those three
  variables held nothing, so any notification text or programming condition
  referencing them read empty. The STRING variables (`PARTITION_n_STATE`,
  `ALERT_*`, `LAST_TROUBLE_*`) were never affected. Programming built against
  the BOOL variables will start working with no change on your side.
- **Fixed the cause, not just the call sites.** Every value now passes
  through one coercion (`VariableValueString`), booleans rendering as
  `true` / `false`.
- **The test mock now rejects a non-string exactly as Director does.** This
  is what let the bug live: three tests asserted `Variables['X'] == false`
  and passed, because the mock stored whatever it was handed. A mock more
  permissive than the runtime is worse than no test — it certifies the
  broken behaviour. Those assertions are corrected and the boundary is now
  enforced for every call site, present and future.

## v39 — init is synchronous again, and measured

v36 moved driver init onto a timer to fix a ~50 second Composer freeze.
v38 then had to patch two races that created. That is the wrong trade for a
security driver: it swaps a guaranteed annoyance for a rare wrong answer
about whether a house is armed.

- **Init is synchronous again.** When `OnDriverLateInit` returns, the driver
  is fully loaded — no window in which a panel frame can interleave with a
  half-built driver, and no timer whose loss leaves it stranded. The v36
  staging, the v38 rescue path and the v38 seed race all go away with it,
  because none of them can happen any more.
- **The freeze is treated as a volume problem instead.** On a 40-zone,
  one-partition install the load callback made **55** blocking Director calls
  at v35; it now makes **36**, and no per-zone call touches it at all:
  - **No zone batch runs inline.** v13 left the first batch synchronous as a
    compromise. Zone publishing was always the one deferral with no
    correctness question attached — a zone *inventory* arriving 50 ms later
    cannot mis-state whether the house is armed, which is exactly the
    distinction v38 had to learn the hard way.
  - **Partition variables are declared only for partitions that exist.** A
    one-partition house was paying four extra `AddVariable` round trips per
    load to create variables for partitions it does not have — and Composer
    offered them in the programming picker as though it did.
- **Every load now reports where its time went**, at Info:
  `init timing: variables 000ms, visibility 000ms, proxies 000ms, zones 000ms,
  TOTAL 000ms`. The "0.4s per Director round trip" this project has been
  optimising against came from a single v13 observation and has been
  extrapolated across five versions without recheck. The next cut should be
  aimed at whichever phase that line actually implicates — the largest
  remaining block is 12 `SetPropertyAttribs`, and whether that is 5 seconds
  or 50 milliseconds is currently unknown.
- The load-callback test is now a **budget** (40 calls) rather than a
  deferral check. Cut calls; do not move them.

## v38 — hardening the deferred init

Two risks the v36 deferral introduced, found by going looking for them
rather than by hitting them in the field.

- **Fixed: init could overwrite live partition state with `OFFLINE`.** The
  `PARTITION_STATE_INIT` seed is `OFFLINE` because at load time the driver
  genuinely does not know the state. Once that seed moved onto a timer, a
  panel reconnecting inside the window could report *Armed Away* first — and
  the seed would then paint an armed house as offline until the next sync.
  The seed is now skipped in favour of the real state when the panel has
  already verified.
- **Added a rescue path if the init timer is ever lost.** A dropped timer
  left the driver permanently half-loaded — no variables, partition proxies
  never enabled — with a connected panel and nothing in the log pointing at
  the cause. A verifying panel now completes init inline and says so at
  Warning level. It costs nothing on the normal path and only runs when
  something has already gone wrong.

## v37

- **The mute indication moved to the app's partition status line** — the line
  on the Status tab below the lock indicator. While events are muted it reads
  `Notifications OFF`.
- **Removed the standing "Event notifications disabled" trouble** that v31
  used for this. It asserted a fault on a panel that has none, and since v35
  gave troubles stable identifiers it also took a slot in a list meant for
  real conditions. The *clear* is still sent on every enable, so a driver
  upgraded from v31–v36 while muted does not leave a phantom trouble behind.
- **Bypassed zones are named on the same line** — `Bypassed: Patio Door`, or
  `Bypassed: 5 zones` past three. A bypass is a disabled detector; Control4
  shows it per zone on the Zones tab, where noticing it means going to look.
  A bypassed **Quiet** zone is named too: that setting silences open/close
  chatter, and was never meant to hide a bypass.
- **Partition Display Text** is no longer an experiment. It is the fixed
  prefix of the line, so an installer label and the driver's status coexist:
  `Ground Floor | Bypassed: Patio Door`.
- Settled the v24 question: `DISPLAY_TEXT` does **not** fill the Zones-tab
  `UNKNOWN` header. It renders on the Status tab. Nothing further on the
  driver side will change that header.

## v36

- **Fixed: Composer Pro froze for ~50 seconds on every driver update.** v13
  batched the per-zone publishing off the driver-load callback for exactly
  this reason, but everything added since went straight back onto it — 12
  `AddVariable` calls (v30–v35), 12 `SetPropertyAttribs` (v15), the partition
  notifications and the first zone batch. Each one is a blocking Director
  round trip, and on a 40-zone install that measured **55 of them before
  `OnDriverLateInit` returned**, which is the thread Composer waits on.
  None of that work has to finish before the callback returns, so it now runs
  on a short timer instead: **2 blocking calls at load, down from 55.**
- The deferred work is split into three stages, one per timer tick, so it does
  not simply move a multi-second block onto Director's own thread. A stage
  that throws is logged and the remaining stages still run — a driver whose
  partition proxies were never enabled is unusable, and that must not depend
  on a cosmetic stage succeeding first. If no timer can be created the work
  still runs inline, because a driver that skipped its init would be worse
  than a slow one.
- A regression test now **counts** the blocking calls made by the load
  callback and fails if the number creeps back up. Counting is the only guard
  that holds; the previous fix was correct and still regressed, because
  nothing stopped the next feature from adding one more call to that path.

## v35

- **Fixed: two `Force::TROUBLE_TYPE` variables in Composer.** The security
  panel proxy already declares its own `TROUBLE_TYPE`; v32 added driver
  variables with the same names on top of it, so Composer showed two entries
  with no way to tell them apart — and the one referenced in notification
  text was the proxy's, which this driver does not populate. The driver's
  pair is renamed **`LAST_TROUBLE_TYPE`** / **`LAST_TROUBLE_TEXT`**, which
  cannot collide. A test now asserts no driver variable takes a
  proxy-declared name.
- **Fixed: every trouble was sent with `IDENTIFIER = 0`.** That is how the
  proxy tells standing troubles apart, so they overwrote each other: with
  mains power and low battery both active, clearing either cleared the single
  id-0 trouble and the other silently vanished from the app while still being
  a real condition. Each trouble now has its own stable identifier.
- `TROUBLE_CLEAR` now carries `IDENTIFIER` alone, matching the shipped
  reference driver's parameters exactly.

## v33 / v34 — event correctness review

Prompted by alarm and trouble events firing with no fault behind them.

- **Fixed: a reconnect replayed the panel's event buffer as live events.**
  PIMA's spec has the panel buffer events and report them once a connection
  is up, and resend anything un-ACKed. The guard against that was a single
  remembered key, *cleared on every connect* — so a reconnect re-fired
  alarms and troubles for things that had already happened, and any
  notification wired to them fired again. Replaced with a bounded,
  time-windowed set that deliberately survives reconnects.
- **Fixed: a retransmit arriving after any other event was dispatched
  again.** Single-slot dedupe only caught back-to-back repeats.
- **Fixed: routine panel housekeeping fired `Unmapped Panel Event`.** The
  periodic test (CID 602), power-up, programming change, manual test,
  time/date change and remote upload are normal operation; they are now
  named in the log and raise nothing. Genuinely unrecognised events still
  fire `Unmapped Panel Event`, and now also log at Warning.
- Removed a dead `panelWide` variable in the burglary path that could only
  ever be false, and a stale comment on `PartitionTargets` that described
  partition 0 fanning out to every partition — behaviour deliberately removed
  as a safety fix, and the comment was inviting someone to restore it.

## v32

- **Fixed: trouble restores also fired `Any Trouble`**, so every mains
  flicker or comms blip produced two notifications instead of one. Alarms
  were already scoped to the new condition only; troubles now match.
- **Added `TROUBLE_TYPE` and `TROUBLE_TEXT` variables.** Notification text
  referencing them resolved empty because they had never existed. They are
  set alongside `ALERT_*` on every trouble, and unlike `ALERT_*` they survive
  a later alarm, so "the last trouble" and "the last thing that happened" are
  separately available.
- **Fixed: variable failures were silent.** `AddVariable` and `SetVariable`
  were wrapped in `pcall` logging only at Debug, so if variable creation
  failed the only symptom was notification text resolving empty with nothing
  in the log to explain it. Both now report at Error level and say that
  notification text will be empty as a result.
- Added a **Report Variables** action that reads every variable back from
  Director and logs it, so an empty notification is answerable from one log
  line rather than by guesswork.
- Alerts are never published with empty text: a blank value falls back to the
  alert type.

## v31

- Added **Disable Event Notifications** / **Enable Event Notifications** to
  the app's Functions menu, for muting a panel that has started
  machine-gunning events.
- Muting gates `C4:FireEvent` only, through a single `FireDriverEvent`
  choke point. **Live state is never muted** — the shield still shows ALARM,
  zones still update. Silencing the notification about an alarm is
  reasonable; silencing its display is not.
- While muted the driver raises a standing panel **trouble**, so the mute is
  visible in the app rather than silent, and it publishes an
  `EVENTS_ENABLED` variable for programming.
- The mute **auto-re-enables** after **Event Mute Minutes** (default 60), and
  a driver reload always comes back un-muted. A forgotten mute on a security
  system is its own hazard.

## v30

- **Two programming scripts instead of forty-four.** Added consolidated
  **`Any Alarm`** and **`Any Trouble`** events that fire alongside the
  specific ones, so a complete push-notification setup is two scripts rather
  than one per condition.
- Added **`Panel Connection Lost`** / **`Panel Connection Restored`** events.
  The link watchdog already detected this; there was simply nothing to
  program against, despite an unreachable panel meaning the system is not
  being monitored.
- Added driver **variables** — `ALERT_TYPE`, `ALERT_TEXT`, `PANEL_CONNECTED`,
  and `PARTITION_N_STATE` / `PARTITION_N_ARMED` — so programming can test
  partition state directly instead of maintaining a Variables-agent boolean
  by hand, and so notification text can name what happened if the agent
  supports interpolation. Added at runtime, so they need no static metadata.
- **Fixed:** `PanelWasConnected` used the self-preserving `X = X or false`
  idiom, which would have kept `true` across a driver reload and suppressed
  the first `Panel Connection Restored`.
- Tests: one asserting every function the driver calls by name exists (a
  helper that failed to insert passes `luac -p` and only breaks at runtime),
  and one asserting every fired event is declared in `driver.xml`.

## v29

- Corrected the **Non-Bypassable Zones** description, which claimed the
  property put a bypass control on a zone in the app. It does not — Control4
  has no such control (see v28). Behaviour unchanged.

## v28

- Added **Bypass Open Zones** and **Clear All Bypasses** to the app's
  Functions menu, after confirming from Control4's user guide that the Zones
  screen has **no per-zone bypass control** — tapping a zone was never going
  to bypass it. Both are scoped to the partition whose menu was opened,
  respect Non-Bypassable Zones, and go through bypass verification.

## v27 — validated against PIMA's specification

- **Fixed: CID 400 (arm/disarm by master code) was unhandled.** Only 401
  (user and remote codes) was. Arming or disarming with the master code
  reported nothing, so the app kept showing the previous state until a later
  sync corrected it.
- **Fixed:** system key `1` means *Partition Not Exist*, not an unknown arm
  code. It was logging an error on every sync for a partition that simply is
  not configured on the panel.
- **Fixed:** faults now decode to readable text via the spec's 98-entry fault
  table, instead of being reported as raw hex.
- **Changed:** Arm All / Disarm All send one operation to `partition: 0`, the
  panel's documented all-partitions target, instead of one frame per
  partition — falling back to per-partition when a partition is restricted
  from arming Away.

## v26

- **Fixed: a bypass ACK is not proof the bypass was applied.** A zone
  cancelled in technician programming is acknowledged and then not bypassed.
  Every bypass write is now read back and the app is told what the panel
  reports, not what was requested. Unapplied bypasses are reported as
  failures; a failed *clear* re-arms the safety auto-clear.

## v25

- Added the app's **Functions** menu (`<functions>` capability): Check
  Status, Arm All, Disarm All, Refresh Troubles. Every entry is backed by a
  real panel command.
- Added **Non-Bypassable Zones**, enforced driver-side wherever a bypass
  originates. Clearing a bypass is never blocked.
- Emergency (fire / medical / police / panic) deliberately left disabled:
  PIMA's protocol has no command to raise one.

## v24

- Added **Partition Display Text**, an experiment against the Zones-tab
  `UNKNOWN` header using the `DISPLAY_TEXT` notify.
- Documented the confirmed finding that `ZONE_STATE` drives both the app's
  History rows and the live zone list, so the two cannot be separated.

## v23

- **Quiet Zones** now accepts zone **numbers** as well as type words, since
  the app draws `motion` and `interior` identically and a type word could
  match nothing silently. The log now names the zones it silenced, or warns
  that the setting matched none.
- A quiet zone publishes as closed and is never seeded with a live status.

## v22

- **Fixed:** zones could resolve to *no* partition — published with an empty
  `<partitions>` field and no `HAS_ZONE` — whenever two or more partitions
  were configured and a zone's config omitted its partition. They now fall
  back to the lowest configured partition, and the fallback is reported.
- Added **Quiet Zones** and **Zone State Reporting** to control what reaches
  the app's History.

## v21 — validated against a second implementation

- **Fixed: zone status (parameter 2149) was decoded with the wrong model.**
  It is a *sparse* list where the zone number is packed into the low byte and
  a 16-bit status field sits above it — not one value per requested zone. The
  earlier "truncated response" diagnosis was wrong.
- **Fixed:** arm operations send `order: 1` (was `0`), matching validated
  panel traffic. Disarm keeps `order: 0`.
- **Changed:** Link Timeout default 90s → 600s. The panel's real heartbeat
  cadence is about four minutes, so 90s risked false disconnects on a healthy
  panel.

## v20 and earlier

Earlier versions predate this changelog. The significant work, documented in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md):

- **v19** — system key `2` confirmed as Disarmed against a real panel.
- **v18** — removed an unjustified "unknown system key means disarmed"
  default, which could show an armed house as disarmed.
- **v16** — log levels; `SET_ZONE_INFO` handling; a link watchdog for
  half-open sockets that left the driver reporting Connected forever.
- **v15** — diagnostic properties hidden from the config grid; partition
  state seeded and then restated live.
- **v14** — property-write deduplication, after the properties panel became
  unusable during zone-event bursts.
- **v13** — zone inventory published across timer ticks instead of in one
  blocking burst, fixing a ~40 second Composer freeze on every driver update.
- **v12** — the partition document is republished when a partition's state
  changes, fixing a header stuck on `Unknown`.
- **v1–v11** — initial implementation: TCP listener, JSON protocol engine,
  security proxies, arming, zones, bypass, Hebrew name decoding.
