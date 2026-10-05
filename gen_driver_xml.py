#!/usr/bin/env python3
"""Generates driver.xml for the PIMA FORCE Control4 driver.
Repetitive per-partition properties/events are templated to avoid hand-typing
errors across 8 partitions. Structure (element order/nesting) is modeled
directly on Control4's own official generic_http sample driver.xml:
  <devicedata>
    <config>
      <script/> <documentation/> <properties/> <commands/> <actions/>
    </config>
    <proxies/>
    <events/>
  </devicedata>
"""

# How many partitions get a dedicated Control4 surface: a "Partition N State"
# property, a set of named programming events, a Security Partition proxy
# binding, and its room-selection connection.
#
# MUST MATCH `MAX_DECLARED_PARTITIONS` in driver.lua. They are two constants
# in two files describing one thing: if driver.lua is higher, the driver sends
# notifications to proxy bindings that do not exist; if it is lower, the extra
# bindings are declared in Composer but never updated. `test_regressions.lua`
# parses the generated driver.xml and fails if the two disagree.
#
# Raising this is cheap (regenerate and rebuild); it costs 7 events, 1
# property, 1 proxy and 2 connections per partition, and every declared
# partition shows up in Composer whether or not it is configured (unconfigured
# ones are disabled at runtime via PARTITION_ENABLED=false).
MAX_PARTITIONS = 3

# Driver version. Composer Pro's "Update Drivers" only offers a driver whose
# <version> is HIGHER than the one already in the project -- so this MUST be
# incremented for every build you hand to an installer, or Composer may keep
# running the previously installed copy and none of your changes take effect.
#
# MUST MATCH `DRIVER_VERSION` in driver.lua, which logs it at startup so the
# log proves which build is actually loaded. test_regressions.lua fails if
# the two drift apart.
DRIVER_VERSION = 47

# Arm-mode labels, carrying both the Control4-conventional name and PIMA's own
# name for the same mode (as shown on the panel keypad and in PIMA's
# programming software). Used for the arm_states capability, the Arm actions
# and the per-partition events, so all three read the same way.
#
# MUST MATCH ARM_LABEL_AWAY / ARM_LABEL_STAY / ARM_LABEL_NIGHT in driver.lua.
# test_regressions.lua parses the generated driver.xml and fails on drift.
ARM_LABEL_AWAY = 'Away (Full Arm)'
ARM_LABEL_STAY = 'Stay (Home1)'
ARM_LABEL_NIGHT = 'Night (Home2)'

import datetime
import html as htmllib
import os

HERE = os.path.dirname(os.path.abspath(__file__))

# Regenerated on every build so Composer sees a fresh modified stamp.
BUILD_TIME = datetime.datetime.now().strftime('%m/%d/%Y %H:%M')

