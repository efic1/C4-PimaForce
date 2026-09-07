-- Regression suite for the defects found in the pre-deployment review.
-- Each test names the specific failure it locks down. Unlike test_driver.lua
-- (a linear happy-path walkthrough that accumulates state), every test here
-- reloads the driver fresh so nothing leaks between cases.
--
-- Run: lua5.4 test_regressions.lua

local calls, timers, timerSeq, now

local function resetCalls()
  calls = { UpdateProperty = {}, FireEvent = {}, ServerSend = {}, CreateServer = {},
            AddTimer = {}, KillTimer = {}, SendToProxy = {}, DestroyServer = {},
            SetPropertyAttribs = {} }
end

local function mockC4()
  timers, timerSeq, now = {}, 0, 1000000
  C4 = {
    CreateServer = function(self, port) table.insert(calls.CreateServer, port) end,
    DestroyServer = function(self, port) table.insert(calls.DestroyServer, port) end,
    UpdateProperty = function(self, name, value)
      Properties[name] = value
      table.insert(calls.UpdateProperty, { name, value })
    end,
    FireEvent = function(self, name) table.insert(calls.FireEvent, name) end,
    ServerSend = function(self, handle, data) table.insert(calls.ServerSend, { handle, data }) end,
    SendToProxy = function(self, id, cmd, params, mode)
      table.insert(calls.SendToProxy, { id, cmd, params, mode })
    end,
    AddTimer = function(self, v, unit)
      timerSeq = timerSeq + 1
      timers[timerSeq] = { v = v, unit = unit }
      table.insert(calls.AddTimer, { timerSeq, v, unit })
      return timerSeq
    end,
    KillTimer = function(self, id) timers[id] = nil; table.insert(calls.KillTimer, id) end,
    SetPropertyAttribs = function(self, name, attrib)
      calls.SetPropertyAttribs[name] = attrib
    end,
    DebugLog = function(self, msg) end,
    GetDriverConfigInfo = function(self, key) return '1.0' end,
    GetTime = function(self) return now end,
  }
end

local DEFAULT_PROPS = {
  ['Listen Port'] = '7780',
  ['Account ID'] = '1234',
  ['Partitions Config'] = '1,Main,1111,ASN;2,Garage,2222,A',
  ['Zones Config'] = '1,Front Door,contact,1;7,Shed,contact,',
  ['Log Level'] = 'Info',
  ['Link Timeout Seconds'] = '90',
  ['Zone Bypass Auto-Clear Minutes'] = '30',
  ['Zone/User Name Encoding'] = 'Windows-1255',
  ['Reverse Zone/User Names'] = 'Off',
  ['Partition 1 State'] = '',
  ['Partition 2 State'] = '',
  ['Connection Status'] = '',
  ['Last Command Result'] = '',
  ['Recent Activity'] = '',
}

-- Fresh driver + mock for each test. Returns nothing; all state is global,
-- matching how DriverWorks actually loads a driver.
local function freshDriver(overrides)
  resetCalls()
  Properties = {}
  for k, v in pairs(DEFAULT_PROPS) do Properties[k] = v end
  for k, v in pairs(overrides or {}) do Properties[k] = v end
  mockC4()
  dofile('driver.lua')
  -- Test-only fixture: system key 1 has meant "starts disarmed" throughout
  -- this suite since before SYSTEM_KEY_DISARMED existed. Seeding it here is a
  -- test convenience, not a claim that any real panel uses this value --
  -- the shipped driver starts with SYSTEM_KEY_DISARMED empty and refuses to
  -- guess (see "an unconfirmed system key ..." below).
  -- NOT 1: PIMA's Appendix C reserves 1 for "Partition Not Exist", so using
  -- it here would collide with a real, spec-defined meaning.
  SYSTEM_KEY_DISARMED[97] = true
  OnDriverInit()
  OnDriverLateInit()
end

-- Bring a verified panel session up on the given handle.
--
-- Verification now kicks off a cold state sync (one DATA-REQ per configured
-- partition), so by default this drains that traffic and resets the queue --
-- otherwise every test downstream would have its counters shifted and its
-- queue occupied by sync requests it never asked for. Pass keepSync=true to
-- observe the sync itself.
local function connectPanel(handle, keepSync)
  handle = handle or 1
  OnServerConnectionStatusChanged(handle, 7780, 'ONLINE')
  OnServerDataIn(handle, '{"frame_type":"null","account":"1234","counter":1}', '10.0.0.50', 5555)
  if not keepSync then
    ClearInFlight()
    ResetQueueState()
    calls.ServerSend = {}
    calls.SendToProxy = {}
  end
  return handle
end

