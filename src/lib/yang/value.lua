-- Use of this source code is governed by the Apache 2.0 license; see
-- COPYING.
module(..., package.seeall)

local util = require("lib.yang.util")
local ipv4 = require("lib.protocol.ipv4")
local ipv6 = require("lib.protocol.ipv6")
local ffi = require("ffi")
local bit = require("bit")
local ethernet = require("lib.protocol.ethernet")

types = {}

local function integer_type(ctype)
   local ret = {ctype=ctype}
   local min, max = ffi.new(ctype, 0), ffi.new(ctype, -1)
   if max < 0 then
      -- A signed type.  Hackily rely on unsigned types having 'u'
      -- prefix.
      max = ffi.new(ctype, bit.rshift(ffi.new('u'..ctype, max), 1))
      min = max - max - max - 1
   end
   function ret.parse(str, what)
      return util.tointeger(str, what, min, max)
   end
   function ret.tostring(val)
      local str = tostring(val)
      if str:match("ULL") then return str:sub(1, -4)
      elseif str:match("LL") then return str:sub(1, -3)
      else return str end
   end
   return ret
end

types.int8 = integer_type('int8_t')
types.int16 = integer_type('int16_t')
types.int32 = integer_type('int32_t')
types.int64 = integer_type('int64_t')
types.uint8 = integer_type('uint8_t')
types.uint16 = integer_type('uint16_t')
types.uint32 = integer_type('uint32_t')
types.uint64 = integer_type('uint64_t')

local function unimplemented(type_name)
   local ret = {}
   function ret.parse(str, what)
      error('unimplemented '..type_name..' when parsing '..what)
   end
   function ret.tostring(val)
      return tostring(val)
   end
   return ret
end

types.binary = unimplemented('binary')
types.bits = unimplemented('bits')

types.boolean = {ctype='bool'}
function types.boolean.parse(str, what)
   local str = assert(str, 'missing value for '..what)
   if str == 'true' then return true end
   if str == 'false' then return false end
   error('bad boolean value: '..str)
end
function types.boolean.tostring(val)
   return tostring(val)
end

-- FIXME: We lose precision by representing a decimal64 as a double.
types.decimal64 = {ctype='double'}
function types.decimal64.parse(str, what)
   local str = assert(str, 'missing value for '..what)
   return assert(tonumber(str), 'not a number: '..str)
end
function types.decimal64.tostring(val)
   -- FIXME: Make sure we are not given too many digits after the
   -- decimal point.
   return tostring(val)
end

types.empty = unimplemented('empty')
types.identityref = unimplemented('identityref')
types['instance-identifier'] = unimplemented('instance-identifier')
leafref = unimplemented('leafref')

types.string = {}
function types.string.parse(str, what)
   return assert(str, 'missing value for '..what)
end
function types.string.tostring(val)
   return val
end

types.enumeration = {}
function types.enumeration.parse(str, what)
   return assert(str, 'missing value for '..what)
end
function types.enumeration.tostring(val)
   return val
end

types.union = unimplemented('union')

--[[ Disable special type support.
types['ipv4-address'] = {
   ctype = 'uint32_t',
   parse = function(str, what) return util.ipv4_pton(str) end,
   tostring = function(val) return util.ipv4_ntop(val) end
}

types['legacy-ipv4-address'] = {
   ctype = 'uint8_t[4]',
   parse = function(str, what) return assert(ipv4:pton(str)) end,
   tostring = function(val) return ipv4:ntop(val) end
}

types['ipv6-address'] = {
   ctype = 'uint8_t[16]',
   parse = function(str, what) return assert(ipv6:pton(str)) end,
   tostring = function(val) return ipv6:ntop(val) end
}

types['mac-address'] = {
   ctype = 'uint8_t[6]',
   parse = function(str, what) return assert(ethernet:pton(str)) end,
   tostring = function(val) return ethernet:ntop(val) end
}

types['ipv4-prefix'] = {
   ctype = 'struct { uint8_t prefix[4]; uint8_t len; }',
   parse = function(str, what)
      local prefix, len = str:match('^([^/]+)/(.*)$')
      return { util.ipv4_pton(prefix), util.tointeger(len, 'slash', 1, 32) }
   end,
   tostring = function(val)
      return util.ipv4_ntop(val[1])..'/'..tostring(val[2])
   end
}

types['ipv6-prefix'] = {
   ctype = 'struct { uint8_t prefix[16]; uint8_t len; }',
   parse = function(str, what)
      local prefix, len = str:match('^([^/]+)/(.*)$')
      return { assert(ipv6:pton(prefix)), util.tointeger(len, 'slash', 1, 128) }
   end,
   tostring = function(val) return ipv6:ntop(val[1])..'/'..tostring(val[2]) end
}
]]--

function selftest()
   assert(types['uint8'].parse('0') == 0)
   assert(types['uint8'].parse('255') == 255)
   assert(not pcall(types['uint8'].parse, '256'))
   assert(types['int8'].parse('-128') == -128)
   assert(types['int8'].parse('0') == 0)
   assert(types['int8'].parse('127') == 127)
   assert(not pcall(types['int8'].parse, '128'))
end
