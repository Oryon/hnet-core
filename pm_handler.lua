#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_handler.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Wed Nov  7 19:33:20 2012 mstenber
-- Last modified: Mon Mar 11 09:23:35 2013 mstenber
-- Edit time:     13 min
--

-- single pm handler prototype

require 'mst'

module(..., package.seeall)

pm_handler = mst.create_class{class='pm_handler', 
                              mandatory={'pm'},
                              events={'changed'}}

function pm_handler:repr_data()
   return '?'
end

function pm_handler:init()
   self.shell = self.pm.shell
   self.file_contents = {}
end

function pm_handler:queue()
   local old = self.queued
   self.queued = true
   return not old
end

function pm_handler:ready()
   return true
end

function pm_handler:maybe_tick()
   if not self.tick
   then
      return
   end
   if not self:ready()
   then
      return
   end
   self:tick()
end

function pm_handler:maybe_run()
   if not self.queued
   then
      --self:d(' not queued')
      return
   end

   -- if not ready, not going to do a thing
   self:d('maybe_run')

   if not self:ready()
   then
      self:d(' not ready')
      return
   end
   self.queued = nil
   local v = self:run()
   if v and v > 0
   then
      self:changed()
   end
end

function pm_handler:run()
   -- REALLY implemented by the children
end

function pm_handler:write_to_file(fpath, t0, comment_prefix)
   local t = mst.array:new()
   local s0 = table.concat(t0, '\n')
   if comment_prefix
   then
      t:insert(comment_prefix)
      t:insert(comment_prefix .. fpath)
      t:insert(comment_prefix .. 
               'automatically generated by ' .. self.class .. 
               ' on ' .. os.date())
      t:insert(comment_prefix)
   end
   t:insert(s0)
   t:insert('')
   local s = t:join('\n')
   if self.file_contents[fpath] == s0
   then
      return
   end
   self.file_contents[fpath] = s0

   local f, err = io.open(fpath, 'w')
   self:a(f, 'unable to open for writing', fpath, err)
   f:write(s)
   -- close the file
   io.close(f)
   return true
end
