#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Thu Oct  4 19:38:48 2012 mstenber
-- Last modified: Fri Oct  5 01:07:51 2012 mstenber
-- Edit time:     4 min
--

-- 'prefix manager' (name still temporary)
--
-- it is responsible for keeping the skv state and system state in
-- sync, by listening to skv change notifications, and attempting to
-- make the local state reflect skv state

-- (add/remove interface IPv6 addresses, and possibly rewrite
-- radvd.conf/dhcp/... configurations and kick them in the head etc
-- later on)

require 'mst'
require 'pm_core'
require 'skv'
require 'ssloop'

-- XXX - option processing

mst.d('initializing skv')
local s = skv.skv:new{long_lived=true}
mst.d('initializing pm')
local pm = pm_core.pm:new{shell=mst.system, skv=s}
mst.d('entering event loop')
ssloop.loop():loop()
