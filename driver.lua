--[[=============================================================================
    PIMA FORCE <-> Control4 Integration Driver
    Copyright 2026. Provided as a starting point; see README.md.

    Talks the PIMA FORCE panel's local JSON CMS protocol (Force Interface
    using JSON format 2.4). The panel is the TCP CLIENT: it dials OUT to
    this driver (same model as a CMS/monitoring-station receiver), so this
    driver runs a TCP SERVER and waits for the panel to connect in. Point
    the panel's CMS2/3 network comm path at this controller's IP and the
    "Listen Port" property below, with Protocol = JSON.

    Architecture notes (see README.md "What's verified vs. what to check"):
      * Protocol engine (framing, ACK, OPERATION, DATA-REQ/DATA, event
        decode) is transcribed from the vendor's own JSON-format spec and
        cross-checked against a mature open-source implementation. High
        confidence.
      * Control4-side surface uses LUA_ACTIONS commands, properties and
        FireDriverEvent() programming events -- all directly confirmed against
        Control4/Snap One's own published sample drivers. This is what
        Composer Pro programming (arm/disarm buttons, "when armed away"
        triggers, zone-open triggers) is built on, and it WILL import and
        run.
      * The call that writes back to an accepted TCP-server connection is
        C4:ServerSend(nHandle, strData) -- confirmed against Snap One's own
        DriverWorks API reference (Server Socket Interface section):
        nHandle is "Server Socket handle received in
        OnServerConnectionStatusChanged. Replies to or disconnects this
        same Server Socket"; strData is "Data to be sent over the open
        Server Socket connection." Used directly in SendRaw() below.
        CreateServer/DestroyServer/OnServerDataIn/OnServerConnectionChanged
        are confirmed from a real shipped driver. Every Control4-facing
        call in this driver is now a confirmed API, not an inference.
===============================================================================]]

--[[=============================================================================
    Protocol constants (PIMA FORCE JSON spec, Appendices A-D)
===============================================================================]]

-- Appendix B: OPERATION optypes
local OPTYPE_ARM_AWAY        = 12  -- Full Arm
local OPTYPE_ARM_HOME1       = 13  -- Stay
local OPTYPE_ARM_HOME2       = 14  -- Night
local OPTYPE_ARM_HOME3       = 15
local OPTYPE_ARM_HOME4       = 16
local OPTYPE_DISARM          = 17
local OPTYPE_ARM_SHABBAT     = 43
local OPTYPE_ACTIVATE_OUT    = 35
local OPTYPE_DEACTIVATE_OUT  = 36

local OUTPUT_EXTERNAL_SIREN  = 1
local OUTPUT_INTERNAL_SIREN  = 2

-- Appendix C: DATA-REQ / DATA parameter IDs
local PARAM_ZONE_NAMES       = 260
local PARAM_USER_NAMES       = 411
local PARAM_ZONE_COUNT       = 2148
local PARAM_ZONE_STATUS      = 2149
local PARAM_BYPASS           = 2150
local PARAM_FAULTS           = 2250
local PARAM_OUTPUT_STATUS    = 2301
local PARAM_SYSTEM_KEY       = 2310

-- Appendix A: CID-style event types we act on
local EV_MEDICAL     = 100
local EV_FIRE        = 110
local EV_FIRE_PULL   = 115
local EV_PANIC_KP    = 120
local EV_DURESS      = 121
local EV_PANIC_SIL   = 122
local EV_BURGLARY    = 130
local EV_TAMPER      = 137
local EV_AC_LOSS     = 301
local EV_LOW_BATTERY = 302
local EV_COMM_TROUBLE= 350
-- Appendix A distinguishes the master code (400) from user/remote codes
-- (401). Only 401 was handled, so arming or disarming the panel with the
-- MASTER code reported nothing at all: the widget kept its previous state
-- until the next 2310 sync happened to correct it.
local EV_MASTER_ARM  = 400
local EV_LOCAL_ARM   = 401
local EV_AUTO_ARM    = 403
local EV_REMOTE_ARM  = 407
local EV_FAST_ARM    = 408
local EV_KEYSW_ARM   = 409
local EV_HOMEX_ARM   = 441
local EV_BYPASS      = 570
local EV_ZONE        = 760
local EV_OUTPUT      = 770

local QUALIFIER_NEW     = 1  -- alarm / new / disarm
local QUALIFIER_RESTORE = 3  -- restore / arm

