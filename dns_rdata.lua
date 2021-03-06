#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_rdata.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Jan 14 13:08:00 2013 mstenber
-- Last modified: Tue Jun 18 17:14:55 2013 mstenber
-- Edit time:     21 min
--

require 'dns_const'
require 'dns_name'
require 'mdns_const'

module(..., package.seeall)

local abstract_base = codec.abstract_base
local abstract_data = codec.abstract_data
local cursor_has_left = codec.cursor_has_left
local try_encode_name = dns_name.try_encode_name
local try_decode_name = dns_name.try_decode_name

local function simple_equal(self, v1, v2)
   local r = (not v1 or not v2) or v1 == v2
   --mst.d('simple_equal', v1, v2, r)
   return r
end

local function repr_equal(self, v1, v2)
   local r = (not v1 or not v2) or mst.repr_equal(v1, v2)
   --mst.d('repr_equal', v1, v2, r)
   return r
end

local function encode_ll_field(self, o, context)
   local v = o[self.field]
   mst.a(v, 'missing', self.field, o)
   local t, err = try_encode_name(v, context)
   if not t then return nil, err end
   return table.concat(t)
end

local function decode_ll_field(self, o, cur, context)
   local name, err = try_decode_name(cur, context)
   if not name then return nil, err end
   o[self.field] = name
   return true
end

