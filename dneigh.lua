#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dneigh.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Fri Oct 12 14:54:48 2012 mstenber
-- Last modified: Tue Nov 13 15:50:04 2012 mstenber
-- Edit time:     27 min
--

-- structure is:
-- neigh[rid] = 
--  {iid1={rid2=iid2,rid3=iid3,...},..}}


require 'mst'

module(..., package.seeall)

dneigh = mst.create_class{class='dneigh'}

function dneigh:init()
   self.neigh = self.neigh or {}
end

function dneigh:iterate_flat(f)
   -- get list of (rid1, iid1, rid2, iid2) connections
   -- (without duplicates; ensure that rid1 <= rid2, (if ==, iid1<=iid2))
   for rid1, h in pairs(self.neigh)
   do
      for iid1, h2 in pairs(h)
      do
         for rid2, iid2 in pairs(h2)
         do
            self:d(rid1, iid1, rid2, iid2)

            if rid1 < rid2 or (rid1 == rid2 and iid1 <= iid2)
            then
               f(rid1,iid1,rid2,iid2)
            end
         end
      end
   end
end

function dneigh:get_flat_list()
   local t = mst.array:new{}
   self:iterate_flat(function (...)
                        t:insert{...}
                     end)
   return t
end


function dneigh:iterate_iid_neigh(rid, iid, f)
   local all_neigh = self.neigh[rid] or {}
   local if_neigh = all_neigh[iid] or {}
   for rid, iid in pairs(if_neigh)
   do
      f{iid=iid, rid=rid}
   end
end

function dneigh:iterate_ifo_neigh(rid, ifo, f)
   self:iterate_iid_neigh(rid, ifo.index, f)
end

function dneigh:iterate_all_connected_rid(rid, f)
   -- recursively list all nodes that are connected to the node,
   -- including self
   local seen = mst.set:new{}
   function dump(rid)
      seen:insert(rid)
      f(rid)
   end
   function rec(rid)
      for k, v in pairs(self.neigh[rid] or {})
      do
         for rid2, iid2 in pairs(v)
         do
            if not seen[rid2]
            then
               dump(rid2)
               rec(rid2)
            end
         end
      end
   end
   -- start at the rid we have
   dump(rid)
   rec(rid)
end

-- perform single bidirectional connection
function dneigh:raw_handle_neigh_one(r1, i1, r2, i2, f)
   self:a(r1 and i1 and r2 and i2, r1, i1, r2, i2)
   function _goe(h, k)
      if not h[k]
      then
         h[k] = {}
      end
      return h[k]
   end

   function _conn(r1, i1, r2, i2)
      local h = _goe(_goe(self.neigh, r1), i1)
      f(h, r2, i2)
   end
   _conn(r1, i1, r2, i2)
   _conn(r2, i2, r1, i1)
end

function dneigh:connect_neigh_one(r1, i1, r2, i2)
   self:raw_handle_neigh_one(r1, i1, r2, i2, function (h, rid, iid)
                                h[rid] = iid
                                             end)
   self:changed()
end

function dneigh:disconnect_neigh_one(r1, i1, r2, i2)
   self:raw_handle_neigh_one(r1, i1, r2, i2, function (h, rid, iid)
                                h[rid] = nil
                                             end)
   self:changed()
end

-- connect arbitrary # of nodes to each other
function dneigh:connect_neigh(...)
   local l = {...}
   mst.a(#l % 2 == 0, 'odd number of parameters', l)
   local nc = #l / 2
   for i=0, nc-2
   do
      for j=i+1, nc-1
      do
         -- connect these neighbors
         self:connect_neigh_one(l[2*i+1], l[2*i+2],
                                l[2*j+1], l[2*j+2])
         
      end
   end
end

function dneigh:changed()
   -- child responsibility
end
