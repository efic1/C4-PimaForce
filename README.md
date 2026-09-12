# PIMA FORCE — Control4 Driver

A Control4 DriverWorks driver for **PIMA FORCE** alarm panels, over the
panel's own local JSON interface. No cloud, no bridge, no extra hardware.

Arming and disarming, live zone status, bypass, panel troubles and alarm
events all appear natively in the Control4 app through the standard Security
Panel and Security Partition proxies, so the built-in security UI and Composer
programming both work against the panel.

> Independent community project. Not affiliated with, or endorsed by, PIMA
> Electronic Systems or Snap One / Control4.

---

## Status

Developed and tested against a live installation with **Force JSON Interface
2.3**, on Control4 OS 3.3+. Validated line by line against PIMA's *Force
Interface JSON Format Specification v2.4* — see
[docs/SPEC-VALIDATION.md](docs/SPEC-VALIDATION.md) for exactly what is
confirmed by the spec, what the spec corrected, and what remains ambiguous.

291 offline regression tests, one per defect found in review or in the field.

## Features

- **Arm / disarm** — Away (Full Arm), Stay (Home1), Night (Home2), plus
  Home3, Home4 and Shabbat detection. Per-partition, with per-partition user
  codes and per-partition restrictions on which modes are allowed.
- **Multi-partition** — three partitions get their own proxy, state property
  and programming events; arm/disarm commands work for any panel partition.
- **Live zone status** — open / closed / bypassed, from both panel events and
  a full status sync on connect.
- **Zone bypass** — set and clear, verified against the panel rather than
  trusted from the ACK, with a safety auto-clear timer and a never-bypass
  list for life-safety detectors.
  Bypassed zones are named on the partition status line in the app.
- **Alarm and trouble reporting** — burglary, fire, medical, panic, duress,
  tamper, AC loss, low battery and more, as Control4 programming events.
  Panel faults decode to readable text from the spec's fault table.
- **Functions menu in the app** — Check Status, Arm All, Disarm All, Bypass
  Open Zones, Clear All Bypasses, Refresh Troubles, and Disable / Enable
  Event Notifications for muting a misbehaving panel.
- **Hebrew zone names** — Windows-1255 names from the panel are transcoded to
  UTF-8 automatically, with a visual-order flag for panels that need it.
- **Diagnostics** — connection state, last event, recent activity, a link
  watchdog that catches a half-open socket, and four log levels.

## Requirements

- A PIMA FORCE panel with **JSON interface support** in its firmware. This is
  not present in every build — ask PIMA or your installer.
- Control4 OS 3.3 or newer, and Composer Pro.
- A panel account and a user code with rights for the operations you intend
  to use.

## Installing

