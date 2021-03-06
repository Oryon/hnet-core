#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_proxy.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Apr 29 18:16:53 2013 mstenber
-- Last modified: Sat Oct 19 01:49:55 2013 mstenber
-- Edit time:     135 min
--

-- This is minimalist DNS proxy implementation.

-- Whole design is written around coroutines, as they make ~low-impact
-- handling of LARGE number of requests possible.

-- The way of handling 'too many' requests is simple; we maintain
-- ordered data structure of events, and have two different strategies
-- available:

-- - drop oldest (requires FIFO data structure with fast seek)
-- - prevent new (just require # in flight number)
-- XXX - choose

-- XXX - see if {tcp,udp}_handler subclasses are even needed. with the
-- channel abstraction, they might not be.

-- Architecturally, 'handler' is responsible for single socket (see
-- diagrams). It provides a way of getting a request, and sending a
-- reply to it. Requests and replies are handled in a loop, and it is
-- assumed that the loop is started as a coroutine using scr
-- framework+reactor.

require 'mst'
require 'scr'
require 'scb'
require 'scbtcp'
require 'dns_channel'

module(..., package.seeall)

handler = mst.create_class{class='handler', mandatory={"c", "tcp"}}

function handler:init()
   self.stopped = true
   self:start()
end

function handler:uninit()
   self:stop()
   -- kill the underlying channel too
   self.c:done()
end

function handler:start()
   if not self.stopped
   then
      return
   end
   self.stopped = nil
   scr.run(self.loop, self)
end

function handler:stop()
   -- loop shouldn't even resume, if things happen correctly, but at
   -- least it should never send a reply any more..
   self.stopped = true
end

function handler:loop()
   while true
   do
      -- subclass responsibility
      local r, err = self:read_request()
      if self.stopped then return end
      if r
      then
         scr.run(self.handle_request, self, r)
      else
         self:d('error reading', err)
         break
      end
   end
   -- kill the object from eventloop etc
   self:done()
end

function handler:handle_request(msg, src)
   self:d('handle_request', msg, src)

   -- call the callback
   local reply = self.process_callback(msg, src, self.tcp)

   if self.stopped then return end
   if reply
   then
      self:d('sending reply', reply)
      self.c:send(reply)
   else
      self:d('error occurred?')
   end
end

function handler:read_request()
   self:d('read_request')
   return self.c:receive()
end

dns_proxy = mst.create_class{class='dns_proxy', 
                             mandatory={'ip', 
                                        'process_callback'},
                            }

function dns_proxy:init()
   -- create UDP channel
   local udp_c = dns_channel.get_udp_channel{ip=self.ip, 
                                             port=self:get_udp_port()}
   if not udp_c
   then
      return
   end
   -- and then associate handler with it
   self.udp = handler:new{c=udp_c, process_callback=self.process_callback, tcp=false}
   self.udp:start()

   
   local tcp_s = scbtcp.create_listener{ip=self.ip,
                                        port=self:get_tcp_port()}
   self.tcp_s = scr.wrap_socket(tcp_s)
   
   -- fire off coroutine; we get rid of it by killing the tcp_s..
   scr.run(function ()
              while true
              do
                 local s = self.tcp_s:accept()
                 local tcp_c = dns_channel.tcp_channel:new{s=s}
                 -- XXX - do we need to keep track of these handlers?
                 -- or just fire and forget?
                 local h = handler:new{c=tcp_c, process_callback=self.process_callback, tcp=true}
                 h:start()
              end
           end)
end

function dns_proxy:get_udp_port()
   return self.udp_port or self.port or dns_const.PORT
end

function dns_proxy:get_tcp_port()
   return self.tcp_port or self.port or dns_const.PORT
end

function dns_proxy:uninit()
   self.udp:done()
   self.tcp_s:done()
end

