#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Sun Jan 27 12:38:01 2013 mstenber
-- Last modified: Mon Jan 28 12:51:30 2013 mstenber
-- Edit time:     16 min
--

-- 'mdns' daemon, which shares state (via skv and then via OSPF AC LSA
-- TLV) with other instances of itself on other routers. The daemon
-- itself here is relatively simple, just a wrapper for mdns_core and
-- scb's UDP.

require 'mst'
require 'skv'
require 'ssloop'
require 'mdns_ospf'

local loop = ssloop.loop()

_TEST = false

function create_cli()
   local cli = require "cliargs"

   cli:set_name('mdns.lua')
   -- XXX - think about command line options we might want
   --cli:add_flag("-m, --dnsmasq", "use dnsmasq instead of ISC dhcpd + radvd")

   return cli
end

function checked_setoption(s, o, v)
   local r, err = s:setoption(o, v)
   mst.a(r, 'error', err, o, v)
end

local args = create_cli():parse()
if not args 
then
   -- something wrong happened and an error was printed
   return
end

mst.d('initializing socket')
local o,err = scb.new_udp_socket{host='*', 
                                 port=mdns_const.PORT,
                                 callback=true,
                                 v6only=true}
mst.a(o, 'error initializing udp socket', err)

-- by default, join on _all_ interfaces, what's the harm? we can
-- ignore packets from the interfaces we don't care about, anyway..
local mcast = mdns_const.MULTICAST_ADDRESS
local ifindex=nil
local mct = {multiaddr=mcast, interface=ifindex}

--checked_setoption(o.s, 'ipv6-v6only', true)
checked_setoption(o.s, 'ipv6-add-membership', mct)
checked_setoption(o.s, 'ipv6-unicast-hops', 255)
checked_setoption(o.s, 'ipv6-multicast-hops', 255)
checked_setoption(o.s, 'ipv6-multicast-loop', false)

mst.d('initializing skv')

-- doesn't _have_ to be long lived, but _can_ be (pm should be the
-- long-lived process, as it passes the data between mdns and ospf
-- implementation)
local s = skv.skv:new{long_lived=false}

mst.d('initializing pm')
local mdns = mdns_ospf.mdns:new{skv=s,
                                sendto=o.s.sendto,
                               }

function o.callback(...)
   -- just pass the callback data directly
   mdns:recvfrom(...)
end

mst.d('entering event loop')
loop:loop()

