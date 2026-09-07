# Validation against PIMA's Force Interface JSON Format Specification v2.4

Every claim below is checked against PIMA's own document rather than against
a reference implementation. Where the two disagree, that is called out.

---

## 1. Confirmed correct

These were inferred from reference implementations and captures. The spec
now confirms them outright.

### Zone status (parameter 2149) — exactly right

Appendix C gives the bit table, and it matches the v21 implementation bit for
bit:

| Bit | Meaning | Bit | Meaning |
| --- | --- | --- | --- |
| 0 | Supervision Loss (W/L) | 8 | Auto Bypassed |
| 1 | Low Battery (W/L) | 9 | Alarmed |
| 2 | Short (Wired) | 10 | Armed |
| 3 | Cut (Tamper) | 11 | Open |
| 4 | Soak | 12 | Duress |
| 5 | Chime | 13 | Fire |
| 6 | Anti Mask | 14 | Medical |
| 7 | Manual Bypassed | 15 | Panic |

The sparse behaviour is confirmed in the spec's own words: *"only zones which
their status bytes (2-4) are not 0 are included in the response"*, and *"a
zone with all status bytes set to 0 indicates a closed and un-bypassed zone
that is not in alarm"*. That is precisely the model v21 implemented.

It also settles the very first capture from this installation. `40007`
decodes as zone 7 (`0x07`), status `0x400`, bit 10 = **Armed** — a normal
armed zone, not a truncated response. The v18 theory that this was the same
truncation bug zone names had was wrong, and the v21 rewrite was right.

Spec worked examples, all decoding correctly under the current
implementation: `81B` = zone 27 tamper, `80005` = zone 5 open, `800C` = zone
12 manually bypassed, `0A0019` = zone 25 alarmed and open.

### System key status (2310)

Appendix C: `1` Partition Not Exist, `2` Disarmed, `3` Full Armed, `4` Home1,
`5` Home2, `6` Home3, `7` Home4, `8` Shabbat-ON, `9` Shabbat-OFF. The
mapping matches, including **2 = Disarmed**, which was added in v19 on
nothing more than one confirmation against a known physical panel state. That
guess is now spec-backed.

### Zone bypass (2150)

Write and read-back shapes both match the spec exactly: a `DATA` frame with
`id: 2150`, `start_order` = zone number, `parameters: ["1"]` to bypass and
`["0"]` to clear; read via `DATA-REQ` with `start_order`/`stop_order`,
answered positionally. The v26 read-back verification uses the documented
read shape.

### Other confirmations

- **250-byte limit** on frames sent to the panel — matches `MAX_DATA_WRITE_BYTES`.
- **`kc: 1`** in ACKs keeps the panel connected; without it the panel
  disconnects after acknowledging. The driver has always sent it.
- **Event `zone` field** carries the *user* number for arm/disarm and panic
  events, not a zone — handled correctly.
- **Output numbering**: order `1` = external siren, `2` = internal siren,
  `34-41` = controlled outputs 1-8. The driver's Activate/Deactivate Output
  actions already document and accept exactly this range, so "output 1" does
  not silently fire the external siren.
- **NAK reasons** (Appendix D) are surfaced rather than swallowed.

---

## 2. Corrected in v27

### CID 400 — arm/disarm by master code was missed entirely

Appendix A separates `400` (master code) from `401` (user and remote codes).
The driver handled 401, 403, 407, 408, 409 and 441 but **not 400**. Arming or
disarming the panel with the master code therefore reported nothing at all:
the app kept showing the previous state until some later sync happened to
correct it. On a security display that is the worst class of bug — a house
shown as armed after it was disarmed at the keypad. Now handled alongside the
others.

### System key 1 was treated as an unknown code

`1` means *Partition Not Exist*. It was falling through to the
"unrecognised arm code" path, which logs an error and leaves state unchanged
— so a partition configured in Composer but not created on the panel produced
an error on every single sync, with a message that suggested a protocol gap
rather than a configuration mistake. It now says plainly that the partition
does not exist on the panel.

### Faults were reported as raw hex

Appendix E lists all 98 fault IDs, encoded as low byte = fault ID, high byte
= order (which expander, keypad, siren...). The driver dumped the raw array,
so a real trouble read `Faults: ["1","6","309"]`. It now reads
`AC Loss, PSTN Fault - DC, Zone Expander Fault #3`. For the communication
fault IDs (30-38) the description already names the path, so the high byte is
not appended there. This is what makes the **Refresh Troubles** function
added in v25 actually useful.

### Arm All / Disarm All now use the panel's own broadcast

