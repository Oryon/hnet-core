#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_v6_rule.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Nov  8 07:12:11 2012 mstenber
-- Last modified: Thu Nov  8 09:08:14 2012 mstenber
-- Edit time:     25 min
--

require 'pm_handler'

module(..., package.seeall)

-- we use the (128-length of prefix as preference on top of the base => 128)
RULE_PREF_MIN=1000
RULE_PREF_MAX=RULE_PREF_MIN + 128 
MAIN_TABLE='main'

pm_v6_rule = pm_handler.pm_handler:new_subclass{class='pm_v6_rule'}

function pm_v6_rule:init()
   pm_handler.pm_handler.init(self)

   self.applied_usp = {}

   local rt = linux_if.rule_table:new{shell=self.shell}
   self.rule_table = rt
   local vs = mst.validity_sync:new{t=self.rule_table, single=true}
   self.vsrt = vs
   function vs:remove(rule)
      if rule.pref >= RULE_PREF_MIN and rule.pref <= RULE_PREF_MAX
      then
         rule:del(rt.shell)
      end
      rt:remove(rule)
   end
end

function pm_v6_rule:ready()
   return self.pm.ospf_usp
end

function pm_v6_rule:get_usp_nhl(usp)
   return self.pm.nh[usp.ifname] or (usp.nh and {usp.nh}) or {}
end

function pm_v6_rule:get_usp_key(usp)
   local v = mst.repr{usp.prefix, usp.ifname, self:get_usp_nhl(usp)}
   self:d('usp key', v)
   return v
end

function pm_v6_rule:run()
   -- we have the internal rule_table object. we compare that against
   -- the state we have in skv for OSPF (pd changes should come via
   -- OSPF process, hopefully, to keep the dataflow consistent)

   -- refresh the state
   self.rule_table:parse()

   -- mark all rules non-valid 
   self.vsrt:clear_all_valid()

   -- we ignore all USPs without ifname + nh
   local usps = self.pm:get_ipv6_usp()
   usps = usps:filter(function (usp) return usp.ifname end)
   usps = usps:filter(function (usp) return #self:get_usp_nhl(usp)>0 end)
   
   for _, usp in ipairs(usps)
   do
      local sel = 'from ' .. usp.prefix
      local i1, i2, s = string.find(usp.prefix, '/(%d+)$')
      self:a('invalid prefix', usp.prefix)
      local bits = tonumber(s)
      local pref = RULE_PREF_MIN + 128 - bits
      local template = {sel=sel, pref=pref}
      local o = self.rule_table:find(template)

      -- in this iteration, we don't care about USP that lack ifname
      local update_table = nil
      if o
      then
         local uspk = self:get_usp_key(usp)
         self.vsrt:set_valid(o)
         if self.applied_usp[usp.prefix] ~= uspk
         then
            -- in rule table, changed => refresh the table's contents
            -- (but keep the table)
            update_table = o.table
         end
      end
      if not o
      then
         -- store that it has been added
         local uspk = self:get_usp_key(usp)
         self.applied_usp[usp.prefix] = uspk

         -- figure table number
         local table = self.rule_table:get_free_table()
         template.table = table

         local r = self.rule_table:add_rule(template)

         -- and add it 
         r:add(self.shell)

         update_table = table
      end
      if update_table
      then
         local table = update_table
         local nhl = self:get_usp_nhl(usp)
         
         -- and flush the table
         self.shell('ip -6 route flush table ' .. table)
         
         -- and add the default route         
         dev = usp.ifname

         for i, nh in ipairs(nhl)
         do
            self.shell(string.format('ip -6 route add default via %s dev %s table %s',
                                     nh, dev, table))
         end
      end
   end
   
   for _, usp in ipairs(usps)
   do
      -- to rules just point at main table => no content to care about
      local sel = 'from all to ' .. usp.prefix
      local pref = RULE_PREF_MIN
      local template = {sel=sel, pref=pref, table=MAIN_TABLE}
      local o = self.rule_table:find(template)
      if o
      then
         self.vsrt:set_valid(o)
      else
         local r = self.rule_table:add_rule(template)
         r:add(self.shell)
      end
   end

   -- in rule table, not in OSPF => del
   self.vsrt:remove_all_invalid()

   return 1
end
