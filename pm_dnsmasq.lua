#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_dnsmasq.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Wed Nov 21 17:13:32 2012 mstenber
-- Last modified: Mon Sep 30 14:09:44 2013 mstenber
-- Edit time:     122 min
--

require 'pm_handler'
require 'pa'

module(..., package.seeall)

local _null=string.char(0)

local _parent = pm_handler.pm_handler_with_pa_dns

pm_dnsmasq = _parent:new_subclass{class='pm_dnsmasq'}

DEFAULT_V4_LEASE="10m"
DEFAULT_V6_LEASE="10m"

SCRIPT='/usr/share/hnet/dnsmasq_handler.sh'

function pm_dnsmasq:run()
   local fpath = self.config.dnsmasq_conf_filename
   local c = self:write_dnsmasq_conf(fpath)
   -- if 'same', do nothing
   if not c
   then
      self:d('no change')
      return
   end
   local op 
   if c == 0
   then
      -- have to kill existing, if any
      op = ' stop'
   else
      if self.started
      then
         op = ' reload ' .. fpath
      else
         op = ' start ' .. fpath
      end
   end
   self.shell(SCRIPT .. op)
   self.started = c > 0
   return 1
end

function pm_dnsmasq:write_dnsmasq_conf_dns_raw(t, dns4, search4, dns6, search6)
   -- first off, handle normal DNS option
   local function dump_list(l, format)
      for i, v in ipairs(l)
      do
         t:insert(string.format(format, v))
      end
   end
   dump_list(dns4, 'server=%s')
   dump_list(dns6, 'server=%s')

   -- then DNS search list
   if #search4 > 0
   then
      local s = table.concat(search4, ',')
      t:insert('dhcp-option=option:domain-search,' .. s)
   end

   -- XXX - domain?

   -- and DHCPv6 search list
   if #search6 > 0
   then
      local s = table.concat(search6, ',')
      t:insert('dhcp-option=option6:domain-search,' .. s)
   end

end