The spec is explicit that `partition` accepts *"0 — all the partitions"*, and
its worked examples for "Arming Away all" and "Disarming all" both send
`partition: 0`. v25 looped and sent one frame per partition. Now it sends the
single documented broadcast — **except** when a configured partition is not
allowed to arm Away in Partitions Config, where the broadcast would override
the installer's restriction; there it falls back to per-partition and reports
which it skipped.

---

## 3. Suggested additions, in priority order

### 3.1 Unhandled events worth surfacing (Appendix A)

Currently unhandled and falling to the generic "Unmapped Panel Event":

| CID | Event | Why it matters |
| --- | --- | --- |
| `421-1-0` | Access Denied — invalid code, or outside time window | Someone tried a wrong code. Squarely a security event and a natural automation trigger. |
| `381-N` / `384-N` | Wireless zone supervision loss / low battery | Per-zone detector health. A wireless detector that has dropped off is a silent hole in coverage. |
| `144-N` / `145-N` | Cut/short on a zone; expander tamper | Tamper conditions the driver does not distinguish today. |
| `138-N` | Pre-alarm on a zone | Early warning ahead of a full alarm. |
| `373-N` | Wireless detector trouble (low sensitivity, clean-me, end of life) | Maintenance signals; end-of-life especially. |
| `312`, `321`, `322`, `338`, `342`, `344`, `351` | Aux voltage, siren troubles, expander battery/AC, jamming, comm faults | System health. Jamming in particular is an attack indicator. |
| `412-1-0` | Remote upload/download | Someone is reprogramming the panel remotely. |
| `454-1-0` | System inactivity | Useful for occupancy-style automations. |
| `601` / `602` | Manual and periodic test | Distinguishes a test from a real event. |
| `625-1-0` | Time/date changed | |

Each is a small addition: a constant, a dispatch branch, and a programming
event so it can be used in Composer.

### 3.2 Zone status bits the driver tracks but does not expose

The 2149 decode reads all 16 bits, but only open/bypassed reach the proxy;
alarmed, tamper, supervision loss and low battery are logged at Warning and
otherwise dropped. The Control4 security proxy has `TROUBLE_START` /
`TROUBLE_CLEAR`, which the driver already knows how to send — routing the
zone-level trouble bits into per-zone troubles would put detector faults in
front of the user instead of in the log.

### 3.3 Exit time (parameter 180)

Readable from the panel, and the partition proxy's `PARTITION_STATE` accepts
`EXIT_DELAY` with a total and remaining time — that is how other drivers show
a live exit-delay countdown in the app. The driver currently never reports an
exit delay at all, so arming jumps straight to armed.

### 3.4 User names (parameter 411)

Already defined as a constant but never requested. Appendix A gives the user
number in arm/disarm events, so with the name table the driver could report
*"Disarmed by Efi"* rather than *"Disarmed by user 3"* — in the log, in
Recent Activity, and as a property for automations.

### 3.5 Siren and output status (2301)

Orders 1-2 are the sirens, 34-41 the controlled outputs. The driver can
*command* outputs but never *reads* their state, so the app cannot show
whether a siren is currently sounding.

---

## 4. One unresolved ambiguity: the `order` field on arm

The spec contradicts itself:

- **Appendix B** lists `Order = 0` for Full Arm, Home1-4, Shabbat and Disarm.
- **The worked example on page 9** sends `"order":1` for arming away, and
  again for Home2.
- **Table 2** sends `"order":1` for "Arming Away all", but omits `order`
  entirely for "Home 1 partition 4" and for "Disarming all".

v21 changed arm from `order: 0` to `order: 1` on the strength of the Home
Assistant integration's note that *"validated FORCE traffic requires order=1
for arming modes"*, which agrees with the spec's examples but not its
appendix. Disarm sends `order: 0`, which every source agrees on.

Current behaviour is left as-is, since it matches both the physically
validated implementation and the spec's own examples. **If arming ever fails
with a NAK on some firmware, `order: 0` is the first thing to try** — the
appendix says that is the documented value.

---

## 5. Confirmed: Emergency cannot be implemented

Appendix B is the complete operation table, and it contains exactly seven
commands: Full Arm (12), Home1-4 (13-16), Shabbat (43), Disarm (17), Activate
Output (35), De-activate Output (36).

There is **no operation type for fire, medical, police or panic**. The panel
reports these as events when they happen (CID 100, 110, 115, 120, 122), but
there is no way for a home-automation system to raise one.

The decision to leave `has_fire` / `has_medical` / `has_police` / `has_panic`
set to `false` was therefore correct, and is now settled rather than
cautious: enabling them would put a Police button in the app that cannot do
anything. The only route to those functions is a keypad or a monitored
emergency path.
