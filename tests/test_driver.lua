-- Offline smoke test harness for driver.lua: mocks the C4 runtime table and
-- Properties, loads the driver, and exercises the protocol/logic paths that
-- don't require an actual Control4 controller.

local calls = { UpdateProperty = {}, FireEvent = {}, ServerSend = {}, CreateServer = {}, AddTimer = {}, SendToProxy = {} }

Properties = {
  ['Listen Port'] = '7780',
  ['Account ID'] = '1234',
  ['Partitions Config'] = '1,Main,1111,ASN;2,Garage,2222,A',
  ['Zones Config'] = '1,Front Door,contact,1;13,Kitchen Smoke,smoke,1',
  ['Log Level'] = 'Debug',
  ['Zone Bypass Auto-Clear Minutes'] = '30',
  ['Partition 1 State'] = '',
  ['Partition 2 State'] = '',
}

local timerSeq = 0

C4 = {
  CreateServer = function(self, port) table.insert(calls.CreateServer, port) end,
  DestroyServer = function(self, port) end,
  UpdateProperty = function(self, name, value)
    Properties[name] = value
    table.insert(calls.UpdateProperty, {name, value})
  end,
  FireEvent = function(self, name) table.insert(calls.FireEvent, name) end,
  ServerSend = function(self, handle, data) table.insert(calls.ServerSend, {handle, data}) end,
  AddTimer = function(self, v, unit) timerSeq = timerSeq + 1; table.insert(calls.AddTimer, {v, unit}); return timerSeq end,
  SendToProxy = function(self, idBinding, sCommand, tParams, mode) table.insert(calls.SendToProxy, {idBinding, sCommand, tParams, mode}) end,
  KillTimer = function(self, id) end,
  DebugLog = function(self, msg) end,
  GetDriverConfigInfo = function(self, key) return '1.0' end,
  GetTime = function(self) return os.clock() * 1000 end,
}

dofile('driver.lua')

print('=== JSON round trip ===')
local sample = { frame_type = 'EVENT', counter = 42, account = '1234', type = 760, qualifier = 1, zone = 1, partition = 1 }
local encoded = JSON.encode(sample)
print('encoded:', encoded)
local decoded = JSON.decode(encoded)
assert(decoded.frame_type == 'EVENT')
assert(decoded.counter == 42)
assert(decoded.zone == 1)
print('OK JSON round trip')

