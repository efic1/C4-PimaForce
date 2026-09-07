# Architecture and design notes

How this driver works internally, and why it is built the way it is. Most
sections exist because something failed in the field first — the reasoning
and the original symptom are kept together deliberately, so a future change
does not quietly undo a fix.

For installation and configuration, see the
[README](../README.md). For validation against PIMA's published
specification, see [SPEC-VALIDATION.md](SPEC-VALIDATION.md).

> Setup and configuration live in the [README](../README.md); this document
> assumes the driver is already installed and concentrates on how it behaves.

## Repository layout

- `driver.lua` — all the logic: TCP server, PIMA JSON protocol engine,
  Control4 property/command/event glue. Self-contained, no external
  `require()`s, so there is nothing else to package.
- `gen_driver_xml.py` — generates `driver.xml`. **Edit this, never the XML.**
  Repetitive per-partition properties and events are templated to avoid
  hand-typing errors.
- `driver.xml` — generated device metadata: properties, commands, actions,
  programming events, proxies and capabilities. Committed so the tests and
  the packaged `.c4z` have it, and checked for staleness in CI.
- `tests/test_regressions.lua` — 245 regression tests, one per defect found
  in review or in the field, each named for the failure it locks down. Run
  this before shipping any change; it is the file that will tell you if a
  "small fix" has reintroduced a fail-open disarm or a stuck alarm.
- `tests/test_driver.lua` — happy-path harness against a mocked Control4 `C4`
  table.
- `build.sh` — regenerates the XML, checks syntax, runs the tests and
  packages `PimaForce.c4z` (a zip of `driver.xml` + `driver.lua`).

## Hebrew (Windows-1255) zone names

PIMA FORCE panels sold in Israel store zone/user names in the Windows-1255
codepage, not UTF-8 -- the panel sends those raw single-byte codepage bytes
straight into the JSON string. Left alone, that shows up as garbled text (or
`?` characters) in Composer Pro. The driver now decodes it automatically:

- **Zone/User Name Encoding** property (default `Windows-1255`, matching
  what Israeli FORCE panels actually use): the driver transcodes every name
  returned by **Discover Zone Names** from Windows-1255 to proper UTF-8
  before writing it into the **Discovered Zones** property, so what you copy
  into **Zones Config** is correct Hebrew text, not mojibake. Switch this to
  `UTF-8` for English-only/non-Hebrew panels (no transcoding needed, pure
  passthrough).
- **Reverse Zone/User Names** property (default `Off`): some panels store
  names in "visual order" (the order characters are drawn on the LCD, left
  to right) rather than logical reading order, which comes out
  letter-reversed for Hebrew once decoded. If discovered names come back
  backwards, turn this On. (The homebridge-pima-force project carries the
  same flag, documented there as panel-dependent and not universally
  needed -- same caveat applies here.)

The Windows-1255 byte-to-Unicode mapping (`WIN1255_HIGH` in `driver.lua`) was
generated from Python's built-in `cp1255` codec, which mirrors Microsoft's
published codepage spec, and is exercised end-to-end in `tests/test_driver.lua`
against an actual Hebrew zone name ("דלת כניסה" / front door) -- both the
plain transcode and the visual-order-reversed variant.

Only zone names discovered through the **Discover Zone Names** action go
through this decoding step. Anything you type directly into **Zones Config**
in Composer Pro is already whatever text you typed (Composer's property
fields are UTF-8), so no decoding is applied there.

## What is verified, and what is not

