# Changelog

Driver versions are a single integer in `<version>` (and `DRIVER_VERSION` in
`driver.lua`, which the tests check for drift). Composer Pro only offers an
update when the version is **higher** than the installed one.

Note that changes to properties or `<capabilities>` are static device
metadata; those updates generally need a Director restart, while Lua-only
changes hot-reload.

---

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