def esc(s):
    return (s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;'))

properties = []
# Plain metadata alongside the XML, so the Documentation tab's reference
# section is generated from the same definitions and cannot drift.
property_meta = []

def add_property(name, ptype, default='', readonly=False, description='', minimum=None, maximum=None, items=None):
    property_meta.append(dict(name=name, ptype=ptype, default=default, readonly=readonly,
                              description=description, minimum=minimum, maximum=maximum, items=items))
    lines = ['\t\t\t<property>']
    lines.append(f'\t\t\t\t<name>{esc(name)}</name>')
    lines.append(f'\t\t\t\t<type>{ptype}</type>')
    if minimum is not None:
        lines.append(f'\t\t\t\t<minimum>{minimum}</minimum>')
    if maximum is not None:
        lines.append(f'\t\t\t\t<maximum>{maximum}</maximum>')
    if items:
        lines.append('\t\t\t\t<items>')
        for it in items:
            lines.append(f'\t\t\t\t\t<item>{esc(it)}</item>')
        lines.append('\t\t\t\t</items>')
    lines.append(f'\t\t\t\t<default>{esc(str(default))}</default>')
    lines.append(f'\t\t\t\t<readonly>{"true" if readonly else "false"}</readonly>')
    if description:
        lines.append(f'\t\t\t\t<description>{esc(description)}</description>')
    lines.append('\t\t\t</property>')
    properties.append('\n'.join(lines))

# --- Connection / identity ---
add_property('Listen Port', 'RANGED_INTEGER', 7780, minimum=1, maximum=65535,
    description='TCP port this driver listens on for the panel to dial into. Must match the port set in the panel CMS network comm path (Installer Code -> System Configuration -> CMS & Communication -> Monitoring Station -> CMS2/3 -> Comm.Paths -> Network), with Protocol set to JSON.')
add_property('Account ID', 'RANGED_INTEGER', 1234, minimum=0, maximum=999999,
    description='Account ID configured on the panel CMS path for this comm path. Use an ID not shared with any other CMS/monitoring-station path on the panel.')
add_property('Partitions Config', 'STRING', '1,Main,1234,ASN',
    description='One entry per partition, separated by ";": id,name,userCode,modes. modes is any combination of A(way) S(tay/Home1) N(ight/Home2) - Disarm is always allowed. Example: 1,Main,1234,ASN;2,Garage,9876,A')
add_property('Zones Config', 'STRING', '',
    description='OVERRIDES only - leave empty unless something needs changing. The zone list itself (numbers and names) is read from the panel automatically and kept in the driver\'s zone store, not here. Each entry is zone,name,type,partition separated by ";", and any field left empty keeps what the zone store has: "5,,motion" sets zone 5\'s icon; "7,,,2" puts zone 7 in partition 2; "12,Garage Side Door" renames zone 12; "9,,hidden" removes zone 9 from the app. type sets the app icon only (never panel behaviour): contact, door, window, interior, motion, fire, gas, co, heat, leak/water, smoke, pressure, glass, gate, garage, or hidden. Zones with no partition use the lowest configured partition. Run "List Zones" (Actions) to see the full table in the log. When upgrading from v42 or earlier, the old full list is imported automatically and this field is shortened to just your changes; "Restore Zones Config" puts the original back.')
add_property('Zone Bypass Auto-Clear Minutes', 'RANGED_INTEGER', 30, minimum=0, maximum=1440,
    description='When a zone is bypassed via the "Bypass Zone" action, automatically clear the bypass after this many minutes so a forgotten bypass does not leave a detector permanently disabled. 0 disables auto-clear.')
add_property('Zone/User Name Encoding', 'LIST', 'Windows-1255', items=['Windows-1255', 'UTF-8'],
    description='Text encoding the panel uses for zone/user names read from the panel. Windows-1255 is correct for Israeli FORCE panels with Hebrew names (the default). Use UTF-8 for English-only/non-Hebrew panels. If discovered names show as garbled text or "?", try switching this.')
add_property('Reverse Zone/User Names', 'LIST', 'Off', items=['Off', 'On'],
    description='Some panels store names in "visual order" (LCD left-to-right pixel order) rather than logical reading order, which comes out letter-reversed for Hebrew once decoded. Turn On only if zone names read from the panel come back backwards.')
add_property('Log Level', 'LIST', 'Info', items=['Error', 'Warning', 'Info', 'Debug'],
    description='How much this driver writes to Composer Pro\'s Lua Output and Director\'s log. Error: only things that failed. Warning: also things that look wrong but were handled. Info (default): also connection, arming and event activity. Debug: also a full frame-level trace of everything sent to and received from the panel, and it un-hides the read-only diagnostic properties. User codes are redacted at every level, so traces are safe to share.')
add_property('Non-Bypassable Zones', 'STRING', '',
    description='Zones that must NEVER be bypassed, as a comma-separated list of zone NUMBERS and/or type words - for example "smoke,fire" or "13,14". Life-safety detectors (smoke, fire, gas, co, heat) are the usual entries. This is enforced by the driver wherever a bypass comes from: the Functions menu\'s "Bypass Open Zones" skips these zones and says so, and a bypass requested from the Actions tab or from programming is refused and reported. Clearing a bypass is never blocked, whatever is listed here, so a zone bypassed at the panel keypad can always be restored. It also sets each zone\'s can_bypass flag in the zone document - note that the Control4 app\'s Zones screen has no per-zone bypass control to hide or show, so that flag currently changes nothing visible; the enforcement above is the part that matters. Leave empty (the default) to allow every zone to be bypassed.')
add_property('Quiet Zones', 'STRING', '',
    description='Zones that should NOT report open/close to the app, as a comma-separated list of zone NUMBERS and/or type words - for example "motion" or "4,12" or "motion,12". The Control4 app builds its History list from the same notifications that drive the live zone list, and the protocol has no way to say "update the status but do not log this", so a house with motion detectors fills History with open/close rows. A quiet zone still appears in the zone list (shown permanently as Normal), still tracks its state internally, and still fires its Control4 programming events, so automations keep working - it just stops pushing updates, which is what stops the History rows. Zone numbers are the reliable form: the app draws motion and interior zones with the same icon, so a type word may not match what Zones Config actually says. On every reload the log states which zones matched, or warns that none did. Leave empty to report every zone.')
add_property('Zone State Reporting', 'LIST', 'Partition + Panel', items=['Partition + Panel', 'Partition only', 'Panel only', 'Off'],
    description='Which proxy notifications carry live zone open/close. CONFIRMED ON REAL HARDWARE: ZONE_STATE (sent to the partition) drives BOTH the app History rows and the live open/closed indication in the zone list, while PANEL_ZONE_STATE (sent to the panel) drives neither - setting this to "Panel only" produced a clean History and a zone list with no open indication at all. So History noise and live zone status cannot be separated with this setting: they are the same notification. Use "Quiet Zones" instead to silence individual noisy zones while the rest stay live. "Partition only" is the efficient choice (half the proxy traffic, no observed loss); "Panel only" and "Off" both cost you live zone status.')
add_property('Partition Display Text', 'STRING', '',
    description='Fixed text shown on the partition status line in the app - the line on the Status tab, below the lock indicator. Leave empty for none. The driver appends its own status to this line: "Notifications OFF" while event notifications are muted, and the names of any bypassed zones in that partition. So "Ground floor" here can read "Ground floor | Bypassed: Patio Door" in the app. (Originally added as an experiment against the Zones-tab "UNKNOWN" heading. It does not fill that heading - nothing on the driver side does - it renders on the Status tab instead, which turned out to be the more useful place.)')
add_property('Exit Delay Countdown', 'LIST', 'Auto - all arm modes', items=['Auto - all arm modes', 'Auto - Away only', 'Off'],
    description='Shows the panel exit delay as a live countdown in the app (with its Cancel button) after you arm from the app or from programming. The length is read from the panel itself (exit time, parameter 180), so there is nothing to type in; if the panel has no exit delay configured, no countdown is shown. "Auto - Away only" limits it to Away arming for panels whose Stay/Night modes arm instantly. When the countdown ends the driver asks the panel what actually happened: armed is shown armed, and if the panel is still disarmed (an open zone at the end of the delay, typically) the app is told the arm failed. An arm made at the keypad has no countdown, because this driver did not start it. Off restores the previous behaviour of jumping straight to armed.')
add_property('Exit Delay Refresh Seconds', 'RANGED_INTEGER', 0, minimum=0, maximum=30,
    description='Leave at 0 unless the countdown in the app sits still. The driver sends the remaining time once, when the exit delay starts, and the app is expected to count down by itself. If the number shown does not tick, set this to 1-5 and the driver will resend the remaining time at that interval. Each resend is a few messages to the Control4 Director, so use the largest value that looks smooth.')
add_property('Event Mute Minutes', 'RANGED_INTEGER', 60, minimum=0, maximum=1440,
    description='How long "Disable Event Notifications" (Functions menu in the app) stays in effect before the driver re-enables events by itself. A mute that is forgotten on a security system is its own hazard - after this many minutes, programming events and notifications resume automatically. 0 means stay muted until re-enabled by hand, which is not recommended. Muting only stops programming events; live status in the app - armed state, zone open/closed, the shield - is never affected, and while muted the partition status line on the app\'s Status tab reads "Notifications OFF" so the mute is visible rather than silent.')
add_property('Link Timeout Seconds', 'RANGED_INTEGER', 600, minimum=0, maximum=3600,
    description='Treat the panel as disconnected if nothing at all arrives from it for this many seconds. The panel normally sends traffic (a heartbeat, at minimum) about every 4 minutes, so silence past that means the link is gone - but a socket left half-open (panel powered off, cable pulled, network dropped) never reports a TCP disconnect, and without this the driver would keep reporting Connected forever and no alarm would ever reach Control4. The default of 600 leaves a comfortable margin over the normal ~240s cadence; do not set this below about 300 or ordinary heartbeat gaps risk being flagged as a dropped link. 0 disables the check, which is not recommended.')

# --- Diagnostics (read-only) ---
add_property('Event Notifications', 'STRING', 'Enabled', readonly=True,
    description='Whether the driver is currently firing programming events. Controlled from the app Functions menu (Disable / Enable Event Notifications) and auto-re-enabled after Event Mute Minutes.')
add_property('Connection Status', 'STRING', 'Not Connected', readonly=True,
    description='Not Connected / Client Connected (awaiting verification) / Connected.')
add_property('Panel Verified Account', 'STRING', '', readonly=True,
    description='Account ID the currently-connected panel presented, once verified.')
add_property('Zones Summary', 'STRING', '', readonly=True,
    description='How many zones the driver knows, by type, and how many overrides Zones Config holds. The full list is printed by the "List Zones" action.')
add_property('Last Event Type', 'STRING', '', readonly=True, description='Raw CID event type code of the last panel event (Appendix A of the PIMA JSON spec).')
add_property('Last Event Qualifier', 'STRING', '', readonly=True, description='Raw qualifier of the last panel event (1=new/alarm/disarm, 3=restore/arm).')
add_property('Last Event Zone', 'STRING', '', readonly=True, description='Zone field of the last panel event.')
add_property('Last Event Partition', 'STRING', '', readonly=True, description='Partition field of the last panel event.')
add_property('Last Event Summary', 'STRING', '', readonly=True, description='Human-readable summary of the last event this driver did not have a specific mapping for.')
add_property('Last Zone Number', 'STRING', '', readonly=True, description='Zone number from the most recent zone open/close/bypass event.')
add_property('Last Zone Name', 'STRING', '', readonly=True, description='Zone name (from Zones Config) for Last Zone Number.')
add_property('Last Zone Partition', 'STRING', '', readonly=True, description='Partition reported by the panel for the most recent zone event.')
add_property('Last Output Number', 'STRING', '', readonly=True, description='Output number from the most recent output activated/deactivated event.')
add_property('Last NAK Reason', 'STRING', '', readonly=True, description='Reason string from the most recent NAK the panel sent (Appendix D).')
add_property('Recent Activity', 'STRING', '', readonly=True,
    description='Rolling log of the last 25 security-relevant events (connection changes, arm/disarm, alarms, troubles, command failures), newest first, with timestamps. Deliberately excludes routine zone open/close so arm/disarm/alarm activity is not buried - use the Zones tab or Control4\'s own History for per-zone traffic. In-memory only: cleared on every driver reload. User codes are redacted.')
add_property('Last Command Result', 'STRING', '', readonly=True,
    description='Outcome of the most recent arm/disarm/bypass command this driver sent to the panel: whether the panel accepted it, or why it failed (wrong code, no connection, timeout). Check this first when a command appears to do nothing.')
add_property('Last Raw Frame In', 'STRING', '', readonly=True, description='Most recent frame received from the panel, re-encoded as JSON. For diagnostics.')
add_property('Driver Version', 'STRING', '', readonly=True)

for i in range(1, MAX_PARTITIONS + 1):
    add_property(f'Partition {i} State', 'STRING', 'Unknown', readonly=True,
        description=f'Current known state of partition {i}: Unknown / Disarmed / Armed {ARM_LABEL_AWAY} / Armed {ARM_LABEL_STAY} / Armed {ARM_LABEL_NIGHT} / Armed / Alarm. Mode names carry both the Control4 term and PIMA\'s own name for the same mode.')

# --- Commands + matching Actions (Composer Pro's "Actions" tab entries each
# reference an underlying <command> by name; both are needed - confirmed
# against Control4's own generic_http sample driver.xml) ---
# Each entry: (command_name, description, [(param_name, param_type, {extra_attrs})])
command_defs = [
    (f'Arm {ARM_LABEL_AWAY}', 'Arm the given partition in Away mode - PIMA calls this Full Arm.',
        [('PARTITION', 'RANGED_INTEGER', {'minimum': 1, 'maximum': 16})]),
    (f'Arm {ARM_LABEL_STAY}', 'Arm the given partition in Stay mode - PIMA calls this Home 1.',
        [('PARTITION', 'RANGED_INTEGER', {'minimum': 1, 'maximum': 16})]),
    (f'Arm {ARM_LABEL_NIGHT}', 'Arm the given partition in Night mode - PIMA calls this Home 2.',
        [('PARTITION', 'RANGED_INTEGER', {'minimum': 1, 'maximum': 16})]),
    ('Disarm', 'Disarm the given partition.',
        [('PARTITION', 'RANGED_INTEGER', {'minimum': 1, 'maximum': 16})]),
    ('Bypass Zone', 'Bypass a single zone (parameter 2150). The only way to suppress a 24-hour zone (smoke/flood).',
        [('ZONE', 'RANGED_INTEGER', {'minimum': 1, 'maximum': 144})]),
    ('Clear Bypass', 'Clear a zone bypass.',
        [('ZONE', 'RANGED_INTEGER', {'minimum': 1, 'maximum': 144})]),
    ('Activate Output', 'Activate a panel output (1=external siren, 2=internal siren, 34-41=controlled outputs 1-8).',
        [('OUTPUT', 'RANGED_INTEGER', {'minimum': 1, 'maximum': 41})]),
    ('Deactivate Output', 'Deactivate a panel output.',
        [('OUTPUT', 'RANGED_INTEGER', {'minimum': 1, 'maximum': 41})]),
    ('Sync Partition States', 'Ask the panel for the current arm state of every configured partition and update the driver to match. Runs automatically when the panel connects; use this to re-sync without reloading the driver.', []),
    ('Refresh Zones From Panel', 'Read the zone names from the panel and add any zone the driver does not know yet. Runs automatically once per driver load; use this after adding zones at the panel. Never renames or removes a zone the driver already has - use Zones Config for that.', []),
    ('List Zones', 'Print every zone to the log: number, name, type, partition, and where each came from (panel, Zones Config, or a rename in the app).', []),
    ('List Recent Activity', 'Print the full recent-activity buffer (last 25 entries) to the log. The Recent Activity property shows only the newest few.', []),
    ('Restore Zones Config', 'Put back the full Zones Config you had before upgrading to v43, and stop using the zone store. Only needed if the automatic zone import looks wrong.', []),
    ('Request Zone Status', 'Query current zone status bitfields (parameter 2149) and log a summary.', []),
    ('Report Variables', 'Logs every driver variable and its current value, so a notification that came through with empty text can be diagnosed: either the variables exist and hold values, or they do not.', []),
    ('Request Faults', 'Query current system faults (parameter 2250) and log a summary.', []),
]

def params_block(params, indent):
    if not params:
        return ''
    lines = [f'{indent}<params>']
    for pname, ptype, extra in params:
        lines.append(f'{indent}\t<param>')
        lines.append(f'{indent}\t\t<name>{pname}</name>')
        lines.append(f'{indent}\t\t<type>{ptype}</type>')
        for k, v in extra.items():
            lines.append(f'{indent}\t\t<{k}>{v}</{k}>')
        lines.append(f'{indent}\t</param>')
    lines.append(f'{indent}</params>')
    return '\n' + '\n'.join(lines)

commands = []
actions = []
cmd_indent = '\t\t\t\t'
for name, desc, params in command_defs:
    pblock = params_block(params, cmd_indent)
    commands.append(
        f'\t\t\t<command>\n\t\t\t\t<name>{esc(name)}</name>\n\t\t\t\t<description>{esc(desc)}</description>{pblock}\n\t\t\t</command>'
    )
    actions.append(
        f'\t\t\t<action>\n\t\t\t\t<name>{esc(name)}</name>\n\t\t\t\t<command>{esc(name)}</command>{pblock}\n\t\t\t</action>'
    )

# --- Events (top-level sibling of <config>, per generic_http/driver.xml) ---
events = []
event_id = 1

event_meta = []

def add_event(name, description):
    global event_id
    event_meta.append((name, description))
    events.append(f'\t\t<event>\n\t\t\t<id>{event_id}</id>\n\t\t\t<name>{esc(name)}</name>\n\t\t\t<description>{esc(description)}</description>\n\t\t</event>')
    event_id += 1

for i in range(1, MAX_PARTITIONS + 1):
    add_event(f'Partition {i} Armed {ARM_LABEL_AWAY}', f'Partition {i} was armed in Away mode (PIMA: Full Arm).')
    add_event(f'Partition {i} Armed {ARM_LABEL_STAY}', f'Partition {i} was armed in Stay mode (PIMA: Home 1).')
    add_event(f'Partition {i} Armed {ARM_LABEL_NIGHT}', f'Partition {i} was armed in Night mode (PIMA: Home 2).')
    add_event(f'Partition {i} Armed', f'Partition {i} was armed in another mode (Home 3/4, Shabbat) or the mode could not be determined.')
    add_event(f'Partition {i} Disarmed', f'Partition {i} was disarmed.')
    add_event(f'Partition {i} Alarm', f'Partition {i} is in burglary alarm.')
    add_event(f'Partition {i} Alarm Restored', f'Partition {i} burglary alarm restored.')

generic_events = [
    # Consolidated hooks so a complete notification setup is two programming
    # scripts rather than one per condition. The specific events below still
    # fire as well; these are in addition, never instead.
    ('Any Alarm', 'ANY alarm condition: burglary, fire, medical, panic, duress or tamper, on any partition. Fires alongside the specific event. Use this for a single push-notification script instead of wiring one per alarm type - the ALERT_TYPE and ALERT_TEXT variables say which it was.'),
    ('Any Trouble', 'ANY system trouble: mains power, battery, communications, or the panel connection being lost. Fires alongside the specific event. ALERT_TYPE and ALERT_TEXT describe it.'),
    ('Panel Connection Lost', 'The driver can no longer reach the panel - either the socket closed or nothing arrived for Link Timeout Seconds. The system is not being monitored through Control4 until it returns. Worth a notification.'),
    ('Panel Connection Restored', 'The panel is talking to the driver again.'),
    ('Zone Opened', 'A zone opened. See Last Zone Number / Last Zone Name.'),
    ('Zone Closed', 'A zone closed. See Last Zone Number / Last Zone Name.'),
    ('Zone Bypassed', 'A zone was bypassed (from the keypad or this driver). See Last Zone Number / Last Zone Name.'),
    ('Zone Bypass Cleared', 'A zone bypass was cleared. See Last Zone Number / Last Zone Name.'),
    ('Fire Alarm', 'Fire alarm (zone or pull station).'),
    ('Fire Alarm Restored', 'Fire alarm restored.'),
    ('Medical Alarm', 'Medical alarm.'),
    ('Medical Alarm Restored', 'Medical alarm restored.'),
    ('Panic Alarm', 'Panic alarm (keypad or silent).'),
    ('Panic Alarm Restored', 'Panic alarm restored.'),
    ('Duress Alarm', 'Duress code used.'),
    ('Duress Alarm Restored', 'Duress alarm restored.'),
    ('Tamper Alarm', 'Panel or zone tamper.'),
    ('Tamper Restored', 'Tamper restored.'),
    ('AC Power Lost', 'Panel AC power lost.'),
    ('AC Power Restored', 'Panel AC power restored.'),
    ('Low Battery', 'Panel or zone low battery.'),
    ('Low Battery Restored', 'Low battery restored.'),
    ('Communication Trouble', 'CMS communication path trouble.'),
    ('Communication Restored', 'CMS communication path restored.'),
    ('Output Activated', 'A panel output (e.g. siren) activated. See Last Output Number.'),
    ('Output Deactivated', 'A panel output deactivated.'),
    ('Unmapped Panel Event', 'A panel event this driver does not have a specific mapping for. See Last Event Type/Qualifier/Zone/Partition or Last Event Summary.'),
]
for name, desc in generic_events:
    add_event(name, desc)

# --- Native Control4 Security proxy (Security Panel + one Security
# Partition proxy per declared partition). Proxy type strings
# ("securitypanel" / "security"), the <connections> classnames
# (SECURITY_PANEL / SECURITY / SECURITY_SYSTEM room-selection autobind),
# and the <capabilities> shape below are all confirmed from a real shipped
# Control4 security driver (Konnected Security System Mirror .c4z), not
# guessed -- see README.md "What's verified vs. what to double-check".
# Binding IDs: panel = 5001, partition N = 5001+N (matches
# PANEL_PROXY_BINDINGID / PartitionProxyBindingID() in driver.lua).
PANEL_PROXY_BINDINGID = 5001

proxies = [f'\t\t<proxy proxybindingid="{PANEL_PROXY_BINDINGID}">securitypanel</proxy>']
for i in range(1, MAX_PARTITIONS + 1):
    proxies.append(f'\t\t<proxy proxybindingid="{PANEL_PROXY_BINDINGID + i}">security</proxy>')

connections = [f'''\t\t<connection>
\t\t\t<id>{PANEL_PROXY_BINDINGID}</id>
\t\t\t<facing>6</facing>
\t\t\t<connectionname>Security Panel</connectionname>
\t\t\t<type>2</type>
\t\t\t<consumer>False</consumer>
\t\t\t<audiosource>False</audiosource>
\t\t\t<videosource>False</videosource>
\t\t\t<linelevel>False</linelevel>
\t\t\t<classes>
\t\t\t\t<class>
\t\t\t\t\t<classname>SECURITY_PANEL</classname>
\t\t\t\t</class>
\t\t\t</classes>
\t\t\t<hidden>False</hidden>
\t\t</connection>''']
for i in range(1, MAX_PARTITIONS + 1):
    bindingid = PANEL_PROXY_BINDINGID + i
    connections.append(f'''\t\t<connection>
\t\t\t<id>{bindingid}</id>
\t\t\t<facing>6</facing>
\t\t\t<connectionname>Security Partition {i}</connectionname>
\t\t\t<type>2</type>
\t\t\t<consumer>False</consumer>
\t\t\t<audiosource>False</audiosource>
\t\t\t<videosource>False</videosource>
\t\t\t<linelevel>False</linelevel>
\t\t\t<classes>
\t\t\t\t<class>
\t\t\t\t\t<classname>SECURITY</classname>
\t\t\t\t</class>
\t\t\t</classes>
\t\t\t<hidden>False</hidden>
\t\t</connection>
\t\t<connection proxybindingid="{bindingid}">
\t\t\t<id>{2000 + bindingid}</id>
\t\t\t<facing>6</facing>
\t\t\t<connectionname>Room Selection Partition {i}</connectionname>
\t\t\t<type>7</type>
\t\t\t<consumer>False</consumer>
\t\t\t<audiosource>False</audiosource>
\t\t\t<videosource>False</videosource>
\t\t\t<linelevel>False</linelevel>
\t\t\t<classes>
\t\t\t\t<class>
\t\t\t\t\t<autobind>True</autobind>
\t\t\t\t\t<classname>SECURITY_SYSTEM</classname>
\t\t\t\t</class>
\t\t\t</classes>
\t\t</connection>''')

capabilities = f"""\t<capabilities>
\t\t<can_set_time>false</can_set_time>
\t\t<can_activate_partitions>false</can_activate_partitions>

\t\t<ui_version>2</ui_version>
\t\t<has_fire>false</has_fire>
\t\t<has_medical>false</has_medical>
\t\t<has_police>false</has_police>
\t\t<has_panic>false</has_panic>
\t\t<star_label>*</star_label>
\t\t<pound_label>#</pound_label>
\t\t<button_A>
\t\t\t<visible>False</visible>
\t\t\t<label>A</label>
\t\t</button_A>
\t\t<button_B>
\t\t\t<visible>False</visible>
\t\t\t<label>B</label>
\t\t</button_B>
\t\t<button_C>
\t\t\t<visible>False</visible>
\t\t\t<label>C</label>
\t\t</button_C>
\t\t<button_D>
\t\t\t<visible>False</visible>
\t\t\t<label>D</label>
\t\t</button_D>

\t\t<arm_states>{ARM_LABEL_AWAY},{ARM_LABEL_STAY},{ARM_LABEL_NIGHT}</arm_states>
\t\t<functions>Check Status,Arm All,Disarm All,Bypass Open Zones,Clear All Bypasses,Refresh Troubles,Disable Event Notifications,Enable Event Notifications</functions>
\t</capabilities>"""

# Composer Pro renders a file referenced here in its Documentation tab.
# Inline text inside <documentation> is shown as plain text, which is why the
# tab used to be one unformatted block. The file is HTML, generated below from
# docs/COMPOSER-GUIDE.md plus reference tables built from this script's own
# property / action / event definitions. The inline text is the fallback for
# viewers that cannot show the file.
DOC_FILE = 'www/documentation/index.html'
documentation_fallback = (
    'PIMA FORCE Alarm Panel driver v' + str(DRIVER_VERSION) + '. Full documentation: ' + DOC_FILE +
    ' inside the driver package.')


xml = f"""<devicedata>
\t<copyright>Provided as a starting point for Efi's own use - not an official PIMA or Control4 product.</copyright>
\t<manufacturer>PIMA (community driver)</manufacturer>
\t<name>PIMA FORCE Alarm Panel</name>
\t<model>FORCE Series</model>
\t<creator>Community</creator>
\t<created>09/04/2026 00:00</created>
\t<modified>{BUILD_TIME}</modified>
\t<version>{DRIVER_VERSION}</version>
\t<small>devices_sm/c4.gif</small>
\t<large>devices_lg/c4.gif</large>
\t<control>lua_gen</control>
\t<driver>DriverWorks</driver>
\t<proxies qty="{len(proxies)}">
{chr(10).join(proxies)}
\t</proxies>
{capabilities}
\t<config>
\t\t<script file="driver.lua"></script>
\t\t<documentation file="{DOC_FILE}"><![CDATA[{documentation_fallback}]]></documentation>
\t\t<properties>
{chr(10).join(properties)}
\t\t</properties>
\t\t<commands>
{chr(10).join(commands)}
\t\t</commands>
\t\t<actions>
{chr(10).join(actions)}
\t\t</actions>
\t</config>
\t<events>
{chr(10).join(events)}
\t</events>
\t<connections>
{chr(10).join(connections)}
\t</connections>
\t<search_types>
\t\t<type></type>
\t</search_types>
\t<composer_categories>
\t\t<category>Security</category>
\t</composer_categories>
</devicedata>
"""

with open(os.path.join(HERE, 'driver.xml'), 'w') as f:
    f.write(xml)

# --- Documentation tab -------------------------------------------------------
def _cell(text):
    return htmllib.escape(str(text))

def _prop_range(m):
    if m['items']:
        return ' / '.join(m['items'])
    if m['minimum'] is not None:
        return f"{m['minimum']}-{m['maximum']}"
    return ''

def reference_html():
    out = ['<h2 id="reference">Reference</h2>',
           '<p>Generated from the driver definition, so it always matches this version.</p>']
    settings = [m for m in property_meta if not m['readonly']]
    status = [m for m in property_meta if m['readonly']]
    out.append('<h3 id="properties">Properties you set</h3>')
    out.append('<table><thead><tr><th>Property</th><th>Default</th><th>Values</th><th>What it does</th></tr></thead><tbody>')
    for m in settings:
        default = m['default'] if str(m['default']) != '' else '(empty)'
        out.append(f"<tr><td><b>{_cell(m['name'])}</b></td><td><code>{_cell(default)}</code></td>"
                   f"<td>{_cell(_prop_range(m))}</td><td>{_cell(m['description'])}</td></tr>")
    out.append('</tbody></table>')
    out.append('<h3 id="status-properties">Status properties (read-only)</h3>')
    out.append('<p>Most of the <i>Last ...</i> properties are hidden unless <b>Log Level</b> is <code>Debug</code>.</p>')
    out.append('<table><thead><tr><th>Property</th><th>Shows</th></tr></thead><tbody>')
    for m in status:
        out.append(f"<tr><td><b>{_cell(m['name'])}</b></td><td>{_cell(m['description'] or '')}</td></tr>")
    out.append('</tbody></table>')
    out.append('<h3 id="actions">Actions</h3>')
    out.append('<table><thead><tr><th>Action</th><th>What it does</th></tr></thead><tbody>')
    for name, desc, params in command_defs:
        p = ', '.join(pn for pn, _, _ in params)
        out.append(f"<tr><td><b>{_cell(name)}</b>{(' <span class=muted>(' + _cell(p) + ')</span>') if p else ''}</td><td>{_cell(desc)}</td></tr>")
    out.append('</tbody></table>')
    out.append('<h3 id="events">Events</h3>')
    per_partition = [(n, d) for n, d in event_meta if n.startswith('Partition 1 ')]
    others = [(n, d) for n, d in event_meta if not n.startswith('Partition ')]
    out.append(f'<p>Per partition, for partitions 1-{MAX_PARTITIONS} (partition 1 shown):</p>')
    out.append('<table><thead><tr><th>Event</th><th>Fires when</th></tr></thead><tbody>')
    for n, d in per_partition:
        out.append(f"<tr><td><b>{_cell(n)}</b></td><td>{_cell(d)}</td></tr>")
    out.append('</tbody></table>')
    out.append('<p>Panel-wide:</p>')
    out.append('<table><thead><tr><th>Event</th><th>Fires when</th></tr></thead><tbody>')
    for n, d in others:
        out.append(f"<tr><td><b>{_cell(n)}</b></td><td>{_cell(d)}</td></tr>")
    out.append('</tbody></table>')
    return '\n'.join(out)

# Self-contained on purpose: no external stylesheet, font or script. Composer
# may show this with no internet access, and a dealer machine may block it.
DOC_CSS = """
:root { color-scheme: light; }
body { margin: 0; background: #ffffff; color: #1f2328;
  font: 14px/1.55 -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; }
main { max-width: 900px; margin: 0 auto; padding: 24px 28px 48px; }
h1 { font-size: 26px; margin: 0 0 4px; }
h2 { font-size: 20px; margin: 32px 0 8px; padding-bottom: 4px; border-bottom: 1px solid #d0d7de; }
h3 { font-size: 16px; margin: 22px 0 6px; }
p, li { max-width: 72ch; }
a { color: #0969da; text-decoration: none; }
code, pre { font-family: Consolas, "Courier New", monospace; font-size: 13px; background: #f6f8fa; border-radius: 4px; }
code { padding: 1px 4px; }
pre { padding: 10px 12px; overflow-x: auto; }
pre code { padding: 0; background: none; }
table { border-collapse: collapse; margin: 8px 0 16px; width: 100%; }
th, td { border: 1px solid #d0d7de; padding: 6px 9px; text-align: left; vertical-align: top; }
th { background: #f6f8fa; font-weight: 600; }
tbody tr:nth-child(even) td { background: #fbfcfd; }
blockquote { margin: 12px 0; padding: 8px 14px; border-left: 4px solid #d4a72c; background: #fff8e5; color: #3b2e00; }
blockquote p { margin: 4px 0; }
.version { color: #57606a; margin: 0 0 20px; }
.muted { color: #57606a; font-weight: normal; }
"""

def write_documentation():
    try:
        import markdown
    except ImportError:
        raise SystemExit('gen_driver_xml.py needs the "markdown" package to build the '
                         'Documentation tab: pip install markdown')
    with open(os.path.join(HERE, 'docs', 'COMPOSER-GUIDE.md'), encoding='utf-8') as f:
        md = f.read()
    body = markdown.markdown(md, extensions=['tables', 'fenced_code', 'toc'])
    body = body.replace('<!-- REFERENCE -->', reference_html())
    # Version line under the title, from the same constant as driver.xml.
    body = body.replace('</h1>', f'</h1>\n<p class="version">Driver version {DRIVER_VERSION}</p>', 1)
    page = ('<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            '<title>PIMA FORCE Alarm Panel</title>\n<style>' + DOC_CSS + '</style>\n</head>\n'
            '<body>\n<main>\n' + body + '\n</main>\n</body>\n</html>\n')
    path = os.path.join(HERE, DOC_FILE)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(page)
    return path, len(page)

doc_path, doc_len = write_documentation()
print('Wrote', os.path.relpath(doc_path, HERE) + ':', doc_len, 'bytes')

print('Wrote driver.xml:', len(xml), 'bytes,', len(properties), 'properties,', len(commands), 'commands,', len(actions), 'actions,', len(events), 'events')