1. Download `PimaForce.c4z` from
   [Releases](../../releases), or build it yourself (see
   [Development](#development)).
2. In Composer Pro, add the driver to the project and place it in a room.
3. Set **Listen Port** and **Account ID** to match the panel.
4. Set **Partitions Config** — one entry per partition,
   `id,name,userCode,modes` separated by `;`, where modes is any combination
   of `A` (Away), `S` (Stay), `N` (Night). Example:
   `1,Main,1234,ASN;2,Garage,9876,A`
5. Run the **Discover Zone Names** action, then **Apply Discovered Zones** to
   populate **Zones Config**.
6. Point the panel at the controller and wait for it to dial in.

### Panel side

The panel is the TCP **client** — it dials out to a monitoring-station
receiver, and this driver plays that role. There is no "panel IP address"
setting; you point the panel at the Control4 controller instead.

On the panel, under *Installer Code → System Configuration → CMS &
Communication → Monitoring Station → CMS2 or CMS3 → Comm.Paths → Network*:

| Setting | Value |
| --- | --- |
| IP / host | the Control4 controller's IP |
| Port | must match **Listen Port** (default 7780) |
| Protocol | `JSON` |
| Account ID | must match **Account ID** |
| Zone/Output Toggle | `ON` — required for zone open/close events |
| Remote Disarm | `ON` — required for the Disarm command |

Use an account ID not shared with a real monitoring-station path.

## Configuration

| Property | Default | Purpose |
| --- | --- | --- |
| Listen Port | `7780` | TCP port the driver listens on for the panel |
| Account ID | `1234` | Must match the panel's CMS account |
| Partitions Config | `1,Main,1234,ASN` | `id,name,userCode,modes` per partition |
| Zones Config | *(empty)* | `zone,name,type,partition` per zone |
| Zone Bypass Auto-Clear Minutes | `30` | Safety timer so a bypass is never left forever. `0` disables |
| Zone/User Name Encoding | `Windows-1255` | Set `UTF-8` for non-Hebrew panels |
| Reverse Zone/User Names | `Off` | For panels storing names in visual order |
| Log Level | `Info` | Error / Warning / Info / Debug |
| Non-Bypassable Zones | *(empty)* | Zone numbers and/or type words that must never be bypassed |
| Quiet Zones | *(empty)* | Zone numbers and/or type words that stop reporting open/close to the app |
| Zone State Reporting | `Partition + Panel` | Which proxies carry live zone state |
| Partition Display Text | *(empty)* | Fixed prefix for the partition status line on the app's Status tab |
| Event Mute Minutes | `60` | How long *Disable Event Notifications* lasts before events resume by themselves. `0` = until re-enabled by hand |
| Link Timeout Seconds | `600` | Treat the link as dead after this much silence. `0` disables |

Plus 20 read-only diagnostic properties, hidden unless **Log Level** is
`Debug`.

**User codes are stored in plain text** in Partitions Config, so anyone with
Composer Pro or project-file access can read them. They are redacted from
every log path, so debug logs are safe to share. The protocol itself is
plaintext on a local port — put it on a trusted VLAN.

## What the Control4 app can and cannot do

Some of this is Control4's UI, not the driver, and is worth knowing before
filing a bug:

- **Zone bypass is not a per-zone control.** Control4's Zones screen only
  views status; tapping a zone does nothing for an alarm zone. Bypass is in
  the driver's **Functions** menu (Bypass Open Zones / Clear All Bypasses),
  or per zone via the Bypass Zone / Clear Bypass actions in programming.
- **Zone open/close fills the app's History.** The same notification drives
  the live zone list and the History row, so they cannot be separated. Use
  **Quiet Zones** to silence noisy detectors such as motion.
- **The Status tab carries a driver status line.** Below the lock indicator,
  the driver states what is currently suppressed: `Notifications OFF` while
  events are muted, and the names of any bypassed zones. **Partition Display
  Text** prefixes it with a label of your own.
- **No Emergency menu.** PIMA's protocol has no command to raise a fire,
  medical or police emergency, so those capabilities are deliberately off
  rather than being buttons that do nothing.
- **The Functions menu is fixed at build time.** Capabilities are static
  driver metadata; there is no runtime API to change them.

## Development

```bash
./build.sh                        # regenerate driver.xml and package PimaForce.c4z
lua5.4 tests/test_regressions.lua # 291 regression tests
lua5.4 tests/test_driver.lua      # happy-path harness
```

`driver.xml` is **generated** — edit `gen_driver_xml.py`, never the XML. The
test suite parses the generated XML and fails if it drifts from `driver.lua`
(driver version, partition count, arm-mode labels, and the Functions list all
have to agree).

Run the regression suite before shipping any change. It is the file that will
tell you whether a "small fix" has reintroduced a fail-open disarm or a stuck
alarm.

### Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the protocol engine,
  proxy model and each subsystem work, and why. Includes the reasoning behind
  most non-obvious decisions and the field bugs behind them.
- [docs/SPEC-VALIDATION.md](docs/SPEC-VALIDATION.md) — line-by-line
  validation against PIMA's specification, plus suggested additions.
- [docs/NOTIFICATIONS.md](docs/NOTIFICATIONS.md) — how to get push
  notifications for alarms and faults (Push Notification agent + 4Sight), and
  what the driver can and cannot do about it.
- [CHANGELOG.md](CHANGELOG.md) — version history.

## Credits

- [homebridge-pima-force](https://github.com/electricmonk/homebridge-pima-force)
  — the original reference for the PIMA JSON protocol.
- [amithalp/pima-force-ha-integration](https://github.com/amithalp/pima-force-ha-integration)
  — an independent, physically-validated Home Assistant integration whose
  documentation confirmed the zone-status bit layout, the arm `order` value,
  the real heartbeat cadence and the ACK-without-apply bypass failure mode.
- PIMA Electronic Systems — the *Force Interface JSON Format Specification*.
- Konnected's Security System Mirror driver — the reference for Control4's
  own security proxy behaviour.

## License

[MIT](LICENSE).