-- Capture everything the driver prints, plus every C4:DebugLog line, so we
-- can assert on the complete log surface rather than one path at a time.
function withCapturedLogs(fn)
  local printed = {}
  local realPrint = print
  print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts+1] = tostring(select(i, ...)) end
    printed[#printed+1] = table.concat(parts, '\t')
  end
  local ok, err = pcall(fn)
  print = realPrint
  if not ok then error(err, 0) end
  return printed
end

-- Simulates a panel holding `names` (index = zone number) and answers the
-- driver's requests until discovery finishes: the zone-count query first,
-- then each paged range. Deliberately honours start_order/stop_order and
-- never returns more than was asked for, so pagination is genuinely
-- exercised rather than satisfied by one oversized reply.
-- `pageCap` optionally caps how many entries the panel will return per page,
-- to model a panel that answers with fewer than requested.
function runDiscovery(handle, names, pageCap, reportedCount)
  PostOperationGuardUntil = 0
  ClearInFlight(); ResetQueueState(); calls.ServerSend = {}
  DiscoverZoneNames()

  local pages, sawCountQuery = 0, false
  while pages < 200 do
    pages = pages + 1
    local req
    for _, s in ipairs(calls.ServerSend) do
      local f = JSON.decode(s[2])
      if f and f.frame_type == 'DATA-REQ' then req = f end
    end
    if not req then break end
    calls.ServerSend = {}
    PostOperationGuardUntil = 0

    local id = tonumber(req.id)
    local body
    if id == 2148 then                      -- zone count
      sawCountQuery = true
      body = '"' .. (reportedCount or names.n or #names) .. '"'
    elseif id == 260 then                   -- zone names for a range
      local from = tonumber(req.start_order)
      local to = tonumber(req.stop_order) or from
      if pageCap then to = math.min(to, from + pageCap - 1) end
      local out = {}
      for z = from, math.min(to, names.n or #names) do
        local n = names[z]
        out[#out+1] = (n == nil) and 'null' or ('"' .. n .. '"')
      end
      body = table.concat(out, ',')
    else
      break                                  -- some other request; stop driving
    end

    OnServerDataIn(handle, string.format(
      '{"frame_type":"DATA","account":1234,"counter":%d,"id":%d,"start_order":%s,"parameters":[%s]}',
      req.counter, id, tostring(req.start_order), body), '10.0.0.50', 5555)
  end
  return sawCountQuery, pages
end

-- Move the mocked clock. The driver reads time through C4:GetTime(), so this
-- is how a test says "two minutes of silence passed".
function advanceClock(ms)
  now = now + ms
end

local function proxyCalls(binding, cmd)
  local out = {}
  for _, c in ipairs(calls.SendToProxy) do
    if (binding == nil or c[1] == binding) and (cmd == nil or c[2] == cmd) then out[#out + 1] = c end
  end
  return out
end

local function wireFrames()
  local out = {}
  for _, s in ipairs(calls.ServerSend) do out[#out + 1] = JSON.decode(s[2]) end
  return out
end

local function operations()
  local out = {}
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'OPERATION' then out[#out + 1] = f end
  end
  return out
end

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print('  PASS  ' .. name)
  else
    failed = failed + 1
    print('  FAIL  ' .. name)
    print('        ' .. tostring(err))
  end
end

local function section(title) print(''); print(title) end

--=============================================================================
section('Transport: TCP reassembly')
--=============================================================================

test('a frame split across two TCP segments is reassembled, dispatched and ACKed', function()
  freshDriver()
  local h = connectPanel()
  calls.ServerSend = {}
  calls.FireEvent = {}
  local whole = '{"frame_type":"event","counter":900,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}'
  local cut = 40
  OnServerDataIn(h, whole:sub(1, cut), '10.0.0.50', 5555)
  assert(#calls.FireEvent == 0, 'partial frame should not dispatch anything yet')
  OnServerDataIn(h, whole:sub(cut + 1), '10.0.0.50', 5555)
  local fired = false
  for _, e in ipairs(calls.FireEvent) do if e == 'Zone Opened' then fired = true end end
  assert(fired, 'reassembled frame must dispatch Zone Opened')
  local acked = false
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'ACK' and tonumber(f.counter) == 900 then acked = true end
  end
  assert(acked, 'reassembled frame must be ACKed (otherwise the panel retransmits forever)')
end)

test('a frame split across THREE segments mid-string still reassembles', function()
  freshDriver()
  local h = connectPanel()
  calls.FireEvent = {}
  local whole = '{"frame_type":"event","counter":901,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}'
  OnServerDataIn(h, whole:sub(1, 20), '10.0.0.50', 5555)
  OnServerDataIn(h, whole:sub(21, 60), '10.0.0.50', 5555)
  OnServerDataIn(h, whole:sub(61), '10.0.0.50', 5555)
  local fired = false
  for _, e in ipairs(calls.FireEvent) do if e == 'Zone Opened' then fired = true end end
  assert(fired, 'three-way split must still reassemble')
end)

test('a complete frame followed by the start of another keeps the tail for later', function()
  freshDriver()
  local h = connectPanel()
  calls.FireEvent = {}
  local a = '{"frame_type":"event","counter":902,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}'
  local b = '{"frame_type":"event","counter":903,"account":"1234","type":760,"qualifier":3,"zone":1,"partition":1}'
  OnServerDataIn(h, a .. b:sub(1, 30), '10.0.0.50', 5555)
  OnServerDataIn(h, b:sub(31), '10.0.0.50', 5555)
  local opened, closed = false, false
  for _, e in ipairs(calls.FireEvent) do
    if e == 'Zone Opened' then opened = true end
    if e == 'Zone Closed' then closed = true end
  end
  assert(opened and closed, 'both frames must dispatch across the boundary')
end)

test('unbounded garbage without a complete frame is discarded, not accumulated forever', function()
  freshDriver()
  local h = connectPanel()
  OnServerDataIn(h, '{' .. string.rep('x', 70000), '10.0.0.50', 5555)
  assert(#RecvBuffer == 0, 'buffer must be dropped once it exceeds the cap, got ' .. #RecvBuffer)
  calls.FireEvent = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":904,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}', '10.0.0.50', 5555)
  local fired = false
  for _, e in ipairs(calls.FireEvent) do if e == 'Zone Opened' then fired = true end end
  assert(fired, 'driver must still work after discarding a hostile buffer')
end)

--=============================================================================
section('Transport: queue integrity')
--=============================================================================

test('a Lua error inside a result callback does not park the queue', function()
  freshDriver()
  local h = connectPanel()
  PostOperationGuardUntil = 0
  local secondRan = false
  EnqueueRequest({
    frame = { account = 1234, frame_type = 'DATA-REQ', id = 2310, start_order = 1 },
    match = function(f) return f.frame_type == 'DATA' end,
    onResult = function(f, err) error('callback blew up') end,
  })
  EnqueueRequest({
    frame = { account = 1234, frame_type = 'DATA-REQ', id = 2149, start_order = 1 },
    match = function(f) return f.frame_type == 'DATA' end,
    onResult = function(f, err) secondRan = true end,
  })
  local first = wireFrames()[1]
  calls.ServerSend = {}
  OnServerDataIn(h, string.format('{"frame_type":"DATA","account":1234,"counter":%d,"id":2310,"start_order":1,"parameters":["3"]}', first.counter), '10.0.0.50', 5555)
  assert(InFlight ~= nil or #OutQueue == 0, 'queue must have advanced despite the throwing callback')
  local sentSecond = false
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'DATA-REQ' and tonumber(f.id) == 2149 then sentSecond = true end
  end
  assert(sentSecond, 'the queued second request must still go out after the first callback threw')
end)

test('a late ACK for a superseded command does not complete the newer one', function()
  freshDriver()
  local h = connectPanel()
  local armErr, disarmDone = 'unset', false
  ArmPartition(1, 'away')
  local armFrame = operations()[1]
  assert(armFrame, 'the arm must go straight to the wire, not into a queue')
  calls.ServerSend = {}
  SendOperation(1, 17, 0, nil, function(f, err) disarmDone = true end)
  local disarmFrame = operations()[1]
  assert(disarmFrame and disarmFrame.counter ~= armFrame.counter, 'disarm must carry a new counter')
  -- The panel's delayed ACK for the ARM arrives now.
  OnServerDataIn(h, string.format('{"frame_type":"ACK","account":1234,"counter":%d,"kc":1}', armFrame.counter), '10.0.0.50', 5555)
  assert(not disarmDone, 'a stale ACK must not be credited to a different command')
  OnServerDataIn(h, string.format('{"frame_type":"ACK","account":1234,"counter":%d,"kc":1}', disarmFrame.counter), '10.0.0.50', 5555)
  assert(disarmDone, 'the matching ACK must complete the disarm')
end)

test('the queue is not stalled for the size of a backwards clock step', function()
  freshDriver()
  connectPanel()
  PostOperationGuardUntil = 0
  ArmPartition(1, 'away')                 -- sets the ~550ms pacing guard
  ClearInFlight()
  now = now - 3600000                     -- NTP steps the clock back an hour
  calls.AddTimer = {}
  EnqueueRequest({
    frame = { account = 1234, frame_type = 'DATA-REQ', id = 2149, start_order = 1 },
    match = function(f) return f.frame_type == 'DATA' end,
  })
  local longest = 0
  for _, t in ipairs(calls.AddTimer) do
    if t[3] == 'MILLISECONDS' and t[2] > longest then longest = t[2] end
  end
  assert(longest <= 600, 'pacing wait must be clamped; scheduled ' .. longest .. 'ms')
end)

test('arm sends order=1, disarm sends order=0 (v21, confirmed against real validated FORCE traffic)', function()
  -- An independent, physically-validated PIMA Force integration documents
  -- this explicitly: "validated FORCE traffic requires order=1 for arming
  -- modes... disarm uses order=0 on the tested firmware". Through v20 this
  -- driver sent order=0 for every arm mode too.
  freshDriver()
  connectPanel()
  ArmPartition(1, 'away')
  local armFrame = operations()[1]
  assert(armFrame and armFrame.order == 1, 'Arm Away must send order=1, got ' .. tostring(armFrame and armFrame.order))
  calls.ServerSend = {}
  ArmPartition(1, 'stay')
  local stayFrame = operations()[1]
  assert(stayFrame and stayFrame.order == 1, 'Arm Stay must send order=1, got ' .. tostring(stayFrame and stayFrame.order))
  calls.ServerSend = {}
  DisarmPartition(1)
  local disarmFrame = operations()[1]
  assert(disarmFrame and disarmFrame.order == 0, 'Disarm must send order=0, got ' .. tostring(disarmFrame and disarmFrame.order))
end)

test('Link Timeout Seconds defaults to 600s, not 90s, when unset (v21)', function()
  -- The 90s default through v20 was based on an unconfirmed "heartbeat every
  -- few seconds" assumption. A physically-validated reference integration
  -- documents the real cadence as ~240s, with its own watchdog set to 720s
  -- specifically because of that gap -- a 90s timeout on this driver would
  -- very likely fire against a perfectly healthy panel.
  freshDriver()
  Properties['Link Timeout Seconds'] = nil
  assert(LinkTimeoutMs() == 600000, 'default Link Timeout must be 600s, got ' .. tostring(LinkTimeoutMs()))
end)

test('the outbound queue is capped rather than growing without bound', function()
  freshDriver()
  connectPanel()
  InFlight = { counter = 1, match = function() return false end, timerId = 999 }
  local rejected = 0
  for i = 1, 60 do
    EnqueueRequest({
      frame = { account = 1234, frame_type = 'DATA-REQ', id = 2149, start_order = i },
      match = function(f) return false end,
      onResult = function(f, err) if err and err:find('queue full') then rejected = rejected + 1 end end,
    })
  end
  assert(#OutQueue <= 32, 'queue depth must be capped, got ' .. #OutQueue)
  assert(rejected > 0, 'over-cap requests must fail loudly, not silently vanish')
end)

--=============================================================================
section('Transport: connection trust')
--=============================================================================

-- Connection policy: NEWEST WINS. The panel keeps one connection per CMS
-- path and reconnects on a new socket; a "first verified session wins" rule
-- locks the driver onto a dead socket after a half-open drop. Trust is
-- enforced by the account check, not by which socket arrived first.

test('the panel reconnecting on a new handle is picked up, not ignored', function()
  freshDriver()
  connectPanel(1)
  assert(PanelVerified and ConnHandle == 1)
  -- Panel reconnects on a new socket without the old one ever reporting
  -- OFFLINE (half-open: power cut, network path died).
  OnServerConnectionStatusChanged(2, 7780, 'ONLINE')
  assert(ConnHandle == 2, 'the driver must follow the panel to its new socket')
  assert(not PanelVerified, 'the new session must re-verify before being trusted')
  calls.FireEvent = {}
  OnServerDataIn(2, '{"frame_type":"event","counter":905,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}', '10.0.0.50', 5555)
  local fired = false
  for _, e in ipairs(calls.FireEvent) do if e == 'Zone Opened' then fired = true end end
  assert(fired, 'traffic on the new session must be processed once verified')
  assert(PanelVerified)
end)

test('a replaced session is announced so the churn is visible in the log', function()
  freshDriver()
  connectPanel(1)
  local logs = withCapturedLogs(function()
    OnServerConnectionStatusChanged(2, 7780, 'ONLINE')
  end)
  local announced = false
  for _, l in ipairs(logs) do
    if l:find('replacing the previous session', 1, true) then announced = true end
  end
  assert(announced, 'connection churn must be visible, not silent')
end)

test('an unverified connection is still never sent a user code', function()
  freshDriver()
  connectPanel(1)
  OnServerConnectionStatusChanged(2, 7780, 'ONLINE')   -- unverified takes the slot
  calls.ServerSend = {}
  ArmPartition(1, 'away')
  for _, f in ipairs(wireFrames()) do
    assert(not (f and f.password),
      'no credential may go to a connection that has not presented the account')
  end
end)

test('a connection that keeps presenting a wrong account is dropped', function()
  freshDriver()
  OnServerConnectionStatusChanged(9, 7780, 'ONLINE')
  for i = 1, 5 do
    OnServerDataIn(9, string.format('{"frame_type":"null","account":"%d","counter":%d}', 7000 + i, i), '10.0.0.99', 5555)
  end
  assert(not PanelVerified, 'wrong account must never verify')
  assert(ConnHandle == nil, 'the connection must be dropped after repeated failures')
end)

test('the user code is never sent to an unverified connection', function()
  freshDriver()
  OnServerConnectionStatusChanged(9, 7780, 'ONLINE')
  calls.ServerSend = {}
  ArmPartition(1, 'away')
  for _, f in ipairs(wireFrames()) do
    assert(not (f and f.password), 'no frame carrying a password may be sent before verification')
  end
end)

test('changing Listen Port drops the stale session instead of reporting Connected', function()
  freshDriver()
  connectPanel()
  assert(Properties['Connection Status'] == 'Connected')
  Properties['Listen Port'] = '7781'
  OnPropertyChanged('Listen Port')
  assert(Properties['Connection Status'] == 'Not Connected', 'must not claim a connection on the old port')
  assert(ConnHandle == nil and not PanelVerified)
end)

--=============================================================================
section('Protocol: panel data handling')
--=============================================================================

test('a null inside a zone-name array does not shift every later zone', function()
  freshDriver()
  local h = connectPanel()
  -- Zone 2 is unnamed: the panel returns null in its slot.
  local names = { n = 3 }
  names[1] = 'Front Door'
  names[3] = 'Garage Door'
  runDiscovery(h, names)
  local discovered = Properties['Discovered Zones']
  assert(discovered:find('1,Front Door'), 'zone 1 should be Front Door, got: ' .. tostring(discovered))
  assert(discovered:find('3,Garage Door'),
    'Garage Door is zone 3 and must not slide up to zone 2, got: ' .. tostring(discovered))
  assert(not discovered:find('2,Garage Door'), 'the null must hold zone 2 open')
end)

test('a non-array "parameters" from the panel does not throw or strand the partition', function()
  freshDriver()
  local h = connectPanel()
  PostOperationGuardUntil = 0
  QueryArmModeAndFire(1)
  local req = wireFrames()[#wireFrames()]
  local ok = pcall(OnServerDataIn, h, string.format(
    '{"frame_type":"DATA","account":1234,"counter":%d,"id":2310,"start_order":1,"parameters":3}', req.counter),
    '10.0.0.50', 5555)
  assert(ok, 'a scalar parameters value must not raise')
  assert(Properties['Partition 1 State'] == 'Armed',
    'the partition must still land on a known armed state, got ' .. tostring(Properties['Partition 1 State']))
end)

test('a different event reusing a counter is not swallowed as a retransmit', function()
  freshDriver()
  local h = connectPanel()
  calls.FireEvent = {}
  -- Burglary on partition 1, counter 0 (panels reset their counter on reboot).
  OnServerDataIn(h, '{"frame_type":"event","counter":0,"account":"1234","type":130,"qualifier":1,"zone":0,"partition":1}', '10.0.0.50', 5555)
  -- A genuinely different event that happens to carry the same counter.
  OnServerDataIn(h, '{"frame_type":"event","counter":0,"account":"1234","type":110,"qualifier":1,"zone":5,"partition":1}', '10.0.0.50', 5555)
  local fire = false
  for _, e in ipairs(calls.FireEvent) do if e == 'Fire Alarm' then fire = true end end
  assert(fire, 'a fire alarm reusing the last counter must NOT be silently dropped')
end)

test('an identical retransmit is still deduped', function()
  freshDriver()
  local h = connectPanel()
  calls.FireEvent = {}
  local ev = '{"frame_type":"event","counter":42,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}'
  OnServerDataIn(h, ev, '10.0.0.50', 5555)
  local after1 = #calls.FireEvent
  OnServerDataIn(h, ev, '10.0.0.50', 5555)
  assert(#calls.FireEvent == after1, 'a true retransmit must not double-fire')
end)

--=============================================================================
section('Security proxy: disarm must fail closed')
--=============================================================================

test('PARTITION_DISARM with NO user code is rejected and never reaches the panel', function()
  freshDriver()
  connectPanel()
  calls.ServerSend = {}
  calls.SendToProxy = {}
  ReceivedFromProxy(5002, 'PARTITION_DISARM', { InterfaceID = 'nav1' })
  assert(#operations() == 0, 'a codeless disarm must NOT be sent to the panel')
  assert(#proxyCalls(5002, 'DISARM_FAILED') == 1, 'the proxy must be told the disarm failed')
end)

test('PARTITION_DISARM with an empty user code is rejected', function()
  freshDriver()
  connectPanel()
  calls.ServerSend = {}
  ReceivedFromProxy(5002, 'PARTITION_DISARM', { UserCode = '', InterfaceID = 'nav1' })
  assert(#operations() == 0, 'an empty code must NOT disarm')
  assert(#proxyCalls(5002, 'DISARM_FAILED') == 1)
end)

test('PARTITION_DISARM with a wrong user code is rejected', function()
  freshDriver()
  connectPanel()
  calls.ServerSend = {}
  ReceivedFromProxy(5002, 'PARTITION_DISARM', { UserCode = '9999', InterfaceID = 'nav1' })
  assert(#operations() == 0, 'a wrong code must NOT disarm')
  assert(#proxyCalls(5002, 'DISARM_FAILED') == 1)
end)

test('PARTITION_DISARM with the correct user code disarms', function()
  freshDriver()
  connectPanel()
  calls.ServerSend = {}
  ReceivedFromProxy(5002, 'PARTITION_DISARM', { UserCode = '1111', InterfaceID = 'nav1' })
  local ops = operations()
  assert(#ops == 1 and ops[1].optype == 17 and ops[1].partition == 1,
    'the correct code must produce exactly one disarm OPERATION for partition 1')
end)

test('a disarm aimed at the PANEL binding is ignored, not treated as partition 0', function()
  freshDriver({ ['Partitions Config'] = '0,Bad,1111,ASN;1,Main,1111,ASN' })
  connectPanel()
  calls.ServerSend = {}
  ReceivedFromProxy(5001, 'PARTITION_DISARM', { UserCode = '1111' })
  assert(#operations() == 0,
    'binding 5001 is the panel proxy; it must never resolve to a partition (0 = panel-wide disarm)')
end)

--=============================================================================
section('Security proxy: arm behaviour')
--=============================================================================

test('an arm mode the partition is not configured for is refused', function()
  freshDriver()
  connectPanel()
  calls.ServerSend = {}
  calls.SendToProxy = {}
  -- Partition 2 is configured "A" (away only).
  ReceivedFromProxy(5003, 'PARTITION_ARM', { ArmType = 'Stay' })
  assert(#operations() == 0, 'Stay must not be sent for an away-only partition')
  assert(#proxyCalls(5003, 'ARM_FAILED') == 1, 'the widget must be told the arm failed')
end)

test('a configured arm mode is accepted', function()
  freshDriver()
  connectPanel()
  calls.ServerSend = {}
  ReceivedFromProxy(5003, 'PARTITION_ARM', { ArmType = 'Away' })
  local ops = operations()
  assert(#ops == 1 and ops[1].optype == 12 and ops[1].partition == 2)
end)

test('a failed arm reports ARM_FAILED to the proxy instead of only logging', function()
  freshDriver()
  -- No panel connection at all: the arm cannot be delivered.
  calls.SendToProxy = {}
  ArmPartition(1, 'away')
  assert(#proxyCalls(5002, 'ARM_FAILED') == 1,
    'an arm that never reached the panel must surface on the widget')
  assert(Properties['Last Command Result']:find('FAILED'),
    'the failure must also be visible in a property, got: ' .. tostring(Properties['Last Command Result']))
end)

--=============================================================================
section('Security proxy: state truthfulness')
--=============================================================================

test('losing the panel connection reports OFFLINE rather than leaving a stale state', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  calls.SendToProxy = {}
  OnServerConnectionStatusChanged(h, 7780, 'OFFLINE')
  local offline = false
  for _, c in ipairs(proxyCalls(5002, 'PARTITION_STATE')) do
    if c[3].STATE == 'OFFLINE' then offline = true end
  end
  assert(offline, 'the widget must not keep showing "Armed Away" for a panel we cannot see')
end)

test('initial state is seeded OFFLINE, not an optimistic DISARMED_READY', function()
  freshDriver()
  local init = proxyCalls(5002, 'PARTITION_STATE_INIT')
  assert(#init >= 1, 'partition 1 must be seeded')
  assert(init[1][3].STATE == 'OFFLINE',
    'seeding DISARMED_READY would show a green disarmed shield for an armed house, got ' .. tostring(init[1][3].STATE))
end)

test('unconfigured partitions are explicitly disabled so they do not litter the project', function()
  freshDriver({ ['Partitions Config'] = '1,Main,1111,ASN' })
  -- Derived, not hardcoded: this must stay true whatever the partition count
  -- is changed to.
  local declared = 0
  while PartitionProxyBindingID(declared + 1) do declared = declared + 1 end
  local disabled = 0
  for _, c in ipairs(proxyCalls(nil, 'PARTITION_ENABLED')) do
    if c[3].ENABLED == 'false' then disabled = disabled + 1 end
  end
  assert(disabled == declared - 1,
    'every declared partition except the one configured must be disabled; expected ' ..
    (declared - 1) .. ', got ' .. disabled)
end)

test('the panel proxy is notified of partition state, not just the partition proxy', function()
  freshDriver()
  connectPanel()
  calls.SendToProxy = {}
  SetPartitionState(1, 'Armed Away')
  local panel = proxyCalls(5001, 'PANEL_PARTITION_STATE')
  assert(#panel == 1, 'the securitypanel proxy needs its own view of partition state')
  assert(panel[1][3].PARTITION_ID == 1 and panel[1][3].STATE == 'ARMED' and panel[1][3].TYPE == 'Away')
end)

test('a burglary alarm that restores returns to the pre-alarm state, not ALARM', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  OnServerDataIn(h, '{"frame_type":"event","counter":600,"account":"1234","type":130,"qualifier":1,"zone":3,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Alarm')
  calls.SendToProxy = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":601,"account":"1234","type":130,"qualifier":3,"zone":3,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Armed Away',
    'restore must return to the pre-alarm state, got ' .. tostring(Properties['Partition 1 State']))
  local stillAlarm = false
  for _, c in ipairs(proxyCalls(5002, 'PARTITION_STATE')) do
    if c[3].STATE == 'ALARM' then stillAlarm = true end
  end
  assert(not stillAlarm, 'the widget must not stay pinned in ALARM after the alarm restores')
end)

test('a fire alarm reaches the native widget, not only the programming event', function()
  freshDriver()
  local h = connectPanel()
  calls.SendToProxy = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":610,"account":"1234","type":110,"qualifier":1,"zone":5,"partition":1}', '10.0.0.50', 5555)
  assert(#proxyCalls(5002, 'EMERGENCY_TRIGGERED') >= 1, 'a fire alarm must surface on the security proxy')
  local alarm = false
  for _, c in ipairs(proxyCalls(5002, 'PARTITION_STATE')) do
    if c[3].STATE == 'ALARM' and c[3].TYPE == 'Fire' then alarm = true end
  end
  assert(alarm, 'the partition must show ALARM/Fire during a fire alarm')
end)

test('a panel trouble surfaces on the panel proxy', function()
  freshDriver()
  local h = connectPanel()
  calls.SendToProxy = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":620,"account":"1234","type":301,"qualifier":1,"zone":0,"partition":1}', '10.0.0.50', 5555)
  assert(#proxyCalls(5001, 'TROUBLE_START') == 1, 'AC loss must raise a panel trouble')
  calls.SendToProxy = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":621,"account":"1234","type":301,"qualifier":3,"zone":0,"partition":1}', '10.0.0.50', 5555)
  assert(#proxyCalls(5001, 'TROUBLE_CLEAR') == 1, 'AC restore must clear it')
end)

test('an arm mode with no declared event still fires the generic Armed event', function()
  freshDriver()
  local h = connectPanel()
  PostOperationGuardUntil = 0
  QueryArmModeAndFire(1)
  local req = wireFrames()[#wireFrames()]
  calls.FireEvent = {}
  -- System key 8 = Shabbat: a real mode with no per-mode event in driver.xml.
  OnServerDataIn(h, string.format(
    '{"frame_type":"DATA","account":1234,"counter":%d,"id":2310,"start_order":1,"parameters":["8"]}', req.counter),
    '10.0.0.50', 5555)
  local generic = false
  for _, e in ipairs(calls.FireEvent) do if e == 'Partition 1 Armed' then generic = true end end
  assert(generic, 'Shabbat arm must still fire a declared event so "when armed" programming runs')
end)

--=============================================================================
section('Zones')
--=============================================================================

test('a zone with no partition in config falls back to the partition on the event', function()
  freshDriver()
  local h = connectPanel()
  calls.SendToProxy = {}
  -- Zone 7 is configured with an empty partition field.
  OnServerDataIn(h, '{"frame_type":"event","counter":700,"account":"1234","type":760,"qualifier":1,"zone":7,"partition":2}', '10.0.0.50', 5555)
  local zs = proxyCalls(5003, 'ZONE_STATE')
  assert(#zs == 1, 'the zone must appear on the partition the panel reported it against')
  assert(zs[1][3].ZONE_ID == '7' and zs[1][3].ZONE_OPEN == 'true')
end)

test('a bypassed zone stays flagged bypassed when it later opens', function()
  freshDriver()
  local h = connectPanel()
  OnServerDataIn(h, '{"frame_type":"event","counter":710,"account":"1234","type":570,"qualifier":1,"zone":1,"partition":1}', '10.0.0.50', 5555)
  calls.SendToProxy = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":711,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}', '10.0.0.50', 5555)
  local zs = proxyCalls(5002, 'ZONE_STATE')
  assert(#zs >= 1)
  assert(zs[#zs][3].ZONE_BYPASSED == 'true',
    'a later zone-open must not silently clear the bypass flag on the widget')
end)

--=============================================================================
section('Timers')
--=============================================================================

test('a pending pacing guard does not swallow an unrelated timer', function()
  freshDriver()
  connectPanel()
  -- Put a bypass auto-clear timer in place.
  ScheduleBypassAutoClear(4)
  local bypassTimer = AutoBypassTimerForZone[4]
  assert(bypassTimer, 'auto-clear timer should exist')
  -- Now make a pacing guard pending.
  PostOperationGuardUntil = now + 500
  EnqueueRequest({
    frame = { account = 1234, frame_type = 'DATA-REQ', id = 2149, start_order = 1 },
    match = function(f) return false end,
  })
  assert(QueueGuardTimerId, 'a pacing guard should be pending')
  calls.ServerSend = {}
  OnTimerExpired(bypassTimer)
  -- The write may legitimately still be sitting behind the pacing guard, so
  -- look for it anywhere in the pipeline (wire or queue) -- the point of the
  -- test is that the timer was HANDLED, not swallowed by the guard branch.
  local sawBypassWrite = false
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'DATA' and tonumber(f.id) == 2150 then sawBypassWrite = true end
  end
  for _, req in ipairs(OutQueue) do
    if req.frame and req.frame.frame_type == 'DATA' and tonumber(req.frame.id) == 2150 then sawBypassWrite = true end
  end
  assert(sawBypassWrite, 'the bypass auto-clear must run even while a pacing guard is pending')
  assert(AutoBypassTimers[bypassTimer] == nil, 'the fired timer must be consumed by its own branch')
end)

test('re-bypassing a zone replaces its auto-clear timer instead of stacking one', function()
  freshDriver()
  connectPanel()
  ScheduleBypassAutoClear(5)
  local first = AutoBypassTimerForZone[5]
  ScheduleBypassAutoClear(5)
  local second = AutoBypassTimerForZone[5]
  assert(first ~= second, 'a new timer should be created')
  assert(AutoBypassTimers[first] == nil, 'the old timer must be forgotten so it cannot fire early')
  local killed = false
  for _, id in ipairs(calls.KillTimer) do if id == first then killed = true end end
  assert(killed, 'the old timer must be killed')
end)

--=============================================================================
section('Second-round fixes (defects found in the fixes themselves)')
--=============================================================================

test('a failed timeout-timer allocation does not strand the rest of the queue', function()
  freshDriver()
  local h = connectPanel()
  PostOperationGuardUntil = 0
  local thirdRan = false
  -- Queue three; break AddTimer for the second dequeue only.
  EnqueueRequest({ frame = { account = 1234, frame_type = 'DATA-REQ', id = 1, start_order = 1 },
                   match = function(f) return f.frame_type == 'DATA' end })
  EnqueueRequest({ frame = { account = 1234, frame_type = 'DATA-REQ', id = 2, start_order = 1 },
                   match = function(f) return f.frame_type == 'DATA' end })
  EnqueueRequest({ frame = { account = 1234, frame_type = 'DATA-REQ', id = 3, start_order = 1 },
                   match = function(f) return f.frame_type == 'DATA' end,
                   onResult = function() thirdRan = true end })
  local realAddTimer = C4.AddTimer
  local broken = true
  C4.AddTimer = function(self, v, unit)
    if broken and unit == 'MILLISECONDS' and v == 5000 then broken = false; return nil end
    return realAddTimer(self, v, unit)
  end
  local first = wireFrames()[1]
  OnServerDataIn(h, string.format('{"frame_type":"DATA","account":1234,"counter":%d,"id":1,"start_order":1,"parameters":["x"]}', first.counter), '10.0.0.50', 5555)
  C4.AddTimer = realAddTimer
  assert(#OutQueue == 0, 'nothing may be left stranded in the queue, got ' .. #OutQueue)
end)

test('a re-announced ONLINE fails queued requests instead of dropping them silently', function()
  freshDriver()
  local h = connectPanel()
  InFlight = { counter = 1, match = function() return false end, timerId = 111 }
  local reported = nil
  EnqueueRequest({ frame = { account = 1234, frame_type = 'DATA-REQ', id = 9, start_order = 1 },
                   match = function(f) return false end,
                   onResult = function(f, err) reported = err end })
  OnServerConnectionStatusChanged(h, 7780, 'ONLINE')   -- re-announced, same handle
  assert(reported ~= nil, 'a queued request must be failed with an error, not silently discarded')
end)

test('an empty or lowercase modes field means all modes, not none', function()
  freshDriver({ ['Partitions Config'] = '1,Main,1111,;2,Garage,2222,asn' })
  assert(Partitions[1].away and Partitions[1].stay and Partitions[1].night,
    'a trailing comma must not lock the partition out of every arm mode')
  assert(Partitions[2].away and Partitions[2].stay and Partitions[2].night,
    'lowercase modes must be honoured')
  connectPanel()
  calls.ServerSend = {}
  ReceivedFromProxy(5002, 'PARTITION_ARM', { ArmType = 'Away' })
  assert(#operations() == 1, 'the partition must be armable from the widget')
end)

test('an out-of-range partition id in config is rejected, not treated as panel-wide', function()
  freshDriver({ ['Partitions Config'] = '0,Bad,1111,ASN;1,Main,1111,ASN' })
  assert(Partitions[0] == nil, 'partition 0 must never be configurable (0 = panel-wide on the wire)')
  assert(Partitions[1] ~= nil, 'valid entries alongside it must still load')
end)

test('the 250-byte DATA guard accounts for the counter added at send time', function()
  freshDriver()
  connectPanel()
  local params = {}
  for i = 1, 100 do params[i] = '1' end
  local rejected = nil
  calls.ServerSend = {}
  WriteData(2150, 1, params, '1111', function(f, err) rejected = err end)
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'DATA' then
      assert(#calls.ServerSend[1][2] <= 250,
        'a frame that reached the wire must be within the panel limit, was ' .. #calls.ServerSend[1][2])
    end
  end
end)

test('a valid frame followed by a huge garbage tail is still dispatched and ACKed', function()
  freshDriver()
  local h = connectPanel()
  calls.FireEvent = {}
  calls.ServerSend = {}
  local ev = '{"frame_type":"event","counter":950,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}'
  OnServerDataIn(h, ev .. '{' .. string.rep('x', 70000), '10.0.0.50', 5555)
  local fired = false
  for _, e in ipairs(calls.FireEvent) do if e == 'Zone Opened' then fired = true end end
  assert(fired, 'the complete frame must not be thrown away with the garbage')
  local acked = false
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'ACK' and tonumber(f.counter) == 950 then acked = true end
  end
  assert(acked, 'and it must still be ACKed')
end)

test('a blocked handle stays blocked instead of being re-adopted on its next byte', function()
  freshDriver()
  OnServerConnectionStatusChanged(9, 7780, 'ONLINE')
  for i = 1, 5 do
    OnServerDataIn(9, string.format('{"frame_type":"null","account":"7777","counter":%d}', i), '10.0.0.99', 5555)
  end
  -- Now it guesses the right account.
  OnServerDataIn(9, '{"frame_type":"null","account":"1234","counter":99}', '10.0.0.99', 5555)
  assert(not PanelVerified, 'a handle that burned through the failure limit must not be able to verify')
end)

test('an ACK carrying counter 0 still completes a queued request', function()
  freshDriver()
  local h = connectPanel()
  PostOperationGuardUntil = 0
  local done = false
  WriteData(2150, 1, { '1' }, '1111', function(f, err) done = (err == nil) end)
  OnServerDataIn(h, '{"frame_type":"ACK","account":1234,"counter":0,"kc":1}', '10.0.0.50', 5555)
  assert(done, 'a zero-counter ACK must complete the in-flight request, matching the NAK path')
end)

test('a failed bypass auto-clear re-arms the safety timer instead of giving up', function()
  freshDriver()
  connectPanel()
  ZoneStateFor(3).bypassed = true
  AutoBypassTimerForZone[3] = nil
  -- Clear attempt with no panel connection -> fails immediately.
  ConnHandle = nil
  PanelVerified = false
  SetZoneBypass(3, false)
  assert(AutoBypassTimerForZone[3] ~= nil,
    'a zone left bypassed after a failed clear must keep a retry scheduled')
end)

test('a panel-wide emergency restore does not clear another partition live burglary alarm', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(2, 'Armed Away')
  -- Burglary on partition 2.
  OnServerDataIn(h, '{"frame_type":"event","counter":800,"account":"1234","type":130,"qualifier":1,"zone":9,"partition":2}', '10.0.0.50', 5555)
  assert(Properties['Partition 2 State'] == 'Alarm')
  -- Fire on partition 1, then a panel-wide fire restore.
  OnServerDataIn(h, '{"frame_type":"event","counter":801,"account":"1234","type":110,"qualifier":1,"zone":5,"partition":1}', '10.0.0.50', 5555)
  calls.SendToProxy = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":802,"account":"1234","type":110,"qualifier":3,"zone":5,"partition":0}', '10.0.0.50', 5555)
  for _, c in ipairs(proxyCalls(5003, 'PARTITION_STATE')) do
    assert(c[3].STATE ~= 'DISARMED_READY',
      'partition 2 is still in burglary alarm; a fire restore must not show it disarmed')
  end
  assert(Properties['Partition 2 State'] == 'Alarm', 'the burglary alarm must still stand')
end)

test('overlapping emergency and burglary do not corrupt the saved pre-alarm state', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  OnServerDataIn(h, '{"frame_type":"event","counter":810,"account":"1234","type":130,"qualifier":1,"zone":3,"partition":1}', '10.0.0.50', 5555)
  OnServerDataIn(h, '{"frame_type":"event","counter":811,"account":"1234","type":110,"qualifier":1,"zone":5,"partition":1}', '10.0.0.50', 5555)
  OnServerDataIn(h, '{"frame_type":"event","counter":812,"account":"1234","type":110,"qualifier":3,"zone":5,"partition":1}', '10.0.0.50', 5555)
  OnServerDataIn(h, '{"frame_type":"event","counter":813,"account":"1234","type":130,"qualifier":3,"zone":3,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Armed Away',
    'after both alarms restore, the partition must be back to its true pre-alarm state, got ' ..
    tostring(Properties['Partition 1 State']))
end)

test('the panel proxy answers setup queries with partition and zone documents', function()
  freshDriver()
  connectPanel()
  calls.SendToProxy = {}
  ReceivedFromProxy(5001, 'GET_PANEL_SETUP', {})
  local parts = proxyCalls(5001, 'ALL_PARTITIONS_INFO')
  local zones = proxyCalls(5001, 'ALL_ZONES_INFO')
  assert(#parts == 1 and #zones == 1, 'both documents must be sent')
  assert(parts[1][3]:find('<binding_id>5002</binding_id>'), 'partition 1 must advertise its binding')
  assert(zones[1][3]:find('<name>Front Door</name>'), 'the zone list must carry configured zone names')
end)

test('zone names containing XML metacharacters do not corrupt the zone document', function()
  freshDriver({ ['Zones Config'] = '1,Bob & "Sue" <Room>,contact,1' })
  connectPanel()
  calls.SendToProxy = {}
  ReceivedFromProxy(5001, 'GET_ALL_ZONE_INFO', {})
  local xml = proxyCalls(5001, 'ALL_ZONES_INFO')[1][3]
  assert(xml:find('&amp;') and xml:find('&lt;Room&gt;'), 'metacharacters must be escaped: ' .. xml)
  assert(not xml:find('<Room>'), 'raw angle brackets would break the document')
end)

test('the native keypad bypass button reaches the panel', function()
  freshDriver()
  connectPanel()
  calls.ServerSend = {}
  ReceivedFromProxy(5002, 'BYPASS_ZONE', { ZONE_ID = '1' })
  local sawWrite = false
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'DATA' and tonumber(f.id) == 2150 then sawWrite = true end
  end
  for _, req in ipairs(OutQueue) do
    if req.frame and tonumber(req.frame.id) == 2150 then sawWrite = true end
  end
  assert(sawWrite, 'BYPASS_ZONE from the widget must actually bypass the zone')
end)

test('the Actions tab enforces the same arm modes as the widget', function()
  freshDriver()
  connectPanel()
  calls.ServerSend = {}
  ExecuteCommand('Arm Stay', { PARTITION = '2' })   -- partition 2 is away-only
  assert(#operations() == 0,
    'Composer programming must not be able to arm a mode the partition is not configured for')
end)

--=============================================================================
section('Third round: derived partition-state model')
--=============================================================================

-- The scenario that broke every snapshot-based version: the user disarms
-- DURING an alarm, so any state captured when the alarm began is stale.
test('disarming during a burglary alarm survives the alarm restoring', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  OnServerDataIn(h, '{"frame_type":"event","counter":900,"account":"1234","type":130,"qualifier":1,"zone":3,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Alarm')
  -- User disarms while the siren is going.
  OnServerDataIn(h, '{"frame_type":"event","counter":901,"account":"1234","type":401,"qualifier":1,"zone":0,"partition":1}', '10.0.0.50', 5555)
  calls.SendToProxy = {}
  -- Alarm restores.
  OnServerDataIn(h, '{"frame_type":"event","counter":902,"account":"1234","type":130,"qualifier":3,"zone":3,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Disarmed',
    'the house is disarmed; the alarm restoring must not resurrect "Armed Away", got ' ..
    tostring(Properties['Partition 1 State']))
  local last = proxyCalls(5002, 'PARTITION_STATE')
  assert(last[#last][3].STATE == 'DISARMED_READY', 'the widget must agree with the property')
end)

test('disarming during a fire alarm survives the fire restoring', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  OnServerDataIn(h, '{"frame_type":"event","counter":910,"account":"1234","type":110,"qualifier":1,"zone":5,"partition":1}', '10.0.0.50', 5555)
  OnServerDataIn(h, '{"frame_type":"event","counter":911,"account":"1234","type":401,"qualifier":1,"zone":0,"partition":1}', '10.0.0.50', 5555)
  calls.SendToProxy = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":912,"account":"1234","type":110,"qualifier":3,"zone":5,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Disarmed', 'got ' .. tostring(Properties['Partition 1 State']))
  local last = proxyCalls(5002, 'PARTITION_STATE')
  assert(last[#last][3].STATE == 'DISARMED_READY', 'property and proxy must not diverge')
end)

test('a routine GET_CURRENT_STATE does not cancel a live fire alarm', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  OnServerDataIn(h, '{"frame_type":"event","counter":920,"account":"1234","type":110,"qualifier":1,"zone":5,"partition":1}', '10.0.0.50', 5555)
  calls.SendToProxy = {}
  ReceivedFromProxy(5002, 'GET_CURRENT_STATE', {})
  local states = proxyCalls(5002, 'PARTITION_STATE')
  assert(#states >= 1, 'the query must be answered')
  assert(states[#states][3].STATE == 'ALARM',
    'a state query during a fire alarm must still report ALARM, got ' .. tostring(states[#states][3].STATE))
end)

test('the panel info document reports ALARM during a live alarm', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  OnServerDataIn(h, '{"frame_type":"event","counter":925,"account":"1234","type":110,"qualifier":1,"zone":5,"partition":1}', '10.0.0.50', 5555)
  calls.SendToProxy = {}
  ReceivedFromProxy(5001, 'GET_ALL_PARTITION_INFO', {})
  local xml = proxyCalls(5001, 'ALL_PARTITIONS_INFO')[1][3]
  assert(xml:find('<state>ALARM</state>'), 'the panel document must not contradict the widget: ' .. xml)
end)

test('overlapping fire and burglary each clear independently', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  OnServerDataIn(h, '{"frame_type":"event","counter":930,"account":"1234","type":130,"qualifier":1,"zone":3,"partition":1}', '10.0.0.50', 5555)
  OnServerDataIn(h, '{"frame_type":"event","counter":931,"account":"1234","type":110,"qualifier":1,"zone":5,"partition":1}', '10.0.0.50', 5555)
  -- Fire clears; burglary is still live.
  OnServerDataIn(h, '{"frame_type":"event","counter":932,"account":"1234","type":110,"qualifier":3,"zone":5,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Alarm', 'the burglary alarm must still stand')
  -- Burglary clears too.
  OnServerDataIn(h, '{"frame_type":"event","counter":933,"account":"1234","type":130,"qualifier":3,"zone":3,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Armed Away',
    'once every alarm clears we return to the real arm state, got ' .. tostring(Properties['Partition 1 State']))
end)

test('a fire alarm outranks a burglary in what the widget shows', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  OnServerDataIn(h, '{"frame_type":"event","counter":940,"account":"1234","type":130,"qualifier":1,"zone":3,"partition":1}', '10.0.0.50', 5555)
  calls.SendToProxy = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":941,"account":"1234","type":110,"qualifier":1,"zone":5,"partition":1}', '10.0.0.50', 5555)
  local states = proxyCalls(5002, 'PARTITION_STATE')
  assert(states[#states][3].TYPE == 'Fire',
    'life safety must take precedence over intrusion, got ' .. tostring(states[#states][3].TYPE))
end)

test('an emergency restore with no matching alarm is a harmless no-op', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  calls.SendToProxy = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":950,"account":"1234","type":110,"qualifier":3,"zone":5,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Armed Away', 'state must be untouched')
end)

test('a burglary event with no partition is surfaced but not applied to any partition', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed ' .. ARM_LABEL_AWAY)
  SetPartitionState(2, 'Armed ' .. ARM_LABEL_AWAY)
  calls.FireEvent = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":960,"account":"1234","type":130,"qualifier":1,"zone":3,"partition":0}', '10.0.0.50', 5555)
  -- It must be visible...
  local unmapped = false
  for _, e in ipairs(calls.FireEvent) do if e == 'Unmapped Panel Event' then unmapped = true end end
  assert(unmapped, 'an intrusion alarm must never vanish silently')
  assert((Properties['Last Event Summary'] or ''):find('Burglary', 1, true))
  -- ...but must NOT invent a partition to apply it to.
  assert(Properties['Partition 1 State'] ~= 'Alarm' and Properties['Partition 2 State'] ~= 'Alarm',
    'an event the panel did not attribute to a partition must not alarm every partition')
end)

test('a disarm event with no partition does not disarm the whole house', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed ' .. ARM_LABEL_AWAY)
  SetPartitionState(2, 'Armed ' .. ARM_LABEL_AWAY)
  calls.FireEvent = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":965,"account":"1234","type":401,"qualifier":1,"zone":0,"partition":0}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Armed ' .. ARM_LABEL_AWAY,
    'partition 1 must stay armed, got ' .. tostring(Properties['Partition 1 State']))
  assert(Properties['Partition 2 State'] == 'Armed ' .. ARM_LABEL_AWAY,
    'partition 2 must stay armed, got ' .. tostring(Properties['Partition 2 State']))
  local unmapped = false
  for _, e in ipairs(calls.FireEvent) do if e == 'Unmapped Panel Event' then unmapped = true end end
  assert(unmapped, 'but it must still be reported so it is not invisible')
end)

test('a malformed or missing partition is treated the same as unknown', function()
  for _, raw in ipairs({ '"partition":"A"', '"partition":0' }) do
    freshDriver()
    local h = connectPanel()
    SetPartitionState(1, 'Armed ' .. ARM_LABEL_AWAY)
    OnServerDataIn(h, '{"frame_type":"event","counter":966,"account":"1234","type":401,"qualifier":1,"zone":0,' .. raw .. '}', '10.0.0.50', 5555)
    assert(Properties['Partition 1 State'] == 'Armed ' .. ARM_LABEL_AWAY,
      'a garbage partition (' .. raw .. ') must not change security state, got ' ..
      tostring(Properties['Partition 1 State']))
  end
end)

test('an emergency on an undeclared partition does not alarm the wrong partitions', function()
  freshDriver({ ['Partitions Config'] = '1,Main,1111,ASN;12,Guest,3333,ASN' })
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  calls.SendToProxy = {}
  -- Partition 12 is valid on the panel but has no declared proxy binding.
  OnServerDataIn(h, '{"frame_type":"event","counter":970,"account":"1234","type":110,"qualifier":1,"zone":5,"partition":12}', '10.0.0.50', 5555)
  for _, c in ipairs(proxyCalls(5002, 'PARTITION_STATE')) do
    assert(c[3].STATE ~= 'ALARM',
      'a fire in partition 12 must not put partition 1 into alarm')
  end
  assert(Properties['Partition 1 State'] == 'Armed Away', 'partition 1 must be untouched')
end)

--=============================================================================
section('Third round: robustness')
--=============================================================================

test('a non-integer zone number in config cannot abort driver init', function()
  local ok = pcall(freshDriver, { ['Zones Config'] = '2.5,Half,contact,1;3,Real,contact,1' })
  assert(ok, 'a typo in a text property must not throw during init')
  assert(Zones[3] ~= nil, 'valid entries must still load')
  local xmlOk = pcall(AllZonesInfoXML)
  assert(xmlOk, 'the zone document must not throw either')
end)

test('an unassigned zone is placed in a real partition and the fallback is reported (v22)', function()
  -- This test used to assert the OPPOSITE: that an unassigned zone on a
  -- multi-partition system must NOT be claimed by partition 1, on the
  -- reasoning that a wrong partition is worse than none. Real hardware
  -- showed that reasoning was backwards. A zone claimed by nobody is
  -- published with an empty partitions field and never gets HAS_ZONE, so it
  -- belongs to no partition's list -- which is what the bare "UNKNOWN" group
  -- header above the app's zone list turned out to be. A zone in the wrong
  -- partition is visible and fixable with one Zones Config edit; a zone in
  -- no partition looks like a broken driver. The guard against a *silent*
  -- wrong placement is the log line, asserted below, not an empty field.
  local logged = withCapturedLogs(function()
    freshDriver({ ['Zones Config'] = '9,Garage Door,contact,' })
  end)
  local xml = AllZonesInfoXML()
  assert(not xml:find('<partitions></partitions>'),
    'a zone must never be published with an empty partitions field: ' .. xml)
  assert(xml:find('<partitions>1</partitions>'),
    'an unassigned zone must fall back to the lowest configured partition: ' .. xml)
  local text = table.concat(logged, '\n')
  assert(text:find('fall back to partition'),
    'falling back must be reported, never silent: ' .. text)
end)

test('correcting a mistyped Account ID lets the live session verify again', function()
  freshDriver({ ['Account ID'] = '9999' })   -- installer typo
  OnServerConnectionStatusChanged(3, 7780, 'ONLINE')
  -- Panel is talking, but the property has the wrong account.
  for i = 1, 6 do
    OnServerDataIn(3, string.format('{"frame_type":"null","account":"1234","counter":%d}', i), '10.0.0.50', 5555)
  end
  assert(not PanelVerified, 'the wrong configured account must reject the panel')
  -- Installer fixes it.
  Properties['Account ID'] = '1234'
  OnPropertyChanged('Account ID')
  OnServerDataIn(3, '{"frame_type":"null","account":"1234","counter":50}', '10.0.0.50', 5555)
  assert(PanelVerified, 'after correcting the account the same session must be able to verify')
end)

test('byte-at-a-time garbage stays bounded and stays responsive', function()
  freshDriver()
  local h = connectPanel()
  local started = os.clock()
  for i = 1, 3000 do
    OnServerDataIn(h, 'x', '10.0.0.50', 5555)
    if #RecvBuffer > 70000 then error('buffer grew past the cap: ' .. #RecvBuffer) end
  end
  local elapsed = os.clock() - started
  assert(elapsed < 5, 'byte-at-a-time delivery must not be quadratic; took ' .. elapsed .. 's')
end)

--=============================================================================
section('Fourth round: alarm state cannot get permanently stuck')
--=============================================================================

test('an alarm whose restore is lost to a disconnect does not pin the widget in ALARM', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  OnServerDataIn(h, '{"frame_type":"event","counter":980,"account":"1234","type":130,"qualifier":1,"zone":3,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Alarm')
  -- Link drops mid-alarm, so the restore is never seen.
  OnServerConnectionStatusChanged(h, 7780, 'OFFLINE')
  local h2 = connectPanel(2)
  -- Panel reports the system disarmed.
  OnServerDataIn(h2, '{"frame_type":"event","counter":981,"account":"1234","type":401,"qualifier":1,"zone":0,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Disarmed',
    'a stale alarm must not survive a reconnect, got ' .. tostring(Properties['Partition 1 State']))
end)

test('the property and the widget agree while disconnected', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  OnServerDataIn(h, '{"frame_type":"event","counter":985,"account":"1234","type":130,"qualifier":1,"zone":3,"partition":1}', '10.0.0.50', 5555)
  calls.SendToProxy = {}
  OnServerConnectionStatusChanged(h, 7780, 'OFFLINE')
  assert(Properties['Partition 1 State'] ~= 'Alarm',
    'the property must not still say Alarm while the widget is told OFFLINE')
  local last = proxyCalls(5002, 'PARTITION_STATE')
  assert(last[#last][3].STATE == 'OFFLINE')
end)

test('an alarm raised on a partition clears on that same partition', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed ' .. ARM_LABEL_AWAY)
  SetPartitionState(2, 'Armed ' .. ARM_LABEL_AWAY)
  OnServerDataIn(h, '{"frame_type":"event","counter":990,"account":"1234","type":130,"qualifier":1,"zone":3,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Alarm')
  assert(Properties['Partition 2 State'] ~= 'Alarm', 'only the named partition alarms')
  OnServerDataIn(h, '{"frame_type":"event","counter":991,"account":"1234","type":130,"qualifier":3,"zone":3,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Armed ' .. ARM_LABEL_AWAY,
    'the restore must return it to its real pre-alarm state, got ' ..
    tostring(Properties['Partition 1 State']))
end)

test('a partition-scoped alarm restoring does NOT clear another partition own alarm', function()
  freshDriver()
  local h = connectPanel()
  SetPartitionState(1, 'Armed Away')
  SetPartitionState(2, 'Armed Away')
  OnServerDataIn(h, '{"frame_type":"event","counter":992,"account":"1234","type":130,"qualifier":1,"zone":3,"partition":1}', '10.0.0.50', 5555)
  OnServerDataIn(h, '{"frame_type":"event","counter":993,"account":"1234","type":130,"qualifier":1,"zone":4,"partition":2}', '10.0.0.50', 5555)
  OnServerDataIn(h, '{"frame_type":"event","counter":994,"account":"1234","type":130,"qualifier":3,"zone":3,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Armed Away', 'partition 1 clears')
  assert(Properties['Partition 2 State'] == 'Alarm', 'partition 2 keeps its own live alarm')
end)

test('an unrecognised arm mode does not produce "Armed Armed"', function()
  freshDriver()
  local h = connectPanel()
  PostOperationGuardUntil = 0
  QueryArmModeAndFire(1)
  local req = wireFrames()[#wireFrames()]
  OnServerDataIn(h, string.format(
    '{"frame_type":"DATA","account":1234,"counter":%d,"id":2310,"start_order":1,"parameters":["99"]}', req.counter),
    '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Armed',
    'an unknown system key must fall back to plain "Armed", got ' .. tostring(Properties['Partition 1 State']))
end)

test('a burglary alarm with no configured partition is still surfaced', function()
  freshDriver({ ['Partitions Config'] = '' })
  local h = connectPanel()
  calls.FireEvent = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":995,"account":"1234","type":130,"qualifier":1,"zone":3,"partition":0}', '10.0.0.50', 5555)
  local fired = false
  for _, e in ipairs(calls.FireEvent) do if e == 'Unmapped Panel Event' then fired = true end end
  assert(fired, 'an intrusion alarm must never vanish silently, even on a misconfigured system')
end)

test('a configured partition above the declared range still tracks its own events', function()
  freshDriver({ ['Partitions Config'] = '12,Guest,3333,ASN' })
  local h = connectPanel()
  OnServerDataIn(h, '{"frame_type":"event","counter":996,"account":"1234","type":401,"qualifier":1,"zone":0,"partition":12}', '10.0.0.50', 5555)
  local st = PartitionStatusFor(12)
  assert(st.base == 'Disarmed',
    'an event addressed to partition 12 must update partition 12, got ' .. tostring(st.base))
end)

--=============================================================================
section('Logging: no user code may ever reach a log or a property')
--=============================================================================


local function assertNoSecret(lines, secret, where)
  for _, line in ipairs(lines) do
    assert(not line:find(secret, 1, true),
      'user code "' .. secret .. '" leaked into ' .. where .. ': ' .. line)
  end
end

test('the outbound wire trace does not leak the user code', function()
  local logs
  freshDriver({ ['Log Level'] = 'Debug' })
  logs = withCapturedLogs(function()
    connectPanel()
    ArmPartition(1, 'away')          -- sends {"password":"1111",...}
    DisarmPartition(2)               -- queued; still encoded
  end)
  local sawFrame = false
  for _, l in ipairs(logs) do if l:find('>>>', 1, true) then sawFrame = true end end
  assert(sawFrame, 'the wire trace should still be present -- redaction must not silence it')
  assertNoSecret(logs, '1111', 'the outbound wire trace')
  assertNoSecret(logs, '2222', 'the outbound wire trace')
  local redacted = false
  for _, l in ipairs(logs) do if l:find('******', 1, true) then redacted = true end end
  assert(redacted, 'the password field should be visibly redacted, not silently dropped')
end)

test('a DATA write (bypass) does not leak the user code either', function()
  freshDriver({ ['Log Level'] = 'Debug' })
  local logs = withCapturedLogs(function()
    connectPanel()
    SetZoneBypass(1, true)
  end)
  assertNoSecret(logs, '1111', 'a DATA write trace')
end)

test('C4:DebugLog receives the trace, so it survives without a Lua Output window', function()
  freshDriver({ ['Log Level'] = 'Debug' })
  local debugLines = {}
  C4.DebugLog = function(self, msg) debugLines[#debugLines+1] = msg end
  withCapturedLogs(function()
    connectPanel()
    ArmPartition(1, 'away')
  end)
  local sawTrace = false
  for _, l in ipairs(debugLines) do if l:find('>>>', 1, true) then sawTrace = true end end
  assert(sawTrace, 'debug-level wire trace must also reach Director\'s persistent log')
  assertNoSecret(debugLines, '1111', 'C4:DebugLog')
end)

test('the Last Raw Frame In property never carries a password', function()
  freshDriver({ ['Log Level'] = 'Debug' })
  local h = connectPanel()
  -- A (hypothetical) inbound frame that echoes a password back at us.
  OnServerDataIn(h, '{"frame_type":"DATA","account":1234,"counter":7,"id":260,"password":"1111","parameters":["x"]}', '10.0.0.50', 5555)
  local raw = Properties['Last Raw Frame In'] or ''
  assert(not raw:find('1111', 1, true), 'the diagnostic property leaked a user code: ' .. raw)
end)

test('Redact handles quoted, unquoted and spaced forms', function()
  freshDriver()
  assert(not Redact('{"password":"1234"}'):find('1234', 1, true))
  assert(not Redact('{"password":1234}'):find('1234', 1, true))
  assert(not Redact('{"password" : "1234"}'):find('1234', 1, true))
  assert(Redact('no secrets here') == 'no secrets here', 'ordinary text must pass through untouched')
  assert(Redact(nil) == nil, 'must tolerate a nil')
end)

--=============================================================================
section('Logging: Recent Activity buffer')
--=============================================================================

test('an alarm is recorded in Recent Activity without any log window open', function()
  freshDriver()   -- Info level, nobody watching
  local h = connectPanel()
  OnServerDataIn(h, '{"frame_type":"event","counter":700,"account":"1234","type":130,"qualifier":1,"zone":3,"partition":1}', '10.0.0.50', 5555)
  local activity = Properties['Recent Activity'] or ''
  assert(activity:find('BURGLARY ALARM', 1, true),
    'the single most important event to find after the fact must be recorded: ' .. activity)
  assert(activity:find('zone 3', 1, true), 'and should say which zone')
end)

test('fire, trouble and disarm events are all recorded', function()
  freshDriver()
  local h = connectPanel()
  OnServerDataIn(h, '{"frame_type":"event","counter":710,"account":"1234","type":110,"qualifier":1,"zone":5,"partition":1}', '10.0.0.50', 5555)
  OnServerDataIn(h, '{"frame_type":"event","counter":711,"account":"1234","type":301,"qualifier":1,"zone":0,"partition":1}', '10.0.0.50', 5555)
  OnServerDataIn(h, '{"frame_type":"event","counter":712,"account":"1234","type":401,"qualifier":1,"zone":0,"partition":1}', '10.0.0.50', 5555)
  local a = Properties['Recent Activity'] or ''
  assert(a:find('FIRE ALARM', 1, true), 'fire alarm missing: ' .. a)
  assert(a:find('AC power lost', 1, true), 'AC loss missing: ' .. a)
  assert(a:find('disarmed', 1, true), 'disarm missing: ' .. a)
end)

test('Recent Activity is newest-first and bounded', function()
  freshDriver()
  connectPanel()
  for i = 1, 40 do LogInfo('event number ' .. i) end
  local a = Properties['Recent Activity'] or ''
  local lines = {}
  for line in a:gmatch('[^\n]+') do lines[#lines+1] = line end
  assert(#lines <= 25, 'the buffer must stay bounded, got ' .. #lines .. ' lines')
  assert(lines[1]:find('event number 40', 1, true),
    'newest entry must be first, got: ' .. lines[1])
end)

test('Recent Activity redacts, and a huge message cannot bloat the property', function()
  freshDriver()
  connectPanel()
  LogInfo('sending {"password":"1111"} to the panel')
  LogInfo(string.rep('x', 5000))
  local a = Properties['Recent Activity'] or ''
  assert(not a:find('1111', 1, true), 'Recent Activity leaked a user code')
  for line in a:gmatch('[^\n]+') do
    assert(#line < 200, 'a single entry must be truncated, got ' .. #line .. ' chars')
  end
end)

test('logging never throws, even before properties exist', function()
  resetCalls()
  Properties = {}
  mockC4()
  dofile('driver.lua')
  local ok = pcall(function()
    LogInfo('early message before OnDriverInit')
    Dbg('early debug')
    RecordActivity('early activity')
  end)
  assert(ok, 'logging must be safe on a bare load')
end)

--=============================================================================
section('driver.lua and driver.xml must agree on the partition count')
--=============================================================================

-- The partition count is declared twice -- MAX_DECLARED_PARTITIONS in
-- driver.lua and MAX_PARTITIONS in gen_driver_xml.py -- and the two describe
-- one thing. Drift is silent and nasty in both directions: too high in Lua
-- and the driver notifies proxy bindings that do not exist; too low and
-- Composer shows partitions that are never updated. These tests read the
-- generated driver.xml and fail if anyone changes one without the other.

local function readFile(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

local function declaredPartitionCount()
  freshDriver()
  local n = 0
  while PartitionProxyBindingID(n + 1) do n = n + 1 end
  return n
end

test('driver.lua and driver.xml declare the same driver version', function()
  local xml = readFile('driver.xml')
  assert(xml, 'driver.xml not found -- run: python3 gen_driver_xml.py')
  local xmlVersion = xml:match('<version>(%d+)</version>')
  assert(xmlVersion, 'driver.xml has no <version>')
  local lua = readFile('driver.lua')
  local luaVersion = lua:match('local DRIVER_VERSION = (%d+)')
  assert(luaVersion, 'driver.lua has no DRIVER_VERSION')
  assert(xmlVersion == luaVersion,
    'driver.xml <version> is ' .. xmlVersion .. ' but driver.lua DRIVER_VERSION is ' ..
    luaVersion .. ' -- Composer would report one and the code would log the other')
end)

test('arm-mode labels in driver.lua and driver.xml agree', function()
  freshDriver()
  local xml = readFile('driver.xml')
  assert(xml, 'driver.xml not found -- run: python3 gen_driver_xml.py')

  -- arm_states is what Navigator offers as arm buttons, and therefore what
  -- comes back as PARTITION_ARM's ArmType. If it does not match what the
  -- driver accepts, every arm from the app fails with ARM_FAILED.
  local armStates = xml:match('<arm_states>([^<]*)</arm_states>')
  assert(armStates, 'driver.xml declares no arm_states')
  local declared = {}
  for s in armStates:gmatch('[^,]+') do declared[#declared+1] = s end
  assert(#declared == 3, 'expected 3 arm states, got ' .. #declared .. ' in "' .. armStates .. '"')
  for _, label in ipairs(declared) do
    assert(ArmModeForType(label),
      'driver.xml advertises arm state "' .. label ..
      '" but the driver would reject it -- arming from the app would fail')
  end

  -- Every label must also appear on its Arm action and its per-partition event.
  for _, label in ipairs({ ARM_LABEL_AWAY, ARM_LABEL_STAY, ARM_LABEL_NIGHT }) do
    assert(armStates:find(label, 1, true),
      'arm_states is missing "' .. label .. '"')
    assert(xml:find('<name>Arm ' .. label .. '</name>', 1, true),
      'no action named "Arm ' .. label .. '"')
    assert(xml:find('<name>Partition 1 Armed ' .. label .. '</name>', 1, true),
      'no event named "Partition 1 Armed ' .. label .. '"')
  end
end)

test('the Arm actions still dispatch under their current names', function()
  freshDriver()
  connectPanel()
  for label, optype in pairs({ [ARM_LABEL_AWAY] = 12, [ARM_LABEL_STAY] = 13, [ARM_LABEL_NIGHT] = 14 }) do
    calls.ServerSend = {}
    PostOperationGuardUntil = 0
    ClearInFlight(); ResetQueueState()
    ExecuteCommand('Arm ' .. label, { PARTITION = '1' })
    local ops = operations()
    assert(#ops == 1 and ops[1].optype == optype,
      'action "Arm ' .. label .. '" should send optype ' .. optype ..
      ', got ' .. (#ops == 1 and tostring(ops[1].optype) or (#ops .. ' operations')))
  end
end)

test('the older bare action names still work, so existing programming survives', function()
  freshDriver()
  connectPanel()
  for name, optype in pairs({ ['Arm Away'] = 12, ['Arm Stay'] = 13, ['Arm Night'] = 14 }) do
    calls.ServerSend = {}
    PostOperationGuardUntil = 0
    ClearInFlight(); ResetQueueState()
    ExecuteCommand(name, { PARTITION = '1' })
    local ops = operations()
    assert(#ops == 1 and ops[1].optype == optype,
      'legacy action "' .. name .. '" must still arm')
  end
end)

test('PARTITION_ARM accepts the full label, the bare name and the PIMA name', function()
  for _, armType in ipairs({ ARM_LABEL_STAY, 'Stay', 'Home1' }) do
    freshDriver()
    connectPanel()
    calls.ServerSend = {}
    PostOperationGuardUntil = 0
    ReceivedFromProxy(5002, 'PARTITION_ARM', { ArmType = armType })
    local ops = operations()
    assert(#ops == 1 and ops[1].optype == 13,
      'ArmType "' .. armType .. '" should arm Stay/Home1, got ' ..
      (#ops == 1 and tostring(ops[1].optype) or (#ops .. ' operations')))
  end
end)

test('the driver announces its version at load', function()
  local logs = withCapturedLogs(function() freshDriver() end)
  local announced = false
  for _, l in ipairs(logs) do
    if l:find('PIMA FORCE driver v', 1, true) then announced = true end
  end
  assert(announced,
    'the log must state which build loaded, so "no effect" and "not installed" are distinguishable')
end)

test('driver.xml declares exactly one security proxy per declared partition', function()
  local xml = readFile('driver.xml')
  assert(xml, 'driver.xml not found -- run: python3 gen_driver_xml.py')
  local n = declaredPartitionCount()
  local securityProxies = 0
  for _ in xml:gmatch('<proxy proxybindingid="%d+">security</proxy>') do
    securityProxies = securityProxies + 1
  end
  assert(securityProxies == n,
    'driver.lua declares ' .. n .. ' partitions but driver.xml has ' ..
    securityProxies .. ' security proxies -- regenerate driver.xml or fix the constants')
  assert(xml:find('<proxy proxybindingid="5001">securitypanel</proxy>', 1, true),
    'the panel proxy must still be declared')
end)

test('every partition binding the driver will notify exists in driver.xml', function()
  local xml = readFile('driver.xml')
  local n = declaredPartitionCount()
  for pid = 1, n do
    local binding = PartitionProxyBindingID(pid)
    assert(xml:find('<proxy proxybindingid="' .. binding .. '">security</proxy>', 1, true),
      'driver.lua will send to binding ' .. binding .. ' but driver.xml does not declare it')
    assert(xml:find('<id>' .. binding .. '</id>', 1, true),
      'binding ' .. binding .. ' has no <connection> entry')
  end
end)

test('a state property and named events exist for every declared partition', function()
  local xml = readFile('driver.xml')
  local n = declaredPartitionCount()
  for pid = 1, n do
    assert(xml:find('<name>Partition ' .. pid .. ' State</name>', 1, true),
      'no state property declared for partition ' .. pid)
    for _, suffix in ipairs({ 'Armed ' .. ARM_LABEL_AWAY, 'Armed ' .. ARM_LABEL_STAY,
                              'Armed ' .. ARM_LABEL_NIGHT, 'Armed', 'Disarmed',
                              'Alarm', 'Alarm Restored' }) do
      assert(xml:find('<name>Partition ' .. pid .. ' ' .. suffix .. '</name>', 1, true),
        'missing event "Partition ' .. pid .. ' ' .. suffix .. '"')
    end
  end
end)

test('driver.xml declares nothing for partitions beyond the declared count', function()
  local xml = readFile('driver.xml')
  local n = declaredPartitionCount()
  assert(not xml:find('<name>Partition ' .. (n + 1) .. ' State</name>', 1, true),
    'driver.xml declares partition ' .. (n + 1) .. ' but driver.lua will never update it')
  assert(not xml:find('<proxy proxybindingid="' .. (5001 + n + 1) .. '">', 1, true),
    'driver.xml declares a proxy binding driver.lua will never notify')
end)

test('a partition beyond the declared count still degrades gracefully', function()
  local n = declaredPartitionCount()
  local beyond = n + 1
  freshDriver({ ['Partitions Config'] = '1,Main,1111,ASN;' .. beyond .. ',Extra,4444,ASN' })
  local h = connectPanel()
  calls.FireEvent = {}
  calls.SendToProxy = {}
  -- The panel reports the out-of-range partition disarmed.
  OnServerDataIn(h, string.format(
    '{"frame_type":"event","counter":300,"account":"1234","type":401,"qualifier":1,"zone":0,"partition":%d}', beyond),
    '10.0.0.50', 5555)
  local unmapped = false
  for _, e in ipairs(calls.FireEvent) do if e == 'Unmapped Panel Event' then unmapped = true end end
  assert(unmapped, 'an out-of-range partition must still surface via the catch-all event')
  assert((Properties['Last Event Summary'] or ''):find('Partition ' .. beyond, 1, true),
    'and must name the partition in Last Event Summary')
  for _, c in ipairs(calls.SendToProxy) do
    assert(c[1] ~= (5001 + beyond),
      'the driver must not send to an undeclared proxy binding ' .. (5001 + beyond))
  end
  -- Arm/disarm commands must still reach the panel for it.
  calls.ServerSend = {}
  ExecuteCommand('Arm Away', { PARTITION = tostring(beyond) })
  assert(#operations() == 1,
    'arm/disarm must still work for a panel partition beyond the declared Control4 surface')
end)

--=============================================================================
section('Diagnostics for a panel that connects but never verifies')
--=============================================================================

test('non-JSON data from the panel is reported, not silently swallowed', function()
  freshDriver()
  local logs
  logs = withCapturedLogs(function()
    OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
    -- Contact-ID-over-IP style binary, i.e. the CMS path set to the wrong protocol.
    OnServerDataIn(1, '\x01\x02\x18\x34\x56\x78\xFF', '10.0.0.50', 5555)
  end)
  local warned = false
  for _, l in ipairs(logs) do
    if l:find('not the JSON protocol', 1, true) then warned = true end
  end
  assert(warned, 'unparseable data must produce an actionable warning, got: ' .. table.concat(logs, ' | '))
  local activity = Properties['Recent Activity'] or ''
  assert(activity:find('not the JSON protocol', 1, true),
    'and it must land in Recent Activity where the installer will find it')
end)

test('SIA DC-09 is named precisely, with the account the panel is using', function()
  freshDriver({ ['Account ID'] = '1234' })
  local logs = withCapturedLogs(function()
    OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
    -- A real capture from a PIMA panel left on Contact ID instead of JSON.
    OnServerDataIn(1,
      '\x0A1F180041"ADM-CID"0003R1L0#111111[#111111|1306 01 000]_16:58:04,09-04-2026\x0D',
      '192.168.1.156', 10077)
  end)
  local named, gaveAccount, saidReportOnly = false, false, false
  for _, l in ipairs(logs) do
    if l:find('SIA DC-09', 1, true) and l:find('ADM-CID', 1, true) then named = true end
    if l:find('Account ID property to 111111', 1, true) then gaveAccount = true end
    if l:find('report-only', 1, true) then saidReportOnly = true end
  end
  assert(named, 'the protocol must be named, not just called "not JSON": ' .. table.concat(logs, ' | '))
  assert(gaveAccount, 'the account from the frame must be surfaced -- it is almost never the default')
  assert(saidReportOnly, 'must say DC-09 cannot arm/disarm, so the switch is not optional')
end)

test('the DC-09 heartbeat frame is recognised too', function()
  freshDriver()
  local logs = withCapturedLogs(function()
    OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
    OnServerDataIn(1, '\x0A6D7E002B"NULL"0001R1L0#111111[]_16:59:43,09-04-2026\x0D',
      '192.168.1.156', 10077)
  end)
  local named = false
  for _, l in ipairs(logs) do
    if l:find('SIA DC-09', 1, true) and l:find('"NULL"', 1, true) then named = true end
  end
  assert(named, 'a DC-09 null/heartbeat must be identified as DC-09')
end)

test('DetectDC09 does not misfire on JSON or on arbitrary binary', function()
  freshDriver()
  assert(DetectDC09('{"frame_type":"null","account":"1234"}') == nil,
    'a JSON frame must never be reported as DC-09')
  assert(DetectDC09('\xAA\xBB\xCC') == nil, 'random binary is not DC-09')
  assert(DetectDC09('') == nil)
  assert(DetectDC09(nil) == nil)
  local token, acct = DetectDC09('\x0A1F180041"ADM-CID"0003R1L0#111111[]_x\x0D')
  assert(token == 'ADM-CID' and acct == '111111', 'got ' .. tostring(token) .. '/' .. tostring(acct))
end)

test('the raw byte trace shows what actually arrived', function()
  freshDriver({ ['Log Level'] = 'Debug' })
  local logs = withCapturedLogs(function()
    OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
    OnServerDataIn(1, '\x00\x01ABC', '10.0.0.50', 5555)
  end)
  local sawRaw = false
  for _, l in ipairs(logs) do
    if l:find('RAW IN (5 bytes)', 1, true) and l:find('\\x00\\x01ABC', 1, true) then sawRaw = true end
  end
  assert(sawRaw, 'the raw inbound bytes must be visible in the debug trace, got: ' .. table.concat(logs, ' | '))
end)

test('the unparseable warning fires once per connection, not per packet', function()
  freshDriver()
  local logs = withCapturedLogs(function()
    OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
    for i = 1, 25 do OnServerDataIn(1, '\xFF\xFE', '10.0.0.50', 5555) end
  end)
  local count = 0
  for _, l in ipairs(logs) do
    if l:find('not the JSON protocol', 1, true) then count = count + 1 end
  end
  assert(count == 1, 'the warning must not spam the log once per packet, got ' .. count)
end)

test('a partial JSON frame is reported as incomplete, not as a protocol error', function()
  freshDriver({ ['Log Level'] = 'Debug' })
  local logs = withCapturedLogs(function()
    OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
    OnServerDataIn(1, '{"frame_type":"null","acc', '10.0.0.50', 5555)
  end)
  local incomplete, wrongWarning = false, false
  for _, l in ipairs(logs) do
    if l:find('Incomplete frame buffered', 1, true) then incomplete = true end
    if l:find('not the JSON protocol', 1, true) then wrongWarning = true end
  end
  assert(incomplete, 'a genuinely partial frame should say so')
  assert(not wrongWarning, 'a partial JSON frame must NOT be misreported as a protocol mismatch')
end)

test('an account mismatch says both values and stays actionable', function()
  freshDriver({ ['Account ID'] = '5555' })
  local logs = withCapturedLogs(function()
    OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
    OnServerDataIn(1, '{"frame_type":"null","account":"1234","counter":1}', '10.0.0.50', 5555)
  end)
  local found = false
  for _, l in ipairs(logs) do
    if l:find('panel account "1234"', 1, true) and l:find('Account ID "5555"', 1, true) then found = true end
  end
  assert(found, 'the rejection must name BOTH the panel value and the configured value: ' ..
    table.concat(logs, ' | '))
end)

test('a frame with no account field hints at the protocol setting', function()
  freshDriver()
  local logs = withCapturedLogs(function()
    OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
    OnServerDataIn(1, '{"frame_type":"null","counter":1}', '10.0.0.50', 5555)
  end)
  local hinted = false
  for _, l in ipairs(logs) do
    if l:find('NO account field', 1, true) then hinted = true end
  end
  assert(hinted, 'a frame without an account should point at the Protocol setting')
end)

test('a non-numeric panel account explains itself instead of just failing', function()
  freshDriver()
  local logs = withCapturedLogs(function()
    OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
    OnServerDataIn(1, '{"frame_type":"null","account":"A1B2","counter":1}', '10.0.0.50', 5555)
  end)
  local explained = false
  for _, l in ipairs(logs) do
    if l:find('not numeric', 1, true) then explained = true end
  end
  assert(explained, 'a hex/alphanumeric account must be called out specifically')
end)

test('a panel that connects and sends nothing leaves the status truthful', function()
  freshDriver()
  OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
  assert(Properties['Connection Status'] == 'Client Connected (awaiting verification)',
    'the status must say exactly this while connected but unverified')
  assert(not PanelVerified)
end)

--=============================================================================
section('Server data callback: unknown argument layouts')
--=============================================================================

-- The published API reference gives contradictory signatures for this
-- callback, so the driver identifies the payload rather than assuming a
-- position. Each layout below is one of the documented candidates.

local FRAME = '{"frame_type":"null","account":"1234","counter":1}'

local function verifiesWith(callFn)
  freshDriver()
  OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
  callFn()
  return PanelVerified, Properties['Connection Status']
end

test('layout (handle, data, ip, port) verifies', function()
  local ok = verifiesWith(function() OnServerDataIn(1, FRAME, '10.0.0.50', 5555) end)
  assert(ok, 'the originally assumed layout must still work')
end)

test('layout (handle, ip, port, data) verifies', function()
  local ok = verifiesWith(function() OnServerDataIn(1, '10.0.0.50', 5555, FRAME) end)
  assert(ok, 'the payload must be found even when it is the last argument')
end)

test('layout (handle, idClient, data) verifies', function()
  local ok = verifiesWith(function() OnServerDataIn(1, 7, FRAME) end)
  assert(ok, 'a three-argument layout must work')
end)

test('layout (handle, data) verifies', function()
  local ok = verifiesWith(function() OnServerDataIn(1, FRAME) end)
  assert(ok, 'a two-argument layout must work')
end)

test('an IP address argument is never mistaken for the payload', function()
  freshDriver()
  OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
  -- Non-JSON payload, so the JSON shortcut cannot help; the IPv4 literal
  -- must still be rejected as a payload candidate.
  OnServerDataIn(1, '10.0.0.50', 5555, '\xAA\xBB\xCC\xDD')
  local raw = nil
  for _, c in ipairs(calls.UpdateProperty) do
    if c[1] == 'Recent Activity' then raw = c[2] end
  end
  assert(raw and raw:find('not the JSON protocol', 1, true),
    'the binary payload should have been picked and reported, got: ' .. tostring(raw))
end)

test('the alias callback names route to the same handler', function()
  for _, name in ipairs({ 'ReceivedFromServer', 'OnServerData', 'ServerDataIn' }) do
    freshDriver()
    OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
    _G[name](1, FRAME, '10.0.0.50', 5555)
    assert(PanelVerified, 'callback alias ' .. name .. ' must verify the panel too')
  end
end)

test('the argument layout is logged once, naming which callback fired', function()
  freshDriver()
  local logs = withCapturedLogs(function()
    OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
    OnServerDataIn(1, FRAME, '10.0.0.50', 5555)
    OnServerDataIn(1, FRAME, '10.0.0.50', 5555)
  end)
  local count = 0
  for _, l in ipairs(logs) do
    if l:find('Data callback "OnServerDataIn" fired', 1, true) then count = count + 1 end
  end
  assert(count == 1, 'the layout must be logged exactly once per session, got ' .. count)
end)

test('a call with no identifiable payload is ignored without throwing', function()
  freshDriver()
  OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
  local ok = pcall(function() OnServerDataIn(1, 5555) end)
  assert(ok, 'an unrecognised layout must not raise')
  assert(not PanelVerified)
end)

test('data still lands when no handle argument can be identified', function()
  freshDriver()
  OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
  OnServerDataIn(FRAME)          -- payload only, no handle at all
  assert(PanelVerified, 'a payload-only call must be attributed to the current connection')
end)

test('outbound send falls back to an alternate ServerSend form', function()
  freshDriver()
  connectPanel()
  -- Simulate a controller where the two-argument form is not the right one.
  local realSend = C4.ServerSend
  C4.ServerSend = function(self, a, b, c)
    if c == nil then error('bad argument #2 to ServerSend') end
    table.insert(calls.ServerSend, { b, c })
  end
  local logs = withCapturedLogs(function() SendRaw(1, '{"frame_type":"ACK"}') end)
  C4.ServerSend = realSend
  local switched = false
  for _, l in ipairs(logs) do
    if l:find('ServerSend(port, handle, data)', 1, true) then switched = true end
  end
  assert(switched, 'the driver must fall back and report which form worked')
  assert(#calls.ServerSend > 0, 'and the data must actually go out')
end)

--=============================================================================
section('Wire format must match the reference implementation exactly')
--=============================================================================

-- The panel is documented to NAK a frame and then go silent for ~60s if the
-- frame is not shaped as it expects, and the reference implementation notes
-- its wire shapes match a known-good capture's field order. Lua's pairs()
-- is unordered, so without an explicit rule the same frame serialises
-- differently on consecutive sends.

test('ACK field order matches the reference capture exactly', function()
  freshDriver()
  local h = connectPanel()
  calls.ServerSend = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":42,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}', '10.0.0.50', 5555)
  local ack = nil
  for _, s in ipairs(calls.ServerSend) do
    if s[2]:find('"ACK"', 1, true) then ack = s[2] end
  end
  assert(ack, 'an ACK should have been sent')
  assert(ack == '{"account":1234,"counter":42,"frame_type":"ACK","kc":1}',
    'ACK wire shape must be exactly {"account":N,"counter":N,"frame_type":"ACK","kc":1}, got: ' .. ack)
end)

test('OPERATION field order matches the reference capture exactly', function()
  freshDriver()
  connectPanel()
  calls.ServerSend = {}
  PostOperationGuardUntil = 0
  ArmPartition(1, 'away')
  local op = calls.ServerSend[1][2]
  -- Normalise the counter: this test is about FIELD ORDER, and the counter
  -- legitimately varies with how many requests preceded it.
  local normalised = op:gsub('"counter":%d+', '"counter":N')
  local expected = '{"account":1234,"counter":N,"frame_type":"OPERATION",' ..
                   '"opclass":1,"optype":12,"order":1,"partition":1,"password":"1111"}'
  assert(normalised == expected,
    'OPERATION wire shape mismatch.\n  expected: ' .. expected .. '\n  got:      ' .. normalised)
end)

test('the same frame serialises identically every time', function()
  freshDriver()
  local frame = { frame_type = 'ACK', kc = 1, account = 1234, counter = 7 }
  local first = JSON.encode(frame)
  for _ = 1, 200 do
    assert(JSON.encode(frame) == first,
      'encoding must be deterministic; pairs() order must not leak into the wire')
  end
end)

test('the ACK account is a number even though the panel sends a string', function()
  freshDriver()
  local h = connectPanel()
  calls.ServerSend = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":9,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}', '10.0.0.50', 5555)
  local ack
  for _, s in ipairs(calls.ServerSend) do if s[2]:find('"ACK"', 1, true) then ack = s[2] end end
  assert(ack:find('"account":1234', 1, true),
    'account must be emitted unquoted as a number, got: ' .. ack)
  assert(not ack:find('"account":"1234"', 1, true), 'account must NOT be a string')
end)

--=============================================================================
section('A frame is ACKed even when we do not trust the sender')
--=============================================================================

test('a wrong-account frame is still ACKed, so the panel does not reconnect-loop', function()
  freshDriver({ ['Account ID'] = '5555' })
  OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
  calls.ServerSend = {}
  OnServerDataIn(1, '{"frame_type":"event","counter":11,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}', '10.0.0.50', 5555)
  local acked = false
  for _, s in ipairs(calls.ServerSend) do
    if s[2]:find('"ACK"', 1, true) then acked = true end
  end
  assert(acked,
    'withholding the ACK breaks the protocol and causes an endless connect/drop loop ' ..
    'instead of a clean rejection')
  assert(not PanelVerified, 'but the sender must still not be trusted')
end)

test('an unverified frame is ACKed but never dispatched', function()
  freshDriver({ ['Account ID'] = '5555' })
  OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
  calls.FireEvent = {}
  OnServerDataIn(1, '{"frame_type":"event","counter":12,"account":"1234","type":130,"qualifier":1,"zone":3,"partition":1}', '10.0.0.50', 5555)
  assert(#calls.FireEvent == 0,
    'an untrusted frame must not raise alarms or fire programming events')
end)

test('ACK and NAK frames are never themselves ACKed', function()
  freshDriver()
  local h = connectPanel()
  calls.ServerSend = {}
  OnServerDataIn(h, '{"frame_type":"ACK","account":1234,"counter":5,"kc":1}', '10.0.0.50', 5555)
  OnServerDataIn(h, '{"frame_type":"NAK","account":1234,"counter":6,"DATA":"x"}', '10.0.0.50', 5555)
  assert(#calls.ServerSend == 0, 'ACKing a control frame would loop forever')
end)

test('a null heartbeat is ACKed', function()
  freshDriver()
  local h = connectPanel()
  calls.ServerSend = {}
  OnServerDataIn(h, '{"frame_type":"null","account":"1234","counter":3}' .. string.rep('\0', 200), '10.0.0.50', 5555)
  local acked = false
  for _, s in ipairs(calls.ServerSend) do if s[2]:find('"ACK"', 1, true) then acked = true end end
  assert(acked, 'heartbeats must be ACKed or the panel drops the connection')
end)

--=============================================================================
section('Cold state sync on connect (partition must not sit at OFFLINE)')
--=============================================================================

-- Regression for the real-world report: panel connected and verified, but
-- every partition read OFFLINE indefinitely because the driver was purely
-- event-driven and never asked the panel what state it was in.

local function answerSyncQueries(handle, systemKeyValue)
  -- Reply to each queued System Key Status (2310) request in turn.
  local guard = 0
  while InFlight and guard < 10 do
    guard = guard + 1
    local req = nil
    for _, s in ipairs(calls.ServerSend) do
      local f = JSON.decode(s[2])
      if f and f.frame_type == 'DATA-REQ' and tonumber(f.id) == 2310 then req = f end
    end
    if not req then break end
    calls.ServerSend = {}
    PostOperationGuardUntil = 0
    OnServerDataIn(handle, string.format(
      '{"frame_type":"DATA","account":1234,"counter":%d,"id":2310,"start_order":%d,"parameters":["%s"]}',
      req.counter, req.start_order, tostring(systemKeyValue)), '10.0.0.50', 5555)
  end
end

test('verifying the panel triggers a state query for each configured partition', function()
  freshDriver()
  connectPanel(1, true)   -- keep the sync traffic
  local queried = {}
  for _, s in ipairs(calls.ServerSend) do
    local f = JSON.decode(s[2])
    if f and f.frame_type == 'DATA-REQ' and tonumber(f.id) == 2310 then
      queried[tonumber(f.start_order)] = true
    end
  end
  for _, req in ipairs(OutQueue) do
    if req.frame and tonumber(req.frame.id) == 2310 then
      queried[tonumber(req.frame.start_order)] = true
    end
  end
  assert(queried[1] and queried[2],
    'both configured partitions must be queried on connect, got: ' ..
    tostring(queried[1]) .. '/' .. tostring(queried[2]))
end)

test('a partition the panel reports as armed resolves to Armed, not OFFLINE', function()
  freshDriver()
  local h = connectPanel(1, true)
  answerSyncQueries(h, 3)      -- system key 3 = Away
  assert(Properties['Partition 1 State'] == 'Armed ' .. ARM_LABEL_AWAY,
    'expected Armed ' .. ARM_LABEL_AWAY .. ' after sync, got ' .. tostring(Properties['Partition 1 State']))
end)

test('a confirmed disarmed system key resolves to Disarmed', function()
  freshDriver()
  local h = connectPanel(1, true)
  answerSyncQueries(h, 97)     -- seeded as a confirmed test fixture, see freshDriver()
  assert(Properties['Partition 1 State'] == 'Disarmed',
    'a confirmed disarmed code should read Disarmed, got ' .. tostring(Properties['Partition 1 State']))
end)

test('system key 2 is confirmed Disarmed (a real installed panel, 2026-09)', function()
  freshDriver()
  local h = connectPanel(1, true)
  answerSyncQueries(h, 2)
  assert(Properties['Partition 1 State'] == 'Disarmed',
    'confirmed real-world mapping, got ' .. tostring(Properties['Partition 1 State']))
end)

test('an unconfirmed system key is never guessed as Disarmed', function()
  -- This is the shape of bug a real panel exposed: system key 2 came back
  -- from a live PIMA FORCE panel, was not in SYSTEM_KEY_TO_MODE, and the
  -- driver used to default anything unmapped during a cold sync to
  -- Disarmed -- a guess with no evidence behind it (2 is now confirmed and
  -- lives in SYSTEM_KEY_DISARMED, so this test uses a value that is neither
  -- mapped nor confirmed to keep exercising the "we truly don't know" path).
  -- For a security system the wrong-direction guess (reporting Disarmed for
  -- a house that might actually be armed) is the dangerous one, so an
  -- unconfirmed code must leave the partition as-is and say so loudly.
  freshDriver()
  local h = connectPanel(1, true)
  answerSyncQueries(h, 99)      -- not in SYSTEM_KEY_TO_MODE, not in SYSTEM_KEY_DISARMED
  assert(Properties['Partition 1 State'] == 'Unknown',
    'an unconfirmed code must not be asserted as Disarmed, got ' .. tostring(Properties['Partition 1 State']))
  assert(Properties['Last Command Result']:find('confirmed mapping'),
    'and it must say why: ' .. tostring(Properties['Last Command Result']))
end)

test('adding a code to SYSTEM_KEY_DISARMED is how a confirmed value gets trusted', function()
  freshDriver()
  local h = connectPanel(1, true)
  SYSTEM_KEY_DISARMED[99] = true      -- simulates confirming a new code against a real panel
  answerSyncQueries(h, 99)
  assert(Properties['Partition 1 State'] == 'Disarmed',
    'once confirmed, the same code must resolve normally, got ' .. tostring(Properties['Partition 1 State']))
end)

test('SYSTEM_KEY_DISARMED does not accumulate across a driver reload', function()
  -- It is a plain literal, not an "X = X or {}" self-preserving global, on
  -- purpose: static configuration should reset the same way on every load,
  -- not carry a runtime confirmation added in a previous process forever
  -- (that behavior belongs to genuinely runtime-learned state elsewhere,
  -- like RecentActivity or PropShadow).
  freshDriver()
  SYSTEM_KEY_DISARMED[77] = true
  freshDriver()
  assert(SYSTEM_KEY_DISARMED[77] == nil,
    'a fresh load must not remember a confirmation from a previous one')
  assert(SYSTEM_KEY_DISARMED[2] == true, 'but the shipped confirmed value must still be there')
end)

test('a failed state sync explains why the partition reads Unknown', function()
  freshDriver()
  local h = connectPanel(1, true)
  -- Panel NAKs the state query (e.g. wrong user code for that partition).
  local req
  for _, s in ipairs(calls.ServerSend) do
    local f = JSON.decode(s[2])
    if f and tonumber(f.id) == 2310 then req = f end
  end
  assert(req, 'a state query should have been issued')
  OnServerDataIn(h, string.format(
    '{"frame_type":"NAK","account":1234,"counter":%d,"DATA":"Wrong User Code"}', req.counter),
    '10.0.0.50', 5555)
  local result = Properties['Last Command Result'] or ''
  assert(result:find('state query FAILED', 1, true),
    'the failure must be visible in a property, got: ' .. result)
  assert(result:find('Unknown', 1, true),
    'and must connect it to what the app shows')
end)

test('a successful sync records the raw system key it acted on', function()
  freshDriver()
  local h = connectPanel(1, true)
  answerSyncQueries(h, 3)
  local result = Properties['Last Command Result'] or ''
  assert(result:find('system key 3', 1, true),
    'the value the decision was based on must be recorded, got: ' .. result)
end)

test('the raw system key value is always logged so unmapped values can be found', function()
  freshDriver()
  local h
  local logs = withCapturedLogs(function()
    h = connectPanel(1, true)
    answerSyncQueries(h, 7)
  end)
  local logged = false
  for _, l in ipairs(logs) do
    if l:find('System Key Status = 7', 1, true) then logged = true end
  end
  assert(logged, 'the raw value must be logged: ' .. table.concat(logs, ' | '))
end)

test('the cold sync does NOT fire programming events', function()
  freshDriver()
  local h = connectPanel(1, true)
  calls.FireEvent = {}
  answerSyncQueries(h, 3)
  for _, e in ipairs(calls.FireEvent) do
    assert(not e:find('Armed', 1, true),
      'reloading the driver on an armed house must not look like a fresh arming (' .. e .. ')')
  end
end)

test('the cold sync seeds with PARTITION_STATE_INIT and then states it live', function()
  -- The seed alone left the app showing the proxy's default UNKNOWN: Navigator
  -- does not appear to re-render on PARTITION_STATE_INIT. The seed still goes
  -- first so the proxy has no state CHANGE to propagate when the live notify
  -- arrives with the identical value.
  freshDriver()
  local h = connectPanel(1, true)
  calls.SendToProxy = {}
  answerSyncQueries(h, 3)
  local initIdx, liveIdx
  for i, c in ipairs(proxyCalls(5002)) do
    if c[2] == 'PARTITION_STATE_INIT' and c[3].STATE == 'ARMED' then initIdx = initIdx or i end
    if c[2] == 'PARTITION_STATE' and c[3].STATE == 'ARMED' then liveIdx = liveIdx or i end
  end
  assert(initIdx, 'the synced state must still be seeded as an init notification')
  assert(liveIdx, 'and restated live, or the app never redraws')
  assert(initIdx < liveIdx, 'the seed must come first, or the live notify reads as a change')
end)

test('a real arm event after the sync still fires programming normally', function()
  freshDriver()
  local h = connectPanel(1, true)
  answerSyncQueries(h, 97)                    -- starts disarmed
  assert(Properties['Partition 1 State'] == 'Disarmed')
  ClearInFlight(); ResetQueueState(); calls.ServerSend = {}; calls.FireEvent = {}
  -- Panel reports partition 1 armed.
  OnServerDataIn(h, '{"frame_type":"event","counter":770,"account":"1234","type":401,"qualifier":3,"zone":0,"partition":1}', '10.0.0.50', 5555)
  PostOperationGuardUntil = 0
  answerSyncQueries(h, 3)
  assert(Properties['Partition 1 State'] == 'Armed ' .. ARM_LABEL_AWAY,
    'got ' .. tostring(Properties['Partition 1 State']))
  local fired = false
  for _, e in ipairs(calls.FireEvent) do if e == 'Partition 1 Armed ' .. ARM_LABEL_AWAY then fired = true end end
  assert(fired, 'a genuine arm must still fire its programming event')
end)

test('the Sync Partition States action re-queries on demand', function()
  freshDriver()
  connectPanel()          -- sync drained
  calls.ServerSend = {}
  PostOperationGuardUntil = 0
  ExecuteCommand('Sync Partition States', {})
  local asked = false
  for _, s in ipairs(calls.ServerSend) do
    local f = JSON.decode(s[2])
    if f and f.frame_type == 'DATA-REQ' and tonumber(f.id) == 2310 then asked = true end
  end
  for _, req in ipairs(OutQueue) do
    if req.frame and tonumber(req.frame.id) == 2310 then asked = true end
  end
  assert(asked, 'the action must issue a state query')
end)

test('a partition with no user code cannot be synced, and says so', function()
  freshDriver({ ['Partitions Config'] = '1,Main,,ASN' })
  local logs = withCapturedLogs(function() connectPanel(1, true) end)
  local explained = false
  for _, l in ipairs(logs) do
    if l:find('no user code in Partitions Config', 1, true) then explained = true end
  end
  assert(explained, 'the reason a partition cannot sync must be stated: ' .. table.concat(logs, ' | '))
end)

--=============================================================================
section('Zone inventory reaches the Control4 app')
--=============================================================================

test('each zone is announced to the panel proxy with name, type and partition', function()
  freshDriver({ ['Zones Config'] = '1,Front Door,contact,1;5,Hall Motion,motion,1;9,Kitchen Smoke,smoke,2' })
  local info = proxyCalls(5001, 'PANEL_ZONE_INFO')
  assert(#info == 3, 'every configured zone must be announced, got ' .. #info)
  local byId = {}
  for _, c in ipairs(info) do byId[c[3].ID] = c[3] end
  assert(byId[1].NAME == 'Front Door' and byId[1].TYPE_ID == 1, 'contact zone mismatch')
  assert(byId[5].TYPE_ID == 5, 'motion should map to sensor type 5, got ' .. tostring(byId[5].TYPE_ID))
  assert(byId[9].TYPE_ID == 11, 'smoke should map to sensor type 11, got ' .. tostring(byId[9].TYPE_ID))
  assert(byId[9].PARTITIONS == '2', 'zone 9 belongs to partition 2, got ' .. tostring(byId[9].PARTITIONS))
end)

test('each zone is added to its own partition list via HAS_ZONE', function()
  freshDriver({ ['Zones Config'] = '1,Front Door,contact,1;9,Kitchen Smoke,smoke,2' })
  local p1, p2 = {}, {}
  for _, c in ipairs(proxyCalls(5002, 'HAS_ZONE')) do p1[c[3].ZONE_ID] = true end
  for _, c in ipairs(proxyCalls(5003, 'HAS_ZONE')) do p2[c[3].ZONE_ID] = true end
  assert(p1[1], 'zone 1 must be listed under partition 1')
  assert(p2[9], 'zone 9 must be listed under partition 2')
  assert(not p1[9], 'zone 9 must NOT appear under partition 1')
end)

test('a zone in the default state is not given a redundant status message', function()
  freshDriver({ ['Zones Config'] = '1,Front Door,contact,1' })
  -- PANEL_ZONE_INFO already carries IS_OPEN, and a new zone starts closed,
  -- so an extra ZONE_STATE saying "closed" is a Director round trip per zone
  -- that says nothing. On a 40-zone panel that was a third of the cost.
  assert(#proxyCalls(5002, 'ZONE_STATE') == 0,
    'a closed, unbypassed zone needs no seed status')
  local info = proxyCalls(5001, 'PANEL_ZONE_INFO')
  assert(#info == 1 and info[1][3].IS_OPEN == false,
    'the zone status still travels with PANEL_ZONE_INFO')
end)

test('a zone that is open or bypassed IS seeded with its status', function()
  freshDriver({ ['Zones Config'] = '1,Front Door,contact,1' })
  local h = connectPanel()
  -- Zone opens.
  OnServerDataIn(h, '{"frame_type":"event","counter":401,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}', '10.0.0.50', 5555)
  calls.SendToProxy = {}
  -- A change to the inventory forces a republish; the open state must survive it.
  Properties['Zones Config'] = '1,Front Door Renamed,contact,1'
  OnPropertyChanged('Zones Config')
  local states = proxyCalls(5002, 'ZONE_STATE')
  assert(#states == 1 and states[1][3].ZONE_OPEN == 'true',
    'a zone that is genuinely open must be stated on republish, got ' .. #states)
end)

test('partition zone lists are cleared before being rebuilt', function()
  freshDriver({ ['Zones Config'] = '1,Front Door,contact,1' })
  calls.SendToProxy = {}
  -- Zone moves from partition 1 to partition 2.
  Properties['Zones Config'] = '1,Front Door,contact,2'
  OnPropertyChanged('Zones Config')
  local cleared = false
  for _, c in ipairs(proxyCalls(5002, 'CLEAR_ZONE_LIST')) do cleared = true end
  assert(cleared, 'the old partition list must be cleared or the zone shows under both')
  local p2 = false
  for _, c in ipairs(proxyCalls(5003, 'HAS_ZONE')) do if c[3].ZONE_ID == 1 then p2 = true end end
  assert(p2, 'the zone must be added to its new partition')
end)

test('the panel is told initialisation is complete', function()
  freshDriver()
  assert(#proxyCalls(5001, 'PANEL_INITIALIZED') >= 1,
    'Navigator treats the panel as still coming up without PANEL_INITIALIZED')
end)

test('the zone inventory is republished once the panel is actually live', function()
  freshDriver({ ['Zones Config'] = '1,Front Door,contact,1' })
  calls.SendToProxy = {}
  connectPanel(1, true)
  assert(#proxyCalls(5001, 'PANEL_ZONE_INFO') >= 1,
    'on a cold start LateInit runs before the panel connects, so the inventory must be re-sent')
end)

--=============================================================================
section('Inventory publishing cost')
--=============================================================================

-- Every SendToProxy is a Director round trip. Publishing a 40-zone inventory
-- costs ~90 of them, and it used to be re-sent on load, on every panel
-- verification, on any config change, and again from Apply Discovered Zones
-- (which also triggers the config-change handler). That repetition is what
-- made reloading the driver and applying a zone list feel slow.

local function bigZoneConfig(n)
  local z = {}
  for i = 1, n do z[#z+1] = i .. ',Zone ' .. i .. ',contact,1' end
  return table.concat(z, ';')
end

test('an unchanged inventory is not republished', function()
  freshDriver({ ['Zones Config'] = bigZoneConfig(40) })
  connectPanel(1, true)          -- first verification may force one publish
  calls.SendToProxy = {}
  -- A reconnect changes nothing about the zone list.
  OnServerConnectionStatusChanged(1, 7780, 'OFFLINE')
  connectPanel(2, true)
  local zoneCalls = #proxyCalls(5001, 'PANEL_ZONE_INFO')
  assert(zoneCalls == 0,
    'a reconnect must not re-send 40 zones to Director, got ' .. zoneCalls .. ' zone messages')
end)

test('applying the same zone list twice does no work the second time', function()
  freshDriver({ ['Zones Config'] = '' })
  local h = connectPanel()
  local names = {}
  for i = 1, 20 do names[i] = 'Zone ' .. i end
  runDiscovery(h, names)
  ExecuteCommand('Apply Discovered Zones', {})
  calls.SendToProxy = {}
  ExecuteCommand('Apply Discovered Zones', {})    -- identical list
  assert(#proxyCalls(5001, 'PANEL_ZONE_INFO') == 0,
    're-applying an identical list must be a no-op, not a full republish')
end)

test('a real change still republishes', function()
  freshDriver({ ['Zones Config'] = '1,Front Door,contact,1' })
  calls.SendToProxy = {}
  Properties['Zones Config'] = '1,Front Door,contact,1;2,Back Door,contact,1'
  OnPropertyChanged('Zones Config')
  assert(#proxyCalls(5001, 'PANEL_ZONE_INFO') == 2,
    'adding a zone must publish the new list')
end)

test('an explicit Director query is always answered, even if unchanged', function()
  freshDriver({ ['Zones Config'] = '1,Front Door,contact,1' })
  calls.SendToProxy = {}
  ReceivedFromProxy(5001, 'GET_ALL_ZONE_INFO', {})
  assert(#proxyCalls(5001, 'ALL_ZONES_INFO') == 1,
    'a refresh request must be answered regardless of the dedup')
  assert(#proxyCalls(5001, 'PANEL_ZONE_INFO') == 1)
end)

test('publishing a large inventory stays within a sane number of round trips', function()
  freshDriver({ ['Zones Config'] = bigZoneConfig(40) })
  calls.SendToProxy = {}
  SendPanelInfo(true)
  local n = #calls.SendToProxy
  -- 2 info documents + 1 initialised + 3 clears + 2 per zone.
  assert(n <= 40 * 2 + 10,
    'inventory publish should cost about two calls per zone, got ' .. n .. ' for 40 zones')
end)

--=============================================================================
section('Apply Discovered Zones action')
--=============================================================================


test('discovery pages through ALL zones, not just the first', function()
  freshDriver()
  local h = connectPanel()
  local names = {}
  for i = 1, 40 do names[i] = 'Zone ' .. i end
  local sawCount, pages = runDiscovery(h, names)
  assert(sawCount, 'the panel should be asked for its zone count first')
  assert(DiscoveredZonesCount == 40,
    'all 40 zones must be discovered, got ' .. tostring(DiscoveredZonesCount))
  assert(pages > 2, 'a 40-zone panel must take several pages, took ' .. pages)
  assert(DiscoveredZonesFull:find('40,Zone 40,contact,1', 1, true),
    'the last zone must be present')
end)

test('every zone-name request carries an explicit range', function()
  freshDriver()
  local h = connectPanel()
  PostOperationGuardUntil = 0
  ClearInFlight(); ResetQueueState(); calls.ServerSend = {}
  DiscoverZoneNames()
  -- Answer the count query so the first name request is issued.
  local req = wireFrames()[#wireFrames()]
  calls.ServerSend = {}
  OnServerDataIn(h, string.format(
    '{"frame_type":"DATA","account":1234,"counter":%d,"id":2148,"start_order":1,"parameters":["40"]}',
    req.counter), '10.0.0.50', 5555)
  local nameReq
  for _, f in ipairs(wireFrames()) do
    if f and tonumber(f.id) == 260 then nameReq = f end
  end
  assert(nameReq, 'a zone-name request should follow the count')
  assert(nameReq.stop_order ~= nil,
    'without stop_order the panel returns exactly one zone -- this was the bug')
  assert(tonumber(nameReq.stop_order) > tonumber(nameReq.start_order),
    'the range must span more than one zone, got ' ..
    tostring(nameReq.start_order) .. '-' .. tostring(nameReq.stop_order))
end)

test('discovery still completes when the panel returns fewer zones than asked', function()
  freshDriver()
  local h = connectPanel()
  local names = {}
  for i = 1, 30 do names[i] = 'Zone ' .. i end
  runDiscovery(h, names, 3)    -- panel only ever returns 3 per page
  assert(DiscoveredZonesCount == 30,
    'the walk must advance by what was actually returned, got ' .. tostring(DiscoveredZonesCount))
end)

test('discovery works when the panel will not report a zone count', function()
  freshDriver()
  local h = connectPanel()
  PostOperationGuardUntil = 0
  ClearInFlight(); ResetQueueState(); calls.ServerSend = {}
  DiscoverZoneNames()
  -- Panel NAKs the count query.
  local req = wireFrames()[#wireFrames()]
  calls.ServerSend = {}
  OnServerDataIn(h, string.format(
    '{"frame_type":"NAK","account":1234,"counter":%d,"DATA":"Unsupported"}', req.counter),
    '10.0.0.50', 5555)
  -- It should fall back to scanning rather than giving up.
  local nameReq
  for _, f in ipairs(wireFrames()) do
    if f and tonumber(f.id) == 260 then nameReq = f end
  end
  assert(nameReq, 'discovery must continue by scanning when the count is unavailable')
end)

test('discovery gives up when the panel answers past the end with nothing', function()
  freshDriver()
  local h = connectPanel()
  -- Panel claims 144 zones but only has 1; requests past the end come back
  -- with an empty parameter list rather than nulls.
  local names = { 'Front Door' }
  local _, pages = runDiscovery(h, names, nil, 144)
  assert(DiscoveredZonesCount == 1, 'only the named zone should be collected, got ' ..
    tostring(DiscoveredZonesCount))
  assert(pages < 12, 'discovery should give up after a few empty pages, took ' .. pages)
end)

test('unnamed zones returned as nulls do not end discovery early', function()
  freshDriver()
  local h = connectPanel()
  -- Zones 1-20 exist; only a few are named, the rest come back as nulls.
  local names = { n = 20 }
  names[1] = 'Front Door'
  names[15] = 'Back Door'
  names[20] = 'Garage'
  runDiscovery(h, names)
  assert(DiscoveredZonesCount == 3, 'named zones spread across pages must all be found, got ' ..
    tostring(DiscoveredZonesCount))
  assert(DiscoveredZonesFull:find('20,Garage,contact,1', 1, true),
    'a named zone after a long unnamed run must still be discovered')
end)

test('applying discovered zones fills Zones Config and republishes the list', function()
  freshDriver({ ['Zones Config'] = '' })
  local h = connectPanel()
  runDiscovery(h, { 'Front Door', 'Back Door' })
  calls.SendToProxy = {}
  ExecuteCommand('Apply Discovered Zones', {})
  assert(Properties['Zones Config'] == '1,Front Door,contact,1;2,Back Door,contact,1',
    'Zones Config should now hold the discovered list, got: ' .. tostring(Properties['Zones Config']))
  assert(Zones[1] and Zones[1].name == 'Front Door', 'the zones must be parsed into memory')
  assert(Zones[2] and Zones[2].name == 'Back Door')
  assert(#proxyCalls(5001, 'PANEL_ZONE_INFO') == 2, 'the app must get the new zone list immediately')
  assert((Properties['Last Command Result'] or ''):find('Applied 2 zones', 1, true),
    'the outcome must be reported, got: ' .. tostring(Properties['Last Command Result']))
end)

test('applying with nothing discovered says so instead of wiping Zones Config', function()
  freshDriver({ ['Zones Config'] = '1,Existing,contact,1' })
  Properties['Discovered Zones'] = ''
  ExecuteCommand('Apply Discovered Zones', {})
  assert(Properties['Zones Config'] == '1,Existing,contact,1',
    'an empty discovery must never clobber a working configuration')
  assert((Properties['Last Command Result'] or ''):find('Discover Zone Names', 1, true),
    'it must tell you what to do first')
end)

test('a long zone list is applied IN FULL, not cut to the preview', function()
  freshDriver({ ['Zones Config'] = '' })
  local h = connectPanel()
  -- Enough zones that the preview property cannot hold them all.
  local names = {}
  for i = 1, 120 do names[i] = 'Zone Name Number ' .. i .. ' Long Enough To Overflow' end
  runDiscovery(h, names)
  assert(DiscoveredZonesCount == 120, 'all zones must be discovered, got ' .. tostring(DiscoveredZonesCount))
  assert(#(Properties['Discovered Zones'] or '') < #DiscoveredZonesFull,
    'the preview property should indeed be shorter than the full list')
  assert((Properties['Discovered Zones'] or ''):find('preview shows', 1, true),
    'the preview must say it is a preview and point at the action')
  ExecuteCommand('Apply Discovered Zones', {})
  local applied = 0
  for _ in pairs(Zones) do applied = applied + 1 end
  assert(applied == 120, 'every discovered zone must be applied, got ' .. applied)
  assert(Zones[120] and Zones[120].name:find('Number 120', 1, true),
    'the last zone must survive -- this is the case the old code silently dropped')
end)

test('the preview is cut at an entry boundary, never mid-name', function()
  freshDriver()
  local h = connectPanel()
  local names = {}
  for i = 1, 120 do names[i] = 'Zone ' .. i .. ' with a reasonably long descriptive name' end
  runDiscovery(h, names)
  local preview = Properties['Discovered Zones'] or ''
  local body = preview:match('^(.-) %.%.%. %(preview shows') or preview
  for entry in body:gmatch('[^;]+') do
    assert(entry:match('^%d+,'), 'every previewed entry must be whole, got: ' .. entry)
    local fields = select(2, entry:gsub(',', ',')) + 1
    assert(fields == 4, 'entry should have 4 fields, got ' .. fields .. ' in: ' .. entry)
  end
end)

test('a preview-only property is not applied after a reload lost the full list', function()
  freshDriver({ ['Zones Config'] = '1,Existing,contact,1' })
  -- Simulates: discovery ran, driver reloaded, only the shortened preview survives.
  DiscoveredZonesFull = nil
  Properties['Discovered Zones'] = '1,A,contact,1 ... (preview shows 1 of 90 zones -- use the "Apply Discovered Zones" action, which applies all 90)'
  ExecuteCommand('Apply Discovered Zones', {})
  assert(Properties['Zones Config'] == '1,Existing,contact,1',
    'applying a shortened preview would silently lose zones')
end)

test('a complete (unshortened) property still applies after a reload', function()
  freshDriver({ ['Zones Config'] = '' })
  DiscoveredZonesFull = nil
  Properties['Discovered Zones'] = '1,Front Door,contact,1;2,Back Door,contact,1'
  ExecuteCommand('Apply Discovered Zones', {})
  assert(Properties['Zones Config'] == '1,Front Door,contact,1;2,Back Door,contact,1',
    'a short list that was never shortened must still be usable after a reload')
end)

test('a discovery does not survive a driver reload', function()
  freshDriver()
  local h = connectPanel()
  runDiscovery(h, { 'Front Door' })
  assert(DiscoveredZonesFull ~= nil)
  freshDriver()   -- reload
  assert(DiscoveredZonesFull == nil,
    'a stale discovery must not be applied over a config edited since')
end)

--=============================================================================
section('Arm/disarm must never queue behind bookkeeping')
--=============================================================================

-- The reference implementation writes an OPERATION to the socket
-- immediately, with no queue. This driver used to put arm/disarm behind a
-- one-at-a-time request queue that the connect-time state sync fills, so a
-- Disarm pressed just after a reconnect sat behind several 5s-timeout
-- queries and did nothing, silently, for tens of seconds.

test('a disarm sent while state queries are outstanding goes straight out', function()
  freshDriver()
  local h = connectPanel(1, true)     -- keep the connect-time sync traffic
  assert(InFlight ~= nil or #OutQueue > 0, 'the sync should have queued work')
  calls.ServerSend = {}
  DisarmPartition(1)
  local ops = operations()
  assert(#ops == 1 and ops[1].optype == 17,
    'the disarm must reach the wire immediately, not queue behind the sync (got ' ..
    #ops .. ' operations)')
end)

test('arm and disarm issued back-to-back both reach the panel', function()
  freshDriver()
  connectPanel()
  calls.ServerSend = {}
  ArmPartition(1, 'away')
  DisarmPartition(1)
  local ops = operations()
  assert(#ops == 2, 'both commands must go out with no pacing delay, got ' .. #ops)
  assert(ops[1].optype == 12 and ops[2].optype == 17)
  assert(ops[2].counter > ops[1].counter, 'counters must advance')
end)

test('a full request queue does not block arm/disarm', function()
  freshDriver()
  connectPanel()
  -- Saturate the query queue.
  InFlight = { counter = 1, match = function() return false end, timerId = 999 }
  for i = 1, 40 do
    EnqueueRequest({ frame = { account = 1234, frame_type = 'DATA-REQ', id = 2149, start_order = i },
                     match = function() return false end })
  end
  calls.ServerSend = {}
  DisarmPartition(1)
  assert(#operations() == 1, 'disarm must be unaffected by query backlog')
end)

test('an unanswered OPERATION reports back rather than hanging silently', function()
  freshDriver()
  connectPanel()
  local reported
  SendOperation(1, 12, 0, nil, function(f, err) reported = err end)
  -- Fire the reply-timeout timer.
  local timerId
  for id, _ in pairs(PendingOperationTimers) do timerId = id end
  assert(timerId, 'a reply timeout should have been scheduled')
  OnTimerExpired(timerId)
  assert(reported and reported:find('no ACK', 1, true),
    'an unanswered command must be reported, got: ' .. tostring(reported))
end)

test('a NAK for an OPERATION reaches its caller and the property', function()
  freshDriver()
  local h = connectPanel()
  local reported
  SendOperation(1, 17, 0, nil, function(f, err) reported = err end)
  local op = operations()[1]
  OnServerDataIn(h, string.format(
    '{"frame_type":"NAK","account":1234,"counter":%d,"DATA":"Wrong User Code"}', op.counter),
    '10.0.0.50', 5555)
  assert(reported == 'Wrong User Code', 'got ' .. tostring(reported))
  assert(Properties['Last NAK Reason'] == 'Wrong User Code')
end)

--=============================================================================
section('The driver must not go deaf when another socket appears')
--=============================================================================

test('a silent second connection does not stop the real panel being heard', function()
  freshDriver()
  local h = connectPanel(1)
  -- Something else opens the port and says nothing (scanner, probe, stray CMS path).
  OnServerConnectionStatusChanged(2, 7780, 'ONLINE')
  calls.FireEvent = {}
  calls.ServerSend = {}
  -- The real panel keeps talking on its original socket.
  OnServerDataIn(1, '{"frame_type":"null","account":"1234","counter":7}', '10.0.0.50', 5555)
  OnServerDataIn(1, '{"frame_type":"event","counter":8,"account":"1234","type":760,"qualifier":1,"zone":1,"partition":1}', '10.0.0.50', 5555)
  local fired = false
  for _, e in ipairs(calls.FireEvent) do if e == 'Zone Opened' then fired = true end end
  assert(fired, 'the real panel must still be heard while a silent socket holds the slot')
  local acked = false
  for _, f in ipairs(wireFrames()) do if f and f.frame_type == 'ACK' then acked = true end end
  assert(acked, 'and must still be ACKed, or it will drop the connection')
end)

test('following a new socket still requires it to verify', function()
  freshDriver()
  connectPanel(1)
  -- A different socket starts talking with the WRONG account.
  calls.FireEvent = {}
  OnServerDataIn(2, '{"frame_type":"event","counter":9,"account":"9999","type":130,"qualifier":1,"zone":3,"partition":1}', '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] ~= 'Alarm',
    'an unverified socket must not be able to raise an alarm')
end)

test('a partition state change refreshes the ALL_PARTITIONS_INFO document', function()
  -- The app's status header reads <state> out of ALL_PARTITIONS_INFO. That
  -- document used to be published only by SendPanelInfo(), whose fingerprint
  -- ignores live state, so the only copy the app ever saw was the OFFLINE one
  -- from load time -- the header stayed "Unknown" forever even after the panel
  -- reported Armed Away.
  local h = freshDriver()
  connectPanel(h, true)
  answerSyncQueries(h, 3)                      -- system key 3 = Armed Away
  assert(Properties['Partition 1 State']:match('^Armed Away'),
    'precondition: the sync must have produced Armed Away')
  local docs = proxyCalls(5001, 'ALL_PARTITIONS_INFO')
  assert(#docs > 0, 'ALL_PARTITIONS_INFO must be published at all')
  local last = docs[#docs][3]
  assert(last:match('<state>ARMED</state>'),
    'the most recent partitions document must carry the synced state, got: ' .. tostring(last))
end)

test('an unchanged partition state does not re-send the partitions document', function()
  local h = freshDriver()
  connectPanel(h, true)
  answerSyncQueries(h, 3)
  local before = #proxyCalls(5001, 'ALL_PARTITIONS_INFO')
  SetPartitionState(1, 'Armed Away (Full Arm)')
  SetPartitionState(1, 'Armed Away (Full Arm)')
  assert(#proxyCalls(5001, 'ALL_PARTITIONS_INFO') == before,
    'republishing an identical document on every event is the cost this guards against')
end)

test('a large zone list does not block the driver-load callback', function()
  -- Composer froze for ~40s on every driver update once 40 zones were
  -- imported: the per-zone PANEL_ZONE_INFO/HAS_ZONE notifications are
  -- blocking Director round trips, and they all ran inside OnDriverLateInit
  -- and the Zones Config change handler -- the very callbacks Composer waits
  -- on. The whole-inventory documents stay synchronous; the per-zone traffic
  -- is drained on a timer.
  local zl = {}
  for i = 1, 45 do zl[#zl + 1] = i .. ',Zone ' .. i .. ',contact,1' end
  freshDriver({ ['Zones Config'] = table.concat(zl, ';') })

  local zoneCalls = #proxyCalls(nil, 'PANEL_ZONE_INFO') + #proxyCalls(nil, 'HAS_ZONE')
  assert(zoneCalls <= 2 * ZONE_PUBLISH_BATCH,
    'the load callback must publish at most one batch inline, sent ' .. zoneCalls)
  assert(#proxyCalls(5001, 'ALL_ZONES_INFO') > 0,
    'the zone document itself is two calls and must still go out immediately')

  -- Drain.
  local guard = 0
  while ZonePublishTimerId and guard < 100 do
    guard = guard + 1
    OnTimerExpired(ZonePublishTimerId)
  end
  assert(#proxyCalls(nil, 'HAS_ZONE') == 45,
    'every zone must still reach the partition proxy, got ' .. #proxyCalls(nil, 'HAS_ZONE'))
  assert(#proxyCalls(nil, 'PANEL_ZONE_INFO') == 45,
    'and the panel proxy, got ' .. #proxyCalls(nil, 'PANEL_ZONE_INFO'))
end)

test('PANEL_INITIALIZED is sent only after the last zone', function()
  local zl = {}
  for i = 1, 45 do zl[#zl + 1] = i .. ',Zone ' .. i .. ',contact,1' end
  freshDriver({ ['Zones Config'] = table.concat(zl, ';') })
  assert(#proxyCalls(nil, 'PANEL_INITIALIZED') == 0,
    'announcing the panel ready with two thirds of its zones unpublished tells ' ..
    'Navigator to render a list that is still being built')
  local guard = 0
  while ZonePublishTimerId and guard < 100 do
    guard = guard + 1
    OnTimerExpired(ZonePublishTimerId)
  end
  assert(#proxyCalls(nil, 'PANEL_INITIALIZED') == 1, 'exactly one, after the drain')
  local last = calls.SendToProxy[#calls.SendToProxy]
  assert(last[2] == 'PANEL_INITIALIZED', 'and it must be the final notification')
end)

test('a second publish replaces the pending one instead of interleaving', function()
  local zl = {}
  for i = 1, 45 do zl[#zl + 1] = i .. ',Zone ' .. i .. ',contact,1' end
  freshDriver({ ['Zones Config'] = table.concat(zl, ';') })
  local firstTimer = ZonePublishTimerId
  assert(firstTimer, 'precondition: a drain must be pending')

  -- The installer edits the zone list while the first publish is mid-flight.
  calls.SendToProxy = {}
  Properties['Zones Config'] = '1,Only Zone,contact,1'
  OnPropertyChanged('Zones Config')
  local guard = 0
  while ZonePublishTimerId and guard < 100 do
    guard = guard + 1
    OnTimerExpired(ZonePublishTimerId)
  end
  -- The stale timer must be inert: firing it must not resume the old walk.
  OnTimerExpired(firstTimer)
  local ids = {}
  for _, c in ipairs(proxyCalls(nil, 'PANEL_ZONE_INFO')) do ids[#ids + 1] = c[3].ID end
  assert(#ids == 1 and ids[1] == 1,
    'the app must not be shown a mix of the old and new zone lists, got ' .. #ids .. ' zones')
end)

test('a property is not rewritten with the value it already holds', function()
  -- Composer's property grid redraws on every property push from the driver.
  -- A single zone event used to rewrite seven properties, most of them
  -- unchanged (Last Event Partition is "1" forever on a one-partition house),
  -- so a chatty panel kept the panel redrawing -- the stutter felt when
  -- scrolling the properties list.
  freshDriver()
  local h = connectPanel()
  calls.UpdateProperty = {}
  local function zoneEvent(counter, qualifier)
    OnServerDataIn(h, string.format(
      '{"frame_type":"event","counter":%d,"account":"1234","type":760,"qualifier":%d,"zone":1,"partition":1}',
      counter, qualifier), '10.0.0.50', 5555)
  end
  zoneEvent(200, 1)
  local firstBurst = #calls.UpdateProperty
  calls.UpdateProperty = {}
  zoneEvent(201, 1)   -- byte-identical event: nothing about it has changed
  local repeatBurst = #calls.UpdateProperty
  assert(repeatBurst < firstBurst,
    'a repeat of the same event must cost fewer property writes than the first (' ..
    repeatBurst .. ' vs ' .. firstBurst .. ')')
  for _, u in ipairs(calls.UpdateProperty) do
    assert(u[1] == 'Recent Activity' or u[1] == 'Last Raw Frame In',
      'only genuinely-changing properties may be rewritten, got ' .. tostring(u[1]))
  end
end)

test('a forced write still goes out when the value is unchanged', function()
  freshDriver()
  calls.UpdateProperty = {}
  SetProp('Last Command Result', 'same')
  SetProp('Last Command Result', 'same')
  assert(#calls.UpdateProperty == 1, 'the second write is the one being suppressed')
  SetProp('Last Command Result', 'same', true)
  assert(#calls.UpdateProperty == 2, 'force must bypass the unchanged check')
end)

test('the properties panel is never handed multi-kilobyte values', function()
  -- Long STRING property values are what make Composer's property grid slow.
  freshDriver()
  local h = connectPanel()
  for i = 1, 40 do
    RecordActivity(string.rep('x', 400) .. ' event ' .. i)
  end
  assert(#Properties['Recent Activity'] < 3500,
    'Recent Activity must stay small; it is ' .. #Properties['Recent Activity'] .. ' bytes')

  local names = {}
  for i = 1, 60 do names[i] = 'A rather long zone name number ' .. i end
  runDiscovery(h, names)
  assert(#Properties['Discovered Zones'] < 1000,
    'Discovered Zones is a preview only; it is ' .. #Properties['Discovered Zones'] .. ' bytes')
  -- ...and shortening the preview must not shorten what Apply writes.
  ExecuteCommand('Apply Discovered Zones', {})
  local applied = 0
  for _ in pairs(Zones) do applied = applied + 1 end
  assert(applied == 60, 'all 60 zones must still be applied, got ' .. applied)
end)

test('diagnostic properties are hidden from the config panel until debug is on', function()
  freshDriver({ ['Log Level'] = 'Info' })
  local hidden = calls.SetPropertyAttribs
  assert(hidden['Last Raw Frame In'] == 1, 'raw frames are data, not configuration')
  assert(hidden['Recent Activity'] == 1, 'the activity buffer is data too')
  assert(hidden['Listen Port'] == nil, 'configuration must never be hidden')
  assert(hidden['Zones Config'] == nil, 'nor the zone list')
  assert(hidden['Discovered Zones'] == nil,
    'Discovered Zones is part of the setup workflow and stays visible')

  Properties['Log Level'] = 'Debug'
  OnPropertyChanged('Log Level')
  assert(hidden['Last Raw Frame In'] == 0, 'Debug level must reveal them again')
end)

test('a Director without SetPropertyAttribs does not break driver init', function()
  freshDriver()
  C4.SetPropertyAttribs = nil
  local ok = pcall(ApplyPropertyVisibility)
  assert(ok, 'hiding a property is cosmetic and must never take driver init down')
end)

test('a cold sync sends a live PARTITION_STATE, not only the seed', function()
  -- The app kept showing UNKNOWN -- the partition proxy's default -- after a
  -- successful state sync, because the sync only ever sent
  -- PARTITION_STATE_INIT, which Navigator does not appear to re-render on.
  local h = freshDriver()
  connectPanel(h, true)
  calls.SendToProxy = {}
  answerSyncQueries(h, 3)                      -- system key 3 = Armed Away
  local live = proxyCalls(5002, 'PARTITION_STATE')
  local seed = proxyCalls(5002, 'PARTITION_STATE_INIT')
  assert(#seed > 0, 'the seed must still be sent, so a reload is not read as a fresh arming')
  assert(#live > 0, 'and a live state must follow it, or the app never redraws')
  assert(live[#live][3].STATE == 'ARMED',
    'the live notification must carry the synced state, got ' .. tostring(live[#live][3].STATE))
end)

--=============================================================================
print('')
print('Log levels, SET_ZONE_INFO and the link watchdog')

test('an error is still logged at the quietest level', function()
  freshDriver({ ['Log Level'] = 'Error' })
  local out = table.concat(withCapturedLogs(function()
    LogError('something failed')
    LogWarn('something looks odd')
    LogInfo('something happened')
    Dbg('a frame went by')
  end), '\n')
  assert(out:find('ERROR: something failed'), 'errors must survive every level')
  assert(not out:find('looks odd'), 'a warning must not appear at Error level')
  assert(not out:find('something happened'), 'nor an info line')
  assert(not out:find('a frame went by'), 'nor the trace')
end)

test('each level includes the ones above it', function()
  freshDriver({ ['Log Level'] = 'Warning' })
  local out = table.concat(withCapturedLogs(function()
    LogError('E'); LogWarn('W'); LogInfo('Info line')
  end), '\n')
  assert(out:find('ERROR: E') and out:find('WARNING: W'), 'Warning includes Error')
  assert(not out:find('Info line'), 'but not Info')
end)

test('the pre-v16 Debug Logging property still turns the trace on', function()
  -- A project updated in place can still be holding the old On/Off property.
  -- Silently reverting a deliberate trace to the default would be the worst
  -- possible time to lose logging.
  Properties = {}
  freshDriver()
  Properties['Log Level'] = nil
  Properties['Debug Logging'] = 'On'
  ResolveLogLevel()
  assert(DEBUG_ON, 'legacy "On" must map to Debug level')
  Properties['Debug Logging'] = 'Off'
  ResolveLogLevel()
  assert(not DEBUG_ON and LogLevel == LOG_INFO, 'and legacy "Off" to Info, not to silence')
end)

test('SET_ZONE_INFO is handled instead of warned about', function()
  freshDriver()
  local out = table.concat(withCapturedLogs(function()
    ReceivedFromProxy(5001, 'SET_ZONE_INFO', { ZONE_ID = '1', NAME = 'Front Door', TYPE_ID = '2' })
  end), '\n')
  assert(not out:find('unhandled command'),
    'Navigator sends this on every security-agent refresh; it must not log a warning')
end)

test('a zone renamed in the app is written back to Zones Config', function()
  freshDriver()
  ReceivedFromProxy(5001, 'SET_ZONE_INFO', { ZONE_ID = '1', NAME = 'Porch Door' })
  assert(Zones[1].name == 'Porch Door', 'the rename must be taken')
  assert(Properties['Zones Config']:find('1,Porch Door'),
    'and persisted, or it is lost on the next reload: ' .. tostring(Properties['Zones Config']))
  assert(Properties['Zones Config']:find('7,Shed'), 'without dropping the other zones')
end)

test('a rename containing a separator cannot corrupt Zones Config', function()
  freshDriver()
  ReceivedFromProxy(5001, 'SET_ZONE_INFO', { ZONE_ID = '1', NAME = 'Kitchen, Side; Door' })
  local cfg = Properties['Zones Config']
  local separators = select(2, cfg:gsub(';', ';'))
  assert(separators == 1, 'still exactly two zones, got: ' .. cfg)
  Properties['Zones Config'] = cfg
  OnPropertyChanged('Zones Config')
  local reparsed = 0
  for _ in pairs(Zones) do reparsed = reparsed + 1 end
  assert(reparsed == 2, 'and it must survive a round trip through the parser, got ' .. reparsed)
end)

test('a half-open connection is eventually reported as disconnected', function()
  -- The panel is powered off mid-session: the socket stays open, no TCP
  -- disconnect ever arrives, and before v16 the driver reported "Connected"
  -- forever for a panel it could not hear -- so an alarm would never arrive
  -- and nothing anywhere would say why.
  freshDriver()
  local h = connectPanel()
  assert(Properties['Connection Status'] == 'Connected', 'precondition')
  assert(LinkWatchdogTimerId, 'a watchdog must be running while connected')

  advanceClock(200 * 1000)                   -- 200s of silence, limit is 90s
  OnTimerExpired(LinkWatchdogTimerId)
  assert(Properties['Connection Status'] == 'Not Connected',
    'silence past the limit must be reported, got ' .. tostring(Properties['Connection Status']))
  assert(Properties['Partition 1 State'] == 'Unknown',
    'and the partition must stop claiming a state we can no longer see')
end)

test('a heartbeat keeps the link alive', function()
  freshDriver()
  local h = connectPanel()
  for _ = 1, 5 do
    advanceClock(60 * 1000)                  -- 60s, comfortably under the limit
    OnServerDataIn(h, '{"frame_type":"null","account":"1234","counter":50}', '10.0.0.50', 5555)
    OnTimerExpired(LinkWatchdogTimerId)
  end
  assert(Properties['Connection Status'] == 'Connected',
    'a panel that is still sending heartbeats must not be declared dead')
end)

test('unparseable bytes still count as the panel being alive', function()
  freshDriver()
  local h = connectPanel()
  advanceClock(80 * 1000)
  -- A frame split across TCP segments: valid protocol, not yet parseable.
  OnServerDataIn(h, '{"frame_type":"null","acc', '10.0.0.50', 5555)
  advanceClock(80 * 1000)
  OnTimerExpired(LinkWatchdogTimerId)
  assert(Properties['Connection Status'] ~= 'Not Connected',
    'the watchdog asks whether the panel is THERE, not whether it is well')
end)

test('a zero Link Timeout disables the watchdog rather than firing instantly', function()
  freshDriver({ ['Link Timeout Seconds'] = '0' })
  local h = connectPanel()
  advanceClock(9999 * 1000)
  OnTimerExpired(LinkWatchdogTimerId)
  assert(Properties['Connection Status'] == 'Connected',
    '0 means the installer turned the check off, not a zero-second deadline')
end)

test('a clock that steps backwards does not trip the watchdog', function()
  freshDriver()
  local h = connectPanel()
  advanceClock(-500 * 1000)                  -- NTP correction
  OnTimerExpired(LinkWatchdogTimerId)
  assert(Properties['Connection Status'] == 'Connected',
    'a negative interval means the clock moved, not that the panel went away')
end)


test('a burst of zone open/close never displaces arm/disarm/alarm from Recent Activity', function()
  -- The whole point of this buffer being a critical-events log: 40 zones
  -- cycling open/closed all evening must not push a real alarm out of a
  -- 25-entry ring buffer, because zone open/close never occupies a slot in
  -- it at all.
  local h = freshDriver()
  connectPanel(h)

  -- A burglary alarm goes in...
  OnServerDataIn(h, '{"frame_type":"event","counter":300,"account":"1234","type":130,"qualifier":1,"zone":0,"partition":1}',
    '10.0.0.50', 5555)
  assert(Properties['Recent Activity']:find('BURGLARY ALARM'), 'precondition: the alarm must be recorded')

  -- ...then 40 zones open and close, one event per zone.
  local counter = 301
  for zone = 1, 40 do
    OnServerDataIn(h, string.format(
      '{"frame_type":"event","counter":%d,"account":"1234","type":760,"qualifier":1,"zone":%d,"partition":1}',
      counter, zone), '10.0.0.50', 5555)
    counter = counter + 1
    OnServerDataIn(h, string.format(
      '{"frame_type":"event","counter":%d,"account":"1234","type":760,"qualifier":3,"zone":%d,"partition":1}',
      counter, zone), '10.0.0.50', 5555)
    counter = counter + 1
  end

  assert(Properties['Recent Activity']:find('BURGLARY ALARM'),
    '80 zone events must not evict the alarm entry: ' .. Properties['Recent Activity'])
  assert(not Properties['Recent Activity']:find('[Zz]one 1 '),
    'zone open/close text must never appear in this property at all: ' .. Properties['Recent Activity'])
end)

test('arm and disarm are recorded in Recent Activity', function()
  local h = freshDriver()
  local handle = connectPanel(h, true)
  answerSyncQueries(handle, 1)                 -- starts disarmed
  ClearInFlight(); ResetQueueState(); calls.ServerSend = {}
  -- Local disarm event (CID 401-family), then an arm.
  OnServerDataIn(handle, '{"frame_type":"event","counter":400,"account":"1234","type":401,"qualifier":1,"zone":0,"partition":1}',
    '10.0.0.50', 5555)
  assert(Properties['Recent Activity']:find('disarmed'),
    'a disarm must be recorded: ' .. Properties['Recent Activity'])
  OnServerDataIn(handle, '{"frame_type":"event","counter":401,"account":"1234","type":401,"qualifier":3,"zone":0,"partition":1}',
    '10.0.0.50', 5555)
  answerSyncQueries(handle, 3)                 -- the follow-up mode query
  assert(Properties['Recent Activity']:find('Armed'),
    'an arm must be recorded too: ' .. Properties['Recent Activity'])
end)


test('every zone resolves to a partition even with several configured (v22)', function()
  -- The "UNKNOWN" group header above the app's zone list: with 2+ partitions
  -- configured and zones whose Zones Config entry omits the 4th field, every
  -- zone used to resolve to nil -> empty <partitions></partitions> and no
  -- HAS_ZONE, so the zone belonged to no partition at all.
  freshDriver({
    ['Partitions Config'] = '1,Main,1111,ASN;2,Garage,2222,A',
    ['Zones Config'] = '1,Front Door,contact;7,Kitchen Motion,motion',
  })
  assert(ZonePartition(1, nil) == 1, 'an unattributed zone must fall back to a real partition, got ' ..
    tostring(ZonePartition(1, nil)))
  local xml = AllZonesInfoXML()
  assert(not xml:find('<partitions></partitions>'),
    'no zone may be published with an empty partitions field: ' .. xml)
end)

test('an unattributed zone still gets HAS_ZONE on a multi-partition system (v22)', function()
  freshDriver({
    ['Partitions Config'] = '1,Main,1111,ASN;2,Garage,2222,A',
    ['Zones Config'] = '1,Front Door,contact;7,Kitchen Motion,motion',
  })
  local hasZone = proxyCalls(5002, 'HAS_ZONE')
  assert(#hasZone >= 2, 'both zones must be claimed by a partition, got ' .. #hasZone)
end)

test('an explicit partition in Zones Config still wins over the fallback', function()
  freshDriver({
    ['Partitions Config'] = '1,Main,1111,ASN;2,Garage,2222,A',
    ['Zones Config'] = '1,Front Door,contact,2',
  })
  assert(ZonePartition(1, nil) == 2, 'an explicitly-placed zone must stay where it was put')
end)

test('a quiet zone stops reporting to the app but keeps tracking state', function()
  freshDriver({
    ['Zones Config'] = '1,Front Door,contact,1;7,Kitchen Motion,motion,1',
    ['Quiet Zones'] = 'motion',
  })
  connectPanel()
  calls.SendToProxy = {}
  NotifyProxyZoneState(7, true, nil, 1)
  assert(#proxyCalls(nil, 'ZONE_STATE') == 0, 'a quiet zone must not push ZONE_STATE')
  assert(#proxyCalls(nil, 'PANEL_ZONE_STATE') == 0, 'a quiet zone must not push PANEL_ZONE_STATE')
  assert(ZoneState[7].open == true, 'a quiet zone must still track its real state internally')
  -- A non-quiet zone in the same config is unaffected.
  NotifyProxyZoneState(1, true, nil, 1)
  assert(#proxyCalls(nil, 'ZONE_STATE') > 0, 'a normal zone must still report')
end)

test('a quiet zone still fires its Control4 programming event', function()
  freshDriver({
    ['Zones Config'] = '7,Kitchen Motion,motion,1',
    ['Quiet Zones'] = 'motion',
  })
  local h = connectPanel()
  calls.FireEvent = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":9,"account":"1234","type":760,"qualifier":1,"zone":7,"partition":1}',
    '10.0.0.50', 5555)
  local fired = false
  for _, e in ipairs(calls.FireEvent) do
    if e == 'Zone Opened' then fired = true end
  end
  assert(fired, 'silencing the app must never silence automations')
end)

-- Drives one bypass write through to its read-back. `applied` is what the
-- panel reports when asked (nil = the read-back never answers).
local function runBypass(h, zone, requested, applied)
  SetZoneBypass(zone, requested)
  local write
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'DATA' and tonumber(f.id) == 2150 then write = f end
  end
  assert(write, 'the bypass write must reach the panel')
  calls.ServerSend = {}
  OnServerDataIn(h, string.format('{"frame_type":"ACK","account":1234,"counter":%d,"kc":1}',
    write.counter), '10.0.0.50', 5555)
  if applied == nil then return end
  local read
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'DATA-REQ' and tonumber(f.id) == 2150 then read = f end
  end
  assert(read, 'an ACKed bypass must be read back, not trusted')
  assert(read.start_order == zone and read.stop_order == zone,
    'the read-back must ask for exactly that zone')
  OnServerDataIn(h, string.format(
    '{"frame_type":"DATA","account":1234,"counter":%d,"id":2150,"start_order":%d,"parameters":["%s"]}',
    read.counter, zone, applied and '1' or '0'), '10.0.0.50', 5555)
end

test('a bypass is verified by reading 2150 back, not trusted from the ACK (v26)', function()
  freshDriver({ ['Zones Config'] = '4,Store Room,contact,1' })
  local h = connectPanel()
  runBypass(h, 4, true, true)
  assert(ZoneState[4].bypassed == true, 'a confirmed bypass must be reflected')
  assert(Properties['Last Command Result']:find('confirmed'),
    'a verified bypass must say confirmed: ' .. Properties['Last Command Result'])
end)

test('a bypass the panel ACKs but does not apply is reported as failed (v26)', function()
  -- The validated failure mode: a zone cancelled in technician programming
  -- is ACKed and then simply not bypassed. Believing the ACK would show a
  -- live detector as bypassed.
  freshDriver({ ['Zones Config'] = '4,Store Room,contact,1' })
  local h = connectPanel()
  local logged = withCapturedLogs(function() runBypass(h, 4, true, false) end)
  assert(ZoneState[4].bypassed == false,
    'the app must be shown the panel\'s real state, not the requested one')
  assert(table.concat(logged, '\n'):find('NOT applied'),
    'an unapplied bypass must be reported as failed')
  assert(AutoBypassTimerForZone[4] == nil,
    'no auto-clear may be armed for a bypass that never happened')
end)

test('a clear that the panel ACKs but does not apply keeps the safety timer running', function()
  -- The dangerous direction: the detector is still disabled, so the driver
  -- must keep trying rather than walking away.
  freshDriver({ ['Zones Config'] = '4,Store Room,contact,1' })
  local h = connectPanel()
  runBypass(h, 4, true, true)          -- genuinely bypassed first
  calls.ServerSend = {}
  runBypass(h, 4, false, true)         -- asked to clear; panel still says bypassed
  assert(ZoneState[4].bypassed == true, 'the zone is still bypassed and must show that')
  assert(AutoBypassTimerForZone[4] ~= nil,
    'a failed clear must leave the safety auto-clear armed to retry')
end)

test('a bypass whose read-back never answers is reported as unverified, not as success', function()
  freshDriver({ ['Zones Config'] = '4,Store Room,contact,1' })
  local h = connectPanel()
  runBypass(h, 4, true, nil)           -- ACK arrives, read-back does not
  local logged = withCapturedLogs(function()
    OnServerConnectionStatusChanged(h, 7780, 'OFFLINE')
  end)
  assert(Properties['Last Command Result']:find('UNVERIFIED'),
    'an unverifiable bypass must say so rather than claim success: ' ..
    Properties['Last Command Result'])
end)

test('Functions: Bypass Open Zones bypasses only the open, bypassable ones (v28)', function()
  freshDriver({
    ['Zones Config'] = '1,Front Door,contact,1;2,Window,window,1;13,Smoke,smoke,1',
    ['Non-Bypassable Zones'] = 'smoke',
  })
  local h = connectPanel()
  NotifyProxyZoneState(1, true, nil, 1)      -- open
  NotifyProxyZoneState(2, false, nil, 1)     -- closed
  NotifyProxyZoneState(13, true, nil, 1)     -- open but life-safety
  calls.ServerSend = {}
  ExecutePartitionFunction(1, 'Bypass Open Zones')
  local bypassed = {}
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'DATA' and tonumber(f.id) == 2150 then
      bypassed[f.start_order] = JSON.scalar(f.parameters[1])
    end
  end
  assert(bypassed[1] == '1', 'the open zone must be bypassed')
  assert(bypassed[2] == nil, 'a closed zone must be left alone')
  assert(bypassed[13] == nil, 'a non-bypassable zone must never be bypassed')
  assert(Properties['Last Command Result']:find('Front Door'),
    'the result must name what was bypassed: ' .. Properties['Last Command Result'])
  assert(Properties['Last Command Result']:find('Smoke'),
    'and name what was deliberately left armed')
end)

test('Functions: Bypass Open Zones says so when there is nothing open', function()
  freshDriver({ ['Zones Config'] = '1,Front Door,contact,1' })
  connectPanel()
  calls.ServerSend = {}
  ExecutePartitionFunction(1, 'Bypass Open Zones')
  assert(Properties['Last Command Result']:find('no open zones'),
    'got ' .. Properties['Last Command Result'])
end)

test('Functions: Clear All Bypasses clears every bypassed zone', function()
  freshDriver({ ['Zones Config'] = '1,Front Door,contact,1;2,Window,window,1' })
  local h = connectPanel()
  NotifyProxyZoneState(1, nil, true, 1)      -- bypassed
  NotifyProxyZoneState(2, nil, false, 1)     -- not bypassed
  calls.ServerSend = {}
  ExecutePartitionFunction(1, 'Clear All Bypasses')
  local cleared = {}
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'DATA' and tonumber(f.id) == 2150 then
      cleared[f.start_order] = JSON.scalar(f.parameters[1])
    end
  end
  assert(cleared[1] == '0', 'the bypassed zone must be cleared')
  assert(cleared[2] == nil, 'an un-bypassed zone needs no write')
end)

test('Functions: Clear All Bypasses is never blocked by Non-Bypassable Zones', function()
  -- Clearing must always be possible, or a life-safety zone bypassed at the
  -- keypad could never be restored from the app.
  freshDriver({
    ['Zones Config'] = '13,Smoke,smoke,1',
    ['Non-Bypassable Zones'] = 'smoke',
  })
  local h = connectPanel()
  NotifyProxyZoneState(13, nil, true, 1)
  calls.ServerSend = {}
  ExecutePartitionFunction(1, 'Clear All Bypasses')
  local wrote = false
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'DATA' and tonumber(f.id) == 2150 then wrote = true end
  end
  assert(wrote, 'clearing a non-bypassable zone must still be allowed')
end)

test('arming or disarming with the MASTER code (CID 400) is not missed (v27)', function()
  -- PIMA's Appendix A distinguishes 400 (master code) from 401 (user/remote
  -- code). Only 401 was handled, so a master-code disarm reported nothing
  -- and the widget kept showing Armed until some later sync corrected it.
  freshDriver()
  local h = connectPanel(1, true)
  answerSyncQueries(h, 3)                    -- armed away to begin with
  assert(Properties['Partition 1 State']:find('Armed'), 'setup: must start armed')
  ClearInFlight(); ResetQueueState(); calls.ServerSend = {}
  OnServerDataIn(h, '{"frame_type":"event","counter":900,"account":"1234","type":400,"qualifier":1,"zone":0,"partition":1}',
    '10.0.0.50', 5555)
  assert(Properties['Partition 1 State'] == 'Disarmed',
    'a master-code disarm must be applied, got ' .. tostring(Properties['Partition 1 State']))
end)

test('system key 1 is reported as "partition does not exist", not an unknown code (v27)', function()
  -- Appendix C: 1 = Partition Not Exist. Treating it as an unrecognised arm
  -- code logged an error on every sync for a partition simply not created
  -- on the panel.
  freshDriver()
  local h = connectPanel(1, true)
  local logged = withCapturedLogs(function() answerSyncQueries(h, 1) end)
  local text = table.concat(logged, '\n')
  assert(text:find('does not exist on the panel'),
    'system key 1 must be named for what it is: ' .. text)
  assert(not text:find('not a recognised arm mode'),
    'and must not be reported as an unknown code')
end)

test('faults decode to Appendix E descriptions instead of raw hex (v27)', function()
  freshDriver()
  -- Worked examples straight from the spec: AC Loss = 1, PSTN Fault DC = 6,
  -- Zone Expander #3 = 309, Zone 27 (0x2B) Tamper = 2B3C.
  assert(DecodeFault('1') == 'AC Loss', 'got ' .. DecodeFault('1'))
  assert(DecodeFault('6') == 'PSTN Fault - DC', 'got ' .. DecodeFault('6'))
  assert(DecodeFault('309') == 'Zone Expander Fault #3', 'got ' .. DecodeFault('309'))
  assert(DecodeFault('2B3C') == 'Zone Tamper Fault #43', 'got ' .. DecodeFault('2B3C'))
end)

test('a communication fault does not get a meaningless device number appended', function()
  -- IDs 30-38 already name the path in the description, so the high byte is
  -- not a device number there.
  assert(DecodeFault('11E') == 'Station PSTN Comm Fault',
    'got ' .. DecodeFault('11E'))
end)

test('an empty fault list reads as none, and an unknown id is still reported', function()
  freshDriver()
  assert(DecodeFaults({}) == 'none', 'no faults must read as none')
  assert(DecodeFault('FF'):find('Unknown Fault 255'),
    'an id outside Appendix E must still surface: ' .. DecodeFault('FF'))
end)

test('every function in the <functions> capability is one the driver implements (v25)', function()
  -- A name in the capability but not in the dispatcher is a menu item that
  -- does nothing when tapped; the reverse is dead code. They must match.
  freshDriver()
  local xml = readFile('driver.xml')
  assert(xml, 'driver.xml not found -- run: python3 gen_driver_xml.py')
  local declared = xml:match('<functions>([^<]*)</functions>')
  assert(declared and declared ~= '', 'driver.xml declares no functions')
  local declaredList = {}
  for f in declared:gmatch('[^,]+') do declaredList[#declaredList + 1] = f end
  assert(#declaredList == #PARTITION_FUNCTIONS,
    'driver.xml declares ' .. #declaredList .. ' functions but driver.lua implements ' ..
    #PARTITION_FUNCTIONS)
  for i, name in ipairs(declaredList) do
    assert(name == PARTITION_FUNCTIONS[i],
      'function ' .. i .. ' is "' .. name .. '" in driver.xml but "' ..
      tostring(PARTITION_FUNCTIONS[i]) .. '" in driver.lua')
  end
end)

test('Functions: Arm All sends one operation to partition 0, the panel\'s all-partitions target', function()
  -- PIMA's spec: partition "0 - all the partitions", and its own worked
  -- example for "Arming Away all" sends partition:0. One frame the panel
  -- applies itself beats N frames sequenced by the driver.
  freshDriver({ ['Partitions Config'] = '1,Main,1111,ASN;2,Garage,2222,A' })
  connectPanel()
  calls.ServerSend = {}
  ExecutePartitionFunction(1, 'Arm All')
  local ops = operations()
  assert(#ops == 1, 'Arm All must be a single broadcast, got ' .. #ops .. ' frames')
  assert(ops[1].optype == 12 and ops[1].partition == 0,
    'must be an Away operation on partition 0, got optype ' .. tostring(ops[1].optype) ..
    ' partition ' .. tostring(ops[1].partition))
end)

test('Functions: Arm All falls back to per-partition when one may not arm Away', function()
  -- The broadcast would arm a partition the installer restricted, so in that
  -- case the installer's restriction wins over the frame saving.
  freshDriver({ ['Partitions Config'] = '1,Main,1111,ASN;2,Garage,2222,S' })
  connectPanel()
  calls.ServerSend = {}
  local logged = withCapturedLogs(function() ExecutePartitionFunction(1, 'Arm All') end)
  for _, f in ipairs(operations()) do
    assert(f.partition ~= 0, 'must not broadcast when a partition is restricted')
    assert(f.partition ~= 2, 'partition 2 does not allow Away and must not be armed')
  end
  assert(table.concat(logged, '\n'):find('skipped'), 'the skip must be reported')
end)

test('Functions: Disarm All sends one operation to partition 0', function()
  freshDriver({ ['Partitions Config'] = '1,Main,1111,ASN;2,Garage,2222,A' })
  connectPanel()
  calls.ServerSend = {}
  ExecutePartitionFunction(1, 'Disarm All')
  local ops = operations()
  assert(#ops == 1, 'Disarm All must be a single broadcast, got ' .. #ops .. ' frames')
  assert(ops[1].optype == 17 and ops[1].partition == 0,
    'must be a disarm on partition 0')
end)

test('Functions: an unimplemented function name is reported, not silently ignored', function()
  freshDriver()
  local logged = withCapturedLogs(function() ExecutePartitionFunction(1, 'Utility Key') end)
  assert(table.concat(logged, '\n'):find('not a function this driver'),
    'an unknown function must say so')
end)

test('EXECUTE_FUNCTION from the proxy reaches the dispatcher whatever the param is named', function()
  freshDriver({ ['Partitions Config'] = '1,Main,1111,ASN' })
  connectPanel()
  calls.ServerSend = {}
  ReceivedFromProxy(5002, 'EXECUTE_FUNCTION', { FUNCTION = 'Disarm All' })
  assert(#operations() > 0, 'a FUNCTION-named param must dispatch')
  calls.ServerSend = {}
  ReceivedFromProxy(5002, 'EXECUTE_FUNCTION', { NAME = 'Disarm All' })
  assert(#operations() > 0, 'a NAME-named param must dispatch too')
end)

test('an emergency request is refused loudly rather than silently doing nothing', function()
  freshDriver()
  connectPanel()
  calls.ServerSend = {}
  local logged = withCapturedLogs(function()
    ReceivedFromProxy(5002, 'EXECUTE_EMERGENCY', { TYPE = 'Police' })
  end)
  assert(#operations() == 0, 'nothing may be sent to the panel for an unsupported emergency')
  assert(table.concat(logged, '\n'):find('cannot raise an emergency'),
    'an emergency that cannot be sent must be reported as failed')
end)

test('Non-Bypassable Zones removes the bypass control and refuses the write (v25)', function()
  freshDriver({
    ['Zones Config'] = '9,Front Door,contact,1;13,Kitchen Smoke,smoke,1',
    ['Non-Bypassable Zones'] = 'smoke',
  })
  local xml = AllZonesInfoXML()
  assert(xml:find('<id>13</id><name>Kitchen Smoke</name>.-<can_bypass>false</can_bypass>'),
    'a non-bypassable zone must publish can_bypass false: ' .. xml)
  assert(xml:find('<id>9</id><name>Front Door</name>.-<can_bypass>true</can_bypass>'),
    'every other zone stays bypassable: ' .. xml)
  connectPanel()
  calls.ServerSend = {}
  local logged = withCapturedLogs(function() SetZoneBypass(13, true) end)
  local wrote = false
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'DATA' and tonumber(f.id) == 2150 then wrote = true end
  end
  assert(not wrote, 'a refused bypass must never reach the panel')
  assert(table.concat(logged, '\n'):find('Bypass refused'), 'the refusal must be reported')
end)

test('clearing a bypass is never blocked by Non-Bypassable Zones', function()
  -- Blocking the clear direction would strand a zone bypassed with no way
  -- back -- the dangerous direction.
  freshDriver({
    ['Zones Config'] = '13,Kitchen Smoke,smoke,1',
    ['Non-Bypassable Zones'] = 'smoke',
  })
  connectPanel()
  calls.ServerSend = {}
  SetZoneBypass(13, false)
  local wrote = false
  for _, f in ipairs(wireFrames()) do
    if f and f.frame_type == 'DATA' and tonumber(f.id) == 2150 then wrote = true end
  end
  assert(wrote, 'clearing a bypass must always be allowed')
end)

test('with Non-Bypassable Zones empty every zone stays bypassable', function()
  freshDriver({ ['Zones Config'] = '13,Kitchen Smoke,smoke,1' })
  assert(AllZonesInfoXML():find('<can_bypass>true</can_bypass>'),
    'the default must not change behaviour for an existing install')
end)

test('Partition Display Text sends DISPLAY_TEXT in the reference call shape (v24)', function()
  -- Copied from Control4's own shipped proxy template as found in the
  -- reference driver: C4:SendToProxy(BindingID, "DISPLAY_TEXT", DispText)
  -- -- three arguments, a bare string, no NOTIFY mode argument.
  freshDriver({
    ['Partitions Config'] = '1,Main,1111,ASN;2,Garage,2222,A',
    ['Partition Display Text'] = 'Home',
  })
  local p1 = proxyCalls(5002, 'DISPLAY_TEXT')
  local p2 = proxyCalls(5003, 'DISPLAY_TEXT')
  assert(#p1 > 0 and #p2 > 0, 'each configured partition must receive DISPLAY_TEXT')
  assert(p1[#p1][3] == 'Home', 'the payload must be the bare string, got: ' .. tostring(p1[#p1][3]))
  assert(p1[#p1][4] == nil, 'the reference template passes no NOTIFY mode argument')
end)

test('Partition Display Text sends nothing when left empty', function()
  freshDriver({ ['Partition Display Text'] = '' })
  assert(#proxyCalls(nil, 'DISPLAY_TEXT') == 0,
    'an experiment that was never opted into must stay off the wire')
end)

test('editing Partition Display Text applies without a driver reload', function()
  freshDriver({ ['Partition Display Text'] = '' })
  calls.SendToProxy = {}
  Properties['Partition Display Text'] = 'Ground Floor'
  OnPropertyChanged('Partition Display Text')
  local sent = proxyCalls(5002, 'DISPLAY_TEXT')
  assert(#sent > 0 and sent[#sent][3] == 'Ground Floor',
    'the new text must go out on the property edit itself')
end)

test('Quiet Zones matches by zone number, not just type word (v23)', function()
  -- The app draws motion and interior with the same icon, so "motion" can
  -- silently match nothing on a config that says interior. A zone number
  -- always works.
  freshDriver({
    ['Zones Config'] = '4,Kitchen PIR,interior,1;9,Front Door,contact,1',
    ['Quiet Zones'] = '4',
  })
  connectPanel()
  calls.SendToProxy = {}
  NotifyProxyZoneState(4, true, nil, 1)
  assert(#proxyCalls(nil, 'ZONE_STATE') == 0, 'zone 4 was listed by number and must be silent')
  NotifyProxyZoneState(9, true, nil, 1)
  assert(#proxyCalls(nil, 'ZONE_STATE') > 0, 'zone 9 was not listed and must still report')
end)

test('Quiet Zones accepts numbers and type words mixed together', function()
  freshDriver({
    ['Zones Config'] = '4,Kitchen PIR,interior,1;7,Hall PIR,motion,1;9,Front Door,contact,1',
    ['Quiet Zones'] = 'motion, 4',
  })
  assert(IsQuietZone(4, 'interior'), 'the number entry must match zone 4')
  assert(IsQuietZone(7, 'motion'), 'the type entry must match the motion zone')
  assert(not IsQuietZone(9, 'contact'), 'an unlisted zone must not be silenced')
end)

test('Quiet Zones that matches nothing warns loudly instead of failing silently', function()
  local logged = withCapturedLogs(function()
    freshDriver({
      ['Zones Config'] = '4,Kitchen PIR,interior,1',
      ['Quiet Zones'] = 'motion',       -- config says interior, so this matches nothing
    })
  end)
  local text = table.concat(logged, '\n')
  assert(text:find('matched NO zone'),
    'a setting that matched nothing must say so, not look like it worked: ' .. text)
end)

test('Quiet Zones that matches reports which zones it silenced', function()
  local logged = withCapturedLogs(function()
    freshDriver({
      ['Zones Config'] = '4,Kitchen PIR,interior,1',
      ['Quiet Zones'] = '4',
    })
  end)
  local text = table.concat(logged, '\n')
  assert(text:find('Kitchen PIR'), 'the log must name the zones being silenced: ' .. text)
end)

test('a quiet zone is published as closed so it cannot churn the list', function()
  freshDriver({
    ['Zones Config'] = '4,Kitchen PIR,interior,1',
    ['Quiet Zones'] = '4',
  })
  NotifyProxyZoneState(4, true, nil, 1)     -- really open right now
  calls.SendToProxy = {}
  PublishZoneInventory()
  local info = proxyCalls(5001, 'PANEL_ZONE_INFO')
  assert(#info > 0, 'the zone must still be published')
  assert(info[#info][3].IS_OPEN == false,
    'a quiet zone must publish as closed, not carry live status')
  assert(#proxyCalls(nil, 'ZONE_STATE') == 0, 'a quiet zone must not be seeded with a status')
end)

test('Zone State Reporting routes to the selected proxies only', function()
  freshDriver({ ['Zone State Reporting'] = 'Partition only' })
  connectPanel()
  calls.SendToProxy = {}
  NotifyProxyZoneState(1, true, nil, 1)
  assert(#proxyCalls(nil, 'ZONE_STATE') > 0, 'partition-only must still send ZONE_STATE')
  assert(#proxyCalls(nil, 'PANEL_ZONE_STATE') == 0, 'partition-only must not send PANEL_ZONE_STATE')

  freshDriver({ ['Zone State Reporting'] = 'Panel only' })
  connectPanel()
  calls.SendToProxy = {}
  NotifyProxyZoneState(1, true, nil, 1)
  assert(#proxyCalls(nil, 'ZONE_STATE') == 0, 'panel-only must not send ZONE_STATE')
  assert(#proxyCalls(nil, 'PANEL_ZONE_STATE') > 0, 'panel-only must still send PANEL_ZONE_STATE')

  freshDriver({ ['Zone State Reporting'] = 'Off' })
  connectPanel()
  calls.SendToProxy = {}
  NotifyProxyZoneState(1, true, nil, 1)
  assert(#proxyCalls(nil, 'ZONE_STATE') == 0, 'Off must send nothing')
  assert(#proxyCalls(nil, 'PANEL_ZONE_STATE') == 0, 'Off must send nothing')
  assert(ZoneState[1].open == true, 'Off must still track state internally')
end)

test('the default reporting mode is unchanged (both proxies)', function()
  freshDriver()
  connectPanel()
  calls.SendToProxy = {}
  NotifyProxyZoneState(1, true, nil, 1)
  assert(#proxyCalls(nil, 'ZONE_STATE') > 0 and #proxyCalls(nil, 'PANEL_ZONE_STATE') > 0,
    'an unconfigured driver must behave exactly as it did before v22')
end)

test('zone status (2149) request omits stop_order', function()
  -- Confirmed against a real, physically-validated capture (an independent
  -- Home Assistant PIMA Force integration): unlike zone NAMES (260), which
  -- truncates to one entry without an explicit stop_order, 2149 is a
  -- self-contained sparse answer regardless, and the real capture requests
  -- it exactly this way.
  freshDriver()
  local h = connectPanel(1, true)
  ClearInFlight(); ResetQueueState(); calls.ServerSend = {}
  SyncZoneStates()
  local req
  for _, s in ipairs(calls.ServerSend) do
    local f = JSON.decode(s[2])
    if f and f.frame_type == 'DATA-REQ' and tonumber(f.id) == 2149 then req = f end
  end
  assert(req, 'SyncZoneStates must send a 2149 DATA-REQ')
  assert(req.stop_order == nil, 'the 2149 request must not carry a stop_order')
  assert(req.start_order == 1, 'the 2149 request must start at order 1')
end)

test('zone status (2149) decodes the sparse bit-packed response: zone number in the low byte, status bits above it', function()
  -- Worked example confirmed against the same reference integration:
  -- status 0x800 (bit 11) = Open, packed as (status * 0x100) + zone.
  -- Zone 1 open  -> status 0x800, zone 1  -> value 0x80001 -> "80001"
  -- Zone 7 bypassed (manual) -> status 0x80, zone 7 -> value 0x8007 -> "8007"
  freshDriver()  -- default Zones Config has zones 1 (Front Door) and 7 (Shed)
  local h = connectPanel(1, true)
  ClearInFlight(); ResetQueueState(); calls.ServerSend = {}
  SyncZoneStates()
  local req
  for _, s in ipairs(calls.ServerSend) do
    local f = JSON.decode(s[2])
    if f and f.frame_type == 'DATA-REQ' and tonumber(f.id) == 2149 then req = f end
  end
  assert(req, 'SyncZoneStates must send a 2149 DATA-REQ')
  OnServerDataIn(h, string.format(
    '{"frame_type":"DATA","account":1234,"counter":%d,"id":2149,"start_order":1,"parameters":["80001","8007"]}',
    req.counter), '10.0.0.50', 5555)
  assert(ZoneState[1].open == true, 'zone 1 must be decoded as open')
  assert(ZoneState[1].bypassed == false, 'zone 1 must not be decoded as bypassed')
  assert(ZoneState[7].bypassed == true, 'zone 7 must be decoded as manually bypassed')
  assert(ZoneState[7].open == false, 'zone 7 must not be decoded as open')
  local zoneStateSent = proxyCalls(5002, 'ZONE_STATE')
  local sawZone1Open = false
  for _, call in ipairs(zoneStateSent) do
    if call[3].ZONE_ID == '1' and call[3].ZONE_OPEN == 'true' then sawZone1Open = true end
  end
  assert(sawZone1Open, 'the decoded open zone must actually reach the partition proxy')
end)

test('zone status (2149): a zone absent from a complete response is treated as closed and not bypassed', function()
  freshDriver()
  local h = connectPanel(1, true)
  -- Start both zones dirty (open/bypassed) so the sync has something to clear.
  NotifyProxyZoneState(1, true, false)
  NotifyProxyZoneState(7, false, true)
  ClearInFlight(); ResetQueueState(); calls.ServerSend = {}
  SyncZoneStates()
  local req
  for _, s in ipairs(calls.ServerSend) do
    local f = JSON.decode(s[2])
    if f and f.frame_type == 'DATA-REQ' and tonumber(f.id) == 2149 then req = f end
  end
  assert(req, 'SyncZoneStates must send a 2149 DATA-REQ')
  -- An all-normal panel legitimately answers with an empty array -- confirmed
  -- by the reference integration's own real-panel capture fixture.
  OnServerDataIn(h, string.format(
    '{"frame_type":"DATA","account":1234,"counter":%d,"id":2149,"start_order":1,"parameters":[]}',
    req.counter), '10.0.0.50', 5555)
  assert(ZoneState[1].open == false, 'zone 1 must be cleared to closed')
  assert(ZoneState[7].bypassed == false, 'zone 7 must be cleared to not-bypassed')
end)

test('zone status (2149): a zone number not present in Zones Config is ignored, not crashed on', function()
  freshDriver()  -- Zones Config only has zones 1 and 7
  local h = connectPanel(1, true)
  ClearInFlight(); ResetQueueState(); calls.ServerSend = {}
  SyncZoneStates()
  local req
  for _, s in ipairs(calls.ServerSend) do
    local f = JSON.decode(s[2])
    if f and f.frame_type == 'DATA-REQ' and tonumber(f.id) == 2149 then req = f end
  end
  local ok = pcall(function()
    -- zone 99 open (status 0x800, zone 99=0x63) -> value 0x80063
    OnServerDataIn(h, string.format(
      '{"frame_type":"DATA","account":1234,"counter":%d,"id":2149,"start_order":1,"parameters":["80063"]}',
      req.counter), '10.0.0.50', 5555)
  end)
  assert(ok, 'an unconfigured zone number in the response must not raise an error')
  assert(ZoneState[99] == nil, 'an unconfigured zone must not be tracked')
end)

test('zone status (2149): more=yes logs a warning instead of silently dropping data', function()
  freshDriver()
  local h = connectPanel(1, true)
  ClearInFlight(); ResetQueueState(); calls.ServerSend = {}
  SyncZoneStates()
  local req
  for _, s in ipairs(calls.ServerSend) do
    local f = JSON.decode(s[2])
    if f and f.frame_type == 'DATA-REQ' and tonumber(f.id) == 2149 then req = f end
  end
  local logged = withCapturedLogs(function()
    OnServerDataIn(h, string.format(
      '{"frame_type":"DATA","account":1234,"counter":%d,"id":2149,"start_order":1,"parameters":["80001"],"more":"yes"}',
      req.counter), '10.0.0.50', 5555)
  end)
  local text = table.concat(logged, '\n')
  assert(text:find('more=yes'), 'an unhandled more=yes page must be logged, not silently ignored: ' .. text)
end)


test('PARTITION_INFO is sent to each configured partition on init, with its name', function()
  freshDriver({ ['Partitions Config'] = '1,Main,1111,ASN;2,Garage,2222,A' })
  local p1 = proxyCalls(5002, 'PARTITION_INFO')
  local p2 = proxyCalls(5003, 'PARTITION_INFO')
  assert(#p1 > 0, 'partition 1 must receive its own PARTITION_INFO')
  assert(#p2 > 0, 'partition 2 must receive its own PARTITION_INFO')
  assert(p1[#p1][3]:find('<name>Main</name>'),
    'must carry the configured name, got: ' .. tostring(p1[#p1][3]))
  assert(p2[#p2][3]:find('<name>Garage</name>'),
    'must carry the configured name, got: ' .. tostring(p2[#p2][3]))
end)

test('PARTITION_INFO is not sent to an unconfigured partition binding', function()
  freshDriver({ ['Partitions Config'] = '1,Main,1111,ASN' })
  assert(#proxyCalls(5003, 'PARTITION_INFO') == 0,
    'partition 2 was never configured; it must not receive an identity document')
end)

test('renaming a partition re-sends its PARTITION_INFO with the new name', function()
  freshDriver({ ['Partitions Config'] = '1,Main,1111,ASN' })
  calls.SendToProxy = {}
  Properties['Partitions Config'] = '1,Front Hall,1111,ASN'
  OnPropertyChanged('Partitions Config')
  local p1 = proxyCalls(5002, 'PARTITION_INFO')
  assert(#p1 > 0 and p1[#p1][3]:find('<name>Front Hall</name>'),
    'a rename in Partitions Config must reach the app, got: ' .. tostring(p1[#p1] and p1[#p1][3]))
end)

test('a name containing XML-special characters is escaped in PARTITION_INFO', function()
  freshDriver({ ['Partitions Config'] = '1,Main & Garage <East>,1111,ASN' })
  local p1 = proxyCalls(5002, 'PARTITION_INFO')
  assert(p1[#p1][3]:find('&amp;') and p1[#p1][3]:find('&lt;East&gt;'),
    'an unescaped name would produce malformed XML: ' .. tostring(p1[#p1][3]))
end)

--=============================================================================
print('')
print(string.format('%d passed, %d failed', passed, failed))
if failed > 0 then os.exit(1) end
