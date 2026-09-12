# Push notifications for alarms and faults

Research into sending Control4 push notifications from this driver, the way
the DoorBird driver appears to. Sources are linked; where something is my
reconciliation of two sources rather than a documented fact, it says so.

---

## Summary

**A driver cannot raise a Control4 push notification from Lua.** There is no
such API. What sends push notifications is the **Push Notification agent**,
triggered from Composer programming, and it requires 4Sight — which you have.

The good news: **this needs no driver changes to start working.** The driver
already fires 44 programming events, including every alarm and trouble, and
those are exactly what the agent consumes. Alarm and fault notifications can
be wired up today.

The real driver-side work is *more events to trigger on* — several panel
conditions worth notifying about currently arrive as the generic "Unmapped
Panel Event".

---

## What the research found

### There is no outbound notification API in DriverWorks

The [DriverWorks API reference](https://control4.github.io/docs-driverworks-api/)
has no `SendNotification`, `NotifyEvent` or equivalent. Its only
notification-related functions are for *supplying attachments* to a
notification someone else is sending:

- `GetNotificationAttachmentURL`
- `GetNotificationAttachmentFile`
- `GetNotificationAttachmentBytes`
- `FinishedWithNotificationAttachment`

That is an image-provider interface — how a camera driver puts a snapshot
into a notification — not a way to raise one.

Corroborating evidence: third-party drivers exist purely to add notification
capability, such as
[Generic Push Notification Images](https://drivercentral.io/platforms/control4-drivers/generic-push-notification-images/),
whose documentation describes going "to the push notifications agent and
select the push notification you want to add the image to… add an attachment
and select the + icon by this driver." A driver that could send notifications
itself would not need to plug into the agent this way.

### The supported mechanism is the Push Notification agent

From Control4's
[agent types documentation](https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/agent_types.htm):
the **Push Notification agent** lets you "define a push notification to be
sent to your mobile devices as defined in programming", and **requires a
4Sight subscription**.

So the chain is:

```
panel event  →  driver fires a programming event  →  Composer programming
             →  Push Notification agent  →  your phone
```

The driver's job is the first two steps, and it already does them.

The sibling [Email Notification agent](https://docs.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/using_the_email_notification.htm)
works identically for email, also requiring 4Sight, and its documentation
confirms the trigger model: pick an event in the Programming view, drag it
onto the notification action.

It also carries a warning worth heeding here: do not attach notifications to
frequently occurring events, as the volume can degrade the system. On this
panel that means **do not notify on Zone Opened/Closed** — the motion
detectors alone would generate hundreds a day. (Same reason the driver has a
**Quiet Zones** setting for the app's History.)

### About the DoorBird comparison

DoorBird's own
[documentation](https://drivercentral.io/images/CinSiteIcons/DoorBird/Doorbird_documentation.pdf)
describes a built-in push action that "does not require 4Sight", and points
homeowners at `customer.control4.com` → *My Notifications* to choose which
devices receive them, by area, category and severity.

That appears to contradict the agent requiring 4Sight. **My reconciliation —
stated as inference, not verified:** doorbells and cameras are a special case
in Control4. There is a dedicated **Doorbell agent**, and doorbell press with
camera snapshot is a first-class notification path in the OS, which is why it
behaves differently from a general driver-raised notification. An alarm panel
gets no equivalent special treatment.

What is common to both is the delivery side: notifications reach your phone
through the same Control4 account infrastructure, and if they never arrive at
all, the first thing to check is that push is enabled for the right devices at
`customer.control4.com`.

---

## What you can wire up today

No driver changes needed. In Composer Pro:

1. Add a notification in the **Push Notification agent** with the message text
   you want (for example, "Alarm — Main partition").
2. In **Programming**, select the driver's event under Device Events.
3. Drag the agent's *Send Notification* action into the script.

The events worth notifying on, from the 44 the driver exposes:

| Priority | Events |
| --- | --- |
| **Alarms** | `Partition N Alarm`, `Partition N Alarm Restored`, `Fire Alarm`, `Medical Alarm`, `Panic Alarm`, `Duress Alarm`, `Tamper Alarm` (+ their Restored pairs) |
| **Faults** | `AC Power Lost` / `Restored`, `Low Battery` / `Restored`, `Communication Trouble` / `Restored` |
| **Arming** | `Partition N Armed` / `Disarmed`, or the specific mode events |
| **Avoid** | `Zone Opened` / `Zone Closed` — far too frequent |

`Duress Alarm` deserves particular thought: it means someone entered a code
under coercion, so a silent, discreet notification is usually the point.

### One open question

Whether the Push Notification agent's message text can include **dynamic
values** — so a notification could read "Alarm on Kitchen Door" rather than a
fixed "Alarm" — is **not documented anywhere I could find**, and I could not
confirm it either way.

If it cannot, the workaround is one notification per event type, which the
driver's event list already supports at a reasonable granularity (fire vs
panic vs burglary vs tamper). The driver also keeps `Last Zone Name`,
`Last Zone Number`, `Last Event Summary` and `Recent Activity` as properties,
so the detail is available in the app immediately after the alert even if the
alert text itself is static.

Worth ten minutes in Composer to test before designing around it.

---

## What is worth adding to the driver

Since the driver's contribution is *events*, the useful work is surfacing
panel conditions that currently fall into the generic `Unmapped Panel Event`.
From [SPEC-VALIDATION.md](SPEC-VALIDATION.md) §3.1, in the order I would do
them for notification value:

1. **`421` Access Denied** — an invalid code was tried. Squarely worth a
   notification, and currently invisible.
2. **`381` / `384` wireless zone supervision loss and low battery** — a
   wireless detector that has dropped off or is dying is a silent hole in
   coverage. Arguably the single most valuable addition, because nothing else
   tells you.
3. **`344` wireless jamming** — an attack indicator.
4. **`373` wireless detector trouble** — end-of-life, low sensitivity,
   clean-me. Maintenance rather than security.
5. **`138` pre-alarm**, **`143`/`145` expander faults**, **`350`/`351` comm
   faults**, **`312`/`321`/`322` aux voltage and siren troubles** — system
   health.
6. **`412` remote upload/download** — someone is reprogramming the panel
   remotely.

Each is a constant, a dispatch branch and an event declaration — small,
individually testable additions.

A second, larger option: route the per-zone trouble bits the driver already
decodes from zone status (tamper, supervision loss, low battery, alarmed —
all confirmed in the spec's Appendix C) into the security proxy's
`TROUBLE_START` / `TROUBLE_CLEAR`, which the driver already knows how to
send. That surfaces detector faults in the app's own trouble list as well as
making them available to programming.

---

## Recommendation

1. **Try it now** with the existing events — alarms and the three fault pairs.
   That covers most of what you asked for and costs nothing but Composer time.
2. **Test whether notification text can be dynamic**, since that shapes how
   many separate notifications you need.
3. **Then decide** whether the extra events above are worth adding. My
   suggestion would be 421 and 381/384 first: they are the conditions you
   currently cannot know about at all, which makes them the ones where a
   notification adds the most.

---

## Programming recipes

Control4 programming is drag-and-drop, not text: pick an event in the left
pane of Composer's **Programming** view, then drag actions into the script on
the right. The scripts below are written as `WHEN` / `THEN` for clarity.

### The whole notification setup, in two scripts (v30)

Wiring one script per event across 44 events is not a reasonable ask, so the
driver now offers consolidated hooks. **`Any Alarm`** fires for every
alarm-class condition — burglary, fire, medical, panic, duress, tamper, on any
partition — and **`Any Trouble`** for every fault, including the panel
connection being lost. The specific events still fire alongside, so nothing
existing breaks and per-condition scripts remain possible for anyone who wants
them.

```
WHEN   PIMA FORCE  →  Any Alarm
THEN   Push Notification  →  Send "Security alarm"

WHEN   PIMA FORCE  →  Any Trouble
THEN   Push Notification  →  Send "Panel trouble"
```

That is the complete setup. Alongside each, the driver sets two variables
describing what actually happened:

| Variable | Example |
| --- | --- |
| `ALERT_TYPE` | `Fire`, `Burglary`, `Tamper`, `AC Power`, `Panel Offline` |
| `ALERT_TEXT` | `Fire alarm -- Kitchen Smoke`, `Mains power lost` |

If the Push Notification agent can interpolate a variable into its message,
those two scripts give fully specific alerts. If it cannot, the detail is one
glance away in the app and usable in programming conditions either way. That
question is still untested — see below.

### Splitting by severity

If one notification for all alarms is too blunt, the specific events are still
there. A reasonable middle ground is three scripts:

```
WHEN   Fire Alarm      →  THEN  Push  →  "FIRE ALARM"
WHEN   Any Alarm       →  THEN  Push  →  "Security alarm"
WHEN   Any Trouble     →  THEN  Push  →  "Panel trouble"
```

### Duress — discreet by design

Duress means a code was entered under coercion. The script must be silent: no
announcement, no lights, nothing observable in the house. It is included in
`Any Alarm`, so if you want it handled differently, give it its own script and
keep the generic one for the rest.

```
WHEN   PIMA FORCE  →  Duress Alarm
THEN   Push Notification  →  Send "Check in"
```

### The panel going offline

New in v30, and worth its own script even though it is included in
`Any Trouble`: if the panel stops talking to Control4, the system is not being
monitored through it.

```
WHEN   PIMA FORCE  →  Panel Connection Lost
THEN   Push Notification  →  Send "Alarm panel offline"
```

### Mains power, without crying wolf

A brief flicker should not wake you. Gate it behind the **Timer agent**:

```
WHEN   AC Power Lost        →  THEN  Timer "Mains Outage" → Start (10 min)
WHEN   AC Power Restored    →  THEN  Timer "Mains Outage" → Stop
WHEN   Timer "Mains Outage" expires  →  THEN  Push → "Mains power out for 10 minutes"
```

### Conditionals

The driver publishes partition state as variables, so programming can test it
directly — no Variables-agent bookkeeping:

| Variable | Type | Example |
| --- | --- | --- |
| `PARTITION_1_ARMED` | BOOL | `true` |
| `PARTITION_1_STATE` | STRING | `Armed Away (Full Arm)` |
| `PANEL_CONNECTED` | BOOL | `true` |

```
WHEN   PIMA FORCE  →  Zone Opened
THEN   IF  PIMA FORCE  →  PARTITION_1_ARMED is True
         Lighting  →  Flash exterior lights
```

Because these are set from the same place that publishes state to the app,
they cannot drift out of step with what the shield shows.

> **v30-v39: the BOOL variables never held a value.** Director's variable API
> takes strings only, and those three were written with Lua booleans, so every
> write threw and was swallowed by a `pcall`. `PARTITION_n_ARMED`,
> `PANEL_CONNECTED` and `EVENTS_ENABLED` read empty for that whole span; the
> STRING variables (`PARTITION_n_STATE`, `ALERT_*`, `LAST_TROUBLE_*`) were
> always fine. Fixed in v40. If you built programming against a BOOL variable
> during those versions and it never fired, this was why -- it will work now
> without any change on your side.

### What to avoid

- **Do not notify on `Zone Opened` / `Zone Closed`.** Motion detectors alone
  produce hundreds a day, and Control4's documentation warns that
  high-frequency notification triggers degrade the system. Use them for
  automations, gated on `PARTITION_N_ARMED`.
- **Do not put announcements or lighting in the duress script.**

## Still open: dynamic notification text

Whether the Push Notification agent can interpolate a variable such as
`ALERT_TEXT` into its message is not documented anywhere I could find. The
existence of third-party drivers that add richer notification content
suggests the stock agent's text may be static, but that is inference.

Ten minutes in Composer settles it, and the answer decides between one
notification for everything and a handful split by type. The driver supports
both.

## A possible zero-script path, not yet attempted

`C4:SendToDevice(deviceId, command, params)` exists in the DriverWorks API,
and agents are devices with device IDs. In principle the driver could call the
Push Notification agent directly, needing no programming at all.

What is missing is the agent's command name and parameters, neither of which
is documented. `C4:GetDevices()` would let the driver enumerate the project
and find the agent. This is worth an experiment — the same way
**Partition Display Text** was added as a one-property test rather than a
shipped guess — but it is not implemented, and the two-script setup above
works today without it.
