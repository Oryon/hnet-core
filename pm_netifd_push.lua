#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_netifd_push.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed Oct  2 12:54:49 2013 mstenber
-- Last modified: Thu Oct  3 17:56:34 2013 mstenber
-- Edit time:     63 min
--

-- This is unidirectional channel which pushes the 'known state' of
-- skv towards netifd.

-- Basic idea: No change -> nothing occurs.

-- The code generates per-interface blobs for every interface ever
-- seen, but if there's no change, no push towards netifd is done.

-- Pushing itself is done using ubus command line tool, to make this
-- easy to unit test; it could be equally well done with ubus Lua
-- module

require 'pm_handler'
require 'pm_radvd'

local json = require "dkjson"

module(..., package.seeall)

local _parent = pm_handler.pm_handler_with_pa

pm_netifd_push = _parent:new_subclass{class='pm_netifd_push'}

function pm_netifd_push:init()
   _parent.init(self)
   self.set_netifd_state = {}
   self:connect_method(self._pm.network_interface_changed, self.ni_changed)
end

function pm_netifd_push:ni_changed(ni)
   self.ni = ni
   self:queue()
end

function pm_netifd_push:ready()
   -- we can't do anything useful until we have network interface dump available
   -- (from pm_netifd_pull)
   return _parent.ready(self) and self.ni
end

function pm_netifd_push:get_skv_to_netifd_state()
   local state = mst.map:new()
   -- use usp + lap to produce per-interface info blobs we feed to netifd
   local function _setdefault_named_subentity(o, n, class_object)
      return o:setdefault_lazy(n, class_object.new, class_object)
   end
   -- dig out addresses from lap
   for i, lap in ipairs(self.lap)
   do
      local ifname = self.ni:device2hnet_interface(lap.ifname)
      if ifname and lap.address
      then
         local ifo = _setdefault_named_subentity(state, ifname, mst.map)
         local p = ipv6s.new_prefix_from_ascii(lap.prefix)
         local addrs_name = p:is_ipv4() and 'ipaddr' or 'ip6addr'
         local addrs = _setdefault_named_subentity(ifo, addrs_name, mst.array)
         local _, mask = unpack(mst.string_split(lap.prefix, '/'))
         local now = self:time()
         local pref = pm_radvd.abs_to_delta(now, lap[elsa_pa.PREFERRED_KEY])
         local valid = pm_radvd.abs_to_delta(now, lap[elsa_pa.VALID_KEY])
         local o = {
            ipaddr=lap.address,
            mask=mask,
            preferred=pref,
            valid=valid,
         }
         addrs:insert(o)
         self:d('added address', addrs_name, o)

      end
   end

   -- dig out routes from usp
   for i, usp in ipairs(self.usp)
   do
      -- ifname + nh == source route we care about (we're internal
      -- node, and it needs to point somewhere external)
      local ifname = self.ni:device2hnet_interface(usp.ifname)
      if ifname and usp.nh
      then
         local ifo = _setdefault_named_subentity(state, ifname, mst.map)
         local p = ipv6s.new_prefix_from_ascii(usp.prefix)
         local routes_name = p:is_ipv4() and 'routes' or 'routes6'
         local routes = _setdefault_named_subentity(ifo, routes_name, mst.array)
         local addr, mask = unpack(mst.string_split(usp.prefix, '/'))
         local o = {
            target=addr,
            netmask=mask,
            gateway=usp.nh,
            -- metric/valid?
         }
         routes:insert(o)
         self:d('added route', routes_name, o)
      end
   end
   --self:d('produced state', state)
   return state
end

function pm_netifd_push:run()
   -- generate per-interface blobs
   local state = self:get_skv_to_netifd_state()

   local zapping = {}
   
   -- synchronize them with 'known state'
   mst.sync_tables(self.set_netifd_state, state, 
                   -- remove
                   function (k)
                      zapping[k] = true
                   end,
                   -- add
                   function (k, v)
                      zapping[k] = nil
                      self:push_state(k, v)
                   end,
                   -- are values same? use repr
                   function (k, v1, v2)
                      -- we store repr's in set_netifd_state
                      return mst.repr(v2) == v1
                   end)

   -- for those interfaces that we do not have fresh state for, send
   -- empty state update
   for k, v in pairs(zapping)
   do
      self:push_state(k, {})
   end
end

function pm_netifd_push:push_state(k, v)
   self:d('push_state', k)
   self.set_netifd_state[k] = mst.repr(v)
   v.interface = k
   v['link-up'] = true
   v.action = 0
   -- xxx - I don't think we need ifname
   local s = json.encode(v)
   -- json doesn't suit very well in testsuite material - ordering is
   -- arbitrary for those strings
   if self.config.test
   then
      s = mst.repr(v)
   end
   -- xxx - better escaping some day..
   self.shell("ubus call network.interface notify_proto '" .. s .. "'")
end