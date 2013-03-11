#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_v6_nh.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Nov  8 08:10:48 2012 mstenber
-- Last modified: Mon Mar 11 09:43:12 2013 mstenber
-- Edit time:     19 min
--

-- pm_v6_nh is responsible for maintaining the structure of the pm.nh,
-- which is then used by pm_v6_rule to as things change over time

-- novel thing about this is that it runs in tick's, and not otherwise

require 'pm_handler'
require 'linux_if'
require 'pm_v6_rule'

module(..., package.seeall)

pm_v6_nh = pm_handler.pm_handler:new_subclass{class='pm_v6_nh'}

function pm_v6_nh:ready()
   return self.pm.ospf_lap
end

function pm_v6_nh:get_external_set()
   local ext
   for i, lap in ipairs(self.pm.ospf_lap)
   do
      if lap.external
      then
         ext = ext or mst.set:new()
         ext:insert(lap.ifname)
      end
   end
   return ext
end

function pm_v6_nh:calculate_nh()
   -- if we don't have external links, not interested (only external
   -- ones matter)
   local nh = mst.multimap:new{}
   local ext = self:get_external_set()
   if ext
   then
      self:d('external interfaces', ext)

      -- what we do is we recreate the pm.nh every time. however,
      -- we emit the changed signal if and only if 
      self:a(self.shell)
      for i, o in ipairs(linux_if.get_ip6_routes(self.shell))
      do
         -- we ignore dead routes, and non-default ones
         self:d('got', o)
         if not o.dead and o.dst == 'default' 
            and o.metric ~= pm_v6_rule.DUMMY_METRIC
            and ext[o.dev]
         then
            self:d(' seems like valid default route, adding')
            nh:insert(o.dev, o.via)
         end
      end
   end
   return nh
end

function pm_v6_nh:tick()
   local nh = self:calculate_nh()

   if mst.repr_equal(nh, self.pm.nh)
   then
      return
   end

   self:d('pm.nh updated', nh)

   -- ok, a change => we change pm.nh and call changed()

   self.pm.nh = nh
   return 1
end
