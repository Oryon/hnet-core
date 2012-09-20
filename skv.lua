#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: skv.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Tue Sep 18 12:23:19 2012 mstenber
-- Last modified: Thu Sep 20 13:53:17 2012 mstenber
-- Edit time:     151 min
--

require 'mst'
require 'ssloop'
require 'scb'

-- SMC-generated state machine
local sm = require 'skv_sm'

module(..., package.seeall)

skv = mst.create_class{mandatory={"long_lived"}, class="skv"}
skvclient = mst.create_class{mandatory={"s", "parent"}, class="skvclient"}

-- first, skv

skv.__index = skv

local HOST = '127.0.0.1'
local PORT = 12345
local CONNECT_TIMEOUT = 0.1
local INITIAL_LISTEN_TIMEOUT = 0.2

function skv:init()
   self.host = self.host or HOST
   self.port = self.port or PORT
   if self.debug
   then
      --local f = iself.open('x.log', 'w')
      self.fsm = sm:new({owner=self, debugFlag=true})
   else
      self.fsm = sm:new({owner=self})
   end
   self.fsm:enterStartState()
end

-- we're done with the object -> clear state
function skv:done()
   if self.s
   then
      self.s:done()
      self.s = nil
   end
   self:clear_ev()
end

function skv:fail(s)
   self.error = s
   if self.debug
   then
      error(s)
   end
end

function skv:repr()
   return string.format('host:%s port:%d state:%s', 
                        self.host or "?", 
                        self.port or 0, 
                        self.fsm and self.fsm:getState().name or "?")
end

-- Client code

function skv:init_client()
   self.listen_timeout = INITIAL_LISTEN_TIMEOUT
   self.fsm:Initialized()
end

function skv:is_long_lived()
   return self.long_lived
end

function skv:connect()
   self.connected = false
   self:d('skv:connect')
   self.s = scb.new_connect{host=self.host, port=self.port,
                               debug=self.debug,
                               callback=function (c) 
                                  self:d('connect callback')
                                  if c
                                  then
                                     self.connected = true
                                     self.s = c
                                     c.callback = function (r)
                                        self:handle_read(r)
                                     end
                                     c.close_callback = function (s)
                                        self.fsm:ConnectionClosed()
                                     end
                                     self.fsm:Connected()
                                  else
                                     self.s:done()
                                     self.s = nil
                                     self.fsm:ConnectFailed()
                                  end
                               end}
   if not self.connected
   then
      local l = ssloop.loop()
      self.s_t = l:new_timeout_delta(CONNECT_TIMEOUT,
                                     function ()
                                        self:d('!!t1!!')
                                        self.fsm:ConnectFailed()
                                     end):start()
   end
end

function skv:clear_ev()
   -- kill listeners, if any
   local c = 0
   self:d('clear_ev')
   for _, e in ipairs({"s_w", "s_t", "s_r"})
   do
      if self[e]
      then
         self:d(' removing', e, self[e])
         o = self[e]
         o:stop()
         self[e] = nil
         c = c + 1
      end
   end
end

function skv:send_local_updates()
end

function skv:send_listeners()
end

function skv:handle_read(r)
   assert(r and #r)
   -- XXX - do something
end

function skv:set_read_handler()
   -- nop?
end

-- Server code

function skv:init_server()
   self.fsm:Initialized()
   self.connections = {}
end

function skv:bind()
   s, err = scb.new_listener{host=self.host, port=self.port, 
                                debug=self.debug,
                                callback=function (c) 
                                   self:new_client(c)
                                end}
   if s
   then
      self.s = s
      self.fsm:Bound()
      return
   else
      self.fsm:BindFailed()
   end
end

function skv:new_client(s)
   skvclient:new{s=s, parent=self}
end

function skv:increase_retry_timer()
   -- 1.5x every time.. should eventually behave reasonably
   self.listen_timeout = self.listen_timeout * 3 / 2
end

function skv:start_retry_timer()
   local l = ssloop.loop()
   self.s_t = l:new_timeout_delta(CONNECT_TIMEOUT,
                                  function ()
                                     self:d('!!t2!!')
                                     self:clear_ev()
                                     self.fsm:Timeout()
                                  end):start()
end

-- Server's single client side connection handling

function skvclient:init()
   self.is_done = false
   assert(self)
   self.parent.connections[self] = 1
   function self.s.callback(s) 
      self:handle_read(s) 
   end
   function self.s.done_callback(s)
      self:handle_close() 
   end
end

function skvclient:handle_read(s)
   -- to do
end

function skvclient:handle_close()
   self:done()
end

function skvclient:done()
   if not self.is_done
   then
      self.is_done = true
      self:a(self.parent.connections[self] ~= nil, ":done - not in parent table")
      self.parent.connections[self] = nil
      self.s:done()
   end
end