Originally this driver was written against
[homebridge-pima-force](https://github.com/electricmonk/homebridge-pima-force)
and a shipped Control4 security driver, so large parts of the protocol were
inference. **That is no longer the case**: it has since been checked against
PIMA's own specification and against a second, physically-validated
implementation.

[SPEC-VALIDATION.md](SPEC-VALIDATION.md) is the authoritative record. In
summary:

**Confirmed by PIMA's specification** — the zone-status bit layout and its
sparse encoding, system key values (including `2` = Disarmed), the bypass
read and write shapes, output numbering (1-2 sirens, 34-41 controlled
outputs), the 250-byte frame limit, `kc:1` keeping the connection open, and
that the `zone` field carries a *user* number on arm/disarm events.

**Corrected by the specification** (all fixed in v27) — CID 400 was unhandled,
system key `1` means "partition does not exist", faults needed decoding
through the Appendix E table, and "all partitions" is `partition: 0` rather
than a loop.

**Still uncertain:**

- **The `order` field on arm.** The spec contradicts itself: Appendix B says
  `0`, its own worked examples say `1`. The driver sends `1`, matching both
  the examples and validated traffic. If arming ever NAKs on some firmware,
  `0` is the first thing to try.
- **Bits 16-23 of zone status.** The spec allows four bytes but documents only
  bits 0-15.
- **Panel heartbeat cadence.** Not stated in the spec; taken as roughly four
  minutes from a validated implementation, which is what **Link Timeout
  Seconds** defaults around.

This driver's framing is better than the original reference in one respect:
that implementation splits on a `}{` boundary regex and does not buffer across
TCP segments (its own comment admits a split frame is lost). This one does
brace-depth scanning with string awareness and reassembles across segments.

## Field status

**Running on a live installation.** This driver was developed against, and is
in daily use on, a real PIMA FORCE panel with JSON interface 2.3, and has been
validated line by line against PIMA's own *Force Interface JSON Format
Specification v2.4* — see [SPEC-VALIDATION.md](SPEC-VALIDATION.md).

Its history is worth knowing, because it shapes how the code is written. The
driver went through several rounds of adversarial review before it ever ran
against hardware, each finding real defects; then the field found a further
set that offline review could not have. The ones that mattered most were not
crashes but *quiet wrong answers*:

- an unrecognised system-key value defaulting to "Disarmed", which could show
  an armed house as disarmed (fixed in v18/v19, confirmed by the spec in v27);
- arming or disarming with the master code being missed entirely, leaving the
  app showing the previous state (CID 400, fixed in v27);
- a bypass the panel acknowledged and then did not apply, reported as success
  (fixed in v26);
- zone status decoded with the wrong model, so live state was wrong until each
  zone next changed (fixed in v21).

That is the class of bug this codebase is defensive about, and why so much of
it refuses to guess: an unknown value is reported as unknown rather than
assumed, and anything the panel merely acknowledged is verified before it is
believed.

245 offline regression tests cover these, one per defect, each named for the
failure it locks down. They mock the Control4 runtime, so they cannot prove
timing or byte-stream behaviour against a real panel — that part is covered by
the installation it runs on.

**Still sensible on a first install:** keep your existing keypad or app as a
disarm path until you have watched this one arm and disarm your panel, set
**Log Level** to `Debug`, and watch Composer Pro's Lua Output.

Things worth watching, in rough order of likelihood:

1. **Connection**: does **Connection Status** reach `Connected`? If it stops
   at `Client Connected (awaiting verification)`, the Account ID does not
   match. Correcting the **Account ID** property re-admits the panel's
   existing session without waiting for a reconnect.
2. **Arm/disarm**: check **Last Command Result** after each attempt — it
   records whether the panel accepted the command, or why it failed.
3. **Arm mode detection**: modes are learned by querying System Key Status
   (2310) after an arm. The mapping is `SYSTEM_KEY_TO_MODE` in `driver.lua`
   and matches Appendix C of the spec.
4. **The zone list**: zones should populate and show live open/closed state.

### Log levels (v16)

`Debug Logging` (On/Off) is replaced by **Log Level**: Error / Warning / Info
(default) / Debug. Each level includes the ones above it.

- **Error** -- something failed: a refused command, a rejected frame, a
  connection dropped, a state query that came back empty.
- **Warning** -- handled, but wrong: an event for an unconfigured partition, a
  proxy command with no handler, a malformed Zones Config entry.
- **Info** -- normal activity: connect, verify, arm, disarm, alarm, discovery.
- **Debug** -- the full frame trace, and the read-only diagnostic properties
  become visible in Composer.

A project updated in place may still hold the old property; `On` maps to Debug
and `Off` to Info, so a deliberate trace is not silently turned off.
`Recent Activity` records Info and above.

### SET_ZONE_INFO (v16)

Navigator pushes zone identity at the panel proxy whenever the security agent
refreshes, which was logging `unhandled command SET_ZONE_INFO` repeatedly. The
reference driver accepts it as a no-op; this driver takes the rename, writes it
back into **Zones Config** (so it survives a reload) and republishes. Commas
and semicolons in a name are replaced with spaces -- they are the field and
record separators and there is no escape syntax to read back.

### The link watchdog (v16) -- "Connected" for a panel that is gone

`OnServerConnectionStatusChanged` was the only thing that moved
**Connection Status** off `Connected`, and it fires on a clean TCP close. A
panel that is powered off, unplugged, or cut off by a network change leaves the
socket half-open: no FIN arrives, no callback runs, and the driver reported
`Connected` indefinitely for a panel it could not hear. That is not cosmetic --
it is the difference between an alarm reaching Control4 and the system quietly
not being monitored.

A 15-second timer checks how long it has been since **anything** arrived
(unparseable bytes count -- the question is whether the panel is there, not
whether it is well). Past **Link Timeout Seconds** (default 600; 0 disables)
the link is torn down through the same path as a real disconnect: partitions
go Unknown, queued commands fail loudly, and the widget stops showing a
confident state. A clock that steps backwards is treated as "just heard from
it", not as a timeout.

**v21: the default was 90 through v20, on an unconfirmed "heartbeat every few
seconds" assumption.** An independent, physically-validated PIMA Force
integration ([amithalp/pima-force-ha-integration](https://github.com/amithalp/pima-force-ha-integration))
documents the real cadence directly: "the panel normally sends traffic at
least once every four minutes" (~240s), and its own equivalent watchdog uses
a 12-minute (720s) timeout specifically because of that ~4-minute gap. A 90s
default on this driver would very likely have been firing false positives
against a perfectly healthy panel -- every reconnect looking exactly like a
real outage. The default is now 600s, comfortably past the ~240s real
cadence and still well under their 720s ceiling. Anyone who already set their
own value in Composer keeps it unchanged; only a fresh install picks up the
new default. Do not set this below roughly 300s.

### Properties are for configuration (v15)

The read-only diagnostic properties -- `Last Event *`, `Last Zone *`,
`Last Output Number`, `Last NAK Reason`, `Last Raw Frame In`,
`Recent Activity` -- are hidden from the properties panel unless
**Log Level** is `Debug` (`C4:SetPropertyAttribs`, in a pcall, so an older
Director that lacks it cannot take driver init down). They still exist and are
still written, because the driver's Events reference them by name in Composer
programming; they are just not in the way while you are setting a port number.
`Discovered Zones` stays visible -- it is part of the setup workflow.

### The "Unknown" partition header (v15)

`UNKNOWN` is the security partition proxy's own default state, so the app
showing it means the proxy never accepted a state -- not that the driver did
not have one. The driver used `PARTITION_STATE_INIT` for the cold sync on
connect, so a driver reload on an armed house would not read as a fresh arming
to programming. Navigator does not appear to re-render on the INIT
notification: the header stayed at the default while the property, the shield
and the regenerated documents were all correct.

Since v15 the cold sync sends the seed **and then** the same value as a live
`PARTITION_STATE`. The proxy has no state *change* to propagate, so programming
should still not fire, but the UI has a live notification to redraw on.

Two things are now logged at INFO to make this diagnosable rather than
guessable: every `ReceivedFromProxy` command with its binding and parameters
(what Navigator is actually asking for, and when), and every partition state
pushed to a proxy binding with its STATE and TYPE. If the header is still
wrong, those two lines from one log say which side is failing.

### Why the properties panel is kept small (v14)

Composer's property grid redraws whenever the driver pushes a property, and it
renders long STRING values badly. Three things keep it responsive:

- **Unchanged values are not rewritten.** Every property write goes through
  `SetProp()`, which compares against what was last written and returns
  without touching Director if nothing changed. A single zone event used to
  rewrite seven properties, most of them identical to what they already held;
  a 20-event burst costs **26 property writes instead of 140**.
- **`Recent Activity`** is capped at 25 entries of 100 characters (~2.5 KB).
  Full frame-level history belongs in the log, not in a property -- see
  "Recent Activity is a critical-events log" below for what actually lands
  here.
- **`Discovered Zones`** is a 600-byte *preview* only. The complete discovered
  list is held in memory and that is what **Apply Discovered Zones** writes,
  so a shorter preview never means fewer zones applied.

### Security properties worth knowing

- **Disarm from the Control4 keypad fails closed.** The code typed on the
  Navigator is checked against the partition's configured code before
  anything is sent to the panel; a missing, empty, or wrong code is rejected
  with `DISARM_FAILED`. Note that the code actually sent to the panel is the
  one stored in **Partitions Config** -- the typed code is the only
  authentication step, which is why it must match.
- **The listening port is on your LAN.** The driver only accepts frames whose
  Account ID matches, refuses to let a second connection displace a verified
  panel session, stops listening to a socket that repeatedly presents a wrong
  account, and never sends a user code to an unverified connection. It is
  still a plaintext protocol on a local port -- put it on a trusted VLAN.
- **User codes are stored in plain text** in the Partitions Config property
  (same tradeoff the homebridge project documents). Anyone with Composer Pro
  or project-file access can read them. They are, however, **redacted from
  every log path and diagnostic property**, so a debug log is safe to share.

## What the Control4 app shows, and what drives it

**Alarm status** -- the shield widget's armed/disarmed/alarm state comes from
`PARTITION_STATE`, sent on every change and seeded on connect (see below).

The *header* above the zone list is a different thing: it reads `<state>` out
of the `ALL_PARTITIONS_INFO` document. Until v12 that document was published
only by `SendPanelInfo()`, whose fingerprint deliberately ignores live state,
so the only copy the app ever received was the `OFFLINE` one written at load
time -- the header read **Unknown** forever, even with the partition property
and the shield both correctly showing Armed Away. Since v12 the document is
re-sent whenever a partition's proxy state actually changes (one call, not the
~130-call inventory republish), and is skipped when the state is unchanged.

**A third, separate "Unknown" -- the label above the Zones-tab list (v20,
unverified hypothesis).** This turned out not to be either of the above.
Confirmed by direct testing: the label read the bare word `Unknown`, with no
partition name next to it, at a moment where the log showed `PARTITION_STATE`,
`PARTITION_STATE_INIT` and `PANEL_PARTITION_STATE` had all just been sent
correctly (`STATE=DISARMED_READY`). Every notify that carries arm/disarm
*state* was confirmed right, which points away from state entirely and toward
this label reading something that identifies the partition instead -- most
likely its *name*, defaulting to the proxy's own untouched placeholder when
nothing has ever set it.

Control4's own "security" partition proxy template (found inside the
Konnected reference's bundled proxy library, not invented for this driver)
defines a `PARTITION_INFO` notify, sent to each partition's own binding
(5002+) rather than the panel-wide ones -- and this driver never called it.
Konnected's own driver never calls it either (dead template code there too),
so there is no captured real example of the XML it expects. v20 sends
`<partition><id>/<name>/<enabled>/<binding_id></partition>` to each configured
partition's binding, at init and whenever **Partitions Config** changes,
inferring the shape from the sibling documents (`AllPartitionsInfoXML`) that
are already confirmed working.

**v20 result: no change.** The label still reads bare `Unknown` after
updating. Two further checks push this from "unverified" to "probably the
wrong tree entirely":

1. Control4's official Driverworks proxy-protocol reference
   (control4.github.io/docs-driverworks-proxyprotocol) lists the real
   Security Partition notifies -- `ARM_FAILED`, `CLEAR_ZONE_LIST`,
   `CODE_REQUIRED`, `DISARM_FAILED`, `EMERGENCY_TRIGGERED`, `HAS_ZONE`,
   `PARTITION_ENABLED`, `PARTITION_STATE`, `PARTITION_STATE_INIT`,
   `REQUEST_ADDITIONAL_INFO`, `REQUEST_DEFAULT_USER_CODE`, `REMOVE_ZONE`,
   `ZONE_STATE` -- and `PARTITION_INFO` is not among them (neither is
   `DISPLAY_TEXT`). That page's own content was truncated in the fetch, and
   `ALL_PARTITIONS_INFO` -- confirmed real, this driver's own main-header fix
   depends on it -- is *also* missing from the same list, so absence there
   isn't proof by itself. But it lines up with v20 doing nothing.
2. Konnected's reference `getAllPartitionXML()` -- the function that builds
   the real, working `<partitions>` document their shipping driver actually
   sends -- uses exactly the same four fields this driver already sends:
   `id`, `enabled`, `binding_id`, `state`. No `name` field exists anywhere in
   the one partition document that's confirmed to work. So a missing name in
   the data this driver controls was never actually plausible; the reference
   driver doesn't send one either, on hardware where (presumably) this label
   is not stuck on Unknown.

That leaves the most likely explanation as something outside this driver's
reach entirely: the name Navigator shows for a security partition/area is
usually a **project-configuration property set in Composer Pro** when the
partition proxy binding is added to a room -- not something transmitted over
`SendToProxy` at all. If that field was left at its template default (or
blank) when the driver was set up, Navigator would have nothing to show and
"Unknown" is a plausible fallback. Worth checking directly in Composer Pro:
select the partition's binding/agent in the project tree and look for a name
or "Partition Name"-style property on it, distinct from anything in this
driver's own property sheet. If it's already named there, the next real
candidates are `CODE_REQUIRED` (confirmed-real, unsent by this driver, but
its documented purpose is prompting for a code, not labeling) or accepting
this may be a Navigator/OS-version quirk unrelated to any notify.

**Zone list** -- three separate notifications are needed for a zone to appear
with a live status, and missing any one leaves the list empty or dead:

- `PANEL_ZONE_INFO` tells the panel proxy the zone exists (id, name, sensor
  type, partitions).
- `HAS_ZONE` tells each *partition* proxy that the zone is in its list. This
  is the one whose absence usually shows up as an empty zone list.
- `ZONE_STATE` carries live open / closed / bypassed, on every change.

The two whole-inventory documents (`ALL_PARTITIONS_INFO`, `ALL_ZONES_INFO`)
are two calls and go out synchronously. The per-zone notifications are queued
and drained 8 at a time on a 50 ms timer -- since v13. Every `SendToProxy` is
a blocking round trip to Director, and 40 zones meant ~80 of them inside
`OnDriverLateInit` and the Zones Config handler, which are the callbacks
Composer waits on: that was the ~40-second Composer freeze on every driver
update after a zone list was imported. `PANEL_INITIALIZED` is sent after the
last zone, and a publish started while another is draining replaces it rather
than interleaving.

All three are sent at init, whenever **Zones Config** changes, and again once
the panel actually connects (on a cold start the driver initialises before
the panel dials in). `CLEAR_ZONE_LIST` runs first on a rebuild, so a zone
moved between partitions does not end up listed under both.

Zone `type` in Zones Config maps to Control4's sensor type, which controls
the icon: `contact`=1, `door`=2, `window`=3, `interior`=4, `motion`=5,
`fire`=6, `gas`=7, `co`=8, `heat`=9, `water`/`leak`=10, `smoke`=11,
`pressure`=12, `glass`=13, `gate`=14, `garage`=15.

**Cost of publishing** -- each of those notifications is a Director round
trip, so a 40-zone inventory costs roughly 90. It is therefore published only
when something the app displays actually changes (partitions, or a zone's
number, name, type or partition). Reconnects, and re-applying an identical
zone list, cost nothing. An explicit `GET_*`/`SYNC_PANEL_INFO` from Director
always forces a full answer. Zones in the default closed-and-not-bypassed
state get no separate `ZONE_STATE` at publish time, since `PANEL_ZONE_INFO`
already carries `IS_OPEN` -- open or bypassed zones still do.

**History** -- there is no history or log notification in the Control4
security proxy protocol; the driver cannot push history entries. The app's
History tab is built entirely by Control4/Director from the state changes and
events the driver reports (`PARTITION_STATE`, `ZONE_STATE`,
`EMERGENCY_TRIGGERED`, `TROUBLE_START`/`TROUBLE_CLEAR`), so what makes it
useful is that the reporting is complete -- all of the above are wired up.
There is no protocol-level flag to mark a notification "don't put this in
history" while still using it for live status, so the driver cannot filter
the app's own History view; if you want per-zone open/close excluded there,
check whether the History view itself has a type filter (a Control4 UI
feature, not this driver). How long Control4 retains that history is a
Director-level setting this driver has no visibility into and no
documentation for -- that question goes to Control4, not this driver.

**v22-v24: what actually controls this, established by experiment.** The
Event/Alert/Alarm filter was tried on the installed system and changed
nothing, so the driver got its own controls. Setting **Zone State
Reporting** to `Panel only` then produced the decisive result:

> History went completely quiet, AND the zone list stopped showing open/closed.

That settles the mechanism. `ZONE_STATE`, sent to the **partition** binding,
drives *both* the History rows and the live open/closed indication in the
zone list. `PANEL_ZONE_STATE`, sent to the panel binding, drives **neither** --
it is inert as far as the visible UI goes. So History noise and live zone
status are not two things that can be separated by routing: they are the same
notification. No setting will ever give you a live zone list with a quiet
History for the same zone.

What that leaves, and it is the right tool anyway:

- **Quiet Zones** -- a comma-separated list of zone **numbers** and/or type
  words (`motion`, `4,12`, `motion,12`). Listed zones stop reporting, so they
  generate no History rows and show permanently as Normal; every other zone
  stays fully live and still logs. Since motion detectors are almost always
  the entire flood, silencing those by number gives a History with doors,
  windows, arm/disarm and alarms in it and nothing else. A quiet zone still
  tracks its state internally and **still fires its Control4 programming
  events**, so automations keep working -- `C4:FireEvent` runs before the
  proxy notification and only the notification is withheld. Zone numbers are
  the reliable form: the app draws `motion` and `interior` with the same
  icon, so a type word can silently match nothing. On every reload the log
  names the zones it silenced, or warns that the setting matched none.
- **Zone State Reporting** -- now mainly a diagnostic. `Partition only` is
  the efficient setting (half the proxy traffic, no observed loss, since
  `PANEL_ZONE_STATE` was shown to do nothing visible). `Panel only` and `Off`
  both cost you live zone status entirely.

Confirmed from Control4's official end-user documentation
(docs.control4.com, "Using security panel controls"): the History view does
have a native filter -- *"filter the results, select (or deselect) Event,
Alert, or Alarm at the bottom of the screen"* -- alongside a separate,
unrelated filter on the Zones screen for showing open zones only. What isn't
documented anywhere found so far is where the category line falls: whether
zone open/close counts as "Event" (separate from arm/disarm/alarm, in which
case deselecting Event alone should clear the flooding while keeping
arm/disarm/alarm visible) or whether "Event" is the umbrella that includes
everything the panel reports. That has to be checked in the app itself --
open History, deselect Event, and see what's left.

**Recent Activity is a critical-events log, not a raw trace.** The
`Recent Activity` property never receives zone open/close at all --
`DispatchEvent`'s zone branch only calls `C4:FireEvent`/`NotifyProxyZoneState`,
never `LogInfo`, so there is nothing to filter there; it was always
structurally excluded. What lands in `Recent Activity` is every Info-level-
or-above log line: connection changes, arm/disarm, alarms, troubles, command
failures, discovery results. 25 entries, in-memory only, cleared on every
driver reload -- if you need something that survives longer, that has to
live in Control4's own History or Composer's own log capture, not here.

**Live zone status on connect -- decoded as of v21.** Parameter 2149 was
logged raw and left undecoded for weeks (v18 through v20). The layout is now
confirmed against an independent, physically-validated Home Assistant PIMA
Force integration ([amithalp/pima-force-ha-integration](https://github.com/amithalp/pima-force-ha-integration),
validated against real hardware on Force JSON Interface 2.3, documented from
PIMA's own Force Interface JSON Format Specification), and checked against a
real capture from this installation -- decoding that capture with the formula
below reproduces exactly the zone numbers seen (7, 8, 21, 24, 25, 26, 27, 30,
31, 32, 33, 35), which coincidence could not do.

The earlier mental model was wrong in two ways at once:

1. **2149 is not one value per requested zone.** It is a *sparse* list: the
   panel returns one entry only for a zone that currently has at least one
   non-default status bit set (open, armed, bypassed, alarmed, a wireless
   fault, and so on). A zone with nothing to report is simply absent, and a
   panel where every zone is closed, disarmed and clean legitimately answers
   with an **empty array** -- confirmed by the reference integration's own
   real-panel capture fixture. `[40007]` (logged back in v18) almost
   certainly was not a truncated response at all: it was very likely the
   complete, correct answer for a moment when exactly one zone (zone 7) had a
   bit set (Armed). The v18 "fix" -- paging through a positional range on the
   theory that this was the same truncation bug zone names had -- was solving
   the wrong problem, which is why it never seemed to go anywhere.
2. **The zone number is packed into the value itself**, not implied by
   request position. Each entry is a hex string with the zone number in the
   low byte and a 16-bit status field above it:
   ```
   value  = tonumber(entry, 16)
   zone   = value % 0x100            -- low byte
   status = math.floor(value / 0x100)
   ```
   Status bit numbers (0-indexed): `0` Supervision Loss, `1` Low Battery,
   `2` Short (wired), `3` Cut/Tamper, `4` Soak, `5` Chime, `6` Anti-mask,
   `7` Manual Bypassed, `8` Auto Bypassed, `9` Alarmed, `10` Armed, `11` Open,
   `12` Duress, `13` Fire, `14` Medical, `15` Panic.

The driver now requests id 2149 with `start_order=1` and no `stop_order` --
confirmed as the correct shape for this specific parameter by the reference
integration's real capture, unlike zone names (260), which does truncate
without one. It decodes bits 7/8/11 (bypass/bypass/open) into `ZoneState` and
the proxy exactly as a live `ZONE_STATE` event would, only sending a proxy
update when the decoded value actually differs from what was already
tracked. Bits 3, 0, 1 and 9 (tamper, supervision loss, low battery, alarmed)
are logged at Warning if seen, since this driver does not yet carry them on
the proxy and they should never be silently dropped. A zone number in the
response that isn't in **Zones Config** is ignored rather than guessed at.

**Arm OPERATION now sends `order=1`, not `order=0` (v21).** Every arm optype
(Away/Home1-4/Shabbat) sent `order=0` through v20, on no particular evidence
either way. The same reference integration states plainly, from its own
physical validation: "validated FORCE traffic requires order=1 for arming
modes... disarm uses order=0 on the tested firmware." Disarm is unchanged
(`order=0`). If arm ever silently failed or behaved oddly on a firmware
stricter than the one this driver was originally tested against, this was
the likely reason.

**v22: the Zones-tab "UNKNOWN" was a zone-attribution bug, in this driver.**
Three earlier attempts (v12, v15, v20) all chased partition *state* and all
missed, because the label is not a state readout at all. Two observations
from the installed system settled it: the **Status** tab showed the correct
armed/disarmed state at the very same moment the **Zones** tab read
`UNKNOWN`, which rules out state propagation entirely; and the screenshot
showed `UNKNOWN` rendered as an all-caps *section header* above the zone
list -- a group heading, and zones are grouped by partition.

The cause was in `ZonePartition()`. Its last resort returned the only
configured partition when exactly one existed, and **nil** otherwise. A zone
resolving to nil is published with an empty `<partitions></partitions>` and
gets no `HAS_ZONE` at all, so it belongs to no partition: it still appears in
the app (`PANEL_ZONE_INFO` goes to the panel proxy regardless) but under no
partition heading. So on any system with two or more partitions configured
where the zones' Zones Config entries omit the optional 4th field -- easy to
do when the list is hand-edited to set icon types -- *every* zone became
unattributed at once.

The old behaviour was deliberate, with a comment defending it: claiming
partition 1 for an unassigned zone "puts it in the wrong partition's zone
list on a multi-partition system". That reasoning had the failure modes
backwards. A zone in the wrong partition is visible and fixable with one
Zones Config edit; a zone in no partition looks like a broken driver and
cannot be corrected from the app at all. Konnected's reference driver -- the
one confirmed working on real Control4 hardware -- never emits an empty
partitions field; it hardcodes `<partitions>1</partitions>` for every zone.

`ZonePartition()` now falls back to the lowest configured partition (or 1 if
none are configured) and never returns nil, and `PublishZoneInventory()` logs
how many zones took that fallback, alongside which partitions are configured,
so a wrong placement is reported rather than silent. Set the 4th field per
zone in Zones Config to place zones explicitly.

**A cross-check on the Zones-tab "Unknown" label.** The reference
integration's own README states directly: "PIMA's JSON interface does not
expose partition names, so they are displayed as `Partition N`" in Home
Assistant. That is independent, protocol-level confirmation of the
Composer-configuration theory above -- the panel's own wire protocol has
nowhere to carry a partition name at all, so whatever Navigator shows for one
has to come from project configuration, not from anything this driver's Lua
sends over the socket. Still worth checking Composer Pro for a name field on
the partition binding, but this makes it very unlikely that any further
notify-guessing on the driver side would ever change that label.

## The app's Functions and Emergency menus (v25)

Those two menus in the Control4 app are not driver logic -- they are
`<capabilities>` in `driver.xml`:

| Capability | What it renders |
| --- | --- |
| `<functions>` | the **Functions** menu (comma-separated list) |
| `has_fire` / `has_medical` / `has_police` / `has_panic` | the **Emergency** menu entries |
| `arm_states` | the arm buttons |
| `star_label` / `pound_label` / `button_A..D` | the keypad keys |

**These are static.** The DriverWorks API has `GetCapability` but no setter,
so the menu contents cannot be chosen per installation from a Composer
property -- they are fixed when the driver is built. If you want a different
set of Functions entries, that is a rebuild, not a setting.

**Functions**, as declared: `Check Status`, `Arm All`, `Disarm All`,
`Refresh Troubles`. Every one is something this driver can genuinely carry
out against a PIMA panel:

- **Check Status** re-reads partition state (2310) and zone status (2149).
- **Arm All** sends Away to every configured partition, skipping (and
  reporting) any whose Partitions Config does not allow Away.
- **Disarm All** disarms every configured partition.
- **Refresh Troubles** re-reads the active fault list (2250).

Deliberately absent are **Utility Key** and **Clear Troubles**, which other
panels' drivers offer: PIMA's JSON interface has no documented command for
either, so they would be menu items that do nothing. `Refresh Troubles` is
the honest version of the second one. The declared list and the dispatcher
in `driver.lua` (`PARTITION_FUNCTIONS`) are checked against each other by a
regression test, so a name can never exist in one and not the other.

Tapping an entry sends `EXECUTE_FUNCTION`. The official protocol reference is
truncated exactly where its parameters would be documented, so the handler
accepts every plausible parameter name and logs the whole parameter set at
Info -- one tap and the log shows the real shape.

**Emergency is deliberately off.** `has_fire`, `has_medical`, `has_police`
and `has_panic` are all `false`, so this driver shows no Emergency menu.
PIMA's JSON interface has no documented command to raise an emergency: the
optypes known to exist are arm (12-16), disarm (17), outputs (35/36) and
Shabbat (43), and the independent, spec-holding Home Assistant integration
implements no emergency command either. A Police button that silently does
nothing is worse on a security system than no Police button. If PIMA's own
Appendix B turns out to document an emergency optype, wiring it is a small
change. Until then an `EXECUTE_EMERGENCY` that somehow arrives is refused
loudly and reported, never swallowed.

## Per-zone bypass (v25)

### Bypassing from the app

**Control4's native security UI has no per-zone bypass control.** This was
assumed to exist for several versions and it does not: Control4's own user
guide describes the Zones screen as somewhere to *"view the status of each
security zone in your house"*, and says selecting a zone does something only
*"if a device is controllable by the Control4 system (such as a front
gate)"*. Tapping a zone in the list therefore does nothing for an alarm zone,
whatever `can_bypass` says, and no driver change alters that.

Bypass is reachable three ways instead:

1. **The app's Functions menu (v28)** -- `Bypass Open Zones` and `Clear All
   Bypasses`. The Functions menu is an app surface this driver defines and
   the app definitely renders, so this is the in-app route. "Bypass Open
   Zones" is the workflow that actually matters: a door or window that will
   not close, bypassed so the system can arm. Both are scoped to the
   partition whose menu was opened, both respect **Non-Bypassable Zones**,
   both go through the read-back verification below, and each bypass still
   gets the auto-clear safety timer. What was bypassed, and what was
   deliberately left armed, is named in **Last Command Result**.
2. **Composer programming** -- the **Bypass Zone** / **Clear Bypass** actions
   take a zone number, so they can be bound to a custom button, a keypad
   button, or a macro for per-zone control from the app.
3. **The panel's own keypad.**

`can_bypass` is still published per zone (see **Non-Bypassable Zones**),
since it costs nothing and a future Navigator version may use it.

### The protocol side

Tapping a zone in the app's Zones tab offers a bypass control when that
zone's `<can_bypass>` is true, and the app sends `BYPASS_ZONE` in either
direction -- so bypasses can be both added and removed from the app, not
just added. The same applies to the **Bypass Zone** / **Clear Bypass**
actions in Composer's Programming tab and anything driven from programming.

The panel command behind it is a write to parameter 2150 (`"1"` bypass,
`"0"` clear) at `start_order` = the zone. That shape used to be this
driver's own inference; it is now confirmed against the independent,
physically-validated Home Assistant PIMA integration, which writes exactly
the same frame and lists per-zone bypass among the things it verified on
real hardware.

### An ACK is not proof it worked (v26)

That same reference documents a failure mode worth taking seriously: *"If a
zone is permanently cancelled in technician programming, the panel may
acknowledge a temporary-bypass request without applying it."* The panel says
yes and does nothing.

Through v25 this driver stopped at the ACK -- it told the app the zone was
bypassed and started the auto-clear safety timer, both on a bypass that may
never have happened. Since v26 every bypass write is read back: 2150 is
requested for that one zone (it reads back positionally, one value per zone
from `start_order`, unlike the sparse 2149 status list) and the app is told
what the **panel** reports, not what was asked for. The outcomes:

- **Confirmed** -- the panel agrees. Reported as confirmed, and for a bypass
  the auto-clear timer is armed at this point and not before, so it can
  never "clear" a bypass that never existed.
- **ACKed but not applied** -- logged as an error and surfaced in **Last
  Command Result**, with the app corrected to the panel's real state. No
  auto-clear is armed for a bypass that did not happen.
- **Clear ACKed but the zone is still bypassed** -- the dangerous direction,
  since a detector is left disabled. The safety auto-clear is re-armed so
  the driver keeps trying instead of walking away.
- **Read-back never answers** -- reported as `UNVERIFIED` rather than as
  success, and the tracked state is left alone rather than guessed.

Clearing a bypass is never blocked by **Non-Bypassable Zones**, whatever the
list says, for the same reason: blocking that direction could strand a zone
bypassed with no way back.


`<can_bypass>` per zone is what puts a bypass control on that zone in the
app. It was hardcoded `true` for every zone, which offered the control on
smoke and fire detectors too -- zones most panels refuse to bypass, so the
button was there and simply failed.

**Non-Bypassable Zones** takes the same syntax as Quiet Zones: zone numbers
and/or type words, mixed (`smoke,fire` or `13,14`). Listed zones publish
`can_bypass false` so the app offers no control, and the rule is enforced on
the driver side as well -- a bypass requested for a listed zone is refused
and reported wherever it came from, including the Actions tab and
programming. Empty (the default) leaves every zone bypassable, so nothing
changes for an existing install.

Clearing a bypass is never blocked, whatever the list says: blocking that
direction could strand a zone bypassed with no way back, which is the
dangerous failure. Bypassed state is reported to the app either way, through
`ZONE_BYPASSED` on `ZONE_STATE`, and the existing **Zone Bypass Auto-Clear
Minutes** safety timer still applies.

## Arm-mode naming

Modes carry both names -- the Control4-conventional one and PIMA's own name
for the same mode, as it appears on the panel keypad and in PIMA's
programming software:

| Label used everywhere | PIMA optype |
| --------------------- | ----------- |
| `Away (Full Arm)`     | 12 |
| `Stay (Home1)`        | 13 |
| `Night (Home2)`       | 14 |

Home3 (15), Home4 (16) and Shabbat (43) keep PIMA's names as-is -- there is no
separate Control4 term to pair them with. They can be *detected* (the driver
reports them via the generic `Partition N Armed` event) but are not offered as
arm buttons, matching what the Actions tab exposes.

The labels appear in the `arm_states` capability (the arm buttons in the app),
the Arm actions, the per-partition events, and the `Partition N State`
property. They are defined once in `driver.lua` (`ARM_LABEL_*`) and once in
`gen_driver_xml.py`; a regression test parses driver.xml and fails if they
drift, including a check that every arm state the XML advertises is one the
driver will actually act on -- a mismatch there would make every arm from the
app fail with `ARM_FAILED`.

Incoming `PARTITION_ARM` accepts the full label, the bare Control4 name
(`Stay`) and the bare PIMA name (`Home1`), and the old bare action names
(`Arm Stay`) still dispatch, so existing programming keeps working.

## How partition state is learned

On connect (once the panel verifies), the driver queries **System Key Status**
(parameter 2310) for every configured partition and sets the state to match.
Before this existed the driver was purely event-driven: it learned the state
only when someone next armed or disarmed, so a freshly loaded driver on a
perfectly healthy panel showed every partition as `OFFLINE` indefinitely.

The **Sync Partition States** action re-runs that query on demand.

Known System Key values: `3` Away, `4` Stay, `5` Night, `6` Home3, `7` Home4,
`8`/`9` Shabbat. Every value read is logged
(`Partition N System Key Status = X`), so an arm mode this driver does not
recognise is always visible in the log even when it can't be named.

**v18: an unrecognised value is no longer guessed as Disarmed.** Earlier
versions defaulted anything not in the table above to Disarmed during a cold
sync -- a real panel then returned system key `2`, which is not in that
table, exposing that the default was a guess with nothing behind it, not a
confirmed mapping. For a security system the wrong-direction guess matters:
asserting Disarmed for a house that might actually be armed is worse than
leaving it `Unknown` and saying so. The cold sync now leaves the partition
state unchanged and reports the unrecognised value in **Last Command Result**
and the log, asking for it to be confirmed against the panel's real state at
the time. Once a value IS confirmed as Disarmed, add it to
`SYSTEM_KEY_DISARMED` in `driver.lua` (a small table right next to
`SYSTEM_KEY_TO_MODE`) rather than it falling through a guess. This does not
affect the OTHER place an unrecognised value is seen: right after a live arm
EVENT from the panel, the driver already knows the partition just armed (the
event itself is the evidence), so it still reports `Armed` there and only the
specific mode name is unknown.

**v19: system key `2` is now a confirmed Disarmed mapping.** Confirmed against
a real installed panel (2026-09) -- system key status read `2`, and the panel
was independently checked and was in fact Disarmed at that moment. `2` is now
in `SYSTEM_KEY_DISARMED` by default, so a cold sync resolves it to `Disarmed`
directly instead of asking about it every time. `SYSTEM_KEY_DISARMED` is a
plain table (not the self-preserving `X = X or {}` pattern used elsewhere for
genuinely runtime-learned state, e.g. `RecentActivity`/`PropShadow`), so it
resets to exactly this default -- `{ [2] = true }` -- on every load rather
than silently accumulating whatever got confirmed in a previous run.

The query is authenticated with that partition's user code from **Partitions
Config**. If the code is wrong the panel NAKs it and the state stays
`Unknown` -- check **Last NAK Reason**.

## Logging and diagnostics

Three layers, so that "what happened at 3am" is answerable without having
had a log window open at the time.

**1. Diagnostic properties** (Composer Pro, no log window needed):

- **Recent Activity** -- rolling buffer of the last 25 significant events
  (connection changes, arm/disarm, alarms, troubles, command failures),
  newest first, timestamped, and deliberately excludes routine zone
  open/close so it is not buried. Start here after an incident.
- **Last Command Result** -- did the panel accept the last arm/disarm/bypass,
  or why it failed (wrong code, no connection, timeout).
- **Connection Status**, **Panel Verified Account**, **Last NAK Reason**,
  **Last Event Type/Qualifier/Zone/Partition**, **Last Event Summary**,
  **Last Zone Number/Name**, **Last Raw Frame In** (debug only).

**2. Always-on log** -- connection and verification changes, arm/disarm as
reported by the panel, every alarm and trouble, NAK reasons, queue and timer
failures, config parse errors. Goes to Composer Pro's Lua Output *and*
`C4:DebugLog`, so it persists in Director's log whether or not anyone is
watching.

**3. Debug trace** -- set **Log Level** to `Debug` to add a full frame-level
trace of everything sent and received (`>>>` / `<<<`), plus queue and
dispatch detail. This also goes to both destinations.

**Credential redaction.** The frames this driver sends carry the alarm user
code in a `password` field. Every log path and every diagnostic property runs
through `Redact()` first, so the code appears as `******` and never reaches a
log file, Director's log, or a property you might screenshot or paste. This
is enforced by regression tests that assert no configured user code can be
found anywhere in the driver's log output. (Earlier builds of this driver did
leak the codes into the debug trace -- if you have logs from before this
change, treat them as containing your PINs.)

## Known limitations / good v2 candidates

- **Partitions 1-3** get the full Control4 surface: a `Partition N State`
  property, named programming events (`Partition N Armed Away`, etc.) and a
  Security Partition proxy binding (the shield widget). Arm/disarm *commands*
  still work for any panel partition 1-16, but partitions 4-16 surface state
  only through the generic `Unmapped Panel Event` + `Last Event Summary`
  property, and have no widget.

  To change the count, edit `MAX_PARTITIONS` in `gen_driver_xml.py` **and**
  `MAX_DECLARED_PARTITIONS` in `driver.lua` -- they describe one thing and
  must match. `tests/test_regressions.lua` parses the generated `driver.xml` and
  fails with a specific message if they drift, so run it after changing
  either. Each partition costs 7 events, 1 property, 1 proxy binding and 2
  connections; every declared partition appears in Composer Pro whether or
  not it is configured (unconfigured ones are disabled at runtime, so they
  do not show in Navigator).
- No per-zone Control4 events (only generic `Zone Opened`/`Zone Closed` +
  `Last Zone Number`/`Last Zone Name` properties) -- keeps `driver.xml` from
  growing to hundreds of events for panels with many zones. Could add a
  bounded set (e.g. zones 1-32) the same way partitions are handled.
- User names (parameter 411) aren't queried by any action yet -- only zone
  names. Would be a small addition (`RequestData(411, ...)` following the
  same pattern as `DiscoverZoneNames`) if you want user names too.
- User codes are stored in plain text in the **Partitions Config** property,
  same tradeoff the homebridge project makes and documents. Anyone with
  Composer Pro / project-file access can read them. Protect access to the
  project accordingly.
- Zone bypass writes are **not** privilege-filtered by the panel (this is a
  panel behavior, not a driver limitation -- see the protocol notes: any
  configured user code can bypass any zone, even ones its partition can't
  see). Worth knowing if you're relying on partition user codes as an access
  boundary.
- Zones aren't exposed as their own bindable Contacts-proxy devices (per-
  zone drag-into-a-lighting-scene style) -- only via the shield widget's own
  zone list and the existing generic Zone Opened/Closed events. Would need
  one `contact` proxy binding per zone in `driver.xml` plus a `ZONE_STATE`-
  equivalent notify per binding.
- `arm_states` is one fixed list (`Away,Stay,Night`) shared by every
  partition, because capabilities are static driver metadata with no runtime
  setter. The *behaviour* is per-partition, though: an arm from the native
  widget in a mode that partition's `modes` field does not list is refused
  with `ARM_FAILED` rather than sent to the panel. So a garage partition
  configured `A` still shows a Stay button, and pressing it fails cleanly.
- Emergency (fire / medical / police / panic) is not available. PIMA's
  Appendix B contains no operation type for raising one, so those
  capabilities are deliberately `false` rather than buttons that do nothing.

See [SPEC-VALIDATION.md](SPEC-VALIDATION.md) section 3 for a prioritised list
of additions the specification shows are possible — unhandled events worth
surfacing, per-zone troubles, exit-delay countdown, user names and output
status.

## Rebuilding the .c4z after edits

```bash
./build.sh
```

That regenerates `driver.xml` from `gen_driver_xml.py`, checks `driver.lua`
syntax, runs both test suites, and packages `PimaForce.c4z`. Bump
`DRIVER_VERSION` in **both** `gen_driver_xml.py` and `driver.lua` first —
Composer Pro only offers an update when the version is higher than the
installed one, and the tests fail if the two files disagree.