function pm_dnsmasq:write_dnsmasq_conf_dns(t)
   local dns4 = self.ospf_v4_dns or {}
   local search4 = self.ospf_v4_dns_search or {}
   local dns6 = self.ospf_dns or {}
   local search6 = self.ospf_dns_search or {}

   if self.config.use_hp_ospf
   then
      -- For IPv4 nameserver, we provide one of our own assigned 10.*
      -- addresses (it doesn't really matter which one, but we provide
      -- whole list just in case the addresses change over the
      -- lifetime of the DHCP lease, and it doesn't get refreshed)

      -- For IPv6 we do the same thing too.
      
      -- Perhaps using the dnsmasq for a forwarder would be nicer, and
      -- then just run the hp_ospf stuff _without_ forwarding on
      -- different ports or something? Food for thought.

      -- Based on discussions with Ole, we override search domain as this
      -- is different administrative domain

      search6 = self.hp_search or {}
      search4 = self.hp_search or {}

      dns6 = {}
      dns4 = {}

      local l4 = {}
      local l6 = {}
      for i, lap in ipairs(self.lap)
      do
         local a = lap.address
         mst.d('considering', lap, a)
         if a and not lap.depracate
         then
            table.insert(ipv6s.address_is_ipv4(a) and l4 or l6, a)
         end
      end
      if #l4 > 0
      then
         -- just use one address, arbitrarily chosen (XXX - better
         -- heuristic) a lot of addresses just causes clients to
         -- bombard us needlessly
         l4 = {l4[1]}
         local s = table.concat(l4, ',')
         mst.d('adding dns-server option', s)
         t:insert('dhcp-option=option:dns-server,' .. s)
      end
      if #l6 > 0
      then
         -- just use one address, arbitrarily chosen (XXX - better
         -- heuristic) a lot of addresses just causes clients to
         -- bombard us needlessly
         l6 = {l6[1]}
         -- add []s around addresses
         local s = table.concat(mst.array_map(l6,
                                              function (s)
                                                 return string.format('[%s]', s)
                                              end), ',')
         mst.d('adding DHCPv6 dns-server option', s)
         t:insert('dhcp-option=option6:dns-server,' .. s)
      end
      -- disable DNS
      t:insert('port=0')
   end

   self:write_dnsmasq_conf_dns_raw(t, dns4, search4, dns6, search6)
end


function pm_dnsmasq:write_dnsmasq_conf(fpath)
   local t = mst.array:new{}
   local c = 0
   local ext_set = self.usp:get_external_if_set()

   -- dnsmasq has 'flat' configuration structure
   -- => we can just iterate through lap to produce what we want
   -- (+- filtering based on known external interfaces)

   t:insert([[
# We want to use only servers we provide explicitly
no-resolv

# Hardcoded domain.. ugh.
domain=lan

# Enable RA
# (Not needed according to SK; specific ra-stateless ones override
# this - 20130320)
#enable-ra

# Disable dynamic interfaces - because we know what to listen to

# (And because dnsmasq doesn't use SO_REUSE* without
# clever/bind-interfaces being set, so kill+restart sometimes fails at
# booting dnsmasq :-p And the clever stuff sounds Linux specific..)

bind-interfaces

]])

   self:write_dnsmasq_conf_dns(t)

   -- then the ranges for DHCPv4 / SLAAC
   local ifset = mst.set:new{}
   local dumped_pclass = {}

   for i, lap in ipairs(self.lap)
   do
      local ifname = lap.ifname
      -- we never serve anything outside home -> if in ext set, skip
      -- similarly, we have to 'own' the link, and we also
      -- cannot be external (based on BIRD determination). 
      if not ext_set[ifname] and lap.owner and not lap.external
      then
         local prefix = lap.prefix
         local dep = lap.depracate
         -- looks like non-external => we can say something about it
         local p = ipv6s.ipv6_prefix:new{ascii=prefix}
         if not p:is_ipv4()
         then
            local lease = dep and 'deprecated' or DEFAULT_V6_LEASE
            local flags = ',ra-stateless,ra-names'
            local pclass = lap[elsa_pa.PREFIX_CLASS_KEY]
            local prefix_without_slash = mst.string_split(prefix, '/')[1]
            local tags = 'tag:' .. ifname
            if pclass
            then
               local n = dumped_pclass[pclass]
               if not n
               then
                  n = string.format('pc%d', pclass)
                  dumped_pclass[pclass] = n
                  t:insert(string.format('dhcp-prefix-class=set:%s,%s', n, pclass))
               end
               -- convert it from just prefix (used by RA) to address range
               -- append 100, and then prefix+200 again
               flags = string.format('100,%s200', prefix_without_slash)
               -- add the tag for prefix pool
               tags = string.format('%s,tag:%s', tags, n)
            end

            ifset:insert(ifname)
            t:insert(string.format('dhcp-range=%s,%s%s,%s',
                                   tags, 
                                   prefix_without_slash,
                                   flags,
                                   lease))
            c = c + 1
         elseif not dep
         then
            -- depracated ipv4 prefix should be just ignored
            -- XXX - study if we should have really shorter leases or not.
            -- typically, there isn't collisions in the network on v4
            -- address space level, though?
            local lease = DEFAULT_V6_LEASE
            local b = p:get_binary()
            local snb = b .. _null
            local sn = ipv6s.binary_address_to_address(snb)
            local stb = b .. string.char(pa.IPV4_PA_LAST_ROUTER + 1)
            local enb = b .. string.char(254)
            local st = ipv6s.binary_address_to_address(stb)
            local en = ipv6s.binary_address_to_address(enb)
            ifset:insert(ifname)
            t:insert(string.format('dhcp-range=tag:%s,%s,%s,%s',
                                   ifname,
                                   st,
                                   en,
                                   lease))
            c = c + 1
         end
      end
   end

   -- explicit interfaces to listen to
   -- (loopback is automatic)
   if ifset:count() > 0
   then
      local ifs = ifset:keys()
      table.sort(ifs)
      t:insert('interface=' .. table.concat(ifs, ','))
   end

   -- special case - no change to file => do nothing
   -- (indicated by returning nil)
   return self:write_to_file(fpath, t, '# ') and c
end
