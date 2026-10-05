# PIMA FORCE Alarm Panel

A Control4 driver for **PIMA FORCE** alarm panels. It talks directly to the
panel over the panel's own local JSON interface. There's no cloud service,
bridge or extra hardware.

Arming, disarming, live zone status, bypass, troubles and alarms all appear in
the Control4 app through Control4's standard security screens. The same
events and variables are available in Composer programming.

> Independent community driver. It isn't made or supported by PIMA Electronic
> Systems or Snap One / Control4.

## Contents

- [Before you start](#before-you-start)
- [Setting up the panel](#setting-up-the-panel)
- [Setting up the driver](#setting-up-the-driver)
- [Zones](#zones)
- [Using it in the app](#using-it-in-the-app)
- [Programming and notifications](#programming-and-notifications)
- [Troubleshooting](#troubleshooting)
- [What Control4 can and cannot do here](#what-control4-can-and-cannot-do-here)
- [Reference: properties, actions and events](#reference)

## Before you start

- A PIMA FORCE panel whose firmware includes the **JSON interface**. Not
  every build has it, so check with PIMA or your installer.
- Control4 OS 3.3 or newer.
- A panel user code with rights to arm and disarm each partition you'll
  control.

## Setting up the panel

The panel is the one that makes the connection. It dials out to a
monitoring-station receiver, and this driver plays the receiver. So there's
no panel IP address to enter in Composer. Instead, you point the panel at the
Control4 controller.

On the panel, go to *Installer Code → System Configuration → CMS &
Communication → Monitoring Station → CMS2 or CMS3 → Comm. Paths → Network*
and set:

| Setting | Value |
| --- | --- |
| IP / host | The Control4 controller's IP address |
| Port | Same as the driver's **Listen Port** (default `7780`) |
| Protocol | `JSON` |
| Account ID | Same as the driver's **Account ID** |
| Zone/Output Toggle | `ON`. Without it there are no zone open/close events. |
| Remote Disarm | `ON`. Without it the driver can't disarm. |

Use an account ID that no real monitoring-station path uses.

## Setting up the driver

1. Add the driver to the project and put it in a room.
2. Set **Listen Port** and **Account ID** to match the panel.
3. Set **Partitions Config**, with one entry per partition, separated by `;`:

   ```
   id,name,userCode,modes
   ```

   `modes` is any mix of `A` (Away), `S` (Stay) and `N` (Night). Disarm is
   always allowed. For example: `1,Main,1234,ASN;2,Garage,9876,A`
4. Wait for the panel to connect. **Connection Status** changes to
   `Connected`.

**That's it for zones.** On its first connection the driver reads the zone
numbers and names from the panel and builds the zone list itself. You only
touch **Zones Config** to change something the panel can't know, such as a
zone's icon type. See [Zones](#zones).

> **User codes are stored as plain text** in Partitions Config, so anyone
> with Composer access can read them. The driver never writes them to the
> log.

## Zones

### Where the zone list comes from

The driver keeps the zone list in its own **zone store**, which Control4
saves with the driver. It survives driver updates and controller restarts,
and it isn't shown in Composer's property list, which keeps that list quick.

- **The panel provides the zones.** Once each time the driver loads, on the
  first connection, it reads the zone names and adds any zone it doesn't
  know yet. Run **Refresh Zones From Panel** to do this immediately after
  adding zones at the panel.
- **Names you set are kept.** A zone the driver already knows is never
  renamed by the panel. That covers names you corrected by hand, and names
  you changed in the app.
- **Zones are never removed silently.** If the panel stops reporting a zone,
  the log says so and the zone stays until you hide it (see below).
- **Run List Zones** to print the whole table to the log. It shows each
  zone's number, name, type and partition, plus where each value came from.

### Zones Config holds only your changes

**Zones Config** is for overrides only. Leave it empty unless something needs
changing. Each entry is `zone,name,type,partition`, entries are separated by
`;`, and **an empty field keeps what the zone store has**.

| You want to | Enter |
| --- | --- |
| Show zone 5 with a motion icon | `5,,motion` |
| Put zone 7 in partition 2 | `7,,,2` |
| Rename zone 12 | `12,Garage Side Door` |
| Remove zone 9 from the app | `9,,hidden` |
| All four at once | `5,,motion;7,,,2;12,Garage Side Door;9,,hidden` |

**Types** only set the icon in the app. They never change how the panel
behaves. The available types are `contact`, `door`, `window`, `interior`,
`motion`, `fire`, `gas`, `co`, `heat`, `leak` / `water`, `smoke`,
`pressure`, `glass`, `gate`, `garage` and `hidden`. A zone with no partition
belongs to the lowest configured partition.

### Upgrading from v42 or earlier

You don't need to redo any setup. On the first load of v43 or later, the
driver does the following:

1. Saves your existing Zones Config word for word as a backup, and prints it
   to the log.
2. Imports every zone name into the zone store, and reads it back to confirm
   it was saved.
3. Shortens Zones Config to only the entries that differ from the defaults,
   such as your manual types and any zone outside the default partition.

The zones in the app come out exactly as they were. On the first connection
afterwards, any zone the panel has but your old list left out is added as
`N,,hidden`, so it stays out of the app. Delete that entry to show it.

**After updating, run List Zones once and compare it with what you expect.** If anything looks
wrong, run **Restore Zones Config**. It puts back the original text, and the
driver then uses Zones Config alone, as v42 did.

If a step fails, the driver changes nothing and keeps using Zones Config as
before. That includes a controller without persistent storage and a store
that doesn't read back as written.

## Using it in the app

### Arming and disarming

Away, Stay and Night can be armed from the app for each partition, limited to
the modes allowed in **Partitions Config**. The driver also recognises Home3,
Home4 and Shabbat when they're set at the keypad.

- **Nothing is assumed.** The panel's acknowledgement only means it received
  the command. After a disarm, the driver asks the panel for its state and
  updates the app from the answer.
- **A failed arm or disarm is shown as failed.** The previous state isn't
  left on screen.

### Exit delay

After you arm from the app or from programming, the app shows the panel's
exit delay as a countdown with a **Cancel** button. The length is read from
the panel, so there's nothing to set. When the countdown ends, the driver
asks the panel what happened:

- **Armed:** the app shows armed.
- **Still disarmed:** usually a zone was open at the end of the delay. The
  app is told the arm **failed**.
- **No answer:** the app shows Unknown. The driver never assumes Disarmed.

Pressing Cancel, disarming at a keypad, losing the connection, or an alarm
ends the countdown. A keypad arm has no countdown, because the driver didn't
start it. Use **Exit Delay Countdown** to limit the countdown to Away arming
or turn it off. If the number in the app doesn't count down, set **Exit Delay
Refresh Seconds** to 1–5.

### The status line

The line under the lock on the **Status** tab shows what's currently
switched off:

- `Notifications OFF` while event notifications are muted.
- The names of any bypassed zones, or a count if there are more than three.

**Partition Display Text** adds your own label to the front of this line.

### The Functions menu

| Function | What it does |
| --- | --- |
| Check Status | Re-reads partition and zone state from the panel. |
| Arm All / Disarm All | Every partition, using the panel's all-partitions command. |
| Bypass Open Zones | Bypasses the partition's open zones, skipping **Non-Bypassable Zones**. Checks with the panel that each bypass was applied. |
| Clear All Bypasses | Clears every bypass in the partition. |
| Refresh Troubles | Re-reads the panel's fault list. |
| Disable / Enable Event Notifications | Stops or restarts programming events, for a panel that has started sending a flood of events. Turns itself back on after **Event Mute Minutes**. Live status in the app isn't affected. |

## Programming and notifications

The driver fires a programming event for every arm, disarm, alarm and
trouble. The full list is under [Events](#events).

**Two scripts cover every notification.** **Any Alarm** fires for every
alarm type and **Any Trouble** for every trouble, alongside the specific
event. Put a push notification on each and use the variables below in the
message text.

| Variable | Contains |
| --- | --- |
| `ALERT_TYPE`, `ALERT_TEXT` | What just happened, e.g. `Fire` / `Fire alarm -- Kitchen Smoke`. |
| `LAST_TROUBLE_TYPE`, `LAST_TROUBLE_TEXT` | The last trouble. It isn't overwritten by a later alarm. |
| `PARTITION_n_STATE` | For example `Armed Away (Full Arm)`. |
| `PARTITION_n_ARMED` | `true` / `false`. Use it in conditionals. |
| `PANEL_CONNECTED` | `true` / `false`. |
| `EVENTS_ENABLED` | `false` while notifications are muted. |

Don't send notifications on **Zone Opened** or **Zone Closed**. Motion
detectors alone produce hundreds of these a day. Use them for automations,
checked against `PARTITION_n_ARMED`.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Connection Status never reaches `Connected` | The panel's IP / port point at this controller. The Account IDs match. The protocol is `JSON`. |
| Stuck at "awaiting verification" | The Account ID differs between the panel and the driver. |
| Can't disarm from the app | **Remote Disarm** is `ON` at the panel, and the partition's code has disarm rights. |
| Partition shows Offline while zones still update | The driver keeps re-asking the panel for the state, so it clears on its own within a few minutes. **Sync Partition States** (Actions) asks immediately. |
| No zone open/close in the app | **Zone/Output Toggle** is `ON` at the panel. |
| Zone names garbled or reversed | Adjust **Zone/User Name Encoding** or **Reverse Zone/User Names**, then add name overrides for the affected zones. |
| A zone is missing | Run **Refresh Zones From Panel**, then **List Zones**. |
| Notification text is empty | Run **Report Variables** and check the log. |
| Something went wrong earlier | **Recent Activity** shows the newest entries. **List Recent Activity** prints the last 25. |

Set **Log Level** to `Debug` to see every message to and from the panel.
User codes are always masked, so a debug log is safe to share.

## What Control4 can and cannot do here

- **You can't bypass a zone by tapping it in the app.** Control4's Zones
  screen only shows status. Use **Bypass Open Zones** in the Functions menu,
  or the **Bypass Zone** action in programming.
- **Zone open/close events fill the app's History.** One notification drives
  both the live zone list and the History entry. Use **Quiet Zones** on
  detectors that only add noise.
- **There's no Emergency button.** PIMA's interface has no command to raise a
  fire, medical or police alarm.
- **The zone list heading may read UNKNOWN.** The panel doesn't report
  partition names, and the driver can't change that heading.

<!-- REFERENCE -->
