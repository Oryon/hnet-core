#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_v6_dhclient.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Fri Nov 16 12:56:30 2012 mstenber
-- Last modified: Wed Nov 21 18:38:24 2012 mstenber
-- Edit time:     5 min
--

require 'pm_handler'
require 'pm_core'

module(..., package.seeall)

DHCLIENT6_SCRIPT='/usr/share/hnet/dhclient6_handler.sh'
DHCLIENT6_PID_PREFIX='pm-pid-dhclient6-'

pm_v6_dhclient = pm_handler.pm_handler:new_subclass{class='pm_v6_dhclient'}

function pm_v6_dhclient:run()
   -- oddly enough, we actually trust the OS (to a point); therefore,
   -- we keep only track of the dhclients we _think_ we have started,
   -- and just start-kill those as appropriate.
   local running_ifnames = mst.set:new{}
   for i, v in ipairs(mst.string_split(self.shell('ls -1 ' .. pm_core.PID_DIR), '\n'))
   do
      v = mst.string_strip(v)
      if mst.string_startswith(v, DHCLIENT6_PID_PREFIX)
      then
         local s = string.sub(v, #DHCLIENT6_PID_PREFIX+1)
         running_ifnames:insert(s)
      end
   end


   -- get a list of intefaces that BIRD knows about
   local ifs = mst.array_to_table(self.pm.ospf_iflist or {})

   local c = mst.sync_tables(running_ifnames, ifs, 
                             -- remove
                             function (ifname)
                                local p = pm_core.PID_DIR .. '/' .. DHCLIENT6_PID_PREFIX .. ifname
                                local s = string.format('%s stop %s %s', DHCLIENT6_SCRIPT, ifname, p)
                                -- for the time being, we just leave them running;
                                -- OSPF interfaces may flap after all
                                --self.shell(s)
                             end,
                             -- add
                             function (ifname)
                                local p = pm_core.PID_DIR .. '/' .. DHCLIENT6_PID_PREFIX .. ifname
                                local s = string.format('%s start %s %s', DHCLIENT6_SCRIPT, ifname, p)
                                self.shell(s)
                             end
                             -- no equality - if it exists, it exists
                            )
   return c
end
