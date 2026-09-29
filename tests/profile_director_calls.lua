-- Director-impact profile. Not a test: build.sh does not run it.
--
-- Loads driver.lua against a counting mock of the C4 API and reports, per
-- scenario, how many calls reach Director and how much CPU the driver burns.
-- Every SendToProxy / UpdateProperty / FireEvent / SetVariable is a blocking
-- round trip to Director, which is the resource a driver actually spends.
--
--   lua5.4 tests/profile_director_calls.lua               # Info log level
--   PERF_LOG=Debug lua5.4 tests/profile_director_calls.lua
--
-- CPU figures are this machine's, not a Control4 controller's -- use them to
-- compare versions, not as absolute times. Call counts are exact.
-- Director-impact profile: counts every C4 API call and log line per scenario.
local counts = {}
local function bump(k) counts[k] = (counts[k] or 0) + 1 end
local timers, seq, now = {}, 0, 1000000
local ZL = {}
for i = 1, 40 do ZL[#ZL+1] = i .. ',Zone ' .. i .. ',contact,1' end
Properties = {
  ['Listen Port']='7780', ['Account ID']='1234',
  ['Partitions Config']='1,Main,1111,ASN',
  ['Zones Config']=table.concat(ZL,';'),
  ['Log Level']=os.getenv('PERF_LOG') or 'Info', ['Link Timeout Seconds']='600',
  ['Event Mute Minutes']='60', ['Zone Bypass Auto-Clear Minutes']='30',
  ['Zone/User Name Encoding']='Windows-1255', ['Reverse Zone/User Names']='Off',
  ['Zone State Reporting']='Partition + Panel',
}
local sent = {}
C4 = {
  AddVariable=function() bump('AddVariable') end,
  SetVariable=function() bump('SetVariable') end,
  GetVariable=function() end,
  SendToProxy=function(self,id,cmd) bump('SendToProxy'); bump('  proxy:'..tostring(cmd)) end,
  UpdateProperty=function(self,n,v) bump('UpdateProperty'); bump('  prop:'..n); Properties[n]=v end,
  SetPropertyAttribs=function() bump('SetPropertyAttribs') end,
  FireEvent=function() bump('FireEvent') end,
  CreateServer=function() end, DestroyServer=function() end,
  ServerSend=function(self,h,d) bump('ServerSend') end,
  AddTimer=function(self,v,u) seq=seq+1; timers[seq]=1; bump('AddTimer'); return seq end,
  KillTimer=function() bump('KillTimer') end,
  GetTime=function() return now end,
  ErrorLog=function() bump('LOG') end, DebugLog=function() bump('LOG') end,
  GetDriverConfigInfo=function() return '1.0' end,
}
local realprint = print
print = function() bump('LOG') end
dofile('driver.lua')
OnDriverInit(); OnDriverLateInit()
local guard=0 while ZonePublishTimerId and guard<100 do guard=guard+1; OnTimerExpired(ZonePublishTimerId) end
OnServerConnectionStatusChanged(1, 7780, 'ONLINE')
OnServerDataIn(1, '{"frame_type":"null","account":"1234","counter":1}', '10.0.0.50', 5555)
PostOperationGuardUntil = 0

local ctr = 100
local function ev(t, q, z, p)
  ctr = ctr + 1
  OnServerDataIn(1, string.format('{"frame_type":"event","counter":%d,"account":"1234","type":%d,"qualifier":%d,"zone":%d,"partition":%d}', ctr, t, q, z, p or 1), '10.0.0.50', 5555)
end
local function scenario(name, n, fn)
  counts = {}
  collectgarbage(); local m0 = collectgarbage('count')
  local t0 = os.clock()
  for i = 1, n do fn(i) end
  local cpu = (os.clock() - t0) * 1000
  local keys = {}
  for k in pairs(counts) do keys[#keys+1] = k end
  table.sort(keys)
  realprint(string.format('\n== %s  (x%d)  cpu %.2f ms total, %.3f ms each', name, n, cpu, cpu / n))
  local d = 0
  for _, k in ipairs(keys) do
    if not k:find('^  ') then d = d + (k == 'LOG' and 0 or counts[k]) end
  end
  for _, k in ipairs(keys) do
    realprint(string.format('   %-26s %8.2f per iteration', k, counts[k] / n))
  end
end

scenario('heartbeat (null frame)', 200, function(i)
  ctr = ctr + 1
  OnServerDataIn(1, string.format('{"frame_type":"null","account":"1234","counter":%d}', ctr), '10.0.0.50', 5555)
end)
scenario('zone open+close pair', 200, function(i) ev(760,1,(i%40)+1); ev(760,3,(i%40)+1) end)
scenario('arm event + state read reply', 20, function(i)
  ev(401, 3, 1)
  PostOperationGuardUntil = 0
end)
scenario('disarm event', 20, function(i) ev(401, 1, 1) end)
scenario('trouble start+restore (AC loss)', 20, function(i) ev(301,1,0); ev(301,3,0) end)

-- Memory growth under a long soak.
collectgarbage(); local m0 = collectgarbage('count')
for i = 1, 20000 do ev(760, (i%2==0) and 3 or 1, (i%40)+1) end
collectgarbage(); local m1 = collectgarbage('count')
realprint(string.format('\n== memory after 20000 zone events: %.0f KB -> %.0f KB (delta %.0f KB)', m0, m1, m1-m0))