-- MUST MATCH `DRIVER_VERSION` in gen_driver_xml.py (which writes it into
-- driver.xml's <version>). Composer Pro only offers an update when that
-- number is higher than the installed copy, so it has to be bumped for every
-- build handed to an installer. Logged at startup so the log itself proves
-- which build Director actually loaded -- otherwise "my change had no
-- effect" and "Composer never installed my change" look identical.
local DRIVER_VERSION = 40

-- How much of a discovered zone list to show in the read-only preview
-- property. Only affects display: the full list is kept in memory and is what
-- "Apply Discovered Zones" writes into Zones Config.
-- Preview only: the full discovered list lives in DiscoveredZonesFull and
-- that is what "Apply Discovered Zones" writes, so this exists purely to
-- show the installer that discovery worked. Keeping kilobytes of text in a
-- Composer STRING property makes the whole properties panel sluggish for no
-- benefit, so show the first few entries and the count.
local DISCOVERED_PREVIEW_BYTES = 600

local MAX_DATA_WRITE_BYTES = 250
-- Partitions with a dedicated Control4 surface (state property, named events,
-- Security Partition proxy binding). MUST MATCH `MAX_PARTITIONS` in
-- gen_driver_xml.py -- test_regressions.lua parses driver.xml and fails if
-- these two drift apart. Arm/disarm *commands* still work for any panel
-- partition 1-16; ids beyond this range just surface through the generic
-- "Unmapped Panel Event" + Last Event Summary path instead of named events.
local MAX_DECLARED_PARTITIONS = 3

-- Native Control4 Security proxy bindings (driver.xml <proxies>): one
-- Security Panel proxy at 5001, one Security Partition proxy per declared
-- partition at 5001+id (so partition 1 = 5002, partition 2 = 5003, ...).
-- Proxy type strings ("securitypanel" / "security") and this binding-id
-- layout are confirmed from a real shipped Control4 security driver
-- (Konnected's Security System Mirror .c4z), not guessed -- see README.md.
local PANEL_PROXY_BINDINGID = 5001

--[[=============================================================================
    Tiny JSON codec (self-contained -- no external requires, so the driver
    is a single file with no packaging/require-path risk). Handles the
    subset of JSON the PIMA panel actually uses: flat objects, arrays of
    strings/numbers, strings with standard escapes, numbers, booleans, null.
===============================================================================]]

JSON = {}

-- Keys the panel's own frames lead with, in this order. Everything else is
-- emitted alphabetically after them (see the object branch of JSON.encode).
JSON_KEY_PRIORITY = { account = 1, counter = 2, frame_type = 3 }

-- Sentinel standing in for a JSON `null` inside an ARRAY, so that a null
-- element keeps its slot instead of collapsing the array and shifting every
-- later element down one index (see the array branch of jsonDecodeValue).
-- Object members that are null are simply absent, as normal.
JSON.null = setmetatable({}, { __tostring = function() return 'null' end })

function JSON.isNull(v)
  return v == JSON.null
end

-- Panel values reach us as string | number | boolean | JSON.null. Normalise
-- to a plain string ('' for null/absent) before any string/number handling,
-- so a panel that sends an unexpected type can never crash a consumer.
function JSON.scalar(v)
  if v == nil or JSON.isNull(v) or type(v) == 'table' then return '' end
  if type(v) == 'boolean' then return v and 'true' or 'false' end
  return tostring(v)
end

function JSON.encode(value)
  if value == JSON.null then return 'null' end
  local t = type(value)
  if t == 'string' then
    local out = { '"' }
    for i = 1, #value do
      local b = value:byte(i)
      local c = value:sub(i, i)
      if c == '"' then out[#out+1] = '\\"'
      elseif c == '\\' then out[#out+1] = '\\\\'
      elseif b == 10 then out[#out+1] = '\\n'
      elseif b == 13 then out[#out+1] = '\\r'
      elseif b == 9  then out[#out+1] = '\\t'
      elseif b < 32 then out[#out+1] = string.format('\\u%04x', b)
      else out[#out+1] = c
      end
    end
    out[#out+1] = '"'
    return table.concat(out)
  elseif t == 'number' then
    if value == math.floor(value) and math.abs(value) < 1e15 then
      return string.format('%d', value)
    end
    return tostring(value)
  elseif t == 'boolean' then
    return value and 'true' or 'false'
  elseif t == 'table' then
    -- array-like: keys 1..n with nothing else
    local n = 0
    for _ in pairs(value) do n = n + 1 end
    local isArray = (n > 0)
    for i = 1, n do
      if value[i] == nil then isArray = false break end
    end
    if n == 0 then
      -- Ambiguous empty table; PIMA frames never need an empty object, so
      -- treat as empty array (matches how we build "parameters": []).
      return '[]'
    end
    if isArray then
      local parts = {}
      for i = 1, n do parts[i] = JSON.encode(value[i]) end
      return '[' .. table.concat(parts, ',') .. ']'
    end
    -- DETERMINISTIC KEY ORDER. Lua's pairs() iterates in arbitrary order, so
    -- the same frame could serialise differently on consecutive sends. That
    -- matters here: the PIMA panel is documented to NAK a frame and then go
    -- silent for ~60s if the frame is not shaped as it expects, and the
    -- reference implementation notes its wire shapes match a known-good
    -- capture "field order" exactly.
    --
    -- The rule below -- account, counter, frame_type first, then the rest
    -- alphabetically -- reproduces both documented captures exactly:
    --   ACK:       {"account","counter","frame_type","kc"}
    --   OPERATION: {"account","counter","frame_type","opclass","optype",
    --               "order","partition","password"}
    local keys = {}
    for k in pairs(value) do keys[#keys+1] = k end
    table.sort(keys, function(a, b)
      local sa, sb = tostring(a), tostring(b)
      local pa, pb = JSON_KEY_PRIORITY[sa], JSON_KEY_PRIORITY[sb]
      if pa and pb then return pa < pb end
      if pa then return true end
      if pb then return false end
      return sa < sb
    end)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts+1] = JSON.encode(tostring(k)) .. ':' .. JSON.encode(value[k])
    end
    return '{' .. table.concat(parts, ',') .. '}'
  elseif value == nil then
    return 'null'
  end
  return 'null'
end

-- Minimal recursive-descent decoder. Returns value, nextIndex or nil, errMsg.
local function jsonSkipWs(s, i)
  while i <= #s do
    local b = s:byte(i)
    if b == 32 or b == 9 or b == 10 or b == 13 then i = i + 1 else break end
  end
  return i
end

local jsonDecodeValue -- fwd decl

-- UTF-8 encode a single Unicode code point (BMP range, 0-0xFFFF, which
-- covers Hebrew and everything else this protocol needs).
local function Utf8EncodeCodepoint(code)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(0xC0 + math.floor(code / 64), 0x80 + (code % 64))
  else
    return string.char(
      0xE0 + math.floor(code / 4096),
      0x80 + (math.floor(code / 64) % 64),
      0x80 + (code % 64))
  end
end

local function jsonDecodeString(s, i)
  -- s:sub(i,i) == '"'
  i = i + 1
  local out = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(out), i + 1
    elseif c == '\\' then
      local nxt = s:sub(i+1, i+1)
      if nxt == 'n' then out[#out+1] = '\n'; i = i + 2
      elseif nxt == 'r' then out[#out+1] = '\r'; i = i + 2
      elseif nxt == 't' then out[#out+1] = '\t'; i = i + 2
      elseif nxt == '"' then out[#out+1] = '"'; i = i + 2
      elseif nxt == '\\' then out[#out+1] = '\\'; i = i + 2
      elseif nxt == '/' then out[#out+1] = '/'; i = i + 2
      elseif nxt == 'u' then
        local hex = s:sub(i+2, i+5)
        local code = tonumber(hex, 16) or 63
        out[#out+1] = Utf8EncodeCodepoint(code)
        i = i + 6
      else
        out[#out+1] = nxt; i = i + 2
      end
    else
      out[#out+1] = c
      i = i + 1
    end
  end
  return nil, i -- unterminated string
end

local function jsonDecodeNumber(s, i)
  local start = i
  if s:sub(i,i) == '-' then i = i + 1 end
  while i <= #s and s:sub(i,i):match('%d') do i = i + 1 end
  if s:sub(i,i) == '.' then
    i = i + 1
    while i <= #s and s:sub(i,i):match('%d') do i = i + 1 end
  end
  if s:sub(i,i) == 'e' or s:sub(i,i) == 'E' then
    i = i + 1
    if s:sub(i,i) == '+' or s:sub(i,i) == '-' then i = i + 1 end
    while i <= #s and s:sub(i,i):match('%d') do i = i + 1 end
  end
  local numStr = s:sub(start, i - 1)
  return tonumber(numStr), i
end

jsonDecodeValue = function(s, i)
  i = jsonSkipWs(s, i)
  local c = s:sub(i, i)
  if c == '{' then
    local obj = {}
    i = jsonSkipWs(s, i + 1)
    if s:sub(i,i) == '}' then return obj, i + 1 end
    while true do
      i = jsonSkipWs(s, i)
      if s:sub(i,i) ~= '"' then return nil, i end
      local key
      key, i = jsonDecodeString(s, i)
      if key == nil then return nil, i end
      i = jsonSkipWs(s, i)
      if s:sub(i,i) ~= ':' then return nil, i end
      i = i + 1
      local val
      val, i = jsonDecodeValue(s, i)
      obj[key] = val
      i = jsonSkipWs(s, i)
      local d = s:sub(i,i)
      if d == ',' then i = i + 1
      elseif d == '}' then return obj, i + 1
      else return nil, i end
    end
  elseif c == '[' then
    local arr = {}
    local n = 0
    i = jsonSkipWs(s, i + 1)
    if s:sub(i,i) == ']' then return arr, i + 1 end
    while true do
      local val
      val, i = jsonDecodeValue(s, i)
      -- A JSON null inside an array MUST occupy its slot. Storing a raw nil
      -- would collapse the hole and shift every later element down one --
      -- which for a zone-name/zone-status array (where the array index IS
      -- the zone number) silently renames/misreports every zone after the
      -- gap. Park a sentinel instead; consumers test with JSON.isNull().
      n = n + 1
      arr[n] = (val == nil) and JSON.null or val
      i = jsonSkipWs(s, i)
      local d = s:sub(i,i)
      if d == ',' then i = i + 1
      elseif d == ']' then return arr, i + 1
      else return nil, i end
    end
  elseif c == '"' then
    return jsonDecodeString(s, i)
  elseif c == 't' and s:sub(i, i+3) == 'true' then
    return true, i + 4
  elseif c == 'f' and s:sub(i, i+4) == 'false' then
    return false, i + 5
  elseif c == 'n' and s:sub(i, i+3) == 'null' then
    return nil, i + 4
  elseif c == '-' or c:match('%d') then
    return jsonDecodeNumber(s, i)
  end
  return nil, i
end

function JSON.decode(s)
  local ok, val = pcall(function()
    local v, i = jsonDecodeValue(s, 1)
    return v
  end)
  if ok then return val end
  return nil
end

--[[=============================================================================
    Windows-1255 (Hebrew) text support

    PIMA FORCE panels sold in Israel store zone/user names in Windows-1255,
    not UTF-8 -- the panel sends the raw single-byte codepage bytes straight
    into the JSON string with no escaping (JSON's own syntax characters are
    ASCII either way, so the frame still parses fine; only the *content* of
    the string is codepage text rather than UTF-8). Left alone, those bytes
    show up as mojibake/replacement characters in Composer Pro. This table
    is the byte->Unicode mapping for the Windows-1255 codepage (verified
    against Python's built-in cp1255 codec, which mirrors the Microsoft
    codepage spec); undefined byte values map to U+FFFD (replacement
    character), same as a standard decoder in non-fatal mode.

    Some panels also store text in "visual order" (the order the characters
    are drawn on the LCD, left to right) rather than logical reading order;
    with Hebrew's right-to-left direction that comes out letter-reversed
    once decoded. The "Reverse Zone/User Names" property re-reverses it.
    This mirrors a flag the homebridge-pima-force project also carries,
    documented there as panel-dependent -- leave it Off unless discovered
    names come back backwards.
===============================================================================]]

local WIN1255_HIGH = {
  [0x80]=0x20AC, [0x82]=0x201A, [0x83]=0x0192, [0x84]=0x201E, [0x85]=0x2026,
  [0x86]=0x2020, [0x87]=0x2021, [0x88]=0x02C6, [0x89]=0x2030, [0x8B]=0x2039,
  [0x91]=0x2018, [0x92]=0x2019, [0x93]=0x201C, [0x94]=0x201D, [0x95]=0x2022,
  [0x96]=0x2013, [0x97]=0x2014, [0x98]=0x02DC, [0x99]=0x2122, [0x9B]=0x203A,
  [0xA0]=0x00A0, [0xA1]=0x00A1, [0xA2]=0x00A2, [0xA3]=0x00A3, [0xA4]=0x20AA,
  [0xA5]=0x00A5, [0xA6]=0x00A6, [0xA7]=0x00A7, [0xA8]=0x00A8, [0xA9]=0x00A9,
  [0xAA]=0x00D7, [0xAB]=0x00AB, [0xAC]=0x00AC, [0xAD]=0x00AD, [0xAE]=0x00AE,
  [0xAF]=0x00AF, [0xB0]=0x00B0, [0xB1]=0x00B1, [0xB2]=0x00B2, [0xB3]=0x00B3,
  [0xB4]=0x00B4, [0xB5]=0x00B5, [0xB6]=0x00B6, [0xB7]=0x00B7, [0xB8]=0x00B8,
  [0xB9]=0x00B9, [0xBA]=0x00F7, [0xBB]=0x00BB, [0xBC]=0x00BC, [0xBD]=0x00BD,
  [0xBE]=0x00BE, [0xBF]=0x00BF,
  [0xC0]=0x05B0, [0xC1]=0x05B1, [0xC2]=0x05B2, [0xC3]=0x05B3, [0xC4]=0x05B4,
  [0xC5]=0x05B5, [0xC6]=0x05B6, [0xC7]=0x05B7, [0xC8]=0x05B8, [0xC9]=0x05B9,
  [0xCB]=0x05BB, [0xCC]=0x05BC, [0xCD]=0x05BD, [0xCE]=0x05BE, [0xCF]=0x05BF,
  [0xD0]=0x05C0, [0xD1]=0x05C1, [0xD2]=0x05C2, [0xD3]=0x05C3, [0xD4]=0x05F0,
  [0xD5]=0x05F1, [0xD6]=0x05F2, [0xD7]=0x05F3, [0xD8]=0x05F4,
  [0xE0]=0x05D0, [0xE1]=0x05D1, [0xE2]=0x05D2, [0xE3]=0x05D3, [0xE4]=0x05D4,
  [0xE5]=0x05D5, [0xE6]=0x05D6, [0xE7]=0x05D7, [0xE8]=0x05D8, [0xE9]=0x05D9,
  [0xEA]=0x05DA, [0xEB]=0x05DB, [0xEC]=0x05DC, [0xED]=0x05DD, [0xEE]=0x05DE,
  [0xEF]=0x05DF, [0xF0]=0x05E0, [0xF1]=0x05E1, [0xF2]=0x05E2, [0xF3]=0x05E3,
  [0xF4]=0x05E4, [0xF5]=0x05E5, [0xF6]=0x05E6, [0xF7]=0x05E7, [0xF8]=0x05E8,
  [0xF9]=0x05E9, [0xFA]=0x05EA, [0xFD]=0x200E, [0xFE]=0x200F,
}

-- Split a UTF-8 string into an array of its character byte-sequences (each
-- entry is one whole character, however many bytes it takes). Used so
-- "visual order" reversal swaps whole characters, never splits one.
local function Utf8Chars(str)
  local chars = {}
  local i = 1
  local n = #str
  while i <= n do
    local b = str:byte(i)
    local len = 1
    if b >= 0xF0 then len = 4
    elseif b >= 0xE0 then len = 3
    elseif b >= 0xC0 then len = 2
    end
    chars[#chars+1] = str:sub(i, i + len - 1)
    i = i + len
  end
  return chars
end

local function reverseArray(arr)
  local n = #arr
  local out = {}
  for idx = 1, n do out[idx] = arr[n - idx + 1] end
  return out
end

-- Decode panel-sourced text (zone/user names) per the "Zone/User Name
-- Encoding" and "Reverse Zone/User Names" properties. Safe to call on
-- already-ASCII text (Windows-1255 and UTF-8 both agree with ASCII below
-- 0x80), and safe to call with nil.
function DecodePanelText(str)
  if str == nil or str == '' then return str end
  local encoding = Properties and Properties['Zone/User Name Encoding'] or 'Windows-1255'
  local reverse = Properties and Properties['Reverse Zone/User Names'] == 'On'

  local result
  if encoding == 'Windows-1255' then
    local codepoints = {}
    for i = 1, #str do
      local b = str:byte(i)
      codepoints[#codepoints+1] = (b < 0x80) and b or (WIN1255_HIGH[b] or 0xFFFD)
    end
    if reverse then codepoints = reverseArray(codepoints) end
    local parts = {}
    for i = 1, #codepoints do parts[i] = Utf8EncodeCodepoint(codepoints[i]) end
    result = table.concat(parts)
  else
    -- Assume the panel is already sending UTF-8 (or plain ASCII, a subset).
    if reverse then
      result = table.concat(reverseArray(Utf8Chars(str)))
    else
      result = str
    end
  end
  return result
end

--[[=============================================================================
    Small utilities
===============================================================================]]

local function trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function split(s, sep)
  local parts = {}
  if s == nil or s == '' then return parts end
  for field in (s .. sep):gmatch('(.-)' .. sep) do
    parts[#parts+1] = field
  end
  return parts
end

local function nowMs()
  if C4 and C4.GetTime then return C4:GetTime() end
  return os.time() * 1000
end

--[[=============================================================================
    Logging

    Three levels, deliberately:
      Dbg()            -- verbose wire trace, only when Debug Logging is On
      LogInfo()        -- significant events, always on
      RecordActivity() -- the same significant events, kept in a small rolling
                          buffer exposed as the "Recent Activity" property

    Both Dbg and LogInfo write to Composer Pro's Lua Output *and* to
    C4:DebugLog. That second destination matters: Lua Output only exists
    while you happen to be connected with that tab open, so anything that
    only printed there was unrecoverable for exactly the faults you most want
    it for -- an intermittent drop overnight, a command that failed once last
    week. Director's log persists; Recent Activity survives even without that.

    EVERYTHING logged goes through Redact() first. The frames this driver
    sends carry the alarm user code in a "password" field, so an unredacted
    wire trace would put the PINs for the house into a log file -- which is
    the exact artefact you would paste into a forum or hand to someone to
    help you debug.
===============================================================================]]

local REDACTED = '******'

-- Renders arbitrary bytes readably for a log: printable ASCII as-is,
-- everything else as \xNN. Without this, data that arrives but never forms a
-- valid JSON frame (wrong protocol on the panel's CMS path, a binary
-- handshake, an encrypted stream) is invisible even with Debug Logging on --
-- the driver would sit at "awaiting verification" with an empty log and no
-- way to tell "nothing arrived" from "something unusable arrived".
-- Recognises SIA DC-09 framing, the protocol a PIMA panel sends when its CMS
-- path is left on Contact ID / SIA instead of JSON. Shape:
--   <LF><4-hex CRC><4-char length>"TOKEN"<seq><Rrcvr><Lpref>#ACCT[data]<time><CR>
-- Returns token, account (either may be nil) or nil if this is not DC-09.
-- Diagnostic only: the driver does not speak DC-09, it just says so clearly.
function DetectDC09(text)
  if type(text) ~= 'string' or text == '' then return nil end
  if text:byte(1) ~= 0x0A then return nil end          -- DC-09 frames start with LF
  local token = text:match('"([^"]+)"')                 -- e.g. ADM-CID, NULL, SIA-DCS
  if not token then return nil end
  local account = text:match('#(%w+)')
  return token, account
end

function PrintableBytes(s, limit)
  if type(s) ~= 'string' then return '<not a string>' end
  limit = limit or 240
  local out = {}
  for i = 1, math.min(#s, limit) do
    local b = s:byte(i)
    if b >= 32 and b <= 126 then
      out[#out+1] = s:sub(i, i)
    else
      out[#out+1] = string.format('\\x%02X', b)
    end
  end
  local rendered = table.concat(out)
  if #s > limit then
    rendered = rendered .. '...(' .. (#s - limit) .. ' more bytes)'
  end
  return rendered
end

-- Strips secrets out of a JSON string headed for a log or a property.
-- Handles both quoted ("password":"1234") and bare ("password":1234) forms,
-- with or without whitespace, and is safe to call on any string.
function Redact(text)
  if type(text) ~= 'string' then return text end
  local ok, result = pcall(function()
    local s = text
    s = s:gsub('(["\']password["\']%s*:%s*)"[^"]*"', '%1"' .. REDACTED .. '"')
    s = s:gsub('(["\']password["\']%s*:%s*)(%-?%d+)', '%1"' .. REDACTED .. '"')
    return s
  end)
  if ok and result then return result end
  return text
end

-- Same idea for a frame table: returns a shallow copy with the secret
-- replaced, so the original still goes on the wire intact.
function RedactFrame(frame)
  if type(frame) ~= 'table' then return frame end
  local copy = {}
  for k, v in pairs(frame) do copy[k] = v end
  if copy.password ~= nil then copy.password = REDACTED end
  return copy
end

-- 25 entries at up to 100 chars is ~2.5 KB -- still small next to what made
-- Composer's property grid stutter (that was write FREQUENCY from zone
-- open/close on a 40-zone panel, not this property's size; zone events never
-- reach this buffer at all -- see RecordActivity below). Sized generously
-- because what lands here now is genuinely rare: arm, disarm, alarms and
-- troubles, not routine traffic.
local MAX_RECENT_ENTRIES = 25
local MAX_RECENT_LINE = 100
RecentActivity = RecentActivity or {}

local function logTimestamp()
  local ok, t = pcall(function() return os.date('%m-%d %H:%M:%S') end)
  if ok and type(t) == 'string' then return t end
  return tostring(math.floor(nowMs() / 1000))
end

--[[---------------------------------------------------------------------------
    Every C4:UpdateProperty() is a round trip to Director, and Composer's
    property grid redraws when one arrives. A single panel event used to
    rewrite up to eight properties, most of them with the value they already
    held (Last Event Partition is "1" on a one-partition house forever), and
    on a chatty panel that is a steady stream of redraws -- which is what made
    the properties panel stutter while scrolling.

    SetProp writes only when the value actually changes. `Properties` is
    Director's own mirror of the current values, so the comparison is free and
    cannot drift. Pass force=true for the rare property that must be re-sent
    even when unchanged (none currently need it; the parameter exists so a
    future caller does not have to bypass this helper to get one).
-----------------------------------------------------------------------------]]
PropShadow = PropShadow or {}

function SetProp(name, value, force)
  value = tostring(value)
  -- Compare against our own shadow of what we last wrote, not only against
  -- Properties: Director owns that table and there is no guarantee it is
  -- refreshed synchronously by UpdateProperty. Falling back to Properties
  -- covers the first write after a reload, when the shadow is empty but
  -- Director already holds the persisted value.
  local current = PropShadow[name]
  if current == nil then current = Properties[name] end
  if not force and current == value then return false end
  PropShadow[name] = value
  C4:UpdateProperty(name, value)
  return true
end

-- Rolling buffer of significant events, newest first, published to a
-- read-only property. This is the bit you can read straight out of Composer
-- Pro *after* something went wrong, without having had a log window open at
-- the time.
--
-- Deliberately excludes zone open/close: those are logged nowhere but the
-- native Zones tab and Control4's own History (via ZONE_STATE), because on
-- any panel with more than a handful of zones they would swamp everything
-- else here within minutes. Nothing routes a zone open/close through
-- LogInfo/LogWarn/LogError (see DispatchEvent's EV_ZONE branch), so this is
-- structural rather than a filter that could silently start letting them
-- through -- there is nothing to filter.
--
-- In-memory only: it does not survive a driver reload, and its length is a
-- count (the last MAX_RECENT_ENTRIES), not a time window. There is no
-- retention policy beyond that -- for how long the Control4 app itself keeps
-- ITS OWN History (a separate thing Control4 builds from the proxy
-- notifications, not from this property), see the README; that is a
-- Director-level setting this driver has no visibility into.
function RecordActivity(msg)
  msg = Redact(tostring(msg))
  if #msg > MAX_RECENT_LINE then msg = msg:sub(1, MAX_RECENT_LINE) .. '...' end
  table.insert(RecentActivity, 1, logTimestamp() .. '  ' .. msg)
  while #RecentActivity > MAX_RECENT_ENTRIES do
    table.remove(RecentActivity)
  end
  -- Attempt the property write unconditionally (inside a pcall). Gating it on
  -- the property already existing in the Properties table meant that if it
  -- was ever missing, activity was silently not recorded -- the one failure
  -- mode a diagnostic buffer must not have.
  if C4 and C4.UpdateProperty then
    pcall(function() SetProp('Recent Activity', table.concat(RecentActivity, '\n')) end)
  end
end

--[[---------------------------------------------------------------------------
    Log levels.

    Everything used to come out at one level, so the only choice was a quiet
    log that hid failures or a full frame trace that buried them. The levels:

      Error   -- something failed. A command the panel refused, a frame we
                 could not parse, a connection we had to drop.
      Warning -- something looks wrong but was handled. An event for a
                 partition that is not configured, an unexpected proxy
                 command, a value outside what the protocol documents.
      Info    -- normal activity worth a line: connect, verify, arm, disarm,
                 alarm, discovery results. The default.
      Debug   -- the full frame-level wire trace, and the read-only
                 diagnostic properties become visible in Composer.

    Each level includes the ones above it. `Recent Activity` records Info and
    above, so the in-Composer buffer stays a summary rather than a trace.
-----------------------------------------------------------------------------]]
LOG_ERROR, LOG_WARN, LOG_INFO, LOG_DEBUG = 1, 2, 3, 4

local LOG_LEVEL_NAMES = {
  ['error'] = LOG_ERROR, ['warning'] = LOG_WARN, ['warn'] = LOG_WARN,
  ['info'] = LOG_INFO, ['debug'] = LOG_DEBUG,
  -- The pre-v16 property was Debug Logging (On/Off). A project updated in
  -- place can still hand us those values; map them rather than falling back
  -- to the default and silently turning a deliberate trace back off.
  ['on'] = LOG_DEBUG, ['off'] = LOG_INFO,
}

LogLevel = LogLevel or LOG_INFO

function ResolveLogLevel()
  local raw = Properties['Log Level'] or Properties['Debug Logging'] or 'Info'
  LogLevel = LOG_LEVEL_NAMES[tostring(raw):lower()] or LOG_INFO
  -- Kept as a separate global because it is read on every inbound frame and
  -- guards the expensive JSON re-encode of the wire trace.
  DEBUG_ON = (LogLevel >= LOG_DEBUG)
  return LogLevel
end

local LOG_PREFIX = { [LOG_ERROR] = 'ERROR: ', [LOG_WARN] = 'WARNING: ', [LOG_INFO] = '', [LOG_DEBUG] = '' }

function LogAt(level, msg)
  if level > (LogLevel or LOG_INFO) then return end
  local line = '[PimaForce] ' .. (LOG_PREFIX[level] or '') .. Redact(tostring(msg))
  print(line)
  -- Also to Director's log, so the trace outlives the Lua Output window.
  if C4 and C4.DebugLog then
    pcall(function() C4:DebugLog(line) end)
  end
  -- Errors and warnings are exactly what someone opening Composer after the
  -- fact needs to see, so they are recorded even though they are rarer.
  if level <= LOG_INFO then
    RecordActivity((LOG_PREFIX[level] or '') .. tostring(msg))
  end
end

function LogError(msg) LogAt(LOG_ERROR, msg) end
function LogWarn(msg)  LogAt(LOG_WARN, msg) end
function LogInfo(msg)  LogAt(LOG_INFO, msg) end
function Dbg(msg)      LogAt(LOG_DEBUG, msg) end

--[[=============================================================================
    Config parsing
    Partitions Config property format (one partition per ';'-separated entry):
        id,name,userCode,modes
    modes is a combination of A(way) S(tay/Home1) N(ight/Home2) -- Disarm is
    always allowed. Example:
        1,Main,1234,ASN;2,Garage,9876,A
    Zones Config property format:
        zone,name,type,partition
    type is one of: contact, motion, leak, smoke, fire, panic, 24hour
    partition is optional (informational -- picks which user code authorises
    a bypass write; the panel does not actually filter bypass by partition).
        1,Front Door,contact,1;2,Hallway Motion,motion,1;13,Kitchen Smoke,smoke,1
===============================================================================]]

Partitions = {}   -- [id] = { id=, name=, userCode=, away=bool, stay=bool, night=bool }
Zones = {}        -- [zone] = { zone=, name=, type=, partition= }

local function parsePartitions(str)
  local result = {}
  for _, entry in ipairs(split(str or '', ';')) do
    entry = trim(entry)
    if entry ~= '' then
      local f = split(entry, ',')
      local id = tonumber(trim(f[1] or ''))
      -- Partition ids are 1-16 on this panel family. Reject anything else --
      -- id 0 in particular, because partition 0 is what this driver sends for
      -- a PANEL-WIDE operation, so a typo'd "0,..." entry would turn a
      -- single-partition disarm into a disarm of everything.
      if id and (id < 1 or id > 16) then
        LogInfo('Ignoring Partitions Config entry with out-of-range partition id ' .. tostring(id) .. ' (valid range is 1-16)')
        id = nil
      end
      if id then
        -- Default an ABSENT *or EMPTY* modes field to all modes, and compare
        -- case-insensitively. A trailing comma ("1,Main,1111,") or lowercase
        -- ("asn") would otherwise parse as "no modes allowed", which now
        -- means the partition cannot be armed from the native widget at all.
        local modes = trim(f[4] or '')
        if modes == '' then modes = 'ASN' end
        modes = modes:upper()
        result[id] = {
          id = id,
          name = trim(f[2] or ('Partition ' .. id)),
          userCode = trim(f[3] or ''),
          away = modes:find('A') ~= nil,
          stay = modes:find('S') ~= nil,
          night = modes:find('N') ~= nil,
        }
      end
    end
  end
  return result
end

local function parseZones(str)
  local result = {}
  for _, entry in ipairs(split(str or '', ';')) do
    entry = trim(entry)
    if entry ~= '' then
      local f = split(entry, ',')
      local zone = tonumber(trim(f[1] or ''))
      -- Zone numbers are whole numbers; a non-integer is a typo, and letting
      -- it through produces a float table key that breaks the zone document.
      if zone and (zone ~= math.floor(zone) or zone < 1) then
        LogWarn('Ignoring Zones Config entry with invalid zone number ' .. tostring(zone))
        zone = nil
      end
      if zone then
        result[zone] = {
          zone = zone,
          name = trim(f[2] or ('Zone ' .. zone)),
          type = trim(f[3] or 'contact'),
          partition = tonumber(trim(f[4] or '')),
        }
      end
    end
  end
  return result
end

-- The inverse of parseZones. Used when the app renames a zone: the change has
-- to be written back into the Zones Config property or it is lost on the next
-- reload. Commas and semicolons are the field and record separators, so a name
-- containing either would corrupt every entry after it -- they are replaced
-- rather than escaped, because parseZones has no escape syntax to read back.
function SerializeZones()
  local out = {}
  for _, z in ipairs(SortedZoneNumbers()) do
    local c = Zones[z]
    local name = tostring(c.name or ('Zone ' .. z)):gsub('[,;]', ' ')
    out[#out + 1] = table.concat({
      tostring(z), name, tostring(c.type or 'contact'),
      c.partition and tostring(c.partition) or '',
    }, ',')
  end
  return table.concat(out, ';')
end

--[[=============================================================================
    Frame helpers
===============================================================================]]

-- Split a buffer into complete JSON frame strings, returning any trailing
-- INCOMPLETE frame separately so the caller can carry it over to the next
-- TCP chunk. TCP is a byte stream with no message boundaries: a frame can
-- and eventually will be split across two segments, so anything that
-- discards the tail loses that frame entirely (and never ACKs it, so the
-- panel retransmits into the same bug). Frames also arrive back-to-back in
-- one segment with no delimiter but the object boundary, and `null`
-- heartbeats are padded with 0x00 bytes.
-- Returns: parts (array of complete frame strings), remainder (string).
local function splitFrames(raw)
  local text = raw:gsub('%z+', '')
  if text == '' then return {}, '' end
  local parts = {}
  local depth = 0
  local startIdx = nil
  local inStr = false
  local escaped = false
  local lastComplete = 0   -- byte index of the end of the last complete frame
  for i = 1, #text do
    local c = text:sub(i, i)
    if startIdx == nil then
      if c == '{' then startIdx = i; depth = 1; inStr = false; escaped = false end
    else
      if inStr then
        if escaped then escaped = false
        elseif c == '\\' then escaped = true
        elseif c == '"' then inStr = false end
      else
        if c == '"' then inStr = true
        elseif c == '{' then depth = depth + 1
        elseif c == '}' then
          depth = depth - 1
          if depth == 0 then
            parts[#parts+1] = text:sub(startIdx, i)
            startIdx = nil
            lastComplete = i
          end
        end
      end
    end
  end
  -- Everything after the last complete frame is either an unfinished frame
  -- (carry it) or inter-frame filler (harmless to carry; it gets trimmed
  -- the moment a '{' starts the next frame).
  local remainder = text:sub(lastComplete + 1)
  if startIdx == nil and trim(remainder) == '' then remainder = '' end
  return parts, remainder
end

local function buildAck(frame)
  return {
    account = tonumber(frame.account) or 0,
    counter = frame.counter or 0,
    frame_type = 'ACK',
    kc = 1,
  }
end

local function shouldAck(frame)
  local t = frame.frame_type
  return t ~= 'NAK' and t ~= 'ACK'
end

--[[=============================================================================
    Driver state
===============================================================================]]

ConnHandle = nil          -- current accepted client handle, nil if none
PanelVerified = false     -- account number confirmed on this connection
OpCounter = 5000          -- our outbound (HA->AS) frame counter
OutQueue = {}             -- FIFO of pending outbound requests: {frameTbl, match(frame)->bool, onResult(frame|nil, err), timeoutMs}
InFlight = nil            -- the request currently on the wire: {match=, onResult=, sentAt=, timeoutMs=, timerId=}
LastForwardedCounter = nil
PendingArmQuery = {}      -- [partition] = true while we're waiting on a post-arm 2310 query
PostOperationGuardUntil = 0  -- nowMs() before which we must not send another frame (500ms pacing rule)

--[[=============================================================================
    TCP server lifecycle
===============================================================================]]

function StartServer()
  local port = tonumber(Properties['Listen Port']) or 7780
  local ok, err = pcall(function() C4:CreateServer(port) end)
  if not ok then
    LogInfo('ERROR starting TCP server on port ' .. port .. ': ' .. tostring(err))
  else
    LogInfo('Listening for the PIMA panel on TCP port ' .. port)
  end
  ListenPort = port
end

function StopServer()
  if ListenPort then
    pcall(function() C4:DestroyServer(ListenPort) end)
  end
end

-- Tracks the connected/disconnected edge so the events fire on transitions
-- rather than on every status write.
--
-- Deliberately a plain assignment, NOT the `X = X or false` idiom used for
-- genuinely persistent globals: this is per-session state, and preserving it
-- across a driver reload would mean the first connect after a reload does not
-- count as an edge, so Panel Connection Restored would never fire.
PanelWasConnected = false

-- A panel that has stopped talking to Control4 means the system is not being
-- monitored, which is exactly the condition worth a push notification -- and
-- until v30 the driver detected it (the link watchdog) but offered nothing to
-- program against.
function NotePanelDisconnected(reason)
  if not PanelWasConnected then return end
  PanelWasConnected = false
  SetDriverVariable('PANEL_CONNECTED', false)
  local text = 'Panel connection lost' .. (reason and (' (' .. tostring(reason) .. ')') or '')
  SetDriverVariable('ALERT_TYPE', 'Panel Offline')
  SetDriverVariable('ALERT_TEXT', text)
  SetDriverVariable('LAST_TROUBLE_TYPE', 'Panel Offline')
  SetDriverVariable('LAST_TROUBLE_TEXT', text)
  LogError('Panel connection lost' .. (reason and (': ' .. tostring(reason)) or '') ..
    ' -- the system is not being monitored through Control4 until it returns')
  FireDriverEvent('Panel Connection Lost')
  FireDriverEvent('Any Trouble')
end

function OnServerConnectionStatusChanged(nHandle, nPort, strStatus)
  Dbg('OnServerConnectionStatusChanged handle=' .. tostring(nHandle) .. ' port=' .. tostring(nPort) .. ' status=' .. tostring(strStatus))
  local isOnline = (strStatus == 'ONLINE' or strStatus == 'CONNECTED' or strStatus == 'true' or strStatus == true)
  if isOnline then
    -- NEWEST CONNECTION WINS.
    --
    -- The panel keeps exactly one connection per CMS path open, and the
    -- reference implementation explicitly destroys the previous socket when
    -- a new one arrives. That behaviour matters: if a session half-opens
    -- (panel loses power, network path dies) no OFFLINE ever arrives, so a
    -- "first verified session wins" rule -- which this driver used to have --
    -- would ignore the panel's reconnect forever and sit permanently silent
    -- on a socket that is already dead.
    --
    -- The account check below is what actually gates trust; nothing is sent
    -- to a connection until it has presented the configured account.
    if ConnHandle ~= nil and nHandle ~= ConnHandle then
      LogInfo('New inbound connection (handle ' .. tostring(nHandle) ..
        ') replacing the previous session on handle ' .. tostring(ConnHandle))
    end
    ConnHandle = nHandle
    PanelVerified = false
    -- NOT resetting the event dedupe here on purpose: the panel replays its
    -- buffered events on reconnect, and forgetting what we already processed
    -- is what turned that replay into fresh alarm notifications.
    LastEventKey = nil
    RecvBuffer = ''
    VerifyFailures = 0
    BlockedHandles = {}
    UnparseableWarned = false
    -- A reconnect is exactly when our picture is most likely stale: start
    -- from "we don't know" rather than from whatever we last believed.
    ResetPartitionStatus()
    -- Fail (not silently discard) anything still queued from the previous
    -- session: callers -- including the native widget waiting on an arm --
    -- must be told, or a command just evaporates with no error anywhere.
    FailInFlight('connection reset')
    ResetQueueState()
    SetProp('Connection Status', 'Client Connected (awaiting verification)')
    NoteInboundActivity()
    StartLinkWatchdog()
  else
    if ConnHandle == nHandle then
      ConnHandle = nil
      PanelVerified = false
      RecvBuffer = ''
      FailInFlight('panel disconnected')
      ResetQueueState()
      SetProp('Connection Status', 'Not Connected')
      NotePanelDisconnected('link down')
      SetProp('Panel Verified Account', '')
      StopLinkWatchdog()
      LastInboundAt = nil
      -- Drop alarms as well as arm state. An alarm whose restore we never saw
      -- (because the link dropped mid-alarm) has no other way to clear, and
      -- would keep the widget in ALARM for a system we cannot even see.
      ResetPartitionStatus()
      for pid, _ in pairs(Partitions) do
        SetPartitionState(pid, 'Unknown')
      end
      -- Tell the native proxy the truth: we no longer know the panel state.
      -- Leaving the last-known state on the shield widget is worse than
      -- saying nothing -- it shows a confident "Disarmed"/"Armed" for a
      -- system we have no link to.
      NotifyProxyAllPartitionsOffline()
    end
  end
end

-- Hard cap on the reassembly buffer. A frame is normally well under 1KB; a
-- peer that opens '{' and then streams garbage forever would otherwise grow
-- this without bound until the controller runs out of memory.
local MAX_RECV_BUFFER = 65536

--[[=============================================================================
    Server data callback

    The DriverWorks reference gives contradictory signatures for this callback
    (three separate readings of the same published page produced
    `(server, ipAddress, port, data)`, `(server, idClient, data)` and
    `(nHandle, strData, ...)`), and there is no way to test it here. What IS
    known for certain, from a real controller's log, is the CONNECTION
    callback's layout: `OnServerConnectionStatusChanged` arrived as
    (284266996, 7780, "ONLINE") -- a handle, then our listen port, then the
    status. So the API is handle-based, not server-object-based.

    Rather than bet on one argument order, the entry points below accept
    whatever they are given, work out which argument is the payload, and log
    the actual layout once per session so it can be settled from evidence.
    They also register under every plausible callback name, so if Director
    calls a differently-named function this driver still hears the data.
===============================================================================]]

local function looksLikeIPv4(s)
  return type(s) == 'string' and s:match('^%d+%.%d+%.%d+%.%d+$') ~= nil
end

-- Works out (handle, payload) from an arbitrary argument layout.
local function NormalizeServerDataArgs(...)
  local n = select('#', ...)
  local handle, strings = nil, {}
  for i = 1, n do
    local v = select(i, ...)
    if type(v) == 'number' then
      -- Prefer an argument that matches the connection we already know about.
      if handle == nil or v == ConnHandle then handle = v end
    elseif type(v) == 'string' then
      strings[#strings+1] = v
    end
  end
  -- The payload is the string that looks like protocol data: prefer one
  -- containing a JSON object start, else the longest string that is not an
  -- IPv4 literal or a bare number (those are the address/port arguments).
  local data
  for _, s in ipairs(strings) do
    if s:find('{', 1, true) then data = s break end
  end
  if not data then
    for _, s in ipairs(strings) do
      if not looksLikeIPv4(s) and not s:match('^%d+$') then
        if data == nil or #s > #data then data = s end
      end
    end
  end
  -- A numeric string could still be the handle if no number was passed.
  if handle == nil then
    for _, s in ipairs(strings) do
      if s ~= data and s:match('^%d+$') then handle = tonumber(s) break end
    end
  end
  return handle, data
end

-- Logged once per session: the single line that settles what this callback
-- is actually handed, so the guessing above can be replaced with certainty.
local function LogServerDataLayout(callbackName, ...)
  if ServerDataLayoutLogged then return end
  ServerDataLayoutLogged = true
  local parts = {}
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    parts[#parts+1] = i .. ':' .. type(v) .. '=' .. PrintableBytes(tostring(v), 60)
  end
  LogInfo('Data callback "' .. callbackName .. '" fired. Argument layout: ' ..
    (#parts > 0 and table.concat(parts, '  ') or '(no arguments)'))
end

function OnServerDataIn(...)
  LogServerDataLayout('OnServerDataIn', ...)
  local handle, data = NormalizeServerDataArgs(...)
  if data == nil then
    Dbg('OnServerDataIn: could not identify a payload argument; ignoring')
    return
  end
  return HandleServerData(handle, data)
end

-- Aliases. The callback's name is not certain either, and a driver that is
-- never called is indistinguishable from a panel that never transmits. If
-- Director uses any of these instead, we still receive the data -- and the
-- log line above names which one fired.
function ReceivedFromServer(...)
  LogServerDataLayout('ReceivedFromServer', ...)
  local handle, data = NormalizeServerDataArgs(...)
  if data then return HandleServerData(handle, data) end
end

function OnServerData(...)
  LogServerDataLayout('OnServerData', ...)
  local handle, data = NormalizeServerDataArgs(...)
  if data then return HandleServerData(handle, data) end
end

function ServerDataIn(...)
  LogServerDataLayout('ServerDataIn', ...)
  local handle, data = NormalizeServerDataArgs(...)
  if data then return HandleServerData(handle, data) end
end

function HandleServerData(nHandle, strData)
  -- If the argument layout gave us no identifiable handle, assume the data
  -- belongs to the connection we already know about. Dropping it instead
  -- would turn an unknown call signature into total silence -- the failure
  -- mode this whole path exists to avoid.
  if nHandle == nil then nHandle = ConnHandle end

  -- Any bytes at all mean the link is alive, even bytes we cannot parse: the
  -- watchdog is asking "is the panel still there", not "is it well".
  if nHandle == ConnHandle then NoteInboundActivity() end

  -- Data is processed from WHICHEVER socket delivers it.
  --
  -- Previously anything arriving on a handle other than the current
  -- ConnHandle was discarded. Combined with "newest connection wins", a
  -- second TCP client that merely opened the port and said nothing -- a port
  -- scanner, a monitoring probe, a mis-pointed second CMS path -- took the
  -- slot and the driver went deaf to the real panel: no ACKs, no events, and
  -- the silent socket never tripped the verification limit, so nothing
  -- un-stuck it. The panel is whichever socket is actually talking to us.
  if nHandle ~= ConnHandle then
    Dbg('Data on handle ' .. tostring(nHandle) .. ' (current session was ' ..
      tostring(ConnHandle) .. '); following the socket that is talking')
    -- A different socket means a different session: re-verify before trusting.
    if ConnHandle ~= nil then
      PanelVerified = false
      RecvBuffer = ''
      LastEventKey = nil          -- dedupe set deliberately preserved
    end
  end
  -- A handle we already gave up on (too many wrong-account frames) must stay
  -- given up on. Without this the next byte it sends re-adopts it below and
  -- the failure limit means nothing.
  if BlockedHandles and BlockedHandles[nHandle] then
    return
  end
  ConnHandle = nHandle

  -- Reassemble across TCP segment boundaries: carry any trailing partial
  -- frame over to the next chunk rather than dropping it.
  --
  -- The CARRIED remainder is capped before we append and re-scan. Once it is
  -- over the cap no further byte can complete a frame from it, and
  -- re-scanning a near-cap buffer on every inbound byte is quadratic -- which
  -- a peer trickling garbage can use to pin the controller's Lua state at
  -- 100% CPU. Freshly-arrived data is never dropped here, so a big chunk of
  -- [valid frame][garbage] still gets its frame parsed below.
  RecvBuffer = RecvBuffer or ''
  if #RecvBuffer > MAX_RECV_BUFFER then
    LogInfo('Inbound buffer exceeded ' .. MAX_RECV_BUFFER .. ' bytes without a complete frame -- discarding it (malformed or hostile peer)')
    RecvBuffer = ''
  end
  -- Log the raw bytes BEFORE any parsing. This is the only record of what
  -- the panel actually sent when it turns out not to be the JSON protocol.
  if DEBUG_ON then
    Dbg(string.format('RAW IN (%d bytes): %s', #(strData or ''), PrintableBytes(strData)))
  end

  RecvBuffer = RecvBuffer .. (strData or '')

  local frames, remainder = splitFrames(RecvBuffer)
  RecvBuffer = remainder

  -- Data arrived but produced no complete frame. Say so, loudly enough to
  -- diagnose: silence here is what makes a protocol mismatch look identical
  -- to a panel that simply has not transmitted yet.
  if #frames == 0 and #(strData or '') > 0 then
    local dc09Token, dc09Account = DetectDC09(strData)
    if dc09Token then
      -- Name the protocol precisely rather than just "not JSON". This is the
      -- single most common way this install goes wrong, and the panel hands
      -- us its real account number in the same frame -- so say both.
      if not UnparseableWarned then
        UnparseableWarned = true
        LogInfo('The panel is sending SIA DC-09 (message token "' .. dc09Token .. '"' ..
          (dc09Account and (', account ' .. dc09Account) or '') ..
          '), NOT the PIMA JSON protocol this driver needs. ' ..
          'On the panel: CMS path -> Network (Ethernet) -> 2nd screen -> set Protocol = JSON. ' ..
          (dc09Account and ('Then set this driver\'s Account ID property to ' .. dc09Account .. '. ') or '') ..
          'Note DC-09/Contact ID is report-only -- arm/disarm is not possible on it.')
      end
    elseif not RecvBuffer:find('{', 1, true) then
      -- No JSON object start anywhere: this is almost certainly not the JSON
      -- protocol at all. Warn unconditionally, not just in debug -- it is
      -- the single most useful thing we can tell the installer.
      if not UnparseableWarned then
        UnparseableWarned = true
        LogInfo('Received ' .. #strData .. ' bytes from the panel that are not the JSON protocol ' ..
          '(no "{" found). Check the CMS path Protocol is set to JSON, not Contact ID/SIA. First bytes: ' ..
          PrintableBytes(strData, 80))
      end
    else
      Dbg('Incomplete frame buffered (' .. #RecvBuffer .. ' bytes so far), waiting for the rest')
    end
  end
  -- And cap what's left AFTER extracting any complete frames, so a single
  -- oversized chunk is bounded immediately rather than one call later.
  if #RecvBuffer > MAX_RECV_BUFFER then
    LogInfo('Discarding ' .. #RecvBuffer .. ' bytes of unparseable trailing data')
    RecvBuffer = ''
  end

  for _, frameText in ipairs(frames) do
    local frame = JSON.decode(frameText)
    if type(frame) == 'table' then
      -- One bad frame must never abort the rest of the chunk: the frames
      -- after it would be dropped AND left un-ACKed.
      local ok, err = pcall(HandleInboundFrame, nHandle, frame)
      if not ok then
        LogInfo('ERROR handling inbound frame: ' .. tostring(err))
        -- A throw may have left a request stranded mid-flight; keep the
        -- queue moving rather than parking it forever.
        pcall(ProcessQueue)
      end
    else
      Dbg('Could not parse frame: ' .. frameText)
    end
  end
end

--[[=============================================================================
    Low-level send
===============================================================================]]

-- C4:ServerSend(nHandle, strData) -- confirmed against Snap One's
-- DriverWorks API reference: nHandle is the Server Socket handle received
-- in OnServerConnectionStatusChanged (the same value OnServerDataIn's
-- first parameter carries for that connection); strData is the payload to
-- write to it.
-- The published reference is as inconsistent about ServerSend as it is about
-- the data callback (`ServerSend(nHandle, strData)` in one reading,
-- `ServerSend(server, idClient, data, options)` in another). This matters
-- more than it looks: the PIMA protocol requires us to ACK every frame, so
-- if our ACK never reaches the panel it times out and reconnects -- an
-- endless connect/drop loop with no data, which is exactly what a failing
-- install looks like. So try the handle-based form first (consistent with
-- the connection callback's observed layout), fall back to the
-- server-object form, and remember whichever worked.
function SendRaw(handle, text)
  -- Dbg() redacts, so the user code in this frame never reaches the log.
  Dbg('>>> ' .. text)

  local attempts = {
    { name = 'ServerSend(handle, data)',
      fn = function() return C4:ServerSend(handle, text) end },
    { name = 'ServerSend(port, handle, data)',
      fn = function() return C4:ServerSend(ListenPort, handle, text) end },
  }
  -- Once a form has worked, keep using it rather than re-probing every send.
  if ServerSendForm then
    local ok, err = pcall(attempts[ServerSendForm].fn)
    if ok then return end
    LogInfo('ERROR sending to panel via ' .. attempts[ServerSendForm].name .. ': ' .. tostring(err))
    ServerSendForm = nil
  end

  for i, attempt in ipairs(attempts) do
    local ok, err = pcall(attempt.fn)
    if ok then
      if ServerSendForm ~= i then
        LogInfo('Outbound writes are using ' .. attempt.name)
      end
      ServerSendForm = i
      return
    end
    Dbg('C4:ServerSend form "' .. attempt.name .. '" failed: ' .. tostring(err))
  end
  LogInfo('ERROR: could not send to the panel -- no known C4:ServerSend form worked. ' ..
    'The driver can receive but not reply, so the panel will keep reconnecting.')
end

--[[=============================================================================
    Inbound frame handling
===============================================================================]]

-- How many frames with a wrong account we tolerate on one connection before
-- we stop looking at it. Without a limit, a listening socket lets anything
-- on the LAN sit there guessing the account ID indefinitely.
local MAX_VERIFY_FAILURES = 5

-- Run an in-flight request's completion callback without letting a Lua error
-- inside it park the queue forever. Historically the callback ran bare: a
-- throw (e.g. a panel sending an unexpected type) skipped ProcessQueue(),
-- leaving InFlight nil, its timeout timer already killed and nothing left to
-- kick the queue -- so the next command sent hours later would dequeue and
-- fire the STALE head of the queue instead.
local function RunCallback(cb, frame, err)
  if not cb then return end
  local ok, cbErr = pcall(cb, frame, err)
  if not ok then
    LogInfo('ERROR in request callback: ' .. tostring(cbErr))
  end
end

function HandleInboundFrame(handle, frame)
  local isHeartbeat = (frame.frame_type == 'null')

  -- Only mirror real frames into the diagnostic property, and only while
  -- debugging: heartbeats arrive every few seconds forever, and each write
  -- is a Director property update.
  if not isHeartbeat and DEBUG_ON then
    -- Redacted even though inbound frames should not carry a password:
    -- this property is read and shared by people diagnosing a problem, and
    -- "should not" is not a guarantee about someone else's firmware.
    SetProp('Last Raw Frame In', Redact(JSON.encode(RedactFrame(frame))))
  end

  if not isHeartbeat then
    Dbg('<<< ' .. JSON.encode(RedactFrame(frame)))
  end

  -- ACK FIRST, before deciding whether we trust this client.
  --
  -- The panel requires an application-level ACK for every frame it sends.
  -- Withholding it does not "reject" the client -- it breaks the protocol:
  -- the panel concludes the receiver is broken, drops the connection and
  -- reconnects, forever, with no diagnostic. An earlier version returned
  -- without ACKing whenever the account did not match, which turned a
  -- one-line configuration mistake into an unexplained connect/drop loop.
  -- An ACK discloses nothing, so sending it before verification is safe;
  -- verification below still gates everything that actually matters.
  if shouldAck(frame) then
    SendRaw(handle, JSON.encode(buildAck(frame)))
  end

  -- Verify the connecting client is our configured panel account on the
  -- first frame we see on this connection.
  if not PanelVerified then
    local acct = tonumber(frame.account)
    local expected = tonumber(Properties['Account ID'])
    if acct ~= expected then
      VerifyFailures = (VerifyFailures or 0) + 1
      local hint = ''
      if frame.account == nil then
        hint = ' -- the frame carried NO account field at all; is the CMS path Protocol set to JSON?'
      elseif acct == nil then
        hint = ' -- the panel account is not numeric, which this driver cannot match ' ..
               '(the Account ID property is a number). Set a numeric account on the panel CMS path.'
      end
      LogError('Rejecting frame: panel account "' .. tostring(frame.account) ..
        '" does not match configured Account ID "' .. tostring(Properties['Account ID']) ..
        '" (' .. VerifyFailures .. '/' .. MAX_VERIFY_FAILURES .. ')' .. hint)
      if VerifyFailures >= MAX_VERIFY_FAILURES then
        LogError('Too many unverified frames on handle ' .. tostring(handle) .. ' -- ignoring this connection')
        -- Remember the handle: we cannot close the socket from DriverWorks,
        -- so the only way to make the limit mean anything is to refuse to
        -- look at that handle again for the life of this session.
        BlockedHandles = BlockedHandles or {}
        BlockedHandles[handle] = true
        if ConnHandle == handle then
          ConnHandle = nil
          RecvBuffer = ''
          SetProp('Connection Status', 'Not Connected')
          NotePanelDisconnected('too many unverified frames')
        end
      end
      return
    end
    PanelVerified = true
    VerifyFailures = 0
    SetProp('Connection Status', 'Connected')
    if not PanelWasConnected then
      PanelWasConnected = true
      SetDriverVariable('PANEL_CONNECTED', true)
      FireDriverEvent('Panel Connection Restored')
    end
    SetProp('Panel Verified Account', tostring(acct))
    LogInfo('Panel verified (account ' .. tostring(acct) .. ')')
    -- Ask the panel what state everything is actually in. Without this the
    -- driver knows nothing until the next arm/disarm event, so every
    -- partition would sit at OFFLINE on a working system.
    SyncPartitionStates(true)
    SyncZoneStates()
    -- Re-publish the zone inventory once per session as insurance against
    -- LateInit having run before Director was ready to receive it. Later
    -- reconnects skip it: the inventory does not depend on the panel, and
    -- re-sending ~3 Director calls per zone on every reconnect is exactly
    -- the cost this dedup exists to avoid.
    SendPanelInfo(not InventoryForcedOnce)
    InventoryForcedOnce = true
  end

  if isHeartbeat then
    return -- heartbeat; already ACKed above
  end

  -- An ACK or NAK may answer an OPERATION that was sent directly (not queued).
  local replyCounter = tonumber(frame.counter)
  if frame.frame_type == 'NAK' and replyCounter then
    local reason = JSON.scalar(frame.DATA or frame.data)
    if reason == '' then reason = 'unknown' end
    if ResolvePendingOperation(replyCounter, reason) then
      SetProp('Last NAK Reason', reason)
      return
    end
  elseif frame.frame_type == 'ACK' and replyCounter then
    if ResolvePendingOperation(replyCounter, nil) then return end
  end

  -- Route to an in-flight request if this frame answers it.
  if InFlight and frame.frame_type == 'NAK' then
    local counter = tonumber(frame.counter)
    if counter ~= nil and counter ~= 0 and counter == InFlight.counter then
      local reason = JSON.scalar(frame.DATA or frame.data)
      if reason == '' then reason = 'unknown' end
      SetProp('Last NAK Reason', reason)
      local cb = InFlight.onResult
      ClearInFlight()
      RunCallback(cb, nil, reason)
      ProcessQueue()
      return
    end
  end

  if InFlight and InFlight.match(frame) then
    -- An ACK carries the counter of the request it answers. Without checking
    -- it, a LATE ack (for a request we already timed out and failed) would
    -- satisfy whatever is on the wire now -- completing the wrong request,
    -- reporting a failed command as successful, and letting the next request
    -- go out while the real one is still outstanding at the panel.
    -- counter == 0 is treated as "unattributed" here, matching the NAK path
    -- above: some panels answer with a zero counter, and rejecting those
    -- would hang every such request until its timeout.
    local counter = tonumber(frame.counter)
    if frame.frame_type == 'ACK' and InFlight.counter and counter ~= nil and counter ~= 0 and counter ~= InFlight.counter then
      Dbg('Ignoring ACK for counter ' .. tostring(counter) .. '; in flight is ' .. tostring(InFlight.counter))
      return
    end
    local cb = InFlight.onResult
    ClearInFlight()
    RunCallback(cb, frame, nil)
    ProcessQueue()
    return
  end

  -- Not claimed by an in-flight request -- a spontaneous frame from the panel.
  if frame.frame_type == 'NAK' then
    local reason = JSON.scalar(frame.DATA or frame.data)
    if reason == '' then reason = 'unknown' end
    SetProp('Last NAK Reason', reason)
    return
  end

  if frame.frame_type == 'event' or frame.frame_type == 'EVENT' then
    -- Dedupe retransmits: the panel resends an un-ACKed event with the same
    -- counter. We've already re-ACKed above; suppress a duplicate dispatch.
    -- Key on the event CONTENT as well as the counter -- panels reset their
    -- counter on reboot and can wrap it, and a counter-only check would then
    -- silently swallow a genuinely different event (e.g. a fire alarm that
    -- happens to reuse the counter of the last event we saw).
    local counter = tonumber(frame.counter)
    local key = table.concat({
      tostring(counter),
      tostring(frame.type), tostring(frame.qualifier),
      tostring(frame.zone), tostring(frame.partition),
    }, '|')
    if counter ~= nil and AlreadySeenEvent(key) then
      Dbg('Suppressing duplicate retransmit of event ' .. key)
      return
    end
    LastEventKey = key
    if counter ~= nil then LastForwardedCounter = counter end
    DispatchEvent(frame)
    return
  end

  Dbg('Unhandled/stray frame: ' .. JSON.encode(frame))
end

--[[=============================================================================
    Retransmit / replay suppression (v33).

    The panel resends an event it has not seen ACKed, and PIMA's own spec
    says the AS buffers events and reports them once a connection is up
    ("NULL ... sent also after all the events in the AS buffer have been
    reported"). So the same event legitimately arrives more than once, and
    after a reconnect a whole buffer of already-seen events can replay.

    Through v32 this was guarded by remembering ONE key, cleared on every
    connect. That failed in both the ways that matter:

      * a retransmit that arrived after any other event no longer matched the
        single remembered key, so it was dispatched again; and
      * clearing on connect meant a reconnect replayed the buffer as if it
        were live -- firing alarm and trouble events, and the notifications
        wired to them, for things that had already happened.

    Now: a bounded set with a time window, deliberately NOT cleared on
    reconnect, since surviving the reconnect is the entire point. An event
    still counts as new if anything about it differs (the key includes type,
    qualifier, zone and partition as well as the counter), so a genuinely new
    alarm is never swallowed -- only a byte-identical repeat of one already
    processed inside the window.
===============================================================================]]
EVENT_DEDUPE_WINDOW_MS = 5 * 60 * 1000
EVENT_DEDUPE_MAX = 128
SeenEventAt = {}
SeenEventOrder = {}

function ResetEventDedupe()
  SeenEventAt = {}
  SeenEventOrder = {}
end

function AlreadySeenEvent(key)
  local now = nowMs()
  local seenAt = SeenEventAt[key]
  if seenAt then
    local age = now - seenAt
    -- A clock step backwards must not make a stale entry look current
    -- forever; treat a negative age as "just now" and keep suppressing.
    if age < 0 or age <= EVENT_DEDUPE_WINDOW_MS then
      SeenEventAt[key] = now
      return true
    end
  end

  SeenEventAt[key] = now
  SeenEventOrder[#SeenEventOrder + 1] = key
  -- Bounded so a long-running driver cannot grow this without limit.
  while #SeenEventOrder > EVENT_DEDUPE_MAX do
    local oldest = table.remove(SeenEventOrder, 1)
    if oldest ~= key then SeenEventAt[oldest] = nil end
  end
  return false
end

--[[=============================================================================
    Outbound request queue
    The panel processes exactly one HA->AS request at a time and NAKs/drops
    anything sent while one is outstanding (PROTOCOL.md "Behavioural rules").
    We serialise everything through this single queue, and pause briefly
    after every OPERATION before sending the next thing (Nagle coalescing
    workaround documented in the same section).
===============================================================================]]

-- The panel's pacing rule is a fixed ~500ms; nothing legitimate ever needs a
-- longer wait than this. Clamping matters because nowMs() is wall-clock
-- (C4:GetTime), not monotonic: an NTP step backwards would otherwise compute
-- a wait of the size of the step and freeze arm/disarm for that long.
local MAX_QUEUE_GUARD_MS = 600
-- Anything beyond this many queued requests means we are wedged, not busy.
-- Without a cap the backlog is replayed as a burst of stale arm/disarm
-- commands the moment the queue unwedges.
local MAX_QUEUE_DEPTH = 32

function ClearInFlight()
  if InFlight and InFlight.timerId then
    pcall(function() C4:KillTimer(InFlight.timerId) end)
  end
  InFlight = nil
end

-- Clears pacing/guard state. Must run on every connect and disconnect:
-- otherwise a guard set just before a drop survives it, and the queue sits
-- waiting on a timer that belonged to a connection that no longer exists.
function ResetQueueState()
  OutQueue = {}
  PostOperationGuardUntil = 0
  if QueueGuardTimerId then
    pcall(function() C4:KillTimer(QueueGuardTimerId) end)
  end
  QueueGuardTimerId = nil
end

function FailInFlight(reason)
  if InFlight then
    local cb = InFlight.onResult
    ClearInFlight()
    RunCallback(cb, nil, reason)
  end
  -- Swap the queue out BEFORE draining, so a callback that re-enqueues
  -- during the drain lands in the new queue instead of being discarded by
  -- the reset that follows.
  local pending = OutQueue
  OutQueue = {}
  for _, req in ipairs(pending) do
    RunCallback(req.onResult, nil, reason)
  end
end

-- request = { frame = <table to encode>, match = function(frame) bool, onResult = function(frame, err), timeoutMs = number, isOperation = bool }
function EnqueueRequest(request)
  if ConnHandle == nil or not PanelVerified then
    RunCallback(request.onResult, nil, 'no verified panel connection')
    return
  end
  if #OutQueue >= MAX_QUEUE_DEPTH then
    LogInfo('Outbound queue is full (' .. MAX_QUEUE_DEPTH .. ') -- the panel is not answering. Dropping this request.')
    RunCallback(request.onResult, nil, 'outbound queue full; panel not responding')
    return
  end
  OutQueue[#OutQueue+1] = request
  ProcessQueue()
end

function ProcessQueue()
  if InFlight ~= nil then return end
  if #OutQueue == 0 then return end
  if ConnHandle == nil or not PanelVerified then
    FailInFlight('panel disconnected')
    return
  end

  local waitMs = PostOperationGuardUntil - nowMs()
  if waitMs > 0 then
    waitMs = math.min(waitMs, MAX_QUEUE_GUARD_MS)
    if QueueGuardTimerId then
      pcall(function() C4:KillTimer(QueueGuardTimerId) end)
    end
    QueueGuardTimerId = C4:AddTimer(math.max(1, math.floor(waitMs)), 'MILLISECONDS')
    if not QueueGuardTimerId then
      -- Couldn't schedule the pacing timer; better to send slightly early
      -- than to strand the queue with nothing left to wake it.
      LogError('Could not create pacing timer; sending without the post-OPERATION guard')
      PostOperationGuardUntil = 0
    else
      return
    end
  end

  local request = table.remove(OutQueue, 1)
  OpCounter = OpCounter + 1
  request.frame.counter = OpCounter
  local counter = OpCounter

  local timeoutMs = request.timeoutMs or 5000
  local timerId = C4:AddTimer(timeoutMs, 'MILLISECONDS')

  InFlight = {
    counter = counter,
    match = request.match,
    onResult = request.onResult,
    timerId = timerId,
    sentAt = nowMs(),
    timeoutMs = timeoutMs,
  }

  if not timerId then
    -- No timeout timer means this request could never time out and would
    -- park the queue permanently. Fail it now -- and then keep draining, or
    -- everything queued behind it is stranded by the very branch that exists
    -- to prevent a stuck queue.
    LogError('Could not create timeout timer; failing this request rather than risking a stuck queue')
    local cb = InFlight.onResult
    InFlight = nil
    RunCallback(cb, nil, 'could not schedule request timeout')
    ProcessQueue()
    return
  end

  if request.isOperation then
    PostOperationGuardUntil = nowMs() + 550
  end

  SendRaw(ConnHandle, JSON.encode(request.frame))
end

function OnTimerExpired(idTimer)
  if EventMuteTimerId and idTimer == EventMuteTimerId then
    EventMuteTimerId = nil
    SetEventsEnabled(true, 'mute period elapsed')
    return
  end
  -- Match on timer IDENTITY, never on "is a guard pending" -- otherwise an
  -- unrelated timer firing while a guard is pending is consumed by the guard
  -- branch (and that timer's real work, e.g. clearing a zone bypass, is
  -- silently lost).
  if QueueGuardTimerId and idTimer == QueueGuardTimerId then
    QueueGuardTimerId = nil
    ProcessQueue()
    return
  end
  if InFlight and InFlight.timerId == idTimer then
    local cb = InFlight.onResult
    ClearInFlight()
    RunCallback(cb, nil, 'timeout waiting for panel response')
    ProcessQueue()
    return
  end
  -- An OPERATION that never got an ACK or NAK. The frame was still sent; this
  -- only tells the caller it went unanswered.
  local opCounter = PendingOperationTimers[idTimer]
  if opCounter then
    PendingOperationTimers[idTimer] = nil
    ResolvePendingOperation(opCounter, 'no ACK from panel within ' ..
      (OPERATION_REPLY_TIMEOUT_MS / 1000) .. 's')
    return
  end
  if LinkWatchdogTimerId and idTimer == LinkWatchdogTimerId then
    CheckLinkAlive()
    return
  end
  if ZonePublishTimerId and idTimer == ZonePublishTimerId then
    DrainZonePublishQueue()
    return
  end
  if AutoBypassTimers[idTimer] then
    local zone = AutoBypassTimers[idTimer]
    AutoBypassTimers[idTimer] = nil
    if AutoBypassTimerForZone[zone] == idTimer then
      AutoBypassTimerForZone[zone] = nil
    end
    LogInfo('Auto-clearing bypass on zone ' .. zone .. ' (safety timeout)')
    SetZoneBypass(zone, false)
    return
  end
  Dbg('OnTimerExpired: unrecognised timer id ' .. tostring(idTimer))
end
AutoBypassTimers = AutoBypassTimers or {}
AutoBypassTimerForZone = AutoBypassTimerForZone or {}

-- Schedules (or re-schedules) the safety auto-clear for a bypassed zone.
-- Re-bypassing a zone must REPLACE its pending timer, not stack another one:
-- two timers for one zone means the older one clears the bypass early.
function CancelBypassAutoClear(zone)
  local existing = AutoBypassTimerForZone[zone]
  if existing then
    pcall(function() C4:KillTimer(existing) end)
    AutoBypassTimers[existing] = nil
    AutoBypassTimerForZone[zone] = nil
  end
end

function ScheduleBypassAutoClear(zone)
  local minutes = tonumber(Properties['Zone Bypass Auto-Clear Minutes']) or 0
  CancelBypassAutoClear(zone)
  if minutes <= 0 then return end
  local timerId = C4:AddTimer(minutes, 'MINUTES')
  if not timerId then
    LogInfo('Could not schedule bypass auto-clear for zone ' .. tostring(zone) .. ' -- it will stay bypassed until cleared manually')
    return
  end
  AutoBypassTimers[timerId] = zone
  AutoBypassTimerForZone[zone] = timerId
end

--[[=============================================================================
    Domain operations (arm / disarm / outputs / data)
===============================================================================]]

local function accountNum()
  return tonumber(Properties['Account ID']) or 0
end

local function firstPartitionCode()
  for _, p in pairs(Partitions) do
    if p.userCode ~= '' then return p.userCode end
  end
  return nil
end

-- How long to wait for the panel's ACK/NAK before telling the caller the
-- command went unanswered. Reporting only -- the frame is sent either way.
-- Global, not local: OnTimerExpired is defined earlier in the file and a
-- local declared here would be out of scope there (resolving to nil).
OPERATION_REPLY_TIMEOUT_MS = 5000
PendingOperations = PendingOperations or {}
PendingOperationTimers = PendingOperationTimers or {}

--[[=============================================================================
    OPERATION frames (arm / disarm / outputs) BYPASS THE REQUEST QUEUE.

    They used to be queued behind whatever DATA-REQ traffic was outstanding,
    with one request in flight at a time. On every panel reconnect the driver
    enqueues a state query per partition, so a Disarm pressed in the first
    seconds after a reconnect sat fourth in line behind unanswered queries,
    each with a 5s timeout -- the button did nothing, silently, for tens of
    seconds. In a busy config it could be dropped entirely once the queue hit
    its depth cap.

    The reference implementation has no queue at all: it writes the OPERATION
    to the socket immediately, and its own tests fire arm and disarm
    back-to-back with no wait. Arming is the one thing that must never wait
    behind bookkeeping, so it now takes the same direct path. The queue
    remains for DATA-REQ/DATA, where a reply genuinely has to be matched to
    its request.
===============================================================================]]
function SendOperation(partitionId, optype, order, password, onResult)
  local part = Partitions[partitionId]
  local pw = password or (part and part.userCode)
  if pw == '' then pw = nil end   -- '' is truthy in Lua; treat blank as absent
  if not pw then
    if onResult then onResult(nil, 'no user code configured for partition ' .. tostring(partitionId)) end
    return
  end
  if ConnHandle == nil or not PanelVerified then
    RunCallback(onResult, nil, 'no verified panel connection')
    return
  end

  OpCounter = OpCounter + 1
  local frame = {
    account = accountNum(),
    counter = OpCounter,
    frame_type = 'OPERATION',
    opclass = 1,
    optype = optype,
    order = order or 0,
    partition = partitionId,
    password = pw,
  }

  -- Remember it only so a NAK or ACK can be reported back to the caller.
  -- Nothing waits on this: the frame is already on the wire.
  PendingOperations[OpCounter] = {
    onResult = onResult,
    sentAt = nowMs(),
    description = 'optype ' .. optype .. ' partition ' .. tostring(partitionId),
  }
  local timerId = C4:AddTimer(OPERATION_REPLY_TIMEOUT_MS, 'MILLISECONDS')
  if timerId then
    PendingOperationTimers[timerId] = OpCounter
  end

  SendRaw(ConnHandle, JSON.encode(frame))
end

-- Resolves an outstanding OPERATION by counter. Returns true if it matched.
function ResolvePendingOperation(counter, err)
  local pending = counter and PendingOperations[counter]
  if not pending then return false end
  PendingOperations[counter] = nil
  RunCallback(pending.onResult, nil, err)
  return true
end

-- Is this partition configured to allow this arm mode? Applied identically to
-- the native widget and the Actions tab, so the two can never disagree about
-- what a partition will accept.
function ArmModeAllowed(partitionId, mode)
  local part = Partitions[partitionId]
  if not part then return false end
  if mode == 'away' then return part.away end
  if mode == 'stay' then return part.stay end
  if mode == 'night' then return part.night end
  return true   -- shabbat/home3/home4 aren't gated by Partitions Config
end

function ArmPartition(partitionId, mode)
  local optype = OPTYPE_ARM_AWAY
  if mode == 'stay' then optype = OPTYPE_ARM_HOME1
  elseif mode == 'night' then optype = OPTYPE_ARM_HOME2
  elseif mode == 'shabbat' then optype = OPTYPE_ARM_SHABBAT
  end
  -- order=1 for every arm optype, order=0 for disarm only (below) -- this is
  -- not a free choice: it is confirmed against a physically-validated,
  -- independent PIMA Force integration (github.com/amithalp/
  -- pima-force-ha-integration) whose comment states plainly that "validated
  -- FORCE traffic requires order=1 for arming modes; disarm uses order=0 on
  -- the tested firmware". This driver sent order=0 for arm through v20.
  SendOperation(partitionId, optype, 1, nil, function(frame, err)
    if err then
      LogError('Arm (' .. tostring(mode) .. ') partition ' .. partitionId .. ' failed: ' .. tostring(err))
      SetProp('Last Command Result', 'Arm ' .. tostring(mode) .. ' partition ' .. partitionId .. ' FAILED: ' .. tostring(err))
      -- A failed arm MUST be visible on the native widget. Silently logging
      -- it leaves the shield showing whatever it showed before, so someone
      -- can walk out of the house believing they armed it.
      NotifyProxyArmFailed(partitionId)
    else
      Dbg('Arm (' .. tostring(mode) .. ') partition ' .. partitionId .. ' ACKed')
      SetProp('Last Command Result', 'Arm ' .. tostring(mode) .. ' partition ' .. partitionId .. ' accepted by panel')
    end
  end)
end

function DisarmPartition(partitionId)
  SendOperation(partitionId, OPTYPE_DISARM, 0, nil, function(frame, err)
    if err then
      LogError('Disarm partition ' .. partitionId .. ' failed: ' .. tostring(err))
      SetProp('Last Command Result', 'Disarm partition ' .. partitionId .. ' FAILED: ' .. tostring(err))
      NotifyProxyDisarmFailed(partitionId)
    else
      Dbg('Disarm partition ' .. partitionId .. ' ACKed')
      SetProp('Last Command Result', 'Disarm partition ' .. partitionId .. ' accepted by panel')
    end
  end)
end

-- Partition 0 = every partition, per PIMA's spec (Appendix B: "1,2..16 /
-- 0=all"). Used by the app's Arm All / Disarm All functions.
ALL_PARTITIONS = 0

function ArmAllPartitions()
  SendOperation(ALL_PARTITIONS, OPTYPE_ARM_AWAY, 1, firstPartitionCode(), function(frame, err)
    if err then
      LogError('Arm All failed: ' .. tostring(err))
      SetProp('Last Command Result', 'Arm All FAILED: ' .. tostring(err))
      for pid in pairs(Partitions) do NotifyProxyArmFailed(pid) end
    else
      Dbg('Arm All ACKed')
    end
  end)
end

function DisarmAllPartitions()
  SendOperation(ALL_PARTITIONS, OPTYPE_DISARM, 0, firstPartitionCode(), function(frame, err)
    if err then
      LogError('Disarm All failed: ' .. tostring(err))
      SetProp('Last Command Result', 'Disarm All FAILED: ' .. tostring(err))
      for pid in pairs(Partitions) do NotifyProxyDisarmFailed(pid) end
    else
      Dbg('Disarm All ACKed')
    end
  end)
end

function SetOutput(output, active)
  local pw = firstPartitionCode()
  if not pw then
    LogInfo('SetOutput: no partition user code configured to authorise this')
    return
  end
  EnqueueRequest({
    frame = {
      account = accountNum(),
      frame_type = 'OPERATION',
      opclass = 1,
      optype = active and OPTYPE_ACTIVATE_OUT or OPTYPE_DEACTIVATE_OUT,
      order = output,
      partition = 0,
      password = pw,
    },
    match = function(f) return f.frame_type == 'ACK' end,
    onResult = function(f, err)
      if err then LogError('SetOutput(' .. output .. ') failed: ' .. tostring(err)) end
    end,
    isOperation = true,
  })
end

function RequestData(id, startOrder, stopOrder, password, onResult)
  local pw = password or firstPartitionCode()
  if not pw then
    if onResult then onResult(nil, 'no user code available to authorise DATA-REQ') end
    return
  end
  local frame = {
    account = accountNum(),
    frame_type = 'DATA-REQ',
    id = id,
    start_order = startOrder,
    password = pw,
  }
  if stopOrder then frame.stop_order = stopOrder end
  EnqueueRequest({
    frame = frame,
    match = function(f)
      return f.frame_type == 'DATA' and tonumber(f.id) == id and tonumber(f.start_order) == startOrder
    end,
    onResult = onResult,
  })
end

function WriteData(id, startOrder, parameters, password, onResult)
  local pw = password or firstPartitionCode()
  if not pw then
    if onResult then onResult(nil, 'no user code available to authorise DATA write') end
    return
  end
  local frame = {
    account = accountNum(),
    frame_type = 'DATA',
    id = id,
    start_order = startOrder,
    parameters = parameters,
  }
  frame.password = pw
  -- Measure the frame AS IT WILL GO ON THE WIRE. ProcessQueue adds the
  -- counter after this point, so checking the pre-counter length let frames
  -- over the panel's hard limit through by roughly that field's width.
  local sized = { counter = OpCounter + #OutQueue + 1 }
  for k, v in pairs(frame) do sized[k] = v end
  local encodedLen = #JSON.encode(sized)
  if encodedLen > MAX_DATA_WRITE_BYTES then
    if onResult then onResult(nil, 'DATA write exceeds ' .. MAX_DATA_WRITE_BYTES .. '-byte panel limit (' .. encodedLen .. ' bytes)') end
    return
  end
  EnqueueRequest({
    frame = frame,
    match = function(f)
      return (f.frame_type == 'ACK')
        or (f.frame_type == 'DATA' and tonumber(f.id) == id and tonumber(f.start_order) == startOrder)
    end,
    onResult = onResult,
  })
end

--[[---------------------------------------------------------------------------
    Which zones offer a bypass control (v25).

    `<can_bypass>` in the zones document is what puts a bypass control on a
    zone in the app. It was hardcoded `true` for every zone, which offers the
    control on smoke and fire zones too -- ones a panel will usually refuse
    to bypass, so the button is there and simply fails.

    Non-Bypassable Zones takes the same syntax as Quiet Zones: zone numbers
    and/or type words, mixed. Empty (the default) keeps every zone
    bypassable, so nothing changes for an existing install.
-----------------------------------------------------------------------------]]
function IsZoneBypassable(zone, zoneType)
  local configured = tostring(Properties['Non-Bypassable Zones'] or '')
  if trim(configured) == '' then return true end
  local target = tostring(zoneType or 'contact'):lower()
  for word in configured:gmatch('[^,;]+') do
    local entry = trim(word):lower()
    if entry ~= '' then
      local asNumber = tonumber(entry)
      if asNumber then
        if zone and asNumber == zone then return false end
      elseif entry == target then
        return false
      end
    end
  end
  return true
end

function SetZoneBypass(zone, bypassed, password)
  -- Refuse a bypass on a zone the installer marked non-bypassable, wherever
  -- the request came from (app, Actions tab, programming). Hiding the
  -- control in the app is presentation; this is the actual rule.
  local zcfg = Zones[zone]
  if bypassed and not IsZoneBypassable(zone, zcfg and zcfg.type) then
    local msg = 'Bypass refused for zone ' .. zone ..
      ': it is listed in Non-Bypassable Zones'
    LogWarn(msg)
    SetProp('Last Command Result', msg)
    return
  end
  WriteData(PARAM_BYPASS, zone, { bypassed and '1' or '0' }, password, function(f, err)
    if err then
      LogError('Bypass write for zone ' .. zone .. ' failed: ' .. tostring(err))
      SetProp('Last Command Result',
        (bypassed and 'Bypass' or 'Clear bypass') .. ' zone ' .. zone .. ' FAILED: ' .. tostring(err))
      if not bypassed then
        -- A FAILED auto-clear is the dangerous direction: the zone stays
        -- bypassed (detector disabled) with nothing left to retry. Put the
        -- safety timer back so we try again rather than giving up silently.
        LogInfo('Re-arming the safety auto-clear for zone ' .. zone .. ' after a failed clear')
        ScheduleBypassAutoClear(zone)
      end
      return
    end
    Dbg('Bypass write for zone ' .. zone .. ' (' .. tostring(bypassed) .. ') ACKed')
    VerifyZoneBypass(zone, bypassed, password)
  end)
end

--[[---------------------------------------------------------------------------
    An ACK is not proof the bypass was applied (v26).

    This is not a theoretical worry. The independent, physically-validated
    Home Assistant PIMA integration documents it from real hardware: "If a
    zone is permanently cancelled in technician programming, the panel may
    acknowledge a temporary-bypass request without applying it." Its own
    bypass flow therefore writes 2150, waits for the ACK, reads 2150 back,
    and only then reports success.

    This driver used to stop at the ACK: it told the app the zone was
    bypassed and started the auto-clear safety timer, both on a bypass that
    may never have happened. A zone shown as bypassed that is not, or shown
    as live when it is not, is exactly the kind of quiet mismatch that makes
    a security display untrustworthy -- and the timer would then "clear" a
    bypass that never existed.

    Parameter 2150 reads back POSITIONALLY (one value per zone from
    start_order, "1" bypassed / "0" normal), unlike the sparse 2149 status
    list -- so a single-zone read is start_order = stop_order = the zone, and
    the answer is its first parameter.
-----------------------------------------------------------------------------]]
function VerifyZoneBypass(zone, requested, password)
  RequestData(PARAM_BYPASS, zone, zone, password, function(frame, err)
    if err then
      -- The write was ACKed but the read-back did not arrive. Do not claim
      -- either outcome: say so, and leave the tracked state alone.
      LogWarn('Bypass for zone ' .. zone .. ' was ACKed but could not be verified: ' ..
        tostring(err) .. '. The zone state shown may not match the panel; ' ..
        'use "Request Zone Status" once the panel is reachable.')
      SetProp('Last Command Result',
        (requested and 'Bypass' or 'Clear bypass') .. ' zone ' .. zone ..
        ' ACKed but UNVERIFIED: ' .. tostring(err))
      return
    end

    local params = frame and frame.parameters
    local raw = (type(params) == 'table') and JSON.scalar(params[1]) or nil
    local applied = tonumber(tostring(raw))
    if applied == nil then
      LogWarn('Bypass read-back for zone ' .. zone .. ' returned "' .. tostring(raw) ..
        '", which is not a bypass value; treating the state as unknown')
      return
    end
    applied = (applied ~= 0)

    -- Report what the PANEL says, not what was asked for, whichever way it
    -- went. This is the one place the two can disagree.
    NotifyProxyZoneState(zone, nil, applied)

    if applied == requested then
      LogInfo((requested and 'Bypass' or 'Clear bypass') .. ' zone ' .. zone ..
        ' confirmed by the panel')
      SetProp('Last Command Result',
        (requested and 'Bypass' or 'Clear bypass') .. ' zone ' .. zone .. ' confirmed')
      if requested then
        -- Arm the safety auto-clear only for a bypass the panel really
        -- applied, so the timer can never "clear" one that never existed.
        ScheduleBypassAutoClear(zone)
      else
        CancelBypassAutoClear(zone)
      end
      return
    end

    -- ACKed, then not applied.
    local msg = (requested and 'Bypass' or 'Clear bypass') .. ' zone ' .. zone ..
      ' was ACKed but NOT applied: the panel still reports it as ' ..
      (applied and 'bypassed' or 'not bypassed') ..
      '. A zone cancelled in technician programming, or otherwise unavailable, ' ..
      'does this. The app now shows the panel\'s real state.'
    LogError(msg)
    SetProp('Last Command Result', msg)
    if requested then
      -- Nothing was applied, so there is nothing to auto-clear later.
      CancelBypassAutoClear(zone)
    else
      -- A clear that did not take leaves the detector still disabled. Keep
      -- retrying rather than walking away from it.
      LogInfo('Re-arming the safety auto-clear for zone ' .. zone ..
        ': the clear was ACKed but the zone is still bypassed')
      ScheduleBypassAutoClear(zone)
    end
  end)
end

--[[=============================================================================
    Post-arm mode disambiguation
    The arm/disarm CID events (401/407/etc.) tell us a partition became
    armed but not which mode. Right after we see an arm, poll System Key
    Status (2310) for that partition to learn Away/Stay/Night/Shabbat and
    fire the specific event.
===============================================================================]]

-- Arm-mode labels carry BOTH names: the Control4-conventional one an
-- installer expects to see, and PIMA's own name for the same mode as it
-- appears on the panel keypad and in PIMA's programming software. Without the
-- second half, "Stay" and "Home1" look like different features to anyone
-- cross-referencing the panel.
--
-- These strings are user-visible in four places and MUST agree with
-- gen_driver_xml.py, which uses them for the `arm_states` capability, the
-- action names and the per-partition event names. test_regressions.lua parses
-- driver.xml and fails if they drift apart.
-- Deliberately globals, not locals: the regression suite reads them to check
-- they still match what driver.xml declares.
ARM_LABEL_AWAY  = 'Away (Full Arm)'
ARM_LABEL_STAY  = 'Stay (Home1)'
ARM_LABEL_NIGHT = 'Night (Home2)'

-- Appendix C, parameter 2310: 1 means the partition is not configured on the
-- panel at all. It is not an arm state and must not be reported as one --
-- without this it fell through to the "unrecognised code" path and logged an
-- error on every sync for a partition that simply does not exist.
SYSTEM_KEY_NOT_EXIST = 1

local SYSTEM_KEY_TO_MODE = {
  [3] = ARM_LABEL_AWAY,
  [4] = ARM_LABEL_STAY,
  [5] = ARM_LABEL_NIGHT,
  -- Home3/Home4/Shabbat are already PIMA's own names; there is no separate
  -- Control4 convention to pair them with.
  [6] = 'Home3',
  [7] = 'Home4',
  [8] = 'Shabbat',
  [9] = 'Shabbat',
}

-- System key values CONFIRMED (against a known physical panel state, not
-- inferred) to mean Disarmed. Empty until a value is actually confirmed --
-- add to this rather than widening the "unmapped" fallback in
-- QueryPartitionArmState, which must stay a refusal to guess.
--
-- Deliberately global, not local: test_regressions.lua also seeds a fixture
-- value into this so its many pre-existing "starts disarmed" scenarios keep
-- working (a test-only convention, not itself evidence about any panel).
-- Deliberately a plain literal, not an "X = X or {}" self-preserving one
-- (unlike RecentActivity/PropShadow elsewhere): this is static configuration,
-- not runtime-learned state, so it should reset the same way on every load
-- rather than accumulate across the test harness's repeated dofile() calls.
--
-- [2] = confirmed on a real installed panel (Efi's), 2026-09: system key
-- status came back 2, and the panel was independently confirmed Disarmed at
-- that moment. This is real evidence, not the old blanket "unmapped means
-- Disarmed" guess it replaces -- see README "How partition state is
-- learned" for what that guess used to cost.
SYSTEM_KEY_DISARMED = { [2] = true }

--[[=============================================================================
    Asking the panel what state a partition is in.

    Two callers with different needs:

    * After an arm EVENT (`fireEvents = true`): we already know the partition
      armed, we are only resolving WHICH mode. An unreadable answer therefore
      falls back to the generic "Armed" -- never to "Disarmed", which would
      claim the system is off when we know it is on.

    * On connect (`fireEvents = false`): a cold sync. Nothing is known yet.
      This is the query that stops a freshly-loaded driver sitting at OFFLINE
      until someone happens to arm or disarm -- the driver used to be purely
      event-driven, so on a perfectly healthy panel every partition stayed
      "Unknown" indefinitely. Programming events are NOT fired here: a driver
      reload must not look like a real arming and set off "when armed"
      automations.
===============================================================================]]

-- Raw System Key Status values seen for each arm mode. Anything NOT in this
-- table is treated as not-armed on a cold sync. That direction is deliberate:
-- claiming "Armed" for a value we do not recognise would give a false sense
-- of security, whereas claiming "Disarmed" is visible and self-correcting the
-- moment the panel reports a real arm. Every value is logged, so an unmapped
-- one can be identified and added rather than silently guessed at forever.
function QueryPartitionArmState(partitionId, opts)
  opts = opts or {}
  local fireEvents = opts.fireEvents ~= false
  local part = Partitions[partitionId]
  -- An empty string is TRUTHY in Lua, so a blank code in Partitions Config
  -- would otherwise sail past the guard below and be sent to the panel as an
  -- empty password -- producing a NAK instead of a clear "you did not
  -- configure a code" message.
  local pw = part and part.userCode
  if pw == '' then pw = nil end

  local function apply(state, note)
    LogInfo('Partition ' .. partitionId .. ': ' .. state ..
      (note and (' (' .. note .. ')') or ''))
    SetPartitionState(partitionId, state, opts.isInit)
    if fireEvents then FirePartitionEvent(partitionId, state) end
  end

  if not pw then
    if fireEvents then
      apply('Armed', 'no user code configured to query the mode')
    else
      LogInfo('Partition ' .. partitionId .. ': cannot sync state -- no user code in Partitions Config')
    end
    return
  end

  RequestData(PARAM_SYSTEM_KEY, partitionId, partitionId, pw, function(frame, err)
    -- `parameters` comes from the panel and is only ever indexed after a type
    -- check: a panel answering with a scalar would otherwise throw here.
    local params = frame and frame.parameters
    local first = (type(params) == 'table') and params[1] or nil
    if err or first == nil or JSON.isNull(first) then
      if fireEvents then
        apply('Armed', 'mode query failed: ' .. tostring(err or 'no data'))
      else
        -- Say why loudly. A partition stuck on "Unknown" shows as Unknown /
        -- offline in the Control4 app above the zone list, and without this
        -- there is nothing anywhere explaining that the state query is what
        -- failed.
        local msg = 'Partition ' .. partitionId .. ' state query FAILED (' ..
          tostring(err or 'no data') .. '). The partition will read Unknown in the app ' ..
          'until the panel reports an arm or disarm. Check the partition user code in ' ..
          'Partitions Config, then use the "Sync Partition States" action.'
        LogError(msg)
        SetProp('Last Command Result', msg)
      end
      return
    end

    local raw = JSON.scalar(first)
    local code = tonumber(raw)
    local mode = SYSTEM_KEY_TO_MODE[code]
    local confirmedDisarmed = code ~= nil and SYSTEM_KEY_DISARMED[code]
    -- Always log the raw value: this is how an unmapped arm mode gets found.
    LogInfo('Partition ' .. partitionId .. ' System Key Status = ' .. tostring(raw) ..
      (mode and (' -> Armed ' .. mode) or confirmedDisarmed and ' -> Disarmed (confirmed code)'
        or ' -> no arm-mode mapping for this value'))

    -- Last Command Result for the success/confirmed paths -- the unconfirmed
    -- path below sets its own, more detailed message instead of this one.
    if not fireEvents and (mode or confirmedDisarmed) then
      SetProp('Last Command Result', 'Partition ' .. partitionId ..
        ' synced from panel: system key ' .. tostring(raw) ..
        (mode and (' = Armed ' .. mode) or ' = Disarmed'))
    end

    if code == SYSTEM_KEY_NOT_EXIST then
      -- Appendix C: 1 means this partition is not configured on the panel.
      -- Not an arm state, and not an unknown code either -- say so plainly
      -- and leave the partition alone. Reporting it as an unrecognised value
      -- (as v26 and earlier did) put an error in the log every sync for a
      -- partition the installer simply has not created on the panel.
      LogWarn('Partition ' .. partitionId .. ' does not exist on the panel ' ..
        '(system key 1). Remove it from Partitions Config, or create it on the ' ..
        'panel, so the app is not showing a partition the panel has never heard of.')
      SetProp('Last Command Result', 'Partition ' .. partitionId ..
        ' does not exist on the panel')
    elseif confirmedDisarmed and not mode then
      apply('Disarmed', 'system key ' .. tostring(raw) .. ' is a confirmed disarmed code')
    elseif mode then
      apply('Armed ' .. mode)
    elseif fireEvents then
      -- Post-arm: we know it armed (the panel just reported an arm EVENT),
      -- we just could not name the mode. Defaulting to "Armed" here is
      -- justified by that event, not a guess.
      apply('Armed', 'system key ' .. tostring(raw) .. ' is not a known arm mode')
    else
      -- Cold sync: we do NOT know the partition armed. An unrecognised code
      -- here used to default to "Disarmed" -- that was a guess with nothing
      -- behind it (no arm event, no confirmation any specific code means
      -- disarmed), and for a security system the wrong-direction guess is
      -- the dangerous one: a house that is actually armed showing as
      -- Disarmed/Ready is worse than one that is actually disarmed showing
      -- as Unknown. Report it loudly and leave the partition as-is (Unknown,
      -- if this is the first sync) rather than asserting a state we have not
      -- earned. Once a code is confirmed against a known physical state, add
      -- it to SYSTEM_KEY_DISARMED below instead of relying on this fallback.
      local msg = 'Partition ' .. partitionId .. ' state query returned system key ' ..
        tostring(raw) .. ', which is not a recognised arm mode or a confirmed ' ..
        'disarmed code. Leaving the partition state unchanged rather than guessing. ' ..
        'If the panel was actually Disarmed just now, report this system key value ' ..
        'so it can be added as a confirmed mapping.'
      LogError(msg)
      SetProp('Last Command Result', msg)
    end
  end)
end

-- Kept as the post-arm entry point so existing call sites read clearly.
function QueryArmModeAndFire(partitionId)
  QueryPartitionArmState(partitionId, { fireEvents = true })
end

-- Cold sync of every configured partition. Runs when the panel verifies, and
-- available on demand as the "Sync Partition States" action.
function SyncPartitionStates(isInit)
  local any = false
  for pid in pairs(Partitions) do
    any = true
    QueryPartitionArmState(pid, { fireEvents = false, isInit = isInit })
  end
  if not any then
    LogInfo('No partitions configured -- nothing to sync. Check the Partitions Config property.')
  end
end

--[[=============================================================================
    Event dispatch (panel -> Control4 programming events + properties)
===============================================================================]]

--[[=============================================================================
    Partition state model -- ONE source of truth.

    Earlier versions kept the arm state in a property, pushed alarm state
    straight to the proxy, and restored alarms from a snapshot taken when the
    alarm began. That produced a family of bugs with the same shape: the
    snapshot went stale (user disarms during an alarm -> alarm restores ->
    partition springs back to "Armed Away" on a disarmed house), and the two
    stores disagreed (a routine GET_CURRENT_STATE would read the property and
    silently cancel a live fire alarm on the widget).

    Instead each partition holds a `base` (what the panel says about arming)
    and a set of currently-active `alarms`. The effective state is derived,
    never stored: alarms win while any is active, and when the last one
    clears we fall back to whatever `base` is NOW -- which arm/disarm events
    have been keeping current all along. No snapshots, so nothing to go
    stale, and every consumer (property, partition proxy, panel proxy,
    GET_CURRENT_STATE, the panel info XML) reads the same derivation.
===============================================================================]]

PartitionStatus = PartitionStatus or {}

-- Most severe first: a fire alarm outranks a burglary for what the widget shows.
local ALARM_PRIORITY = { 'Fire', 'Police', 'Medical', 'Panic', 'Burglary' }

function PartitionStatusFor(partitionId)
  local st = PartitionStatus[partitionId]
  if not st then
    st = { base = 'Unknown', alarms = {} }
    PartitionStatus[partitionId] = st
  end
  return st
end

-- Returns friendlyState, alarmType. alarmType is nil unless an alarm is live.
function EffectivePartitionState(partitionId)
  local st = PartitionStatusFor(partitionId)
  for _, t in ipairs(ALARM_PRIORITY) do
    if st.alarms[t] then return 'Alarm', t end
  end
  return st.base, nil
end

-- Publishes the derived state everywhere at once, so the property and both
-- proxies can never drift apart.
-- `isInit` sends the proxy PARTITION_STATE_INIT instead of PARTITION_STATE:
-- the documented way to seed state without it reading as a live change. Used
-- for the cold sync on connect, so reloading the driver on an armed house
-- does not look like a fresh arming to anything watching the proxy.
function PublishPartitionState(partitionId, isInit)
  local friendly, alarmType = EffectivePartitionState(partitionId)
  local propName = 'Partition ' .. partitionId .. ' State'
  if Properties[propName] ~= nil then
    SetProp(propName, friendly)
  end
  NotifyProxyPartitionState(partitionId, friendly, alarmType, isInit)
  RefreshPartitionsDocument(partitionId, friendly)
end

-- The ALL_PARTITIONS_INFO document carries a <state> per partition, and the
-- app's status header is populated from it. It used to be sent only by
-- SendPanelInfo(), whose fingerprint deliberately ignores live state -- so
-- the ONE copy the app ever saw was the one published at load/verification
-- time, when the state was still OFFLINE. Every later state change went out
-- as PARTITION_STATE/PANEL_PARTITION_STATE only, and the header kept showing
-- the stale "Unknown" from that first document however many times the panel
-- reported Armed Away.
--
-- Re-send the document whenever a partition's proxy-level state actually
-- changes. That is one SendToProxy call, not the ~130-call inventory
-- republish, so it is cheap enough to do on every arm/disarm/alarm. Guarded
-- on the mapped proxy state rather than the friendly string so cosmetic
-- differences ("Armed Away (Full Arm)" vs "Armed Away") do not churn it.
LastPublishedPartitionState = LastPublishedPartitionState or {}

function RefreshPartitionsDocument(partitionId, friendlyState)
  if not PartitionProxyBindingID(partitionId) then return end
  if Partitions[partitionId] == nil then return end
  local state, armType = proxyStateForFriendly(friendlyState)
  if not state then return end
  local key = state .. '/' .. tostring(armType or '')
  if LastPublishedPartitionState[partitionId] == key then return end
  LastPublishedPartitionState[partitionId] = key
  C4:SendToProxy(PANEL_PROXY_BINDINGID, 'ALL_PARTITIONS_INFO', AllPartitionsInfoXML(), 'NOTIFY')
end

-- Records what the PANEL says about arming (Disarmed / Armed <mode> /
-- Unknown). Never used for alarms -- an alarm must not overwrite the arm
-- state, or we lose what to go back to when it clears.
function SetPartitionState(partitionId, state, isInit)
  PartitionStatusFor(partitionId).base = state
  PublishPartitionState(partitionId, isInit)
  -- Mirror into driver variables so Composer programming can test partition
  -- state directly, instead of the installer maintaining a Variables-agent
  -- boolean by hand off the arm/disarm events (which drifts if one is ever
  -- missed).
  if partitionId >= 1 and partitionId <= MAX_DECLARED_PARTITIONS then
    local effective = tostring(EffectivePartitionState(partitionId))
    SetDriverVariable('PARTITION_' .. partitionId .. '_STATE', effective)
    SetDriverVariable('PARTITION_' .. partitionId .. '_ARMED',
      effective:find('Armed') ~= nil)
  end
end

-- Raises or clears one alarm type on a partition. Multiple alarm types can
-- be active at once and each clears independently. `scope` records whether
-- the raising event named this partition or was panel-wide, so a later
-- restore can be matched at the same breadth (see ClearPartitionAlarm).
function SetPartitionAlarm(partitionId, alarmType, active, scope)
  local st = PartitionStatusFor(partitionId)
  st.alarms[alarmType] = active and (scope or 'partition') or nil
  PublishPartitionState(partitionId)
end

-- Clears an alarm type, honouring how it was raised. A panel-wide alarm that
-- restores with a specific partition number must still clear everywhere --
-- otherwise every OTHER partition it was raised on stays stuck in ALARM with
-- no event left that could ever clear it.
function ClearPartitionAlarm(partitionId, alarmType)
  SetPartitionAlarm(partitionId, alarmType, false)
  for pid, st in pairs(PartitionStatus) do
    if pid ~= partitionId and st.alarms[alarmType] == 'panel' then
      SetPartitionAlarm(pid, alarmType, false)
    end
  end
end

-- Partitions an event applies to.
--
-- NOTE: an earlier comment here described partition 0 as fanning out to every
-- configured partition. It does NOT, and must not -- see below. That comment
-- described behaviour that was removed as a safety fix and is deleted rather
-- than left to invite someone to "restore" it.
--
-- A partition of 0, missing, or unparseable means UNKNOWN -- never
-- "everything". This driver previously fanned those out to every configured
-- partition, which is how one 401/407 event without a partition number could
-- mark an entire multi-partition house Disarmed in Control4 and fire every
-- "when disarmed" automation -- unlocking doors, dropping away mode -- while
-- partitions were still physically armed. `tonumber(...) or 0` also collapses
-- an absent field and a garbage value into the same 0, so a malformed frame
-- had the same effect. The reference implementation refuses to act on such
-- events at all, and so do we: the caller surfaces them through the
-- Unmapped Panel Event path instead of guessing.
function PartitionTargets(partition)
  if partition and partition > 0 then
    return { partition }
  end
  return {}
end

-- Forgets everything we believed about a partition, alarms included. Used
-- whenever the link state means our knowledge is stale: a burglary alarm
-- whose restore we never saw (because the panel dropped mid-alarm) would
-- otherwise pin the partition in ALARM forever -- there is no other way out
-- of an alarm than the matching restore.
function ResetPartitionStatus()
  PartitionStatus = {}
  LastPublishedPartitionState = {}
end

--[[=============================================================================
    Native Control4 Security proxy (Security Panel + one Security Partition
    per declared partition). Additive: everything above (Actions, Events,
    read-only Properties) keeps working exactly as before whether or not
    anyone binds the native proxy to a room. This just mirrors the same
    state onto C4:SendToProxy() so the shield-icon widget/keypad works too.
===============================================================================]]

function PartitionProxyBindingID(partitionId)
  if partitionId and partitionId >= 1 and partitionId <= MAX_DECLARED_PARTITIONS then
    return PANEL_PROXY_BINDINGID + partitionId
  end
  return nil
end

-- Our friendly state strings ("Disarmed", "Armed Away", "Armed Shabbat",
-- "Alarm", "Unknown", ...) -> the Security Partition proxy's STATE/TYPE
-- notification fields (confirmed exact param names/values from the real
-- Konnected driver and Snap One's PARTITION_STATE doc -- see README.md).
-- Returns nil, nil for states (like the initial "Unknown") that don't map
-- to anything meaningful yet, so callers just skip the notify.
-- Global, not local: RefreshPartitionsDocument() is defined earlier in the
-- file and a `local` declared below it would resolve to a nil global there.
function proxyStateForFriendly(friendly)
  if friendly == 'Disarmed' then return 'DISARMED_READY', '' end
  if friendly == 'Alarm' then return 'ALARM', 'Burglary' end
  if friendly == 'Armed' then return 'ARMED', '' end
  -- We have no live link to the panel, so we do not know the state. Saying
  -- OFFLINE is strictly better than leaving the widget showing a confident
  -- stale "Disarmed"/"Armed Away" for a system we cannot see.
  if friendly == 'Unknown' or friendly == 'Offline' then return 'OFFLINE', '' end
  local armType = friendly and friendly:match('^Armed (.+)$')
  if armType then return 'ARMED', armType end
  return nil, nil
end

function NotifyProxyPartitionState(partitionId, friendlyState, alarmType, isInit)
  local bindingId = PartitionProxyBindingID(partitionId)
  if not bindingId then return end
  local state, armType = proxyStateForFriendly(friendlyState)
  if not state then
    LogInfo('Partition ' .. tostring(partitionId) .. ': "' .. tostring(friendlyState) ..
      '" maps to no proxy state; the app keeps showing its previous value')
    return
  end
  -- An alarm carries which KIND of alarm in TYPE (Fire/Burglary/...).
  if state == 'ALARM' and alarmType then armType = alarmType end
  LogInfo('Partition ' .. tostring(partitionId) .. ' -> binding ' .. bindingId ..
    ': STATE=' .. state .. ' TYPE="' .. tostring(armType) .. '"' ..
    (isInit and ' (seed + live)' or ''))
  local stateParams = {
    STATE = state,
    TYPE = armType,
    DELAY_TIME_TOTAL = 0,
    DELAY_TIME_REMAINING = 0,
    CODE_REQUIRED_TO_CLEAR = (state == 'ALARM'),
  }
  if isInit then
    -- Seed first, then state it again as a live change.
    --
    -- The reference driver sends PARTITION_STATE_INIT exactly once, at
    -- LateInit, and everything afterwards as PARTITION_STATE. This driver was
    -- also using INIT for the cold sync on connect, to keep a driver reload on
    -- an armed house from reading as a fresh arming to programming. The cost
    -- of that was the app's partition header sitting at UNKNOWN -- the proxy's
    -- own default -- even though the sync had succeeded and every internal
    -- value was right: nothing Navigator re-renders on had been sent.
    --
    -- Sending both means the seed establishes the value and the live notify
    -- makes the UI reflect it. Because the INIT immediately precedes it with
    -- the same value, the proxy has no state CHANGE to propagate, so this
    -- should not fire "when armed"/"when disarmed" programming either.
    C4:SendToProxy(bindingId, 'PARTITION_STATE_INIT', stateParams, 'NOTIFY')
  end
  C4:SendToProxy(bindingId, 'PARTITION_STATE', stateParams, 'NOTIFY')
  -- The Security PANEL proxy keeps its own view of every partition; the
  -- reference driver notifies both on every change. Without this the panel
  -- proxy's partition table stays empty/stale forever.
  C4:SendToProxy(PANEL_PROXY_BINDINGID, 'PANEL_PARTITION_STATE', {
    PARTITION_ID = partitionId,
    STATE = state,
    TYPE = armType,
  }, 'NOTIFY')
end

function NotifyProxyAllPartitionsOffline()
  for pid = 1, MAX_DECLARED_PARTITIONS do
    if Partitions[pid] then
      NotifyProxyPartitionState(pid, 'Offline')
    end
  end
end

-- Life-safety / panic alarms. These just add to (or remove from) the
-- partition's active-alarm set -- the derived state model handles what the
-- widget should show while several alarms overlap, and what to fall back to
-- when each one clears. No snapshots, so nothing can go stale if the user
-- arms or disarms while the alarm is running.
function NotifyProxyEmergency(partitionId, emergencyType, isNew)
  local panelWide = not (partitionId and partitionId > 0)
  for _, pid in ipairs(PartitionTargets(partitionId)) do
    local bindingId = PartitionProxyBindingID(pid)
    if isNew then
      if bindingId then
        C4:SendToProxy(bindingId, 'EMERGENCY_TRIGGERED', { TYPE = emergencyType }, 'NOTIFY')
      end
      SetPartitionAlarm(pid, emergencyType, true, panelWide and 'panel' or 'partition')
    else
      ClearPartitionAlarm(pid, emergencyType)
    end
  end
end

-- Panel-level trouble conditions (AC loss, low battery, comm trouble,
-- tamper) surface on the Security Panel proxy's own trouble list.
--[[---------------------------------------------------------------------------
    Every trouble used to be sent with IDENTIFIER = 0.

    IDENTIFIER is how the proxy tells one standing trouble from another, so
    sharing 0 across all of them meant they overwrote each other: with mains
    power and low battery both active, clearing either cleared the proxy's
    single id-0 trouble and the other silently vanished from the app while
    still being a real condition.

    Each trouble now has its own stable id. Anything unlisted gets a slot
    derived from its text rather than colliding on 0.

    Parameter names match the shipped reference driver exactly: TROUBLE_START
    carries TROUBLE_TEXT and IDENTIFIER, TROUBLE_CLEAR carries IDENTIFIER
    alone.
-----------------------------------------------------------------------------]]
TROUBLE_IDENTIFIERS = {
  ['Tamper'] = 1,
  ['AC power lost'] = 2,
  ['Low battery'] = 3,
  ['Communication trouble'] = 4,
  ['Event notifications disabled'] = 5,
}
TROUBLE_ID_BASE = 100
TroubleIdAssigned = {}
TroubleIdNext = TROUBLE_ID_BASE

function TroubleIdentifier(troubleText)
  local known = TROUBLE_IDENTIFIERS[troubleText]
  if known then return known end
  if not TroubleIdAssigned[troubleText] then
    TroubleIdAssigned[troubleText] = TroubleIdNext
    TroubleIdNext = TroubleIdNext + 1
  end
  return TroubleIdAssigned[troubleText]
end

function NotifyProxyTrouble(troubleText, isNew)
  local id = TroubleIdentifier(troubleText)
  if isNew then
    C4:SendToProxy(PANEL_PROXY_BINDINGID, 'TROUBLE_START', {
      TROUBLE_TEXT = troubleText,
      IDENTIFIER = id,
    }, 'NOTIFY')
  else
    C4:SendToProxy(PANEL_PROXY_BINDINGID, 'TROUBLE_CLEAR', {
      IDENTIFIER = id,
    }, 'NOTIFY')
  end
end

function NotifyProxyArmFailed(partitionId)
  local bindingId = PartitionProxyBindingID(partitionId)
  if not bindingId then return end
  C4:SendToProxy(bindingId, 'ARM_FAILED', { ACTION = 'NA' }, 'NOTIFY')
end

function NotifyProxyDisarmFailed(partitionId, interfaceId)
  local bindingId = PartitionProxyBindingID(partitionId)
  if not bindingId then return end
  C4:SendToProxy(bindingId, 'DISARM_FAILED', { INTERFACE_ID = interfaceId or '' }, 'NOTIFY')
end

-- Seeds the proxy for every DECLARED partition, not just the configured
-- ones. driver.xml has to declare a fixed set of partition bindings (8), so
-- partitions the installer did not configure must be explicitly told
-- ENABLED=false -- otherwise Composer/Navigator shows 8 security partitions
-- for a one-partition house, 7 of them dead.
-- Runs from OnDriverLateInit, not OnDriverInit: proxy bindings are not
-- reliably connected yet during OnDriverInit, so notifications sent there
-- can be dropped on the floor (this is where the reference driver does it).
function NotifyProxyPartitionsInit()
  for pid = 1, MAX_DECLARED_PARTITIONS do
    local bindingId = PartitionProxyBindingID(pid)
    if bindingId then
      local configured = (Partitions[pid] ~= nil)
      C4:SendToProxy(bindingId, 'PARTITION_ENABLED', { ENABLED = configured and 'true' or 'false' }, 'NOTIFY')
      if configured then
        NotifyPartitionInfo(pid)
        if PanelVerified then
          -- The panel beat us here. Since v36 this runs on a timer rather
          -- than inline in OnDriverLateInit, so a panel that reconnects
          -- inside that window can report real state BEFORE this seed --
          -- and an unconditional OFFLINE would then overwrite a live
          -- "Armed Away" shield with "offline" until the next sync. Seed
          -- what the panel actually told us instead.
          PublishPartitionState(pid, true)
        else
          -- We have not heard from the panel yet, so we genuinely do not
          -- know the state. Seed OFFLINE rather than an optimistic
          -- DISARMED_READY that would show a green "disarmed" shield for an
          -- armed house.
          C4:SendToProxy(bindingId, 'PARTITION_STATE_INIT', {
            STATE = 'OFFLINE',
            TYPE = '',
            DELAY_TIME_TOTAL = 0,
            DELAY_TIME_REMAINING = 0,
          }, 'NOTIFY')
        end
      end
    end
  end
end

-- Per-zone open/bypassed state. Needed so a bypass notification can report
-- the zone's real open state (and vice versa) instead of guessing -- the
-- proxy is sent both fields together every time.
ZoneState = ZoneState or {}

function ZoneStateFor(zone)
  local st = ZoneState[zone]
  if not st then
    st = { open = false, bypassed = false, partition = nil }
    ZoneState[zone] = st
  end
  return st
end

-- Resolves which partition a zone belongs to. Zones Config's partition field
-- is optional (and "Discover Zone Names" historically wrote it empty), so
-- fall back to the partition the panel last reported this zone against --
-- otherwise the zone never appears in ANY partition's zone list, and a
-- bypass (which carries no partition of its own here) would be invisible.
function ZonePartition(zone, eventPartition)
  local zcfg = Zones[zone]
  if zcfg and zcfg.partition then return zcfg.partition end
  if eventPartition and eventPartition > 0 then return eventPartition end
  local st = ZoneState[zone]
  if st and st.partition then return st.partition end
  --[[-------------------------------------------------------------------------
      Last resort: the LOWEST configured partition, and never nil (v22).

      This used to return the only configured partition if there was exactly
      one, and nil otherwise -- the reasoning being that guessing partition 1
      on a multi-partition system puts the zone in the wrong list. That was
      wrong about which failure is worse. A zone that resolves to nil is
      published with an EMPTY <partitions></partitions> field and gets no
      HAS_ZONE at all, so it belongs to no partition: it still appears in the
      app (PANEL_ZONE_INFO goes to the panel proxy regardless) but under no
      partition heading, which is what the bare "UNKNOWN" group header above
      the Zones list turned out to be.

      So: two or more partitions configured plus zones whose Zones Config
      entry omits the 4th field = every zone unattributed. Konnected's
      reference driver -- the one confirmed working on real Control4
      hardware -- never does this: it hardcodes <partitions>1</partitions>
      for every zone. An empty partitions field is not a state Navigator
      appears to handle.

      Being in the wrong partition's list is visible and correctable in one
      Zones Config edit. Being in no partition's list looks like a driver
      bug and cannot be corrected from the app at all. PublishZoneInventory
      logs how many zones landed here so it is never silent.
  ---------------------------------------------------------------------------]]
  return FallbackPartition()
end

-- The partition a zone lands in when nothing else says otherwise: the lowest
-- configured one, or 1 if none are configured. Never nil, by design.
function FallbackPartition()
  local lowest = nil
  for pid in pairs(Partitions) do
    if lowest == nil or pid < lowest then lowest = pid end
  end
  return lowest or 1
end

-- How many configured zones name their own partition, and how many are
-- falling back. Reported at publish time so an "UNKNOWN"-looking zone list
-- can be diagnosed from one log line instead of guessing at the config.
function ZoneAttributionSummary()
  local explicit, defaulted = 0, 0
  for _, zcfg in pairs(Zones) do
    if zcfg.partition then explicit = explicit + 1 else defaulted = defaulted + 1 end
  end
  return explicit, defaulted
end

-- Mirrors zone open/bypass onto both the partition's ZONE_STATE (so the
-- native keypad/shield widget's own zone list is correct) and the panel's
-- PANEL_ZONE_STATE. Param names (ZONE_ID/ZONE_OPEN/ZONE_BYPASSED and
-- ZONE_ID/ZONE_OPEN) confirmed from the Konnected reference driver.
-- Pass nil for isOpen/isBypassed to leave that field at its tracked value.
--[[---------------------------------------------------------------------------
    Live zone reporting, and the app's History list (v22).

    The Control4 security proxy protocol has no "update the status but do not
    log this" flag: the app's History list is built by Director from the same
    zone notifications that drive the live zone list. So a house with motion
    detectors fills History with open/close entries, and there is nothing in
    the protocol to mark them uninteresting. Control4's own Event/Alert/Alarm
    filter on that screen was tried on the installed system and changed
    nothing.

    That leaves two levers, both here, both off by default:

    Quiet Zone Types -- zone types listed here stop reporting live state
    changes. Motion detectors are the usual flood source (they trip all day
    and the entry is never interesting), while doors and windows stay live.
    The zone still appears in the list, still tracks its state internally,
    and -- importantly -- still fires its Control4 programming events, so
    automations built on it keep working. Only the proxy notification that
    feeds the app's list and History is withheld.

    Zone State Reporting -- which of the two notifications to send at all.
    Every zone change currently sends ZONE_STATE to the partition proxy AND
    PANEL_ZONE_STATE to the panel proxy (the reference driver does the same).
    Which of those Director turns into a History row is not documented
    anywhere found, so rather than ship a guess and iterate a version at a
    time, this exposes it: switch it, watch History, keep whatever works.
    "Off" is the guaranteed-quiet setting, at the cost of live zone status
    between inventory publishes.
-----------------------------------------------------------------------------]]
function ZoneReportingMode()
  local v = tostring(Properties['Zone State Reporting'] or ''):lower()
  if v:find('partition only') then return 'partition' end
  if v:find('panel only') then return 'panel' end
  if v:find('off') then return 'off' end
  return 'both'
end

--[[---------------------------------------------------------------------------
    Which zones are quiet (v23: accepts zone NUMBERS as well as type words).

    v22 matched only the type word from Zones Config, which assumed the
    installer and this driver agree on the spelling. They may not: the app
    draws the same little running figure for both `motion` and `interior`,
    so "set Quiet Zone Types to motion" silently does nothing on a config
    that says `interior` -- a failure mode with no feedback at all.

    So the list now takes either form, mixed freely:
        motion, interior, 4, 12
    A zone number is unambiguous and can be read straight off the app's own
    History rows via Zones Config, so it is the reliable way to silence one
    specific noisy detector.
-----------------------------------------------------------------------------]]
function IsQuietZone(zone, zoneType)
  local configured = tostring(Properties['Quiet Zones'] or '')
  if trim(configured) == '' then return false end
  local target = tostring(zoneType or 'contact'):lower()
  for word in configured:gmatch('[^,;]+') do
    local entry = trim(word):lower()
    if entry ~= '' then
      local asNumber = tonumber(entry)
      if asNumber then
        if zone and asNumber == zone then return true end
      elseif entry == target then
        return true
      end
    end
  end
  return false
end

-- Named zones currently being silenced, for the startup log. Proving the
-- setting took effect matters as much as the setting itself -- "I set it and
-- nothing changed" is otherwise indistinguishable from "it did not match".
function QuietZoneSummary()
  local quiet = {}
  for _, z in ipairs(SortedZoneNumbers()) do
    local zcfg = Zones[z]
    if zcfg and IsQuietZone(z, zcfg.type) then
      quiet[#quiet + 1] = z .. ' (' .. tostring(zcfg.name) .. ')'
    end
  end
  return quiet
end

function NotifyProxyZoneState(zone, isOpen, isBypassed, eventPartition)
  local st = ZoneStateFor(zone)
  local bypassWas = st.bypassed
  if isOpen ~= nil then st.open = isOpen end
  if isBypassed ~= nil then st.bypassed = isBypassed end
  -- Remember the partition the panel attributed this zone to, so later
  -- notifications that carry no partition of their own (a bypass written by
  -- this driver, say) still land on the right partition proxy.
  if eventPartition and eventPartition > 0 then st.partition = eventPartition end

  -- Refresh the status line before the suppression checks below, not after.
  -- A quiet zone, or one whose reporting mode is off, is still a disabled
  -- detector when bypassed -- those settings silence open/close chatter, and
  -- were never meant to hide a bypass. Only on an actual change: zone
  -- open/close events arrive in bursts and this is a Director round trip.
  if st.bypassed ~= bypassWas then
    NotifyPartitionDisplayText(ZonePartition(zone, eventPartition))
  end

  -- State is always tracked above, whatever the reporting settings say: the
  -- bypass logic, the inventory's IS_OPEN, and the zone-status sync all read
  -- it. Only the outbound notifications are suppressed below.
  local zcfg = Zones[zone]
  if IsQuietZone(zone, zcfg and zcfg.type) then
    Dbg('Zone ' .. zone .. ' is quiet; state tracked but not reported to the app')
    return
  end

  local mode = ZoneReportingMode()
  if mode == 'off' then return end

  if mode == 'both' or mode == 'partition' then
    local partitionBinding = PartitionProxyBindingID(ZonePartition(zone, eventPartition))
    if partitionBinding then
      C4:SendToProxy(partitionBinding, 'ZONE_STATE', {
        ZONE_ID = tostring(zone),
        ZONE_OPEN = tostring(st.open),
        ZONE_BYPASSED = tostring(st.bypassed),
      }, 'NOTIFY')
    end
  end

  if mode == 'both' or mode == 'panel' then
    C4:SendToProxy(PANEL_PROXY_BINDINGID, 'PANEL_ZONE_STATE', {
      ZONE_ID = tostring(zone),
      ZONE_OPEN = tostring(st.open),
    }, 'NOTIFY')
  end
end

--[[=============================================================================
    ReceivedFromProxy(idBinding, sCommand, tParams)

    Called by Director when the *native* Security proxy (not the Actions
    tab) sends a command -- i.e. someone armed/disarmed from the built-in
    shield-icon widget/keypad rather than a Composer programming action.
    idBinding tells us which partition (PartitionProxyBindingID above).
    Routes onto the exact same ArmPartition/DisarmPartition used by the
    Actions-tab commands, so behaviour (which user code gets sent to the
    panel, etc.) is identical either way.
===============================================================================]]

-- What an incoming PARTITION_ARM's ArmType may say. The full labels are what
-- `arm_states` advertises and therefore what Navigator will send back, but the
-- bare Control4 names and the bare PIMA names are accepted too: an interface
-- that abbreviates, or a project configured against an older build, should
-- still be able to arm rather than failing with an unhelpful ARM_FAILED.
local ARM_TYPE_TO_MODE = {
  [ARM_LABEL_AWAY]  = 'away',  ['Away']  = 'away',  ['Full Arm'] = 'away',
  [ARM_LABEL_STAY]  = 'stay',  ['Stay']  = 'stay',  ['Home1']    = 'stay',
  [ARM_LABEL_NIGHT] = 'night', ['Night'] = 'night', ['Home2']    = 'night',
}

-- Resolves an ArmType string to an internal mode, or nil if unrecognised.
-- Exposed so the regression suite can assert that every arm state driver.xml
-- advertises is one this driver will actually act on.
function ArmModeForType(armType)
  if type(armType) ~= 'string' then return nil end
  return ARM_TYPE_TO_MODE[armType]
end

-- Maps a proxy binding id back to a partition, returning nil for anything
-- that is not one of OUR declared partition bindings. Never trust the
-- arithmetic alone: the panel binding (5001) would otherwise resolve to
-- "partition 0", and partition 0 is what this driver sends for a PANEL-WIDE
-- operation -- i.e. a disarm addressed to every partition at once.
local function PartitionForBinding(idBinding)
  local partitionId = (tonumber(idBinding) or 0) - PANEL_PROXY_BINDINGID
  if partitionId < 1 or partitionId > MAX_DECLARED_PARTITIONS then return nil end
  return partitionId
end

-- XML escaping for the panel-proxy info documents below. Zone names come
-- from the panel (and may be Hebrew, or contain & or <), so they must be
-- escaped or the whole document fails to parse and the zone list stays empty.
local function xmlEscape(s)
  s = tostring(s or '')
  s = s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')
  s = s:gsub('"', '&quot;'):gsub("'", '&apos;')
  return s
end

-- <partitions> document for the Security Panel proxy. Schema (id / enabled /
-- binding_id / state) taken from the shipped reference driver.
function AllPartitionsInfoXML()
  local out = { '<partitions>' }
  for pid = 1, MAX_DECLARED_PARTITIONS do
    local bindingId = PartitionProxyBindingID(pid)
    local configured = (Partitions[pid] ~= nil)
    if bindingId and configured then
      -- Derived from the same model as everything else, so this document can
      -- never contradict what the widget is showing.
      local friendly = EffectivePartitionState(pid)
      local state = proxyStateForFriendly(friendly) or 'OFFLINE'
      out[#out+1] = string.format(
        '<partition><id>%s</id><enabled>true</enabled><binding_id>%s</binding_id><state>%s</state></partition>',
        tostring(pid), tostring(bindingId), state)
    end
  end
  out[#out+1] = '</partitions>'
  return table.concat(out)
end

--[[---------------------------------------------------------------------------
    PARTITION_INFO -- untested hypothesis for the Zones-tab "Unknown" label.

    Confirmed by testing: the bare word "Unknown", not "<name>: Unknown" --
    no partition name shown at all, even though PARTITION_STATE, PARTITION_
    STATE_INIT and PANEL_PARTITION_STATE were all confirmed sent with a real
    state (STATE=DISARMED_READY) at the moment this was seen. So this label
    is very unlikely to be reading arm/disarm state at all -- everything that
    carries state was already correct. "Unknown" matches the security
    partition proxy's own UNTOUCHED default identity, not a state we send.

    `PARTITION_INFO` is a real notify the "security" partition proxy template
    supports (confirmed from Control4's own proxy library inside the
    Konnected reference -- TEMPLATE_VERSION.securitypartition), sent to each
    PARTITION's own binding (5002+), separate from the panel-wide documents.
    Konnected's driver never actually calls it (dead template code in that
    reference too), so there is no captured example of its expected XML to
    copy -- the shape below is inferred from the sibling documents this
    driver already sends successfully (AllPartitionsInfoXML/AllZonesInfoXML),
    not confirmed. This is a hypothesis, not a verified fix -- test it and
    report back what the label shows now.
-----------------------------------------------------------------------------]]
function PartitionInfoXML(partitionId)
  local part = Partitions[partitionId]
  local name = (part and part.name) or ('Partition ' .. partitionId)
  local bindingId = PartitionProxyBindingID(partitionId)
  return string.format(
    '<partition><id>%s</id><name>%s</name><enabled>true</enabled><binding_id>%s</binding_id></partition>',
    tostring(partitionId), xmlEscape(name), tostring(bindingId))
end

function NotifyPartitionInfo(partitionId)
  local bindingId = PartitionProxyBindingID(partitionId)
  if not bindingId then return end
  if not Partitions[partitionId] then return end
  C4:SendToProxy(bindingId, 'PARTITION_INFO', PartitionInfoXML(partitionId), 'NOTIFY')
end

--[[=============================================================================
    DISPLAY_TEXT -- the partition status line.

    Origin. This was added in v24 as an experiment against the Zones-tab
    "UNKNOWN" header: DISPLAY_TEXT is the one partition-proxy notify whose
    literal purpose is putting text on a partition's screen, and its call
    shape is copied exactly from the shipped Control4 proxy template --

        C4:SendToProxy(BindingID, "DISPLAY_TEXT", DispText)

    three arguments, bare string payload, no NOTIFY mode argument.

    Result: it does NOT fill the Zones-tab header, which stays UNKNOWN. It
    renders in the app's **Status tab, below the lock indicator**. So the
    experiment answered its question in the negative and handed back
    something more useful -- a line of driver-controlled text on the screen
    the user is already looking at when they check the system.

    What goes on it. Two pieces of state that the app otherwise shows badly
    or not at all:

      1. Event notifications muted. v31 indicated this by raising a standing
         panel *trouble*, which was wrong on reflection: it puts a fault on a
         panel that has no fault, and since v35 gave troubles stable
         identifiers it also occupies a slot in a list meant for real
         conditions. A status line is the honest place for "the driver is
         deliberately quiet".
      2. Bypassed zones. A bypass is a disabled detector. Control4 shows it
         per zone on the Zones tab, which means noticing it requires going
         looking; naming them here puts it in front of whoever is arming.

    Both are suppression states -- the system doing less than it appears to.
    That is exactly what belongs on a status line, and why they share one.

    The **Partition Display Text** property still works: it is now the fixed
    prefix, so an installer label ("Ground floor") and the driver's own
    status coexist rather than one overwriting the other.
===============================================================================]]
DISPLAY_TEXT_SEPARATOR = ' | '
-- Keypad display lines are narrow and this is a status line, not a report:
-- past roughly this width the app truncates it and the interesting part is
-- as likely to be the half that got cut.
DISPLAY_TEXT_MAX = 64
-- Above this many bypassed zones, naming them all is what blows the budget,
-- so the count replaces the list. The count is the safety-relevant part.
DISPLAY_TEXT_MAX_NAMED_ZONES = 3

-- Last text sent per partition, so an unchanged line is not re-sent. Every
-- DISPLAY_TEXT is a blocking Director round trip, and this is republished
-- from zone events, which arrive in bursts.
DisplayTextSent = {}

function BypassedZonesForPartition(partitionId)
  local names = {}
  for _, z in ipairs(SortedZoneNumbers()) do
    local st = ZoneState[z]
    if st and st.bypassed and ZonePartition(z) == partitionId then
      local zcfg = Zones[z]
      local nm = zcfg and trim(tostring(zcfg.name or '')) or ''
      names[#names + 1] = (nm ~= '') and nm or ('Zone ' .. z)
    end
  end
  return names
end

-- Composes the status line for one partition. Pure: no Director calls, so
-- it is cheap to call on every state change and directly testable.
function PartitionStatusText(partitionId)
  local parts = {}

  local custom = trim(tostring(Properties['Partition Display Text'] or ''))
  if custom ~= '' then parts[#parts + 1] = custom end

  -- Deliberately first among the driver's own states. A muted driver is a
  -- system that will not tell you about the next alarm, which outranks
  -- knowing which door is bypassed.
  if not EventsEnabled then
    parts[#parts + 1] = 'Notifications OFF'
  end

  local bypassed = BypassedZonesForPartition(partitionId)
  if #bypassed > 0 then
    if #bypassed > DISPLAY_TEXT_MAX_NAMED_ZONES then
      parts[#parts + 1] = 'Bypassed: ' .. #bypassed .. ' zones'
    else
      parts[#parts + 1] = 'Bypassed: ' .. table.concat(bypassed, ', ')
    end
  end

  local text = table.concat(parts, DISPLAY_TEXT_SEPARATOR)
  if #text > DISPLAY_TEXT_MAX then
    -- Truncating mid-word would be worse than saying so.
    text = text:sub(1, DISPLAY_TEXT_MAX - 3) .. '...'
  end
  return text
end

function NotifyPartitionDisplayText(partitionId)
  local bindingId = PartitionProxyBindingID(partitionId)
  if not bindingId then return end
  if not Partitions[partitionId] then return end

  local text = PartitionStatusText(partitionId)
  -- An empty string is sent when the line clears, not skipped: skipping it
  -- would leave "Bypassed: Front Door" on screen after the bypass was
  -- cleared, which is a false statement about a security system. Only a
  -- genuinely unchanged line is suppressed.
  if DisplayTextSent[partitionId] == text then return end
  DisplayTextSent[partitionId] = text
  C4:SendToProxy(bindingId, 'DISPLAY_TEXT', text)
  Dbg('Partition ' .. partitionId .. ' status line: "' .. text .. '"')
end

-- Republishes the status line on every configured partition. Called from
-- init, from the mute controls, from bypass changes and when the property
-- changes; the per-partition dedupe above makes calling it freely cheap.
function PublishPartitionDisplayText()
  for pid = 1, MAX_DECLARED_PARTITIONS do
    if Partitions[pid] then
      NotifyPartitionDisplayText(pid)
    end
  end
end

-- <zones> document for the Security Panel proxy. type_id is the numeric
-- Control4 sensor type (icon only -- see README); we map the Zones Config
-- `type` word onto it, defaulting to CONTACT_SENSOR.
local ZONE_TYPE_IDS = {
  contact = 1, door = 2, window = 3, interior = 4, motion = 5,
  fire = 6, gas = 7, co = 8, heat = 9, leak = 10, water = 10,
  smoke = 11, pressure = 12, glass = 13, gate = 14, garage = 15,
}

function AllZonesInfoXML()
  local out = { '<zones>' }
  for zoneNum, zcfg in pairs(Zones) do
    local st = ZoneState[zoneNum]
    -- No '%d' anywhere here: a zone id that isn't an integer (a typo like
    -- "2.5" in Zones Config) makes string.format raise, and this runs from
    -- OnDriverLateInit -- one bad character in a text property would
    -- otherwise abort driver initialisation.
    local partition = ZonePartition(zoneNum, nil)
    local typeId = ZONE_TYPE_IDS[tostring(zcfg.type or 'contact'):lower()] or 1
    -- Never empty (v22): ZonePartition always resolves now. An empty
    -- partitions field put the zone in no partition's list at all, which is
    -- what the "UNKNOWN" group header above the Zones list was.
    local partitionField = partition and tostring(partition) or '1'
    out[#out+1] = string.format(
      '<zone><id>%s</id><name>%s</name><type_id>%s</type_id><partitions>%s</partitions>' ..
      '<can_bypass>%s</can_bypass><is_open>%s</is_open></zone>',
      tostring(zoneNum), xmlEscape(zcfg.name), tostring(typeId), partitionField,
      tostring(IsZoneBypassable(zoneNum, zcfg.type)),
      tostring(st and st.open or false))
  end
  out[#out+1] = '</zones>'
  return table.concat(out)
end

-- Identity of the currently-published inventory: partitions, and each zone's
-- number, name, type and partition. Anything that changes what the app should
-- display changes this string; live open/bypass status deliberately does not,
-- because that is pushed by ZONE_STATE on change rather than by republishing
-- the whole list.
-- Sorted zone numbers, so the app's list order is stable rather than
-- pairs()-random. Defined ahead of its callers: a `local` declared later in
-- the file is not in scope inside functions defined above it.
function SortedZoneNumbers()
  local nums = {}
  for z in pairs(Zones) do nums[#nums+1] = z end
  table.sort(nums)
  return nums
end

local function InventoryFingerprint()
  local parts = {}
  for pid = 1, MAX_DECLARED_PARTITIONS do
    parts[#parts+1] = pid .. '=' .. (Partitions[pid] and '1' or '0')
  end
  for _, z in ipairs(SortedZoneNumbers()) do
    local c = Zones[z]
    parts[#parts+1] = table.concat({ z, c.name or '', c.type or '',
      tostring(ZonePartition(z, nil)) }, ',')
  end
  return table.concat(parts, ';')
end

--[[=============================================================================
    Publishing the inventory costs roughly three Director round trips per
    zone plus the two info documents -- about 130 IPC calls on a 40-zone
    panel. It was previously re-sent unconditionally on driver load, on panel
    verification, on any config change, and again from "Apply Discovered
    Zones" (which also triggers the Zones Config change handler), so a normal
    startup-and-apply sequence made that call several times over. That is the
    delay felt when reloading the driver or applying a zone list.

    It is now skipped when nothing the app displays has actually changed.
===============================================================================]]
function SendPanelInfo(force)
  local fingerprint = InventoryFingerprint()
  if not force and fingerprint == LastInventoryFingerprint then
    Dbg('Zone/partition inventory unchanged; skipping republish')
    return
  end
  LastInventoryFingerprint = fingerprint

  C4:SendToProxy(PANEL_PROXY_BINDINGID, 'ALL_PARTITIONS_INFO', AllPartitionsInfoXML(), 'NOTIFY')
  -- Record what that document says, so the state-change refresh above does
  -- not immediately send an identical second copy.
  for pid = 1, MAX_DECLARED_PARTITIONS do
    if Partitions[pid] ~= nil then
      local st, at = proxyStateForFriendly((EffectivePartitionState(pid)))
      LastPublishedPartitionState[pid] = st and (st .. '/' .. tostring(at or '')) or nil
    end
  end
  C4:SendToProxy(PANEL_PROXY_BINDINGID, 'ALL_ZONES_INFO', AllZonesInfoXML(), 'NOTIFY')
  -- Sends PANEL_INITIALIZED itself once the queue has drained.
  PublishZoneInventory()
end

--[[=============================================================================
    Zone inventory.

    Three separate things have to happen for a zone to appear in the app with
    a live status, and missing any one of them leaves the list empty or dead:

      1. PANEL_ZONE_INFO  -- tells the PANEL proxy the zone exists, its name,
                             sensor type and which partitions it belongs to.
      2. HAS_ZONE         -- tells each PARTITION proxy that this zone is part
                             of ITS list. Without this the zone exists on the
                             panel but shows under no partition, which is what
                             an empty zone list in the app usually means.
      3. ZONE_STATE       -- the live open/closed/bypassed status, sent on
                             every change (and seeded by the sync below).
===============================================================================]]

--[[---------------------------------------------------------------------------
    Why this is spread across timer ticks instead of run in one go.

    Every C4:SendToProxy() is a blocking round trip to Director, and the
    per-zone part of the inventory is two of them per zone. On a 40-zone panel
    that is ~80 blocking calls -- and OnDriverLateInit / OnPropertyChanged run
    on the thread Composer is waiting on, so Composer sat frozen for the whole
    burst (~40s on the installed system). Nothing was wrong with the calls;
    they were simply all on the load path.

    The two whole-inventory DOCUMENTS (ALL_PARTITIONS_INFO, ALL_ZONES_INFO)
    are two calls and stay synchronous -- they are what the app's list and
    header actually read. The per-zone notifications are queued and drained
    ZONE_PUBLISH_BATCH at a time on a short timer, so the load callback
    returns immediately and the list finishes populating a moment later.

    Re-entrancy: a second publish (a Zones Config edit while the first is
    still draining) replaces the pending work list rather than interleaving
    with it, so the app never sees a half-old, half-new membership.
-----------------------------------------------------------------------------]]
ZONE_PUBLISH_BATCH = 8
ZONE_PUBLISH_TICK_MS = 50
ZonePublishQueue = nil
ZonePublishTimerId = nil
ZonePublishCursor = 1

function CancelZonePublish()
  if ZonePublishTimerId then
    pcall(function() C4:KillTimer(ZonePublishTimerId) end)
    ZonePublishTimerId = nil
  end
  ZonePublishQueue = nil
end

function PublishZoneInventory()
  -- Rebuild each partition's membership from scratch: on a Zones Config edit
  -- a zone may have moved partitions, and without clearing first it would be
  -- listed under both the old and the new one.
  CancelZonePublish()
  for pid = 1, MAX_DECLARED_PARTITIONS do
    local binding = PartitionProxyBindingID(pid)
    if binding and Partitions[pid] then
      C4:SendToProxy(binding, 'CLEAR_ZONE_LIST', {}, 'NOTIFY')
    end
  end

  ZonePublishQueue = SortedZoneNumbers()
  ZonePublishCursor = 1

  -- One line that says whether every zone is attributed to a partition. A
  -- zone list that reads "UNKNOWN" in the app is this number being non-zero
  -- on a system with more than one partition configured.
  -- Prove the quiet setting matched something. "I set it and nothing
  -- changed" and "it matched nothing" look identical from the app, so say
  -- which zones are actually being silenced -- or say plainly that the
  -- setting matched no zone at all.
  local configuredQuiet = trim(tostring(Properties['Quiet Zones'] or ''))
  if configuredQuiet ~= '' then
    local quiet = QuietZoneSummary()
    if #quiet > 0 then
      LogInfo('Quiet Zones "' .. configuredQuiet .. '" matched ' .. #quiet ..
        ' zone(s), which will not report status to the app: ' .. table.concat(quiet, ', '))
    else
      LogWarn('Quiet Zones is set to "' .. configuredQuiet .. '" but matched NO zone. ' ..
        'Entries are zone numbers or the type word used in Zones Config ' ..
        '(the app draws motion and interior the same, so check which one your ' ..
        'config actually says) -- listing zone numbers always works.')
    end
  end

  local explicit, defaulted = ZoneAttributionSummary()
  if defaulted > 0 then
    local plist = {}
    for pid in pairs(Partitions) do plist[#plist + 1] = pid end
    table.sort(plist)
    LogInfo('Zone inventory: ' .. explicit .. ' zone(s) name their own partition, ' ..
      defaulted .. ' fall back to partition ' .. tostring(FallbackPartition()) ..
      ' (configured partitions: ' .. (#plist > 0 and table.concat(plist, ',') or 'none') ..
      '). Set the 4th field of each Zones Config entry to place zones explicitly.')
  end

  -- Arm the drain rather than running the first batch inline. v13 left one
  -- batch synchronous as a compromise; with init synchronous again that
  -- batch is ZONE_PUBLISH_BATCH * 2 blocking calls on the thread Composer is
  -- waiting on, for no benefit. Deferring it is the one deferral with no
  -- correctness question attached: a zone INVENTORY arriving 50ms later
  -- cannot mis-state whether the house is armed -- unlike the partition
  -- seeds, which is exactly the distinction v38 had to learn.
  ZonePublishTimerId = C4:AddTimer(ZONE_PUBLISH_TICK_MS, 'MILLISECONDS')
  if not ZonePublishTimerId then
    -- No timer: publish inline rather than leave the app with no zone list.
    DrainZonePublishQueue()
  end
end

-- Publishes at most ZONE_PUBLISH_BATCH zones, then either re-arms the timer
-- or finishes with PANEL_INITIALIZED. Every batch runs on the timer since
-- v39; nothing here touches the load callback.
function DrainZonePublishQueue()
  ZonePublishTimerId = nil
  local queue = ZonePublishQueue
  if not queue then return end

  local last = math.min(ZonePublishCursor + ZONE_PUBLISH_BATCH - 1, #queue)
  for i = ZonePublishCursor, last do
    PublishOneZone(queue[i])
  end
  ZonePublishCursor = last + 1

  if ZonePublishCursor <= #queue then
    ZonePublishTimerId = C4:AddTimer(ZONE_PUBLISH_TICK_MS, 'MILLISECONDS')
    if not ZonePublishTimerId then
      -- No timer available: finish synchronously rather than leaving the app
      -- with a truncated zone list.
      for i = ZonePublishCursor, #queue do PublishOneZone(queue[i]) end
      ZonePublishCursor = #queue + 1
    else
      return
    end
  end

  ZonePublishQueue = nil
  -- Tells the panel proxy the hardware is initialised and ready. Navigator
  -- treats the panel as still coming up until it sees this, so it must come
  -- after the last zone rather than before the queue has drained.
  C4:SendToProxy(PANEL_PROXY_BINDINGID, 'PANEL_INITIALIZED', {}, 'NOTIFY')
end

function PublishOneZone(zoneNum)
  do
    local zcfg = Zones[zoneNum]
    if not zcfg then return end
    local st = ZoneState[zoneNum]
    local partition = ZonePartition(zoneNum, nil)
    local typeId = ZONE_TYPE_IDS[tostring(zcfg.type or 'contact'):lower()] or 1

    -- A quiet zone is published as closed and never seeded with a live
    -- status, so it cannot churn the app's list (or its History) at all.
    -- Showing a motion detector as permanently Normal is exactly what
    -- "quiet" is being asked for; its programming events still fire.
    local quiet = IsQuietZone(zoneNum, zcfg.type)

    C4:SendToProxy(PANEL_PROXY_BINDINGID, 'PANEL_ZONE_INFO', {
      ID = zoneNum,
      NAME = zcfg.name,
      TYPE_ID = typeId,
      PARTITIONS = partition and tostring(partition) or '',
      IS_OPEN = (not quiet) and ((st and st.open) or false) or false,
    }, 'NOTIFY')

    local binding = PartitionProxyBindingID(partition)
    if binding then
      -- A quiet zone is still claimed by its partition: it belongs in the
      -- list, it just does not report status.
      C4:SendToProxy(binding, 'HAS_ZONE', { ZONE_ID = zoneNum }, 'NOTIFY')
      -- Only seed a status for zones that are NOT in the default
      -- closed-and-not-bypassed state. A freshly-added zone starts closed, so
      -- sending that explicitly for every zone is a third Director round trip
      -- per zone that says nothing new -- the dominant cost on a large panel.
      -- Anything genuinely open or bypassed is still stated, and every real
      -- change pushes ZONE_STATE regardless.
      if (not quiet) and st and (st.open or st.bypassed) then
        C4:SendToProxy(binding, 'ZONE_STATE', {
          ZONE_ID = tostring(zoneNum),
          ZONE_OPEN = tostring(st.open),
          ZONE_BYPASSED = tostring(st.bypassed),
        }, 'NOTIFY')
      end
    end
  end
end

--[[---------------------------------------------------------------------------
    Zone status (parameter 2149) -- confirmed bit layout (v21).

    This was logged raw and left undecoded for weeks. The layout below is
    confirmed against an independent, physically-validated Home Assistant
    PIMA Force integration (github.com/amithalp/pima-force-ha-integration,
    validated against real hardware on Force JSON Interface 2.3, documented
    from PIMA's own Force Interface JSON Format Specification) and checked
    against a real raw capture from this installation -- decoding that
    capture with the formula below reproduces exactly the zone numbers seen,
    which a pure coincidence could not do.

    2149 is NOT one value per requested zone, which is the wrong model this
    driver used through v20. It is a SPARSE list: the panel returns one entry
    only for a zone that currently has at least one non-default status bit
    set (open, armed, bypassed, alarmed, a wireless fault, and so on). A zone
    with nothing to report is simply absent from the array, and a panel where
    every zone is closed, disarmed and clean legitimately answers with an
    EMPTY array -- confirmed by the reference integration's own real-panel
    capture fixture. This is also why "[40007]" earlier looked like a
    truncated one-value response: it almost certainly was not truncated at
    all -- it was very likely the complete, correct answer for a moment when
    exactly one zone (zone 7) had a bit set (Armed).

    Each entry is a hex string packing the zone number into the LOW byte and
    a 16-bit status field into the remaining high bits:
        value  = tonumber(entry, 16)
        zone   = value % 0x100            -- low byte
        status = math.floor(value / 0x100)
    Status bit numbers (0-indexed; this driver has no bit32/bitwise-operator
    library available, hence the arithmetic in zoneStatusBit()):
        0 Supervision Loss   8 Auto Bypassed
        1 Low Battery        9 Alarmed
        2 Short (wired)     10 Armed
        3 Cut/Tamper        11 Open
        4 Soak              12 Duress
        5 Chime             13 Fire
        6 Anti-mask         14 Medical
        7 Manual Bypassed   15 Panic
    This driver's proxy model only carries open/bypassed today, so only bits
    7, 8 and 11 drive ZoneState/ZONE_STATE; a handful of the rest are logged
    at WARN so an alarm, tamper, or supervision condition sitting in this
    response is never silently dropped.

    The request omits stop_order, matching the shape confirmed working for
    this specific parameter in the reference integration's real capture --
    unlike zone NAMES (parameter 260), where omitting stop_order was found to
    truncate to one entry, 2149 is a self-contained sparse answer regardless.
-----------------------------------------------------------------------------]]
local ZONE_STATUS_BIT_SUPERVISION    = 0
local ZONE_STATUS_BIT_LOW_BATTERY    = 1
local ZONE_STATUS_BIT_TAMPER         = 3
local ZONE_STATUS_BIT_MANUAL_BYPASS  = 7
local ZONE_STATUS_BIT_AUTO_BYPASS    = 8
local ZONE_STATUS_BIT_ALARMED        = 9
local ZONE_STATUS_BIT_OPEN           = 11

function zoneStatusBit(status, n)
  return math.floor(status / (2 ^ n)) % 2 == 1
end

function SyncZoneStates()
  local pw = firstPartitionCode()
  if not pw then return end
  if next(Zones) == nil then return end
  RequestData(PARAM_ZONE_STATUS, 1, nil, pw, function(frame, err)
    if err then
      LogError('Zone status query failed: ' .. tostring(err))
      return
    end
    if frame and tostring(frame.more or 'no'):lower() == 'yes' then
      LogWarn('Zone status (2149) reported more=yes; only the first page was read. ' ..
        'Pagination for this parameter is not implemented (no real capture has shown ' ..
        'it yet) -- if you see this, report how many zones are open, bypassed, or ' ..
        'faulted at the same moment.')
    end
    ApplyZoneStatusResponse(frame and frame.parameters)
  end)
end

-- Applies one (possibly empty) 2149 response: updates every zone it names,
-- and treats every configured zone it does NOT name as closed/not-bypassed,
-- since an omission from a complete response means nothing to report.
function ApplyZoneStatusResponse(params)
  if type(params) ~= 'table' then params = {} end
  local seen = {}
  for i = 1, #params do
    local raw = JSON.scalar(params[i])
    local value = tonumber(tostring(raw), 16)
    if value then
      local zone = value % 0x100
      local status = math.floor(value / 0x100)
      seen[zone] = true
      if Zones[zone] then
        local isOpen = zoneStatusBit(status, ZONE_STATUS_BIT_OPEN)
        local isBypassed = zoneStatusBit(status, ZONE_STATUS_BIT_MANUAL_BYPASS)
          or zoneStatusBit(status, ZONE_STATUS_BIT_AUTO_BYPASS)
        local st = ZoneStateFor(zone)
        if st.open ~= isOpen or st.bypassed ~= isBypassed then
          NotifyProxyZoneState(zone, isOpen, isBypassed)
        end
        -- Flags this driver does not model on the proxy yet -- surfaced so
        -- they are never silently dropped just because nothing reads them.
        local name = tostring(Zones[zone].name)
        if zoneStatusBit(status, ZONE_STATUS_BIT_ALARMED) then
          LogWarn('Zone ' .. zone .. ' (' .. name .. ') status (2149) reports Alarmed')
        end
        if zoneStatusBit(status, ZONE_STATUS_BIT_TAMPER) then
          LogWarn('Zone ' .. zone .. ' (' .. name .. ') status (2149) reports Cut/Tamper')
        end
        if zoneStatusBit(status, ZONE_STATUS_BIT_SUPERVISION) then
          LogWarn('Zone ' .. zone .. ' (' .. name .. ') status (2149) reports Supervision Loss')
        end
        if zoneStatusBit(status, ZONE_STATUS_BIT_LOW_BATTERY) then
          LogWarn('Zone ' .. zone .. ' (' .. name .. ') status (2149) reports Low Battery')
        end
      else
        Dbg('Zone status (2149) reported zone ' .. zone .. ', which is not in Zones Config; ignoring')
      end
    else
      LogWarn('Zone status (2149): could not parse entry ' .. tostring(raw))
    end
  end

  for zone in pairs(Zones) do
    if not seen[zone] then
      local st = ZoneStateFor(zone)
      if st.open or st.bypassed then
        NotifyProxyZoneState(zone, false, false)
      end
    end
  end
end

--[[---------------------------------------------------------------------------
    Link watchdog.

    OnServerConnectionStatusChanged is the ONLY thing that used to move
    Connection Status off "Connected", and it fires on a clean TCP close. A
    panel that is powered off, unplugged, or cut off by a network change
    leaves the socket half-open: no FIN ever arrives, no callback ever runs,
    and the driver reported "Connected" indefinitely for a panel it could not
    hear. That is not just a cosmetic property -- it is the difference between
    an alarm reaching Control4 and the system quietly not being monitored.

    If nothing at all arrives for Link Timeout Seconds, the link is treated as
    dead by exactly the same path as a real disconnect, so partitions go
    Unknown, queued commands fail loudly, and the widget stops showing a
    confident state for a system we cannot see.

    v21: the default below was 90s through v20, on an assumed "heartbeat
    every few seconds" that was never actually confirmed from a real capture.
    An independent, physically-validated PIMA Force integration
    (github.com/amithalp/pima-force-ha-integration) documents the real
    cadence directly: "the panel normally sends traffic at least once every
    four minutes" (240s), and its own equivalent watchdog uses a 12-minute
    (720s) timeout precisely because of that ~4-minute gap. A 90s default on
    this driver would very likely have been firing false positives against
    a perfectly healthy panel -- every reconnect looking exactly like a real
    outage. The default is now 600s: comfortably past the ~240s real cadence,
    while still well under their 720s ceiling. Anyone who has already set
    their own value in Composer keeps it; this only changes what a fresh
    install starts with.
-----------------------------------------------------------------------------]]
LINK_CHECK_INTERVAL_S = 15
LastInboundAt = nil
LinkWatchdogTimerId = nil

function NoteInboundActivity()
  LastInboundAt = nowMs()
end

function LinkTimeoutMs()
  local secs = tonumber(Properties['Link Timeout Seconds'])
  if secs == nil then secs = 600 end
  if secs <= 0 then return nil end          -- explicitly disabled
  return secs * 1000
end

function StartLinkWatchdog()
  StopLinkWatchdog()
  LinkWatchdogTimerId = C4:AddTimer(LINK_CHECK_INTERVAL_S, 'SECONDS', true)
  if not LinkWatchdogTimerId then
    LogError('Could not create the link watchdog timer; a half-open connection ' ..
      'to the panel will not be detected until the driver is reloaded')
  end
end

function StopLinkWatchdog()
  if LinkWatchdogTimerId then
    pcall(function() C4:KillTimer(LinkWatchdogTimerId) end)
    LinkWatchdogTimerId = nil
  end
end

function CheckLinkAlive()
  if ConnHandle == nil then return end
  local limit = LinkTimeoutMs()
  if not limit then return end
  if not LastInboundAt then
    -- A socket that connected and then said nothing at all is just as dead as
    -- one that went quiet; start the clock at the connection instead of
    -- waiting forever for a first frame that may never come.
    LastInboundAt = nowMs()
    return
  end
  local silent = nowMs() - LastInboundAt
  -- Clock steps backwards (NTP) would otherwise make this fire immediately or
  -- never; treat a negative interval as "just heard from it".
  if silent < 0 then
    LastInboundAt = nowMs()
    return
  end
  if silent < limit then return end
  LogError('No data from the panel for ' .. math.floor(silent / 1000) .. 's (limit ' ..
    math.floor(limit / 1000) .. 's). Treating the link as down: the socket is still ' ..
    'open but the panel is not answering. Check panel power, the network path, and ' ..
    'that the panel still has this driver as its CMS destination.')
  local dead = ConnHandle
  LastInboundAt = nil
  -- Reuse the real disconnect path rather than duplicating its teardown, so
  -- there is exactly one definition of what "the panel is gone" does.
  OnServerConnectionStatusChanged(dead, tonumber(Properties['Listen Port']) or 0, 'OFFLINE')
end

--[[---------------------------------------------------------------------------
    The functions offered in the app's Functions menu.

    MUST MATCH the <functions> capability in gen_driver_xml.py -- the app
    renders that list, this carries it out, and a name in one and not the
    other is a menu item that does nothing. test_regressions.lua parses the
    generated driver.xml and fails if the two drift apart.

    Every entry here is something the driver can genuinely do against a PIMA
    panel. Deliberately absent: "Utility Key" and "Clear Troubles", which
    other panels' drivers offer but PIMA's JSON interface has no documented
    command for -- "Refresh Troubles" re-reads them instead, which is real
    and honestly named.
-----------------------------------------------------------------------------]]
PARTITION_FUNCTIONS = { 'Check Status', 'Arm All', 'Disarm All',
                        'Bypass Open Zones', 'Clear All Bypasses', 'Refresh Troubles',
                        'Disable Event Notifications', 'Enable Event Notifications' }


--[[---------------------------------------------------------------------------
    Fault decoding (parameter 2250) -- Appendix E of PIMA's own spec (v27).

    Each fault is a hex number: the LOW byte is the fault ID, the byte above
    it is an order (which expander, keypad, siren, zone, ... ) where one is
    relevant. Until now the driver reported the raw array, so a real trouble
    read "Faults: [\"1\",\"6\",\"309\"]" instead of "AC Loss, PSTN Fault -
    DC, Zone Expander Fault #3".

    For the communication fault IDs (30-38) the description already names the
    path (PSTN/GPRS/GSM/network), so the order byte there is not a device
    number and is not appended.
-----------------------------------------------------------------------------]]
local FAULT_DESCRIPTIONS = {
  [1] = 'AC Loss',
  [2] = 'Low Battery',
  [3] = 'Panel Tamper 1 Open',
  [4] = 'Panel Tamper 2 Open',
  [5] = 'Panel Auxiliary Voltage Fault',
  [6] = 'PSTN Fault - DC',
  [7] = 'PSTN Fault - Dial Tone',
  [8] = 'Panel Low DC Fault',
  [9] = 'Zone Expander Fault',
  [10] = 'Zone Expander Tamper Open',
  [11] = 'Zone Expander Voltage Fault',
  [12] = 'Zone Expander AC Fault',
  [13] = 'Zone Expander Low Battery',
  [14] = 'Zone Expander Auxiliary Voltage Fault',
  [15] = 'Local Expander Fault',
  [16] = 'Local Expander Voltage Fault',
  [17] = 'Local Expander Auxiliary Voltage Fault',
  [18] = 'Output Expander Fault',
  [19] = 'Output Expander Tamper Open',
  [20] = 'Output Expander Voltage Fault',
  [21] = 'Output Expander AC Fault',
  [22] = 'Output Expander Low Battery',
  [23] = 'Output Expander Auxiliary Voltage Fault',
  [24] = 'Keypad Fault',
  [25] = 'Keypad Tamper Open',
  [26] = 'Keypad Voltage Fault',
  [27] = 'Wireless Receiver Fault',
  [28] = 'Wireless Receiver Tamper Open',
  [29] = 'Wireless Receiver Voltage Fault',
  [30] = 'Station PSTN Comm Fault',
  [31] = 'Station GPRS Fault',
  [32] = 'Station GSM Voice Comm Fault',
  [33] = 'Station Network Comm Fault',
  [34] = 'Reserved Fault 34',
  [35] = 'Contact PSTN Comm Fault',
  [36] = 'Contact GSM Voice Comm Fault',
  [37] = 'Reserved Fault 37',
  [38] = 'Contact SMS Comm Fault',
  [39] = 'GSM Transmitter Fault',
  [40] = 'GSM Link1 Fault',
  [41] = 'GSM Link2 Fault',
  [42] = 'GSM SIM1 Fault',
  [43] = 'GSM SIM2 Fault',
  [44] = 'GSM Boot1 Fault',
  [45] = 'GSM Boot2 Fault',
  [46] = 'GSM Registration1 Fault',
  [47] = 'GSM Registration2 Fault',
  [48] = 'GPRS Registration1 Fault',
  [49] = 'GPRS Registration2 Fault',
  [50] = 'GSM NO SIM 1 Fault',
  [51] = 'GSM NO SIM 2 Fault',
  [52] = 'GSM SIM PINCODE 1 Fault',
  [53] = 'GSM SIM PINCODE 2 Fault',
  [54] = 'GSM SIM LOCK 1 Fault',
  [55] = 'GSM SIM LOCK 2 Fault',
  [56] = 'GSM Module Fault',
  [57] = 'Network Fault',
  [58] = 'Network Invalid MAC Fault',
  [59] = 'Wireless Receiver Jamming Fault',
  [60] = 'Zone Tamper Fault',
  [61] = 'Anti Mask Alarm Fault',
  [62] = 'Wireless Zone Loss Fault',
  [63] = 'Wireless Zone Fire Loss Fault',
  [64] = 'Wireless Zone Low Bat Fault',
  [65] = 'Wireless Zone AntiMask Fault',
  [66] = 'Invalid Code Alarm',
  [67] = 'External Siren Fault',
  [68] = 'Internal Siren Fault',
  [69] = 'Time Not Set Fault',
  [70] = 'Wireless Zone End Of Life Fault',
  [71] = 'Wireless Zone Low Sensitivity Fault',
  [72] = 'Wireless Zone CleanMe Fault',
  [73] = 'Wireless Zone Power Fault',
  [74] = 'Wireless Zone AC Fault',
  [75] = 'Wireless Zone Trouble Fault',
  [76] = 'Wireless Portable Unit Low Bat Fault',
  [77] = 'Wireless Siren Loss Fault',
  [78] = 'Wireless Siren Low Bat Fault',
  [79] = 'Wireless Siren Tamper Fault',
  [80] = 'Wireless Repeater Loss Fault',
  [81] = 'Wireless Repeater Low Bat Fault',
  [82] = 'Wireless Repeater Tamper Fault',
  [83] = 'Wireless Repeater Jamming Fault',
  [84] = 'Wireless Repeater AC Fault',
  [85] = 'Wireless GAS1 Fault',
  [86] = 'Wireless GAS2 Fault',
  [87] = 'Wireless GAS3 Fault',
  [88] = 'Wireless GAS4 Fault',
  [89] = 'Zone Expander Genuine Fault',
  [90] = 'Wireless Receiver Genuine Fault',
  [91] = 'Output Expander Genuine Fault',
  [92] = 'Keypad Genuine Fault',
  [93] = 'Local Expander Genuine Fault',
  [94] = 'Reserved Fault 94',
  [95] = 'Wireless Arming Station Loss Fault',
  [96] = 'Wireless Arming Station Low Bat Fault',
  [97] = 'Wireless Arming Station Tamper Fault',
  [98] = 'Wireless Arming Station Not Enrolled Fault',
}

-- Fault IDs where the high byte is not a device number worth showing.
local FAULT_ORDER_IN_DESCRIPTION = {}
for id = 30, 38 do FAULT_ORDER_IN_DESCRIPTION[id] = true end

function DecodeFault(raw)
  local value = tonumber(tostring(raw), 16)
  if not value then return 'unrecognised fault value "' .. tostring(raw) .. '"' end
  local faultId = value % 0x100
  local order = math.floor(value / 0x100) % 0x100
  local description = FAULT_DESCRIPTIONS[faultId] or ('Unknown Fault ' .. faultId)
  if order > 0 and not FAULT_ORDER_IN_DESCRIPTION[faultId] then
    return description .. ' #' .. order
  end
  return description
end

-- Renders a whole 2250 parameters array as readable text.
function DecodeFaults(params)
  if type(params) ~= 'table' or #params == 0 then return 'none' end
  local out = {}
  for i = 1, #params do
    out[#out + 1] = DecodeFault(JSON.scalar(params[i]))
  end
  return table.concat(out, ', ')
end

function ExecutePartitionFunction(partitionId, name)
  local fn = trim(tostring(name or '')):lower()

  if fn == 'check status' then
    LogInfo('Functions menu: Check Status -- re-reading partition and zone state')
    SyncPartitionStates(false)
    SyncZoneStates()
    SetProp('Last Command Result', 'Check Status: re-read partition and zone state from the panel')
    return
  end

  --[[-------------------------------------------------------------------------
      "All" uses the panel's own all-partitions target (v27).

      PIMA's spec is explicit that the partition field takes "1,2,..16 --
      specific partition" or "0 -- all the partitions", and its own worked
      examples for "Arming Away all" and "Disarming all" both send
      partition:0. That is one frame the panel applies atomically, rather
      than N frames this driver sequences itself.

      Arm All still respects Partitions Config: if any configured partition
      is not allowed to arm Away, the broadcast would arm it anyway, so in
      that case it falls back to arming the allowed partitions individually
      and says which ones it skipped. Refusing to let the app override the
      installer's own restriction matters more here than saving frames.
  ---------------------------------------------------------------------------]]
  if fn == 'arm all' then
    local refused = {}
    for pid in pairs(Partitions) do
      if not ArmModeAllowed(pid, 'away') then refused[#refused + 1] = tostring(pid) end
    end
    if #refused == 0 then
      ArmAllPartitions()
      LogInfo('Functions menu: Arm All -- one Away operation for all partitions')
      SetProp('Last Command Result', 'Arm All: sent Away to all partitions')
      return
    end
    table.sort(refused)
    local armed = 0
    for pid in pairs(Partitions) do
      if ArmModeAllowed(pid, 'away') then
        ArmPartition(pid, 'away')
        armed = armed + 1
      end
    end
    local msg = 'Arm All: sent Away to ' .. armed .. ' partition(s); partition(s) ' ..
      table.concat(refused, ',') .. ' do not allow Away in Partitions Config and were skipped'
    LogWarn(msg)
    SetProp('Last Command Result', msg)
    return
  end

  if fn == 'disarm all' then
    DisarmAllPartitions()
    LogInfo('Functions menu: Disarm All -- one disarm operation for all partitions')
    SetProp('Last Command Result', 'Disarm All: sent to all partitions')
    return
  end

  if fn == 'refresh troubles' then
    local pw = firstPartitionCode()
    if not pw then
      LogWarn('Refresh Troubles: no partition user code configured to authorise the read')
      return
    end
    RequestData(PARAM_FAULTS, 1, nil, pw, function(frame, err)
      if err then
        LogError('Refresh Troubles failed: ' .. tostring(err))
        SetProp('Last Command Result', 'Refresh Troubles FAILED: ' .. tostring(err))
        return
      end
      local faults = frame and frame.parameters or {}
      local decoded = DecodeFaults(faults)
      LogInfo('Refresh Troubles: panel reports ' .. #faults .. ' active fault(s): ' .. decoded)
      SetProp('Last Command Result', 'Troubles (' .. #faults .. '): ' .. decoded)
    end)
    return
  end

  --[[-------------------------------------------------------------------------
      Bypass from the app (v28).

      Control4's native security UI has no per-zone bypass control -- its own
      user guide describes the Zones screen as somewhere to "view the status
      of each security zone", and selecting a zone does something only when
      that zone maps to a controllable Control4 device such as a gate. So
      tapping a zone to bypass it was never going to work, whatever this
      driver publishes in can_bypass.

      The Functions menu, though, is a surface the app definitely renders and
      that this driver defines. "Bypass Open Zones" is the workflow that
      actually matters -- a door or window that will not close, bypassed so
      the system can arm -- and "Clear All Bypasses" undoes it in one action.

      Both respect Non-Bypassable Zones, both go through the v26 read-back
      verification, and a bypass still gets the auto-clear safety timer.
  ---------------------------------------------------------------------------]]
  if fn == 'bypass open zones' then
    local done, skipped = {}, {}
    for _, z in ipairs(SortedZoneNumbers()) do
      local zcfg = Zones[z]
      local st = ZoneState[z]
      -- Only this partition's zones when the menu was opened on a partition.
      local inScope = (partitionId == nil) or (ZonePartition(z, nil) == partitionId)
      if inScope and st and st.open and not st.bypassed then
        if IsZoneBypassable(z, zcfg and zcfg.type) then
          SetZoneBypass(z, true)
          done[#done + 1] = z .. ' (' .. tostring(zcfg and zcfg.name) .. ')'
        else
          skipped[#skipped + 1] = z .. ' (' .. tostring(zcfg and zcfg.name) .. ')'
        end
      end
    end
    local msg
    if #done == 0 and #skipped == 0 then
      msg = 'Bypass Open Zones: no open zones to bypass'
    else
      msg = 'Bypass Open Zones: requested for ' .. #done .. ' zone(s)'
      if #done > 0 then msg = msg .. ': ' .. table.concat(done, ', ') end
      if #skipped > 0 then
        msg = msg .. '; not bypassable and left armed: ' .. table.concat(skipped, ', ')
      end
    end
    LogInfo(msg)
    SetProp('Last Command Result', msg)
    return
  end

  if fn == 'clear all bypasses' then
    local cleared = {}
    for _, z in ipairs(SortedZoneNumbers()) do
      local st = ZoneState[z]
      local inScope = (partitionId == nil) or (ZonePartition(z, nil) == partitionId)
      if inScope and st and st.bypassed then
        SetZoneBypass(z, false)
        cleared[#cleared + 1] = z .. ' (' .. tostring(Zones[z] and Zones[z].name) .. ')'
      end
    end
    local msg = (#cleared == 0)
      and 'Clear All Bypasses: no zones were bypassed'
      or ('Clear All Bypasses: requested for ' .. #cleared .. ' zone(s): ' ..
          table.concat(cleared, ', '))
    LogInfo(msg)
    SetProp('Last Command Result', msg)
    return
  end

  if fn == 'disable event notifications' then
    SetEventsEnabled(false, 'Functions menu')
    return
  end

  if fn == 'enable event notifications' then
    SetEventsEnabled(true, 'Functions menu')
    return
  end

  LogWarn('Functions menu: "' .. tostring(name) .. '" is not a function this driver ' ..
    'implements. Implemented: ' .. table.concat(PARTITION_FUNCTIONS, ', ') ..
    '. If the app is offering something else, the <functions> capability in ' ..
    'driver.xml and this list have drifted apart.')
end


--[[=============================================================================
    Alert routing: two events instead of forty-four (v30).

    Wiring push notifications through Composer means one programming script
    per event you care about. With 44 events that is absurd, and it is the
    driver's fault for offering no coarser hook.

    So every alarm-class condition also fires `Any Alarm`, and every
    trouble-class condition also fires `Any Trouble`. The specific events
    still fire exactly as before -- nothing existing breaks, and anyone who
    wants per-condition scripts can still have them. But a complete
    notification setup is now two scripts:

        WHEN  Any Alarm    ->  Push Notification "Security alarm"
        WHEN  Any Trouble  ->  Push Notification "Panel trouble"

    Alongside each, the driver sets ALERT_TEXT / ALERT_TYPE variables
    describing what actually happened. If the Push Notification agent can
    interpolate a variable into its message text, one script gives fully
    specific alerts; if it cannot, the detail is still one glance away in the
    app and usable in programming conditions.
===============================================================================]]

-- Runtime variables. Added here rather than declared in driver.xml because
-- AddVariable at runtime needs no static metadata change, which means no
-- Director restart to pick them up.
DriverVariablesReady = false

DriverVariableNames = {}

function DeclareDriverVariables()
  if DriverVariablesReady then return end
  DriverVariableNames = {}
  local failed = {}
  local function add(name, value, vtype)
    DriverVariableNames[#DriverVariableNames + 1] = name
    value = VariableValueString(value)
    local ok, err = pcall(function() C4:AddVariable(name, value, vtype) end)
    if not ok then
      failed[#failed + 1] = name .. ' (' .. tostring(err) .. ')'
    end
  end
  add('ALERT_TEXT', '', 'STRING')
  add('ALERT_TYPE', '', 'STRING')
  -- Deliberately NOT named TROUBLE_TYPE / TROUBLE_TEXT: the security panel
  -- proxy already declares its own TROUBLE_TYPE, and v32 added driver
  -- variables with the same names on top of it, so Composer showed two
  -- entries called Force::TROUBLE_TYPE with no way to tell which was which.
  -- These carry the same idea under names that cannot collide: ALERT_* is
  -- "the last thing that happened", LAST_TROUBLE_* is "the last trouble",
  -- which survives a later alarm.
  add('LAST_TROUBLE_TEXT', '', 'STRING')
  add('LAST_TROUBLE_TYPE', '', 'STRING')
  add('PANEL_CONNECTED', false, 'BOOL')
  add('EVENTS_ENABLED', true, 'BOOL')
  -- Only for partitions that are actually configured. Declaring all
  -- MAX_DECLARED_PARTITIONS meant a one-partition house paid four extra
  -- AddVariable round trips at every load to create variables describing
  -- partitions that do not exist -- and offered them in Composer's
  -- programming picker as though they did.
  for pid = 1, MAX_DECLARED_PARTITIONS do
    if Partitions[pid] then
      add('PARTITION_' .. pid .. '_STATE', 'Unknown', 'STRING')
      add('PARTITION_' .. pid .. '_ARMED', false, 'BOOL')
    end
  end
  -- Loudly, on purpose. v30 wrapped this in a pcall that logged only at
  -- Debug level, so if variable creation failed the only symptom was
  -- notification text resolving empty, with nothing in the log to explain
  -- it. A driver that cannot publish its variables must say so.
  if #failed > 0 then
    LogError('Could not create ' .. #failed .. ' driver variable(s): ' ..
      table.concat(failed, ', ') .. '. Notification text referencing them will ' ..
      'resolve EMPTY. Run the "Report Variables" action for the current state.')
  else
    LogInfo('Driver variables published: ' .. table.concat(DriverVariableNames, ', '))
  end
  DriverVariablesReady = true
end

-- Reads every variable back from Director and logs it. The point is to make
-- "the notification came through empty" answerable from one log line instead
-- of guesswork: either the variables exist and hold values, or they do not.
function ReportDriverVariables()
  if #DriverVariableNames == 0 then
    LogError('No driver variables have been declared at all -- DeclareDriverVariables ' ..
      'never ran, or every AddVariable call failed.')
    SetProp('Last Command Result', 'No driver variables declared')
    return
  end
  local lines, missing = {}, 0
  for _, name in ipairs(DriverVariableNames) do
    local ok, value = pcall(function() return C4:GetVariable(name) end)
    if not ok then
      lines[#lines + 1] = name .. '=<READ FAILED>'
      missing = missing + 1
    elseif value == nil then
      lines[#lines + 1] = name .. '=<nil: variable does not exist>'
      missing = missing + 1
    else
      lines[#lines + 1] = name .. '=' .. tostring(value)
    end
  end
  local summary = table.concat(lines, ', ')
  if missing > 0 then
    LogError('Driver variables: ' .. missing .. ' of ' .. #DriverVariableNames ..
      ' unreadable. ' .. summary)
  else
    LogInfo('Driver variables: ' .. summary)
  end
  SetProp('Last Command Result', 'Variables: ' .. summary)
end

-- Failures are reported once per variable rather than on every write, so a
-- broken variable is visible without flooding the log.
VariableWriteFailed = {}

--[[---------------------------------------------------------------------------
    Director's variable API takes STRINGS, and only strings. Passing a Lua
    boolean throws "strValue should be a string".

    v30 introduced PANEL_CONNECTED, EVENTS_ENABLED and PARTITION_n_ARMED as
    BOOL variables and set them with real Lua booleans. Every one of those
    writes has been failing since -- so those three have never held a value,
    and any notification text or programming condition referencing them has
    been reading an empty variable for nine versions. The pcall around the
    write meant it never took the driver down, and until v32 made variable
    failures loud there was nothing in the log to say so either.

    Booleans render as "true"/"false" to match how a BOOL variable reads in
    Composer. The regression mock now rejects a non-string exactly as
    Director does, so this class of bug cannot ship again from any call site.
-----------------------------------------------------------------------------]]
function VariableValueString(value)
  if type(value) == 'boolean' then return value and 'true' or 'false' end
  return tostring(value)
end

function SetDriverVariable(name, value)
  value = VariableValueString(value)
  local ok, err = pcall(function() C4:SetVariable(name, value) end)
  if ok then
    VariableWriteFailed[name] = nil
    return
  end
  if not VariableWriteFailed[name] then
    VariableWriteFailed[name] = true
    LogError('Cannot set variable ' .. name .. ': ' .. tostring(err) ..
      '. Anything in a notification referencing it will be EMPTY.')
  end
end

-- Fired for anything a person would want to be told about immediately.
-- `kind` is a short category ("Fire", "Burglary", ...), `text` a readable
-- description including the zone or partition where one is known.
function FireAlert(kind, text)
  kind, text = NonEmptyAlert(kind, text, 'Alarm')
  SetDriverVariable('ALERT_TYPE', kind)
  SetDriverVariable('ALERT_TEXT', text)
  FireDriverEvent('Any Alarm')
end

-- Fired for system health: power, battery, comms, tamper restore and so on.
function FireTrouble(kind, text)
  kind, text = NonEmptyAlert(kind, text, 'Trouble')
  SetDriverVariable('ALERT_TYPE', kind)
  SetDriverVariable('ALERT_TEXT', text)
  SetDriverVariable('LAST_TROUBLE_TYPE', kind)
  SetDriverVariable('LAST_TROUBLE_TEXT', text)
  FireDriverEvent('Any Trouble')
end

-- A notification that says nothing is worse than no notification: it tells
-- you something happened and denies you what. Never let these go out blank.
function NonEmptyAlert(kind, text, fallback)
  kind = trim(tostring(kind or ''))
  text = trim(tostring(text or ''))
  if kind == '' then kind = fallback end
  if text == '' then text = kind end
  return kind, text
end


--[[=============================================================================
    Muting programming events (v31).

    A panel that malfunctions can machine-gun events -- a flapping detector, a
    trouble that will not clear -- and with notifications wired to Any Alarm /
    Any Trouble that becomes a phone buzzing all night. "Disable Event
    Notifications" in the app's Functions menu stops the driver firing
    programming events until it is re-enabled.

    Deliberate scope: this gates C4:FireEvent ONLY. Live state still flows --
    the shield still shows ARMED or ALARM, zones still update, properties and
    the app's own History are untouched. What stops is programming triggers,
    which is what feeds notifications. Muting the display of a live alarm
    would be a far worse idea than muting the notification about it.

    Because a mute that is forgotten is its own hazard on a security system,
    two things guard it:

      * it auto-re-enables after Event Mute Minutes (default 60), the same
        reasoning as the bypass auto-clear; and
      * while muted the driver raises a panel TROUBLE, so the app shows a
        standing trouble rather than the mute being invisible.
===============================================================================]]
EventsEnabled = true
EventMuteTimerId = nil

function EventMuteMinutes()
  local m = tonumber(Properties['Event Mute Minutes'])
  if m == nil then m = 60 end
  return m
end

function CancelEventMuteTimer()
  if EventMuteTimerId then
    pcall(function() C4:KillTimer(EventMuteTimerId) end)
    EventMuteTimerId = nil
  end
end

-- Every programming event in this driver goes through here. Gating one
-- function is why the mute cannot miss a path, and why a new event added
-- later is muted automatically without anyone remembering to wire it up.
function FireDriverEvent(name)
  if not EventsEnabled then
    Dbg('Event "' .. tostring(name) .. '" suppressed: event notifications are disabled')
    return
  end
  C4:FireEvent(name)
end

function SetEventsEnabled(enabled, reason)
  enabled = not not enabled
  local changed = (enabled ~= EventsEnabled)
  EventsEnabled = enabled
  CancelEventMuteTimer()
  SetDriverVariable('EVENTS_ENABLED', enabled)

  -- The mute is shown on the partition status line (see DISPLAY_TEXT), not
  -- as a panel trouble. Both states publish it, so the line can never
  -- disagree with EventsEnabled.
  PublishPartitionDisplayText()

  if enabled then
    SetProp('Event Notifications', 'Enabled')
    -- v31-v36 indicated the mute by raising a standing trouble. That is gone,
    -- but the clear is still sent: a driver updated from one of those
    -- versions while muted would otherwise leave a phantom "Event
    -- notifications disabled" trouble in the app with nothing left to clear
    -- it. Harmless once no such trouble exists.
    NotifyProxyTrouble('Event notifications disabled', false)
    if changed then
      LogInfo('Event notifications ENABLED' .. (reason and (' (' .. reason .. ')') or '') ..
        ' -- programming events and notifications resume')
    end
    SetProp('Last Command Result', 'Event notifications enabled')
    return
  end

  local minutes = EventMuteMinutes()
  local until_text = 'until re-enabled'
  if minutes > 0 then
    EventMuteTimerId = C4:AddTimer(minutes, 'MINUTES')
    if EventMuteTimerId then
      until_text = 'for ' .. minutes .. ' minutes'
    else
      LogWarn('Could not schedule the event-mute auto-enable timer; notifications ' ..
        'will stay disabled until re-enabled by hand')
    end
  end

  SetProp('Event Notifications', 'DISABLED (' .. until_text .. ')')
  -- Loud on purpose: this is the driver being told to stay quiet about a
  -- security system, and it should be obvious in the log that it did.
  LogWarn('Event notifications DISABLED ' .. until_text ..
    ' -- alarms and troubles will NOT fire programming events or push ' ..
    'notifications. Live status in the app is unaffected.')
  SetProp('Last Command Result', 'Event notifications DISABLED ' .. until_text)
end

function ReceivedFromProxy(idBinding, sCommand, tParams)
  tParams = tParams or {}
  -- Logged at INFO, not debug. What Navigator asks the proxy for, and when, is
  -- the most useful thing available when the app disagrees with the driver's
  -- own state, and it cannot be read off anywhere else.
  local rendered = {}
  for k, v in pairs(tParams) do rendered[#rendered + 1] = tostring(k) .. '=' .. tostring(v) end
  table.sort(rendered)
  Dbg('ReceivedFromProxy: binding ' .. tostring(idBinding) .. ' ' .. tostring(sCommand) ..
    (#rendered > 0 and (' {' .. table.concat(rendered, ' ') .. '}') or ''))
  local partitionId = PartitionForBinding(idBinding)
  local part = partitionId and Partitions[partitionId]

  -- Panel-proxy queries. Director asks for these on bind/refresh; leaving
  -- them unanswered is why the widget's zone and partition lists stay empty.
  if sCommand == 'GET_PANEL_SETUP' or sCommand == 'GET_ALL_PARTITION_INFO'
      or sCommand == 'GET_ALL_ZONE_INFO' or sCommand == 'SYNC_PANEL_INFO' then
    -- Forced: Director is explicitly asking, so "nothing changed since we
    -- last published" is not a reason to stay silent. Leaving this deduped
    -- would answer a refresh with nothing at all.
    SendPanelInfo(true)
    -- Same reasoning for the status line: a rebound proxy has no text, so
    -- drop the "already sent" memory and restate it.
    DisplayTextSent = {}
    PublishPartitionDisplayText()
    return
  end

  -- Navigator pushes zone identity back at the panel proxy when the security
  -- agent is set up, and again if someone renames a zone in the app. The
  -- reference driver implements this as an accepted no-op; unhandled, it was
  -- logging a warning on every refresh. We go one better and keep a rename:
  -- the app is a perfectly reasonable place to fix a zone name, and Zones
  -- Config is where that has to land to survive a reload.
  if sCommand == 'SET_ZONE_INFO' then
    local zone = tonumber(tParams.ZONE_ID or tParams.ZoneID or tParams.ID)
    local newName = tParams.NAME or tParams.Name
    if zone and Zones[zone] and type(newName) == 'string' and newName ~= '' and
        newName ~= Zones[zone].name then
      LogInfo('Zone ' .. zone .. ' renamed from the app: "' .. tostring(Zones[zone].name) ..
        '" -> "' .. newName .. '"')
      Zones[zone].name = newName
      SetProp('Zones Config', SerializeZones())
      SendPanelInfo(true)
    else
      Dbg('SET_ZONE_INFO for zone ' .. tostring(zone) .. ': nothing to change')
    end
    return
  end

  --[[-------------------------------------------------------------------------
      The app's Functions menu (v25).

      The menu itself is the `<functions>` capability in driver.xml -- a
      comma-separated list. Capabilities are STATIC: the DriverWorks API has
      GetCapability but no setter, so this list cannot be chosen per
      installation from a Composer property. It is fixed at build time, and
      only functions this driver can actually carry out on a PIMA panel are
      declared, so nothing in that menu is a button that does nothing.

      Tapping one sends EXECUTE_FUNCTION. The official protocol reference is
      truncated where the parameters would be documented, so rather than
      assume a name this accepts every plausible one and logs the whole
      parameter set at Info the first time -- one tap and the log shows the
      real shape.
  ---------------------------------------------------------------------------]]
  if sCommand == 'EXECUTE_FUNCTION' then
    local fn = tParams.FUNCTION or tParams.Function or tParams.NAME or
               tParams.Name or tParams.FUNCTION_NAME or tParams.VALUE
    LogInfo('Functions menu: EXECUTE_FUNCTION on binding ' .. tostring(idBinding) ..
      ' {' .. table.concat(rendered, ' ') .. '}')
    ExecutePartitionFunction(partitionId, fn)
    return
  end

  -- Fire / Medical / Police / Panic. The has_fire/has_medical/has_police/
  -- has_panic capabilities are all false, so the app shows no Emergency menu
  -- for this driver and this should never arrive -- PIMA's JSON protocol has
  -- no documented command to raise an emergency, and a button that silently
  -- does nothing is worse on a security system than no button. Handled
  -- anyway so it is reported rather than swallowed.
  if sCommand == 'EXECUTE_EMERGENCY' then
    LogError('Emergency requested from the app {' .. table.concat(rendered, ' ') ..
      '} but this driver cannot raise an emergency: PIMA\'s JSON interface has no ' ..
      'documented command for it. Nothing was sent to the panel. Use the panel ' ..
      'keypad or a monitored emergency path instead.')
    SetProp('Last Command Result', 'Emergency NOT sent: unsupported by the PIMA JSON interface')
    return
  end

  -- The native keypad's own bypass button.
  if sCommand == 'BYPASS_ZONE' then
    local zone = tonumber(tParams.ZONE_ID or tParams.ZoneID or tParams.ZONE)
    if zone then
      local wantBypass = not (tostring(tParams.BYPASS or tParams.STATE or 'true'):lower() == 'false')
      SetZoneBypass(zone, wantBypass)
    end
    return
  end

  if sCommand == 'GET_CURRENT_STATE' then
    if partitionId then
      -- Re-derive rather than reading a property: a live alarm must survive
      -- a routine state query, not be cancelled by it.
      PublishPartitionState(partitionId)
    end
    return
  end

  if sCommand == 'PARTITION_ARM' then
    if not partitionId or not part then
      LogWarn('ReceivedFromProxy: PARTITION_ARM on binding ' .. tostring(idBinding) ..
        ' does not map to a configured partition; ignoring')
      return
    end
    local mode = ArmModeForType(tParams.ArmType)
    if not mode then
      LogInfo('ReceivedFromProxy: PARTITION_ARM partition ' .. partitionId ..
        ' ArmType=' .. tostring(tParams.ArmType) .. ' is not a recognised arm state; ignoring')
      NotifyProxyArmFailed(partitionId)
      return
    end
    -- Honour the per-partition `modes` field from Partitions Config. A
    -- partition configured Away-only should not be armable in Stay from the
    -- widget just because the driver-wide arm_states list offers it.
    if not ArmModeAllowed(partitionId, mode) then
      LogWarn('ReceivedFromProxy: partition ' .. partitionId .. ' is not configured for ' ..
        tostring(tParams.ArmType) .. ' (Partitions Config modes); refusing')
      NotifyProxyArmFailed(partitionId)
      return
    end
    ArmPartition(partitionId, mode)

  elseif sCommand == 'PARTITION_DISARM' then
    if not partitionId or not part then
      LogWarn('ReceivedFromProxy: PARTITION_DISARM on binding ' .. tostring(idBinding) ..
        ' does not map to a configured partition; ignoring')
      return
    end
    -- FAIL CLOSED. The code the user types on the Navigator keypad is the
    -- ONLY check that exists: DisarmPartition() sends the code stored in
    -- Partitions Config to the panel, not the typed one, so the panel will
    -- always accept it -- there is no second line of defence behind this
    -- branch. An absent or empty code therefore has to be a rejection, not
    -- a pass. (The earlier version only rejected a *wrong* code, so a
    -- PARTITION_DISARM carrying no code at all disarmed the system.)
    if part.userCode ~= '' then
      local presented = tParams.UserCode
      if type(presented) ~= 'string' or presented == '' or presented ~= part.userCode then
        LogError('Native disarm for partition ' .. partitionId .. ' rejected: user code missing or incorrect')
        NotifyProxyDisarmFailed(partitionId, tParams.InterfaceID)
        return
      end
    end
    DisarmPartition(partitionId)

  else
    LogWarn('ReceivedFromProxy: unhandled command ' .. tostring(sCommand) ..
      ' on binding ' .. tostring(idBinding))
  end
end

-- Event suffixes that gen_driver_xml.py actually declares per partition.
-- Firing a name that isn't declared in driver.xml does nothing at all, so a
-- mode we can detect but didn't declare (Home3/Home4/Shabbat) must fall back
-- to the generic "Armed" event -- otherwise "when the alarm is armed ->
-- shut things down" programming silently never runs for those modes.
local DECLARED_PARTITION_EVENTS = {
  ['Armed ' .. ARM_LABEL_AWAY] = true,
  ['Armed ' .. ARM_LABEL_STAY] = true,
  ['Armed ' .. ARM_LABEL_NIGHT] = true,
  ['Armed'] = true, ['Disarmed'] = true,
  ['Alarm'] = true, ['Alarm Restored'] = true,
}

function FirePartitionEvent(partitionId, suffix)
  if partitionId >= 1 and partitionId <= MAX_DECLARED_PARTITIONS then
    if not DECLARED_PARTITION_EVENTS[suffix] then
      SetProp('Last Event Summary', 'Partition ' .. partitionId .. ' ' .. suffix)
      if suffix:match('^Armed') then
        FireDriverEvent('Partition ' .. partitionId .. ' Armed')
      else
        FireDriverEvent('Unmapped Panel Event')
      end
      return
    end
    FireDriverEvent('Partition ' .. partitionId .. ' ' .. suffix)
  else
    SetProp('Last Event Summary', 'Partition ' .. partitionId .. ' ' .. suffix)
    FireDriverEvent('Unmapped Panel Event')
  end
end

-- CID types that are normal panel housekeeping rather than anything to act
-- on. Names from Appendix A of PIMA's Force Interface JSON specification.
ROUTINE_EVENT_NAMES = {
  [305] = 'system power-up',
  [306] = 'programming changed',
  [412] = 'remote upload/download',
  [601] = 'manual test',
  [602] = 'periodic test',
  [625] = 'time/date changed',
}

function DispatchEvent(frame)
  local etype = tonumber(frame.type) or 0
  local qualifier = tonumber(frame.qualifier) or 0
  local zone = tonumber(frame.zone) or 0
  local partition = tonumber(frame.partition) or 0

  SetProp('Last Event Type', tostring(etype))
  SetProp('Last Event Qualifier', tostring(qualifier))
  SetProp('Last Event Zone', tostring(zone))
  SetProp('Last Event Partition', tostring(partition))

  -- Zone open/closed
  if etype == EV_ZONE and zone > 0 then
    local zcfg = Zones[zone]
    local zname = zcfg and zcfg.name or ('Zone ' .. zone)
    local isOpen = (qualifier == QUALIFIER_NEW)
    SetProp('Last Zone Number', tostring(zone))
    SetProp('Last Zone Name', zname)
    SetProp('Last Zone Partition', tostring(partition))
    FireDriverEvent(isOpen and 'Zone Opened' or 'Zone Closed')
    -- Pass nil for bypassed so the zone's tracked bypass state is preserved:
    -- hardcoding false here used to silently clear the bypass flag on the
    -- widget the moment a bypassed zone next opened or closed.
    NotifyProxyZoneState(zone, isOpen, nil, partition)
    return
  end

  -- Arm / disarm (local keypad, remote/CMS, auto, fast, key-switch, home-x/shabbat)
  if etype == EV_MASTER_ARM or etype == EV_LOCAL_ARM or etype == EV_REMOTE_ARM
      or etype == EV_AUTO_ARM or etype == EV_FAST_ARM or etype == EV_KEYSW_ARM
      or etype == EV_HOMEX_ARM then
    local targets = PartitionTargets(partition)
    if #targets == 0 then
      -- No partition named: report it rather than guessing which partitions
      -- it applies to. Acting on a guess here changes security state.
      LogInfo('Arm/disarm event with no usable partition (raw: ' ..
        tostring(frame.partition) .. ') -- not applied to any partition')
      SetProp('Last Event Summary',
        'Arm/disarm event with no partition (type=' .. etype .. ' qualifier=' .. qualifier .. ')')
      FireDriverEvent('Unmapped Panel Event')
      return
    end
    for _, pid in ipairs(targets) do
      if qualifier == QUALIFIER_RESTORE then
        -- Became armed. Learn the specific mode via a follow-up query.
        QueryArmModeAndFire(pid)
      elseif qualifier == QUALIFIER_NEW then
        LogInfo('Partition ' .. pid .. ' disarmed (reported by panel)')
        SetPartitionState(pid, 'Disarmed')
        FirePartitionEvent(pid, 'Disarmed')
      end
    end
    return
  end

  -- Burglary alarm. Panel-wide (partition 0) fans out rather than being
  -- dropped -- an intrusion alarm reported without a partition used to
  -- produce no event and no state change at all.
  if etype == EV_BURGLARY then
    local isNew = (qualifier == QUALIFIER_NEW)
    local targets = PartitionTargets(partition)
    if #targets == 0 then
      -- An intrusion alarm must never vanish silently, but nor should it be
      -- applied to partitions the panel never named. Raise the generic alarm
      -- events so programming still fires, without claiming a partition.
      LogInfo((isNew and 'BURGLARY ALARM' or 'Burglary alarm restored') ..
        ' with no usable partition (raw: ' .. tostring(frame.partition) .. ')')
      SetProp('Last Event Summary',
        (isNew and 'Burglary alarm' or 'Burglary alarm restored') .. ' (no partition reported)')
      FireDriverEvent('Unmapped Panel Event')
      return
    end
    -- Alarms are the events you will most want to find in a log after the
    -- fact, so they are logged unconditionally (not behind a debug flag)
    -- and land in Recent Activity. PartitionTargets never returns a fan-out
    -- for partition 0 (see its comment -- doing so once marked a whole house
    -- disarmed off one event), so anything reaching here names a partition.
    LogInfo((isNew and 'BURGLARY ALARM' or 'Burglary alarm restored') ..
      ' -- partition ' .. tostring(partition) ..
      (zone > 0 and (', zone ' .. zone) or ''))
    for _, pid in ipairs(targets) do
      if isNew then
        SetPartitionAlarm(pid, 'Burglary', true, 'partition')
      else
        ClearPartitionAlarm(pid, 'Burglary')
      end
      FirePartitionEvent(pid, isNew and 'Alarm' or 'Alarm Restored')
    end
    return
  end

  -- Life-safety / duress / panic. These also drive the native proxy: the
  -- programming events alone leave the shield widget showing "Armed"/
  -- "Disarmed" during a fire or panic alarm with no indication at all.
  local emergency = nil
  if etype == EV_FIRE or etype == EV_FIRE_PULL then emergency = 'Fire'
  elseif etype == EV_MEDICAL then emergency = 'Medical'
  elseif etype == EV_PANIC_KP or etype == EV_PANIC_SIL then emergency = 'Panic'
  elseif etype == EV_DURESS then emergency = 'Police'
  end

  if emergency then
    local names = {
      Fire = { 'Fire Alarm', 'Fire Alarm Restored' },
      Medical = { 'Medical Alarm', 'Medical Alarm Restored' },
      Panic = { 'Panic Alarm', 'Panic Alarm Restored' },
      Police = { 'Duress Alarm', 'Duress Alarm Restored' },
    }
    local isNew = (qualifier == QUALIFIER_NEW)
    LogInfo((isNew and (emergency:upper() .. ' ALARM') or (emergency .. ' alarm restored')) ..
      ' -- partition ' .. tostring(partition) .. (zone > 0 and (', zone ' .. zone) or ''))
    FireDriverEvent(isNew and names[emergency][1] or names[emergency][2])
    if isNew then
      local where = (zone > 0) and (Zones[zone] and Zones[zone].name or ('zone ' .. zone))
        or ('partition ' .. tostring(partition))
      FireAlert(emergency, emergency .. ' alarm -- ' .. where)
    end
    NotifyProxyEmergency(partition, emergency, isNew)
    return
  end

  if etype == EV_TAMPER then
    local isNew = (qualifier == QUALIFIER_NEW)
    LogInfo(isNew and 'TAMPER alarm' or 'Tamper restored')
    FireDriverEvent(isNew and 'Tamper Alarm' or 'Tamper Restored')
    if isNew then FireAlert('Tamper', 'Tamper alarm') end
    NotifyProxyTrouble('Tamper', isNew)
    return
  end

  -- System troubles
  if etype == EV_AC_LOSS then
    local isNew = (qualifier == QUALIFIER_NEW)
    LogInfo(isNew and 'Panel AC power lost' or 'Panel AC power restored')
    FireDriverEvent(isNew and 'AC Power Lost' or 'AC Power Restored')
    if isNew then FireTrouble('AC Power', 'Mains power lost') end
    NotifyProxyTrouble('AC power lost', isNew)
    return
  end
  if etype == EV_LOW_BATTERY then
    local isNew = (qualifier == QUALIFIER_NEW)
    LogInfo(isNew and 'Panel low battery' or 'Panel battery restored')
    FireDriverEvent(isNew and 'Low Battery' or 'Low Battery Restored')
    if isNew then FireTrouble('Battery', 'Panel battery low') end
    NotifyProxyTrouble('Low battery', isNew)
    return
  end
  if etype == EV_COMM_TROUBLE then
    local isNew = (qualifier == QUALIFIER_NEW)
    LogInfo(isNew and 'Panel communication trouble' or 'Panel communication restored')
    FireDriverEvent(isNew and 'Communication Trouble' or 'Communication Restored')
    if isNew then FireTrouble('Communication', 'Panel communication trouble') end
    NotifyProxyTrouble('Communication trouble', isNew)
    return
  end

  -- Bypass
  if etype == EV_BYPASS and zone > 0 then
    local zcfg = Zones[zone]
    local bypassed = (qualifier == QUALIFIER_NEW)
    SetProp('Last Zone Number', tostring(zone))
    SetProp('Last Zone Name', zcfg and zcfg.name or ('Zone ' .. zone))
    FireDriverEvent(bypassed and 'Zone Bypassed' or 'Zone Bypass Cleared')
    -- Keep the widget's bypass indicator truthful: without this a bypassed
    -- (i.e. disabled) detector looks like a live one in the UI, and someone
    -- arms believing they have coverage they do not have.
    NotifyProxyZoneState(zone, nil, bypassed, partition)
    return
  end

  -- Output (siren etc.)
  if etype == EV_OUTPUT and zone > 0 then
    SetProp('Last Output Number', tostring(zone))
    FireDriverEvent(qualifier == QUALIFIER_NEW and 'Output Activated' or 'Output Deactivated')
    return
  end

  --[[-------------------------------------------------------------------------
      Routine housekeeping the panel reports on its own schedule.

      These are normal operation, not faults, and firing Unmapped Panel Event
      for them meant the panel's periodic test alone produced a programming
      event -- something that looks exactly like "an event with no actual
      fault behind it" to anyone with a notification wired up. They are
      identified from Appendix A of PIMA's spec, logged so they are still
      visible, and deliberately raise nothing.
  ---------------------------------------------------------------------------]]
  local routine = ROUTINE_EVENT_NAMES[etype]
  if routine then
    LogInfo('Panel ' .. routine .. ' (CID ' .. etype .. ') -- routine, no action taken')
    SetProp('Last Event Summary', routine .. ' (CID ' .. etype .. ')')
    return
  end

  -- Anything else: genuinely unrecognised, and still visible via the
  -- Last Event * properties above.
  SetProp('Last Event Summary', 'type=' .. etype .. ' qualifier=' .. qualifier .. ' zone=' .. zone .. ' partition=' .. partition)
  LogWarn('Unrecognised panel event: type=' .. etype .. ' qualifier=' .. qualifier ..
    ' zone=' .. zone .. ' partition=' .. partition)
  FireDriverEvent('Unmapped Panel Event')
end

--[[=============================================================================
    Discovery helpers (populate the "Discovered Zones" property so the user
    can copy entries into the Zones Config property)
===============================================================================]]

--[[=============================================================================
    Zone-name discovery.

    A DATA-REQ without a `stop_order` returns exactly ONE entry -- the one at
    `start_order`. An earlier version omitted it and relied on a `more` field
    to paginate, so discovery returned a single zone and stopped, whatever the
    panel actually had. Every page now asks for an explicit range, and the
    walk is driven by the panel's own zone count (parameter 2148) rather than
    by a continuation flag whose semantics were guessed at.
===============================================================================]]

-- Zones requested per page. Kept modest because the panel's maximum response
-- size is not documented here, and Hebrew names are multi-byte.
local ZONE_NAME_PAGE = 8
-- Upper bound when the panel will not tell us its zone count.
local MAX_ZONE_NUMBER = 144
-- Give up after this many consecutive empty pages: an unnamed block of zones
-- is normal, an endless run of them means we are past the end.
local MAX_EMPTY_ZONE_PAGES = 3

function DiscoverZoneNames()
  local pw = firstPartitionCode()
  if not pw then
    LogInfo('Discover Zone Names: configure at least one partition user code first')
    return
  end
  -- Ask how many zones exist, so the walk has a real end rather than relying
  -- on the panel to signal one.
  RequestData(PARAM_ZONE_COUNT, 1, 1, pw, function(frame, err)
    local total
    local params = frame and frame.parameters
    if type(params) == 'table' and params[1] ~= nil and not JSON.isNull(params[1]) then
      total = tonumber(JSON.scalar(params[1]))
    end
    if total and total >= 1 and total <= MAX_ZONE_NUMBER then
      LogInfo('Panel reports ' .. total .. ' zones; reading names.')
    else
      LogInfo('Zone count unavailable (' .. tostring(err or (total and ('got ' .. tostring(total)) or 'no data')) ..
        '); scanning up to ' .. MAX_ZONE_NUMBER .. ' zones instead.')
      total = MAX_ZONE_NUMBER
    end
    DiscoverZoneNamesPage(1, total, pw, {}, 0)
  end)
end

function DiscoverZoneNamesPage(startOrder, total, pw, acc, emptyRuns)
  if startOrder > total then
    FinishZoneDiscovery(acc)
    return
  end
  local stopOrder = math.min(startOrder + ZONE_NAME_PAGE - 1, total)
  Dbg('Discovering zone names ' .. startOrder .. '-' .. stopOrder .. ' of ' .. total)

  RequestData(PARAM_ZONE_NAMES, startOrder, stopOrder, pw, function(frame, err)
    if err then
      -- Keep whatever we already collected rather than losing the whole run.
      LogInfo('Discover Zone Names stopped at zone ' .. startOrder .. ': ' .. tostring(err) ..
        ' (keeping the ' .. #acc .. ' zones found so far)')
      FinishZoneDiscovery(acc)
      return
    end
    -- `parameters` is panel-supplied: type-check before iterating, or a
    -- panel answering with a scalar throws right here and (before the
    -- callbacks were wrapped) parked the whole request queue.
    local params = frame and frame.parameters
    if type(params) ~= 'table' then params = {} end
    for i = 1, #params do
      local name = params[i]
      local zoneNum = startOrder + i - 1
      -- JSON.isNull marks a zone slot the panel returned as null. It still
      -- occupies its index (that index IS the zone number), it just has no
      -- name -- skip naming it without shifting everything after it.
      if not JSON.isNull(name) and JSON.scalar(name) ~= '' then
        local decoded = DecodePanelText(JSON.scalar(name))
        -- Guard the "zone,name,type,partition;..." format against a name
        -- that happens to contain our own delimiters.
        decoded = decoded:gsub('[,;]', ' ')
        -- Default the partition field to 1 rather than leaving it empty:
        -- these lines are meant to be pasted straight into Zones Config, and
        -- a zone with no partition never shows up in any partition's zone
        -- list on the native widget. Edit it if the zone lives elsewhere.
        acc[#acc+1] = zoneNum .. ',' .. decoded .. ',contact,1'
      end
    end
    -- Advance by however many entries the panel actually returned. If it
    -- returned none, step over the whole requested range so an unnamed block
    -- of zones does not stall the walk -- but stop after a few consecutive
    -- empty pages, which means we are past the end.
    local advance = #params
    local nextEmptyRuns = 0
    if advance == 0 then
      advance = (stopOrder - startOrder) + 1
      nextEmptyRuns = (emptyRuns or 0) + 1
      if nextEmptyRuns >= MAX_EMPTY_ZONE_PAGES then
        Dbg('No names in the last ' .. nextEmptyRuns .. ' pages; ending discovery at zone ' .. stopOrder)
        FinishZoneDiscovery(acc)
        return
      end
    end

    DiscoverZoneNamesPage(startOrder + advance, total, pw, acc, nextEmptyRuns)
  end)
end

function FinishZoneDiscovery(acc)
  -- Keep the COMPLETE list in memory. The property below is only a
  -- human-readable preview and may be shortened to keep it manageable;
  -- "Apply Discovered Zones" uses this full copy, so a long zone list is
  -- never silently reduced to whatever happened to fit in a property.
  DiscoveredZonesFull = table.concat(acc, ';')
  DiscoveredZonesCount = #acc

  local preview = DiscoveredZonesFull
  if #preview > DISCOVERED_PREVIEW_BYTES then
    -- Cut at an entry boundary, never mid-entry: a hard byte cut can also
    -- split a multi-byte Hebrew character and render as mojibake.
    local cut = preview:sub(1, DISCOVERED_PREVIEW_BYTES)
    local lastSep = cut:match('.*();')
    if lastSep then cut = cut:sub(1, lastSep - 1) end
    local shown = select(2, cut:gsub(';', ';')) + 1
    preview = cut .. ' ... (preview shows ' .. shown .. ' of ' .. #acc ..
      ' zones -- use the "Apply Discovered Zones" action, which applies all ' .. #acc .. ')'
  end
  SetProp('Discovered Zones', preview)
  LogInfo('Discover Zone Names complete: ' .. #acc ..
    ' named zones found. Run the "Apply Discovered Zones" action to write them into Zones Config.')
  SetProp('Last Command Result', 'Discovered ' .. #acc .. ' named zones.')
end

--[[=============================================================================
    Property / command handling
===============================================================================]]

function OnDriverInit()
  ResolveLogLevel()
  -- First line in the log after every load: which build is running. If this
  -- version is not the one you just installed, Composer is still running the
  -- old driver and nothing else in the log means what you think it does.
  LogInfo('PIMA FORCE driver v' .. DRIVER_VERSION .. ' loading')
  Partitions = parsePartitions(Properties['Partitions Config'])
  Zones = parseZones(Properties['Zones Config'])
  RecvBuffer = ''
  ZoneState = {}
  PartitionStatus = {}
  BlockedHandles = {}
  VerifyFailures = 0
  -- Re-report the data-callback layout and any protocol warning after a
  -- driver reload: that one log line is the whole point of a reload when
  -- someone is diagnosing a panel that connects but never verifies.
  ServerDataLayoutLogged = false
  UnparseableWarned = false
  ServerSendForm = nil
  -- A discovery does not survive a driver reload: applying a zone list
  -- captured before a restart could write stale names over a config that has
  -- since been edited. Re-run "Discover Zone Names" after a reload.
  DiscoveredZonesFull = nil
  DiscoveredZonesCount = 0
  -- Commands outstanding from before a reload are not ours to complete: the
  -- frame counter restarts at 5000 on load, so a stale entry would swallow
  -- the reply belonging to a NEW command that happens to reuse its counter.
  PendingOperations = {}
  PendingOperationTimers = {}
  -- Forget what was published: a reload must re-send the inventory once.
  LastInventoryFingerprint = nil
  LastPublishedPartitionState = {}
  PropShadow = {}
  CancelZonePublish()
  InventoryForcedOnce = false
  ResetQueueState()
  StartServer()
  for pid, _ in pairs(Partitions) do
    SetPartitionState(pid, 'Unknown')
  end
end

--[[---------------------------------------------------------------------------
    The properties panel is for CONFIGURATION. Everything the driver reports
    back -- last event, last zone, raw frames, activity buffer -- is data, and
    it does not belong in a grid the installer scrolls through to change a
    port number. Those properties still exist (the driver's Events reference
    them by name in Composer programming, and they are useful when something
    has gone wrong), but they are hidden unless Debug Logging is On.

    C4:SetPropertyAttribs(name, 1) hides; 0 shows. Wrapped in pcall: an older
    Director that does not implement it must not take driver init down with
    it, and a hidden-vs-shown property is cosmetic.
-----------------------------------------------------------------------------]]
DIAGNOSTIC_PROPERTIES = {
  'Last Event Type', 'Last Event Qualifier', 'Last Event Zone',
  'Last Event Partition', 'Last Event Summary', 'Last Zone Number',
  'Last Zone Name', 'Last Zone Partition', 'Last Output Number',
  'Last NAK Reason', 'Last Raw Frame In', 'Recent Activity',
}

function ApplyPropertyVisibility()
  local hide = not DEBUG_ON
  for _, name in ipairs(DIAGNOSTIC_PROPERTIES) do
    pcall(function() C4:SetPropertyAttribs(name, hide and 1 or 0) end)
  end
end

function OnDriverLateInit()
  -- Prefer the version Director actually loaded (from driver.xml); fall back
  -- to the constant compiled into this Lua file. Showing both when they
  -- disagree is deliberate: a mismatch means the .c4z was assembled wrong.
  local ver = nil
  if C4 and C4.GetDriverConfigInfo then
    local ok, v = pcall(function() return C4:GetDriverConfigInfo('version') end)
    if ok and v then ver = tostring(v) end
  end
  local shown = tostring(DRIVER_VERSION)
  if ver and ver ~= '' and ver ~= shown then
    shown = ver .. ' (driver.lua says ' .. DRIVER_VERSION .. ' -- mismatched package)'
  elseif ver and ver ~= '' then
    shown = ver
  end
  SetProp('Driver Version', shown)
  LogInfo('PIMA FORCE driver ready, version ' .. shown)
  RunDriverInit()
end

--[[=============================================================================
    Driver init -- synchronous, and measured.

    History. v13 batched the per-zone publishing onto a timer to fix a ~40s
    Composer freeze. Everything added since went back onto the load callback
    -- 12 AddVariable (v30-v35), 12 SetPropertyAttribs (v15), the partition
    notifications -- and by v35 a 40-zone install froze Composer for ~50
    seconds again. v36 moved the whole block onto a timer; v38 then had to
    patch two races that created (an OFFLINE seed landing after live panel
    state, and a lost timer stranding the driver half-loaded).

    v39 reverses that. Deferring init trades a guaranteed annoyance for a
    rare wrong answer about whether a house is armed, and on a security
    driver that is the wrong side of the trade. Init is synchronous again:
    when OnDriverLateInit returns, the driver is fully loaded, with no window
    in which a panel frame can interleave with a half-built driver.

    The freeze is then a volume problem, and volume is fixed by making fewer
    calls -- not by moving them. Which calls to cut is a measurement, not a
    guess: the "0.4s per Director round trip" this project has been reasoning
    from is one figure divided out of one v13 observation, and it has been
    extrapolated across five versions without being rechecked. So each phase
    is timed and reported at Info on every load:

        init timing: variables 000ms, visibility 000ms, proxies 000ms,
                     zones 000ms, TOTAL 000ms (n calls)

    One driver update now says exactly where the time goes, and the next cut
    can be aimed rather than guessed.
===============================================================================]]
-- Wraps one init phase: runs it, times it, and never lets it take the rest
-- of init down with it. Returns the elapsed milliseconds.
function RunInitPhase(name, fn)
  local started = nil
  if C4 and C4.GetTime then
    local ok, t = pcall(function() return C4:GetTime() end)
    if ok then started = tonumber(t) end
  end
  local ok, err = pcall(fn)
  if not ok then
    -- A phase failing must not strand the ones after it: a driver with no
    -- property visibility is usable, a driver that never enabled its
    -- partition proxies is not.
    LogError('Driver init phase "' .. name .. '" failed: ' .. tostring(err))
  end
  if not started then return 0 end
  local finished = started
  if C4 and C4.GetTime then
    local ok2, t2 = pcall(function() return C4:GetTime() end)
    if ok2 and tonumber(t2) then finished = tonumber(t2) end
  end
  return math.floor(math.max(0, finished - started))
end

function RunDriverInit()
  local t = {}

  t.variables = RunInitPhase('variables', function()
    DeclareDriverVariables()
    -- A mute must not survive a driver reload silently: a reload is exactly
    -- when someone is fixing the panel, and coming back up muted with no one
    -- aware is the failure this guards against.
    SetEventsEnabled(true, 'driver load')
  end)

  t.visibility = RunInitPhase('visibility', function()
    ApplyPropertyVisibility()
  end)

  t.proxies = RunInitPhase('proxies', function()
    -- Proxy bindings are only reliably connected by LateInit, so the initial
    -- PARTITION_ENABLED / PARTITION_STATE_INIT notifications belong here --
    -- sent from OnDriverInit they can be dropped, leaving the partition proxy
    -- never explicitly enabled and its keypad inert.
    NotifyProxyPartitionsInit()
    PublishPartitionDisplayText()
  end)

  -- Zone publishing stays batched onto a timer, as it has been since v13.
  -- That deferral is not the one v38 found races in: a zone inventory
  -- arriving 50ms later cannot mis-state whether the house is armed, and it
  -- is by far the largest block of calls.
  t.zones = RunInitPhase('zones', function()
    SendPanelInfo()
  end)

  local total = t.variables + t.visibility + t.proxies + t.zones
  LogInfo(string.format(
    'init timing: variables %dms, visibility %dms, proxies %dms, zones %dms, ' ..
    'TOTAL %dms. Composer is frozen for this long on every driver update; ' ..
    'if it is slow, this line says which phase to cut.',
    t.variables, t.visibility, t.proxies, t.zones, total))
end

function OnDriverDestroyed()
  StopLinkWatchdog()
  CancelZonePublish()
  CancelEventMuteTimer()
  StopServer()
  ResetQueueState()
  ClearInFlight()
  for timerId, _ in pairs(AutoBypassTimers) do
    pcall(function() C4:KillTimer(timerId) end)
  end
  AutoBypassTimers = {}
  AutoBypassTimerForZone = {}
end

function OnPropertyChanged(strProperty)
  if strProperty == 'Log Level' or strProperty == 'Debug Logging' then
    ResolveLogLevel()
    -- Debug level also reveals the read-only diagnostic properties.
    ApplyPropertyVisibility()
  elseif strProperty == 'Account ID' then
    -- An installer who mistypes the account ID locks the panel's live session
    -- out (too many rejected frames). Correcting the property has to give the
    -- panel another chance without needing it to reconnect -- a CMS session
    -- is long-lived, so otherwise they sit at "Not Connected" indefinitely.
    BlockedHandles = {}
    VerifyFailures = 0
    if not PanelVerified then
      LogInfo('Account ID changed -- allowing the current connection to verify again')
    end
  elseif strProperty == 'Listen Port' then
    -- Tearing down the listener invalidates any accepted socket on it. Without
    -- clearing the session state the driver keeps reporting "Connected" (and
    -- sending to a dead handle) for a connection that no longer exists.
    StopServer()
    if ConnHandle ~= nil then
      ConnHandle = nil
      PanelVerified = false
      RecvBuffer = ''
      FailInFlight('listen port changed')
      SetProp('Connection Status', 'Not Connected')
      NotePanelDisconnected('link down')
      SetProp('Panel Verified Account', '')
      ResetPartitionStatus()
      for pid, _ in pairs(Partitions) do
        SetPartitionState(pid, 'Unknown')
      end
      NotifyProxyAllPartitionsOffline()
    end
    ResetQueueState()
    StartServer()
  elseif strProperty == 'Partitions Config' then
    Partitions = parsePartitions(Properties['Partitions Config'])
    PartitionStatus = {}
    for pid, _ in pairs(Partitions) do
      SetPartitionState(pid, 'Unknown')
    end
    -- Re-seed enable/disable across ALL declared bindings, so a partition
    -- that was just removed from the config is explicitly disabled rather
    -- than left showing its last state forever.
    NotifyProxyPartitionsInit()
    PublishPartitionDisplayText()
    SendPanelInfo()
  elseif strProperty == 'Zones Config' then
    Zones = parseZones(Properties['Zones Config'])
    -- The panel proxy holds its own copy of the zone list; re-push it or the
    -- widget keeps showing the zones from before the edit.
    SendPanelInfo()
  elseif strProperty == 'Partition Display Text' then
    -- Applied without a driver reload, so the experiment is one property
    -- edit and a glance at the app.
    PublishPartitionDisplayText()
  elseif strProperty == 'Quiet Zones' then
    -- Re-publish so a zone that just became quiet is immediately shown as
    -- closed, and one that stopped being quiet gets its real state back.
    SendPanelInfo(true)
  end
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  Dbg('ExecuteCommand: ' .. strCommand)

  if strCommand == 'LUA_ACTION' and tParams.ACTION then
    strCommand = tParams.ACTION
    tParams.ACTION = nil
  end

  local partition = tonumber(tParams.PARTITION)
  local zone = tonumber(tParams.ZONE)
  local output = tonumber(tParams.OUTPUT)

  local function armAction(mode)
    -- Same gate as the native widget: an Away-only partition must behave the
    -- same way whether the request came from Composer programming or the
    -- shield keypad.
    if not ArmModeAllowed(partition, mode) then
      local msg = 'Arm ' .. mode .. ' refused: partition ' .. tostring(partition) ..
        ' is not configured for it (check Partitions Config modes)'
      LogInfo(msg)
      SetProp('Last Command Result', msg)
      return
    end
    ArmPartition(partition, mode)
  end

  -- Accept both the current action names ("Arm Away (Full Arm)") and the
  -- earlier bare ones ("Arm Away"). Renaming an action would otherwise
  -- silently break any Composer programming written against the old name --
  -- the command would arrive and match nothing.
  local ARM_COMMANDS = {
    ['Arm ' .. ARM_LABEL_AWAY]  = 'away',  ['Arm Away']  = 'away',
    ['Arm ' .. ARM_LABEL_STAY]  = 'stay',  ['Arm Stay']  = 'stay',
    ['Arm ' .. ARM_LABEL_NIGHT] = 'night', ['Arm Night'] = 'night',
  }

  if ARM_COMMANDS[strCommand] and partition then
    armAction(ARM_COMMANDS[strCommand])
  elseif strCommand == 'Disarm' and partition then
    DisarmPartition(partition)
  elseif strCommand == 'Bypass Zone' and zone then
    SetZoneBypass(zone, true)
  elseif strCommand == 'Clear Bypass' and zone then
    SetZoneBypass(zone, false)
  elseif strCommand == 'Activate Output' and output then
    SetOutput(output, true)
  elseif strCommand == 'Deactivate Output' and output then
    SetOutput(output, false)
  elseif strCommand == 'Apply Discovered Zones' then
    -- Copies what "Discover Zone Names" found into Zones Config, so the
    -- installer does not have to hand-transcribe a long list (and cannot
    -- fat-finger a zone number while doing it).
    -- Prefer the full in-memory list from the last discovery. The property is
    -- only a preview and may be shortened, so applying it would drop zones.
    local discovered = DiscoveredZonesFull
    if not discovered or trim(discovered) == '' then
      -- No discovery this session (e.g. the driver reloaded since). Fall back
      -- to the property, but only if it is a complete list rather than a
      -- shortened preview.
      local prop = Properties['Discovered Zones'] or ''
      if trim(prop) ~= '' and not prop:find('preview shows', 1, true) then
        discovered = prop
      end
    end

    if not discovered or trim(discovered) == '' then
      local msg = 'Apply Discovered Zones: nothing to apply -- run "Discover Zone Names" first.'
      LogInfo(msg)
      SetProp('Last Command Result', msg)
    else
      SetProp('Zones Config', discovered)
      Zones = parseZones(discovered)
      local count = 0
      for _ in pairs(Zones) do count = count + 1 end
      LogInfo('Applied ' .. count .. ' discovered zones into Zones Config.')
      SetProp('Last Command Result', 'Applied ' .. count .. ' zones into Zones Config.')
      -- Push the new inventory to the app straight away.
      SendPanelInfo()
    end
  elseif strCommand == 'Sync Partition States' then
    SyncPartitionStates(false)
    SyncZoneStates()
  elseif strCommand == 'Discover Zone Names' then
    DiscoverZoneNames()
  elseif strCommand == 'Request Zone Status' then
    local pw = firstPartitionCode()
    if pw then
      RequestData(PARAM_ZONE_STATUS, 1, nil, pw, function(frame, err)
        if err then LogError('Request Zone Status failed: ' .. tostring(err))
        else SetProp('Last Event Summary', 'Zone status: ' .. JSON.encode(frame.parameters or {})) end
      end)
    end
  elseif strCommand == 'Report Variables' then
    ReportDriverVariables()
  elseif strCommand == 'Request Faults' then
    local pw = firstPartitionCode()
    if pw then
      RequestData(PARAM_FAULTS, 1, nil, pw, function(frame, err)
        if err then LogError('Request Faults failed: ' .. tostring(err))
        else
          local decoded = DecodeFaults(frame.parameters)
          LogInfo('Active faults: ' .. decoded)
          SetProp('Last Event Summary', 'Faults: ' .. decoded)
        end
      end)
    end
  else
    Dbg('Unhandled command: ' .. tostring(strCommand))
  end
end
