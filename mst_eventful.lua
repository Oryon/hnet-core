#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mst_eventful.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu May  9 12:43:00 2013 mstenber
-- Last modified: Thu May  9 12:51:07 2013 mstenber
-- Edit time:     4 min
--

-- eventful class which provides concept of 'events' (ripped out of
-- real baseclass - it was just overhead there in 99% of objects that
-- did not employ this)

local mst = require 'mst'
local table = require 'table'

local ipairs = ipairs
local pairs = pairs
local type = type

module(...)

-- event class (used within the baseclass)

-- observer design pattern (Gamma et al).

-- the classic description involves subject <> observer classes we
-- call subject event instead - as what we're tracking are function
-- invocations, in practise (the update() call is actually just call
-- of the event object itself)

-- what we provide is __call-wrapped metatables for both.
-- convenience factors:
--  - sanity checking
--  - 1:n, n:1 relationships (normal pattern has only 1:n)

event = mst.create_class{class='event'}

function event:init()
   self.observers = {}
end

function event:uninit()
   self:a(mst.table_is_empty(self.observers), 
          "observers not gone when event is!")
end

function event:add_observer(o)
   self.observers[o] = true
end

function event:remove_observer(o)
   self:a(self.observers[o], 'observer missing', o)
   self.observers[o] = nil
end

function event:update(...)
   for k, _ in pairs(self.observers)
   do
      k(...)
   end
end

-- event instances' __call should map directly to event.update
event.__call = event.update


eventful = mst.create_class{class='eventful'}

function eventful:init()
   -- set up event handlers (if any)
   for i, v in ipairs(self.events or {})
   do
      --print('creating event handler', v)
      self[v] = event:new()
   end
end

function eventful:uninit()
   -- get rid of observers
   -- they're keyed (event={fun, fun..})
   for k, l in pairs(self._observers or {})
   do
      for i, v in ipairs(l)
      do
         k:remove_observer(v)
      end
   end
   self._observers = nil

   -- get rid of events
   for i, v in ipairs(self.events or {})
   do
      local o = self[v]
      self:a(o, "event missing")
      o:done()
      self[v] = nil
   end
end

function eventful:connect(ev, fun)
   self:a(ev, 'null event')
   self:a(fun, 'null fun')
   self:a(type(ev) == 'table', 'event not table', type(ev), ev, fun)

   -- connect event 'ev' to local observer function 'fun'
   -- (and keep the connection up as long as we are)

   -- first, update local _observers
   if not self._observers
   then
      self._observers = {}
   end
   local t = self._observers[ev] or {}
   self._observers[ev] = t
   table.insert(t, fun)

   -- then call the event itself to add the observer
   ev:add_observer(fun)
end

function eventful:connect_method(ev, o, fun)
   self:connect(ev, function (...)
                   fun(o, ...)
                    end)
end