print('=== OnDriverInit ===')
OnDriverInit()
assert(Partitions[1].name == 'Main')
assert(Partitions[1].userCode == '1111')
assert(Partitions[1].away and Partitions[1].stay and Partitions[1].night)
assert(Partitions[2].away and not Partitions[2].stay)
assert(Zones[1].name == 'Front Door')
assert(Zones[13].type == 'smoke')
print('OK config parsing + partitions/zones loaded')
assert(#calls.CreateServer == 1 and calls.CreateServer[1] == 7780)
print('OK server started on configured port')

print('=== Simulated panel connect + verify ===')
OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
assert(Properties['Connection Status'] == 'Client Connected (awaiting verification)')

-- Simulate two frames arriving back-to-back in one TCP chunk (coalescing),
-- plus a null heartbeat padded with 0x00, exactly like the real panel does.
local verifyFrame = '{"frame_type":"null","account":"1234","counter":1}'
local nullPad = string.rep('\0', 20)
local zoneEvent = '{"frame_type":"event","counter":501,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}'
local chunk = verifyFrame .. nullPad .. zoneEvent

OnServerDataIn(1, chunk, '10.0.0.50', 5555)

assert(Properties['Connection Status'] == 'Connected', 'expected verified connection, got: ' .. tostring(Properties['Connection Status']))
assert(Properties['Panel Verified Account'] == '1234')
print('OK panel verified from first frame')

local foundZoneOpened = false
for _, ev in ipairs(calls.FireEvent) do
  if ev == 'Zone Opened' then foundZoneOpened = true end
end
assert(foundZoneOpened, 'expected Zone Opened to fire')
assert(Properties['Last Zone Name'] == 'Front Door')
print('OK zone-open event fired with correct zone name')

-- Check that ACKs were sent back for both non-null-suppressed frames (the
-- null heartbeat should also get ACKed once; the event frame ACKed too).
local ackCount = 0
for _, sent in ipairs(calls.ServerSend) do
  if sent[2]:find('"ACK"') then ackCount = ackCount + 1 end
end
assert(ackCount == 2, 'expected 2 ACKs (heartbeat + event), got ' .. ackCount)
print('OK ACKs sent for heartbeat and event frames')

print('=== Retransmit dedupe ===')
local beforeFireCount = #calls.FireEvent
OnServerDataIn(1, zoneEvent, '10.0.0.50', 5555) -- panel resends same counter=501
local afterFireCount = #calls.FireEvent
assert(afterFireCount == beforeFireCount, 'duplicate counter should not re-fire event')
print('OK retransmit with same counter deduped (still re-ACKed though)')

print('=== Arm command -> OPERATION frame queued and ACKed, mode disambiguation ===')
-- Verification now kicks off a cold state sync (a DATA-REQ per configured
-- partition). Drain it so the arm below is the only thing on the wire --
-- otherwise it just queues behind the sync and never reaches ServerSend.
ClearInFlight()
ResetQueueState()
calls.ServerSend = {}
ExecuteCommand('Arm Away', { PARTITION = '1' })
assert(#calls.ServerSend == 1, 'expected exactly one OPERATION on the wire')
local sentOperation = JSON.decode(calls.ServerSend[1][2])
assert(sentOperation.frame_type == 'OPERATION')
assert(sentOperation.optype == 12)
assert(sentOperation.partition == 1)
assert(sentOperation.password == '1111')
-- Redacted before printing: test output gets pasted into issues and chats
-- just like driver logs do.
print('OK Arm Away produced correct OPERATION frame:', Redact(calls.ServerSend[1][2]))

-- Simulate the panel ACKing that OPERATION.
local opCounter = sentOperation.counter
local ackBack = string.format('{"frame_type":"ACK","account":1234,"counter":%d,"kc":1}', opCounter)
OnServerDataIn(1, ackBack, '10.0.0.50', 5555)

-- Because of the 500ms post-operation guard, the follow-up 2310 query (which
-- only happens after a real "armed" CID event, not directly here) is a
-- separate path -- but we can test it directly. In real operation enough
-- wall-clock time has passed by the time the CID confirmation event
-- arrives; simulate that here since the mock clock barely advances.
calls.ServerSend = {}
PostOperationGuardUntil = 0
QueryArmModeAndFire(1)
assert(#calls.ServerSend == 1)
local dataReq = JSON.decode(calls.ServerSend[1][2])
assert(dataReq.frame_type == 'DATA-REQ')
assert(dataReq.id == 2310)
assert(dataReq.start_order == 1)
print('OK post-arm System Key Status query built correctly')

local dreqCounter = dataReq.counter
local dataResp = string.format('{"frame_type":"DATA","account":1234,"counter":%d,"id":2310,"start_order":1,"parameters":["3"]}', dreqCounter)
OnServerDataIn(1, dataResp, '10.0.0.50', 5555)
assert(Properties['Partition 1 State'] == 'Armed ' .. ARM_LABEL_AWAY,
  'expected Armed ' .. ARM_LABEL_AWAY .. ', got ' .. tostring(Properties['Partition 1 State']))
local foundArmedAway = false
for _, ev in ipairs(calls.FireEvent) do if ev == 'Partition 1 Armed ' .. ARM_LABEL_AWAY then foundArmedAway = true end end
assert(foundArmedAway, 'expected Partition 1 Armed Away event to fire')
print('OK System Key Status 3 => Armed Away, event fired, property updated')

print('=== NAK handling ===')
calls.ServerSend = {}
ExecuteCommand('Disarm', { PARTITION = '2' })
local disarmFrame = JSON.decode(calls.ServerSend[1][2])
local nak = string.format('{"frame_type":"NAK","account":1234,"counter":%d,"DATA":"Wrong User Code"}', disarmFrame.counter)
OnServerDataIn(1, nak, '10.0.0.50', 5555)
assert(Properties['Last NAK Reason'] == 'Wrong User Code')
print('OK NAK reason captured in property')

print('=== Bypass write size guard ===')
local hugeParams = {}
for i = 1, 200 do hugeParams[i] = '1' end
local errCaught = nil
WriteData(2150, 1, hugeParams, '1111', function(f, err) errCaught = err end)
assert(errCaught ~= nil and errCaught:find('250%-byte'), 'expected oversized DATA write to be rejected: ' .. tostring(errCaught))
print('OK oversized DATA write rejected before hitting the wire')

print('=== Disconnect resets state ===')
OnServerConnectionStatusChanged(1, 7780, 'OFFLINE')
assert(Properties['Connection Status'] == 'Not Connected')
print('OK disconnect clears connection status')

print('=== Windows-1255 (Hebrew) zone name decoding ===')
-- "דלת כניסה" (front door) as the panel would actually send it: raw
-- Windows-1255 codepage bytes, unescaped, straight in the JSON string.
-- Byte sequence and expected UTF-8 both independently computed via
-- Python's cp1255 codec (Microsoft's own Windows-1255 mapping).
local win1255Bytes = '\227\236\250\32\235\240\233\241\228'
Properties['Zone/User Name Encoding'] = 'Windows-1255'
Properties['Reverse Zone/User Names'] = 'Off'
local decoded = DecodePanelText(win1255Bytes)
assert(decoded == 'דלת כניסה', 'Windows-1255 decode mismatch: ' .. decoded)
print('OK Windows-1255 bytes decoded to correct UTF-8 Hebrew text')

Properties['Reverse Zone/User Names'] = 'On'
local decodedReversed = DecodePanelText(win1255Bytes)
assert(decodedReversed == 'הסינכ תלד', 'reversed decode mismatch: ' .. decodedReversed)
print('OK visual-order reversal produces correctly re-reversed text')
Properties['Reverse Zone/User Names'] = 'Off'

Properties['Zone/User Name Encoding'] = 'UTF-8'
local passthrough = DecodePanelText('Front Door')
assert(passthrough == 'Front Door')
print('OK UTF-8 mode passes ASCII text through unchanged')

print('=== Discover Zone Names applies Hebrew decoding end-to-end ===')
-- Reconnect (the previous section tested disconnect handling).
OnServerConnectionStatusChanged(2, 7780, 'ONLINE')
OnServerDataIn(2, '{"frame_type":"null","account":"1234","counter":1}', '10.0.0.50', 5555)
assert(Properties['Connection Status'] == 'Connected')

Properties['Zone/User Name Encoding'] = 'Windows-1255'
-- Drain the reconnect's cold state sync, as above.
ClearInFlight()
ResetQueueState()
calls.ServerSend = {}
PostOperationGuardUntil = 0 -- enough real time has passed since the last OPERATION in practice
DiscoverZoneNames()
-- Discovery now asks for the zone count first, then pages the names.
local countReq = JSON.decode(calls.ServerSend[1][2])
assert(countReq.frame_type == 'DATA-REQ' and countReq.id == 2148,
  'expected a zone-count query first, got id ' .. tostring(countReq.id))
calls.ServerSend = {}
PostOperationGuardUntil = 0
OnServerDataIn(2, string.format(
  '{"frame_type":"DATA","account":1234,"counter":%d,"id":2148,"start_order":1,"parameters":["1"]}',
  countReq.counter), '10.0.0.50', 5555)
-- Scan for the zone-name request: index 1 is the ACK for the count response.
local discoverReq
for _, s in ipairs(calls.ServerSend) do
  local f = JSON.decode(s[2])
  if f and f.frame_type == 'DATA-REQ' and f.id == 260 then discoverReq = f end
end
assert(discoverReq, 'expected a zone-name request after the count')
assert(discoverReq.stop_order ~= nil, 'zone-name requests must carry an explicit range')
local zoneNamesResp = string.format(
  '{"frame_type":"DATA","account":1234,"counter":%d,"id":260,"start_order":1,"parameters":["%s"]}',
  discoverReq.counter, win1255Bytes)
OnServerDataIn(2, zoneNamesResp, '10.0.0.50', 5555)
assert(Properties['Discovered Zones'] == '1,דלת כניסה,contact,1',
  'expected discovered zone entry with decoded Hebrew name, got: ' .. tostring(Properties['Discovered Zones']))
print('OK Discover Zone Names end-to-end produces decoded Hebrew name:', Properties['Discovered Zones'])

print('=== Native Security proxy: init notifies panel + partition bindings ===')
-- These seeds are sent from OnDriverLateInit (proxy bindings are not
-- reliably connected during OnDriverInit), and the seeded state is OFFLINE
-- rather than DISARMED_READY -- we have not heard from the panel yet, and a
-- green "disarmed" shield for an armed house is worse than "offline".
calls.SendToProxy = {}
OnDriverLateInit()
local foundEnabled5002, foundInit5002, foundDisabled = false, false, 0
for _, c in ipairs(calls.SendToProxy) do
  if c[1] == 5002 and c[2] == 'PARTITION_ENABLED' and c[3].ENABLED == 'true' then foundEnabled5002 = true end
  if c[1] == 5002 and c[2] == 'PARTITION_STATE_INIT' and c[3].STATE == 'OFFLINE' then foundInit5002 = true end
  if c[2] == 'PARTITION_ENABLED' and c[3].ENABLED == 'false' then foundDisabled = foundDisabled + 1 end
end
assert(foundEnabled5002, 'expected PARTITION_ENABLED true on binding 5002 (partition 1) at late init')
assert(foundInit5002, 'expected PARTITION_STATE_INIT OFFLINE on binding 5002 at late init')
-- Derived from the declared partition count rather than hardcoded, so this
-- keeps working if the count is changed.
local declaredCount = 0
while PartitionProxyBindingID(declaredCount + 1) do declaredCount = declaredCount + 1 end
assert(foundDisabled == declaredCount - 2,
  'expected the declared partitions other than the two configured to be disabled; expected ' ..
  (declaredCount - 2) .. ', got ' .. foundDisabled)
print('OK OnDriverLateInit enables configured partitions, seeds OFFLINE, disables the rest')

print('=== Native Security proxy: PARTITION_ARM (binding 5002 = partition 1) ===')
calls.ServerSend = {}
calls.SendToProxy = {}
PostOperationGuardUntil = 0
ReceivedFromProxy(5002, 'PARTITION_ARM', { ArmType = ARM_LABEL_AWAY, InterfaceID = 'nav1' })
assert(#calls.ServerSend == 1, 'expected exactly one OPERATION on the wire from native ArmType=Away')
local nativeArmOp = JSON.decode(calls.ServerSend[1][2])
assert(nativeArmOp.frame_type == 'OPERATION' and nativeArmOp.optype == 12 and nativeArmOp.partition == 1,
  'expected the same Full-Arm OPERATION the Arm Away action would send')
print('OK PARTITION_ARM ArmType=Away on binding 5002 -> Full Arm OPERATION for partition 1, same as Arm Away action')

-- Panel ACKs it, then (post-guard) the System Key Status confirmation query
-- fires the mode-specific PARTITION_STATE notify on the native proxy too.
local ackBack2 = string.format('{"frame_type":"ACK","account":1234,"counter":%d,"kc":1}', nativeArmOp.counter)
OnServerDataIn(2, ackBack2, '10.0.0.50', 5555)
calls.ServerSend = {}
PostOperationGuardUntil = 0
QueryArmModeAndFire(1)
local dreq2 = JSON.decode(calls.ServerSend[1][2])
local dataResp2 = string.format('{"frame_type":"DATA","account":1234,"counter":%d,"id":2310,"start_order":1,"parameters":["3"]}', dreq2.counter)
OnServerDataIn(2, dataResp2, '10.0.0.50', 5555)
local foundNativeArmedAway = false
for _, c in ipairs(calls.SendToProxy) do
  if c[1] == 5002 and c[2] == 'PARTITION_STATE' and c[3].STATE == 'ARMED' and c[3].TYPE == ARM_LABEL_AWAY then
    foundNativeArmedAway = true
  end
end
assert(foundNativeArmedAway, 'expected native-proxy PARTITION_STATE STATE=ARMED TYPE=Away on binding 5002')
print('OK Armed-Away confirmation also notifies the native Security Partition proxy (STATE=ARMED, TYPE=Away)')

print('=== Native Security proxy: PARTITION_ARM with unrecognised ArmType is rejected, not sent to panel ===')
calls.ServerSend = {}
calls.SendToProxy = {}
ReceivedFromProxy(5002, 'PARTITION_ARM', { ArmType = 'Vacation' })
assert(#calls.ServerSend == 0, 'unrecognised ArmType must not reach the panel')
local foundArmFailed = false
for _, c in ipairs(calls.SendToProxy) do
  if c[1] == 5002 and c[2] == 'ARM_FAILED' then foundArmFailed = true end
end
assert(foundArmFailed, 'expected ARM_FAILED notify back to the native proxy for an unrecognised ArmType')
print('OK unrecognised ArmType -> ARM_FAILED, nothing sent to the panel')

print('=== Native Security proxy: PARTITION_DISARM (binding 5003 = partition 2) ===')
calls.ServerSend = {}
calls.SendToProxy = {}
ReceivedFromProxy(5003, 'PARTITION_DISARM', { UserCode = '2222', InterfaceID = 'nav1' })
assert(#calls.ServerSend == 1, 'expected exactly one OPERATION on the wire from native disarm with the correct code')
local nativeDisarmOp = JSON.decode(calls.ServerSend[1][2])
assert(nativeDisarmOp.frame_type == 'OPERATION' and nativeDisarmOp.optype == 17 and nativeDisarmOp.partition == 2)
print('OK PARTITION_DISARM with correct UserCode on binding 5003 -> Disarm OPERATION for partition 2')

calls.ServerSend = {}
calls.SendToProxy = {}
ReceivedFromProxy(5003, 'PARTITION_DISARM', { UserCode = 'wrong-code', InterfaceID = 'nav1' })
assert(#calls.ServerSend == 0, 'a wrong native-keypad code must never reach the panel')
local foundDisarmFailed = false
for _, c in ipairs(calls.SendToProxy) do
  if c[1] == 5003 and c[2] == 'DISARM_FAILED' and c[3].INTERFACE_ID == 'nav1' then foundDisarmFailed = true end
end
assert(foundDisarmFailed, 'expected DISARM_FAILED notify back on binding 5003 for a wrong code')
print('OK wrong UserCode on binding 5003 -> DISARM_FAILED, nothing sent to the panel')

print('=== Native Security proxy: zone open mirrors onto ZONE_STATE (partition) + PANEL_ZONE_STATE (panel) ===')
calls.SendToProxy = {}
OnServerDataIn(2, '{"frame_type":"event","counter":777,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}', '10.0.0.50', 5555)
local foundZoneStateOnPartition, foundPanelZoneState = false, false
for _, c in ipairs(calls.SendToProxy) do
  if c[1] == 5002 and c[2] == 'ZONE_STATE' and c[3].ZONE_ID == '1' and c[3].ZONE_OPEN == 'true' then foundZoneStateOnPartition = true end
  if c[1] == 5001 and c[2] == 'PANEL_ZONE_STATE' and c[3].ZONE_ID == '1' and c[3].ZONE_OPEN == 'true' then foundPanelZoneState = true end
end
assert(foundZoneStateOnPartition, "expected ZONE_STATE on the zone's partition binding (5002) when it opens")
assert(foundPanelZoneState, 'expected PANEL_ZONE_STATE on the panel binding (5001) when a zone opens')
print('OK zone open fires both ZONE_STATE (partition proxy) and PANEL_ZONE_STATE (panel proxy)')

print()
print('ALL TESTS PASSED')