rtype_map = {[dns_const.TYPE_PTR]={
                field='rdata_ptr',
                encode=encode_ll_field,
                decode=decode_ll_field,
                field_equal=repr_equal,
                                  },
             [dns_const.TYPE_NS]={
                field='rdata_ns',
                encode=encode_ll_field,
                decode=decode_ll_field,
                field_equal=repr_equal,
             },
             
             [dns_const.TYPE_CNAME]={
                field='rdata_cname',
                encode=encode_ll_field,
                decode=decode_ll_field,
                field_equal=repr_equal,
             },
             
             [dns_const.TYPE_A]={
                field='rdata_a',
                encode=function (self, o, context)
                   local v = o[self.field]
                   mst.a(v, 'no value for', self.field)
                   local b = ipv4s.address_to_binary_address(v)
                   mst.a(#b == 4, 'encode error')
                   return b
                end,
                decode=function (self, o, cur, context)
                   if not rdata_cursor_has_left(cur, 4)
                   then
                      return nil, 'not enough rdata (4)'
                   end
                   local b = cur:read(4)
                   o[self.field] = ipv4s.binary_address_to_address(b)
                   return true
                end,
                field_equal=simple_equal,
                default_ttl=mdns_const.DEFAULT_NAME_TTL,
             },
             [dns_const.TYPE_AAAA]={
                field='rdata_aaaa',
                encode=function (self, o, context)
                   local v = o[self.field]
                   mst.a(v)
                   local b = ipv6s.address_to_binary_address(v)
                   mst.a(#b == 16, 'encode error', o)
                   return b
                end,
                decode=function (self, o, cur, context)
                   if not rdata_cursor_has_left(cur, 16)
                   then
                      return nil, 'not enough rdata (16)'
                   end
                   local b = cur:read(16)
                   local s = ipv6s.binary_address_to_address(b)
                   o[self.field] = s
                   return s
                end,
                field_equal=simple_equal,
                default_ttl=mdns_const.DEFAULT_NAME_TTL,
             },
}


rdata_srv = abstract_data:new{class='rdata_srv',
                              format='priority:u2 weight:u2 port:u2',
                              header_default={priority=0,
                                              weight=0,
                                              port=0}}

function rdata_srv:try_decode(cur, context)
   -- first off, get the base struct
   local o, err = abstract_data.try_decode(self, cur)
   if not o then return nil, err end

   -- and then 'target', which is FQDN
   local n, err = try_decode_name(cur, context)
   if not n then return nil, err end
   
   o.target = n
   return o
end

function rdata_srv:do_encode(o, context)
   mst.a(type(o) == 'table')
   mst.a(o.target, 'missing targetin ', mst.repr(o))
   local r = abstract_data.do_encode(self, o)
   if context
   then
      context.pos = context.pos + #r
   end
   local t, err = try_encode_name(o.target, context)
   if not t then return nil, err  end
   -- ugh, but oh well :p
   return r .. table.concat(t)
end

local _hr=3600

rdata_soa = abstract_data:new{class='rdata_soa',
                              format='serial:u4 refresh:u4 retry:u4 expire:u4 minimum:u4',
                              header_default={serial=1,
                                              refresh=_hr,
                                              retry=_hr,
                                              expire=_hr,
                                              minimum=_hr}}

function rdata_soa:try_decode(cur, context)
   -- mname = domain-name of server that was original info for this zone
   local mname, err = try_decode_name(cur, context)
   if not mname then return nil, err end
   -- rname = mailbox address of responsible person
   local rname, err = try_decode_name(cur, context)
   if not rname then return nil, err end
   
   -- then 'base struct' which follows after
   local o, err = abstract_data.try_decode(self, cur)
   if not o then return nil, err end
   
   o.mname = mname
   o.rname = rname
   return o
end


function rdata_soa:do_encode(o, context)
   local t1, err = try_encode_name(o.mname, context)
   if not t1 then return nil, err end
   local r1 = table.concat(t1)
   if context
   then
      context.pos = context.pos + #r1
   end
   local t2, err = try_encode_name(o.rname, context)
   if not t2 then return nil, err end
   local r2 = table.concat(t2)
   if context
   then
      context.pos = context.pos + #r2
   end
   local r = abstract_data.do_encode(self, o)
   if context
   then
      context.pos = context.pos + #r
   end
   return r1 .. r2 .. r
end

rdata_nsec = abstract_base:new{class='rdata_nsec'}

function rdata_cursor_has_left(cur, n)
   if cur.endpos 
   then
      return cur.pos + n <= cur.endpos
   end
   return cursor_has_left(cur, n)
end

function rdata_nsec:try_decode(cur, context)
   -- two things - next domain name (ndn)
   local n, err = try_decode_name(cur, context)
   if not n then return nil, err end
   
   -- and bitmap
   --local t = mst.set:new{}
   local t = mst.array:new{}
   while rdata_cursor_has_left(cur, 2)
   do
      -- block #
      local block_offset = string.byte(cur:read(1))
      -- bytes
      local block_bytes = string.byte(cur:read(1))
      self:d('reading', block_offset, block_bytes)
      if not rdata_cursor_has_left(cur, block_bytes)
      then
         return nil, string.format('decode ended mid-way (no %d bytes left)',
                                   block_bytes)
      end
      for i=1,block_bytes
      do
         local c = cur:read(1)
         local b = string.byte(c)
         -- XXX - some day would be nice to have network order
         -- independent decode here. oh well. 
         for j=8,1,-1
         do
            if mst.bitv_is_set_bit(b, j)
            then
               t:insert(256 * block_offset +
                        8 * (i - 1) + 
                        (8 - j))
            end
         end
      end
   end
   return {ndn=n, bits=t}
end

function iterate_modulo_ranges(bits, modulo, f, st, en)
   local st = st or 1
   local nbits = #bits
   local en = en or nbits

   local i = st
   while i <= en
   do
      local j = i
      local v = bits[i]
      local mr = math.floor(v / modulo)
      --mst.d('finding subblock', i, en, modulo, v, mr)
      while (j+1) <= en and math.floor(bits[j+1] / modulo) == mr
      do
         j = j + 1
      end
      f(mr, i, j)
      i = j + 1
      --mst.d('i now', i)
   end
end


function rdata_nsec:do_encode(o, context)
   mst.a(o, 'no object given to encode?!?')
   mst.a(o.ndn)
   local n, err = try_encode_name(o.ndn, context)
   if not n then return nil, err end
   local t = {}
   -- encoding of the bits is bit more complex
   local bits = o.bits
   table.sort(bits)
   -- first off, try to get the 256-bit blocks, and deal with them
   iterate_modulo_ranges(bits, 256,
                         function (mr, i1, j1)
                            --mst.d('handling', mr)
                            local t0 = {}
                            iterate_modulo_ranges(bits, 8,
                                                  function (br, i2, j2)
                                                     br = br % 32
                                                     while #t0 < br
                                                     do
                                                        table.insert(t0, 0)
                                                     end
                                                     local v = 0
                                                     for i=i2,j2
                                                     do
                                                        local b=bits[i]
                                                        v = mst.bitv_set_bit(v, 8-b%8)
                                                     end
                                                     --mst.d('produced', v)
                                                     table.insert(t0, v)
                                                  end, i1, j1)
                            table.insert(t, string.char(mr, #t0, unpack(t0)))
                         end)
   mst.array_extend(n, t)
   --mst.d('concatting', n)
   return table.concat(n)
end

local function add_rtype_decoder(type, cl, o)
   rtype_map[type] = o
   function o.encode(self, o, context)
      return cl:encode(o[self.field], context)
   end
   function o.decode(self, o, cur, context)
      cur.endpos = cur.pos + o.rdlength
      local r, err = cl:decode(cur, context)
      cur.endpos = nil
      if not r then return nil, err end
      o[self.field] = r
      return true
   end
end

add_rtype_decoder(dns_const.TYPE_SRV, rdata_srv, {
                     field='rdata_srv', 
                     field_equal=repr_equal,
                     default_ttl=mdns_const.DEFAULT_NAME_TTL,
                                                 })
add_rtype_decoder(dns_const.TYPE_NSEC, rdata_nsec, {
                     field='rdata_nsec', 
                     field_equal=repr_equal,
                     default_ttl=mdns_const.DEFAULT_NAME_TTL,
                                                   })


add_rtype_decoder(dns_const.TYPE_SOA, rdata_soa, {
                     field='rdata_soa', 
                     field_equal=repr_equal,
                     default_ttl=mdns_const.DEFAULT_NAME_TTL,
                                                 })

