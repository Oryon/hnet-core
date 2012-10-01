#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pa.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Mon Oct  1 11:08:04 2012 mstenber
-- Last modified: Mon Oct  1 17:15:42 2012 mstenber
-- Edit time:     204 min
--

-- This is homenet prefix assignment algorithm, written using fairly
-- abstract data structures. The network abstraction object should
-- provide a way of doing the required operations, and should call us
-- whenever it's state changes.

-- client expected to provide:
--  iterate_rid(f) => callback with rid
--  iterate_asp(f) => callback with prefix, iid, rid
--  iterate_usp(f) => callback with prefix, rid
--  iterate_if(f) => callback with iid

require 'mst'

--mst.enable_debug = true

module(..., package.seeall)

-- local assigned prefix

lap = mst.create_class{class='lap', mandatory={'prefix', 'iid', 'parent'}}

function lap:init()
   self.parent.lap:insert(self.iid, self)
   self:assign()
end

function lap:uninit()
   self.parent.lap:remove(self.iid, self)
end

function lap:assign()
   self.assigned = true
   self.depracated = false
   -- XXX
end

function lap:unassign()
   if not self.assigned
   then
      return
   end
   self.assigned = false
   -- XXX
end

function lap:depracate()
   self:unassign()
   self.depracated = true
   -- XXX
end

-- assigned prefix

asp = mst.create_class{class='asp', mandatory={'prefix', 
                                               'iid', 
                                               'rid', 
                                               'parent'}}

function asp:init()
   local added = self.parent.asp:insert(self.rid, self)
   mst.a(added, "already existed?", self)
end

function asp:uninit()
   self:depracate_lap()
   self.parent.asp:remove(self.rid, self)
end

function asp:find_lap()
   local t = self.parent.lap[self.iid]
   for i, v in ipairs(t or {})
   do
      if v.prefix == prefix
      then
         return v
      end
   end
end

function asp:find_or_create_lap()
   local lap = self:find_lap()
   if lap then return lap end
   return lap:new{prefix=self.prefix, iid=self.prefix, parent=self.parent}
end

function asp:assign_lap()
   local lap = self:find_or_create_lap()
   lap:assign()
end

function asp:depracate_lap()
   -- look up locally assigned prefixes (if any)
   local lap = self:find_lap()
   if not lap then return end
   lap:depracate()
end

function asp:is_remote()
   return self.rid == self.parent.client.rid
end

-- usable prefix, can be either local or remote (no behavioral
-- difference though?)
usp = mst.create_class{class='usp', mandatory={'prefix', 'rid', 'parent'}}

function usp:init()
   local added = self.parent.usp:insert(self.rid, self)
   mst.a(added, 'already existed?', self)
end

function usp:uninit()
   self.parent.usp:remove(self.rid, self)
end

pa = mst.create_class{class='pa'}

-- main prefix assignment class

function pa:init()
   -- locally assigned prefixes - iid => list
   self.lap = mst.multimap:new()

   -- rid reachability => true/false (reachable right now)
   self.ridr = mst.map:new()

   -- all asp data, ordered by prefix
   self.asp = mst.multimap:new()

   -- all usp data, ordered by prefix
   self.usp = mst.multimap:new()
end

function pa:filtered_values_done(h, f)
   mst.a(h.class == 'multimap')
   for i, o in ipairs(h:values())
   do
      if f(o) 
      then 
         self:d('done with', o)
         o:done() 
      end
   end
end

function pa:repr_data()
   return string.format('#lap:%d #ridr:%d #asp:%d #usp:%d',
                        #self.lap:values(),
                        #self.ridr:values(),
                        #self.asp:values(),
                        #self.usp:values())
end

-- convert prefix to binary address blob with only relevant bits included
function prefix_to_bin(p)
   local l = mst.string_split(p, '/')
   mst.a(#l == 2, 'invalid prefix', p)
   mst.a(l[2] % 8 == 0, 'bit-based prefix length handling not supported yet')
   local b = mst.ipv6_ascii_to_binary(l[1])
   return string.sub(l[1], 1, l[2] / 8)
end

function prefix_contains(p1, p2)
   mst.a(p1 and p2, 'invalid arguments to prefix_contains', p1, p2)
   local b1 = prefix_to_bin(p1)
   local b2 = prefix_to_bin(p2)
   if #b1 > #b2
   then
      return false
   end
   -- #b1 <= #b2 if p1 contains p2
   return string.sub(b2, 1, #b1) == b1
end

function pa:run_if_usp(iid, usp)
   local rid = self.client.rid

   self:d('run_if_usp', iid, usp.prefix)


   -- Alg from 6.3.. steps noted 
   
   -- 1. if some shorter prefix contains this usp, skip
   for i, v in ipairs(self.usp:values())
   do
      -- XXX - complain that this seems broken
      -- (BCP38 stuff might make it not-so-working?)
      if v.prefix ~= usp.prefix and prefix_contains(v.prefix, usp.prefix)
      then
         self:d('skipped, containing prefix found')
         return
      end
   end

   -- (skip 2. - we don't really care about neighbors)

   -- 3. determine highest rid of already assigned prefix on the link
   local own
   local highest
   
   for i, asp in ipairs(self.asp:values())
   do
      if asp.iid == iid
      then
         if not highest or highest.rid < asp.rid
         then
            highest = asp
         end
         if asp.rid == rid
         then
            own = asp
         end
      end
   end

   -- 4.
   -- (i) - router made assignment, highest router id
   if own and own == highest
   then
      self:check_asp_conflicts(own)
      return
   end
   -- (ii) - assignment by neighbor
   if highest
   then
      self:assign_other(highest)
      return
   end

   -- (iii) no assignment by anyone, highest rid
   -- XXX - deal with 'neighbors on link'
   self:assign_own(iid, usp)

   -- (iv) no assignment by anyone, not highest rid
end

-- 6.3.1
function pa:assign_own(iid, usp)
   -- 1. find already assigned prefixes
   assigned = self:find_assigned(usp)

   -- 2. try to find 'old one'
   -- .. skip ..

   -- 3. assign /64 if possible
   local p = self:find_new_from(usp, assigned)
   local o
   if p
   then
      o = asp:new{prefix=p,
                  parent=self,
                  iid=iid,
                  rid=self.client.rid}
   end
   
   -- 4. hysteresis (sigh)

   -- 5. if none available, skip

   -- 6. if assigned, mark as valid + send AC LSA
   if o
   then
      o.valid = true
      -- originate LSA - how?
   end
end

function pa:find_assigned(usp)
   local t = mst.set:new()
   for i, asp in ipairs(self.asp:values())
   do
      if prefix_contains(usp.prefix, asp.prefix)
      then
         local b = prefix_to_bin(asp.prefix)
         t:insert(b)
         mst.a(#b == 8, "invalid asp length", #b)
      end
   end
   return t
end

function binary_prefix_next_from_usp(up, p)
   mst.a(#p == 8)
   mst.a(#b <= 8)
   if #b == 8
   then
      mst.a(b == p)
      return p
   end
   -- two different cases - either prefix+1 is still within up => ok,
   -- or it's not => start from zeros
   local pb = {string.byte(p, 1, #p)}
   for i=8, 1, -1
   do
      pb[i] = (pb[i] + 1) % 256
      if pb[i]
      then
         break
      end
   end
   local p2 = string.char(unpack(pb))
   if string.sub(p2, 1, #up) == up
   then
      return p2
   end
   return up .. string.rep(string.char(0), 8 - #up)
end

function pa:find_new_from(usp, assigned)
   local b = prefix_to_bin(usp.prefix)
   local p

   self:a(assigned, 'assigned missing')
   mst.a(b)
   for i=1,10
   do
      p = b
      while #p < 8
      do
         p = p .. string.char(math.floor(256 * math.random()) % 256)
      end
      mst.a(#p == 8)
      if not assigned[p]
      then
         return mst.ipv6_binary_to_ascii(p) .. '/64'
      end
   end

   -- use the last prefix as base, iterate through the whole usable prefix
   local sp = p
   while true
   do
      p = binary_prefix_next_from_usp(b, p)
      mst.a(#p == 8, "binary_prefix_next_from_usp bugs?")

      if not assigned[p]
      then
         return mst.ipv6_binary_to_ascii(p) .. '/64'
      end

      -- prefix is full if we're back at start
      if sp == b
      then
         return
      end
   end
end

-- 6.3.2
function pa:check_asp_conflicts(asp)
   for i, asp2 in ipairs(self.asp:values())
   do
      -- if conflict, with overriding rid is found, depracate prefix
      if asp2.prefix == asp.prefix and asp2.rid > asp.rid
      then
         -- as described in 6.3.3
         asp:depracate()
         return
      end
   end
   -- otherise mark it as valid
   asp.valid = true
end

-- 6.3.4
function pa:assign_other(asp)
   -- if we get here, it's valid asp.. just question of what we need
   -- to do with lap
   asp.valid = true

   -- consider if we already have it
   for i, v in ipairs(self.lap[asp.iid] or {})
   do
      -- we do!
      if v.prefix == asp.prefix
      then
         v.valid = true
         return
      end
   end

   -- nope, not assigned - do so now

   -- Note: the verbiage about locally converted interfaces etc seems
   -- excessively strict in the draft.
   asp:assign_lap()
end

function pa:run()
   self:d('run called')

   client = self.client
   mst.a(client, 'no client')

   -- mark existing data invalid
   self.lap:foreach(function (ii, o) o.valid = false end)
   self.asp:foreach(function (ii, o) o.valid = false end)
   self.usp:foreach(function (ii, o) o.valid = false end)
   self.ridr:keys():map(function (k) self.ridr[k]=false end)

   -- get the rid reachability
   client:iterate_rid(function (rid)
                         self:d('got rid', rid)
                         self.ridr[rid] = true
                      end)

   -- get the usable prefixes from the 'client' [prefix => rid]
   client:iterate_usp(function (prefix, rid)
                         self:d('got usp', prefix, rid)
                         self:add_or_update_usp(prefix, rid)
                      end)

   -- drop those that are not valid immediately
   self:filtered_values_done(self.usp,
                             function (usp) return not usp.valid end)
   
   -- get the (remotely) assigned prefixes
   client:iterate_asp(function (prefix, iid, rid)
                         self:d('got asp', prefix, iid, rid)
                         self:add_or_update_asp(prefix, iid, rid)
                      end)

   -- drop those that are not valid immediately
   self:filtered_values_done(self.asp,
                             function (asp) 
                                mst.a(asp.class == 'asp', asp, asp.class)
                                return asp:is_remote() and not asp.valid 
                             end)

   -- run the prefix assignment
   client:iterate_if(function (iid)
                        for i, usp in ipairs(self.usp:values())
                        do
                           mst.a(usp.class == 'usp', usp, usp.class)
                           self:run_if_usp(iid, usp)
                        end
                     end)

   -- handle the expired local assignments
   self:filtered_values_done(self.asp,
                             function (asp) 
                                return not asp:is_remote() and not asp.valid 
                             end)
   self:d('run done')

end

function pa:add_or_update_usp(prefix, rid)
   self:a(self.ridr[rid], 'sanity-check failed - rid not reachable', rid)
   local o = self.usp[prefix]
   -- just mark it valid?
   if o
   then
      o.valid = true
      return
   end
   usp:new{prefix=prefix, rid=rid, parent=self, valid=true}
end

function pa:get_asp(prefix, iid, rid)
   for i, o in ipairs(self.asp[rid] or {})
   do
      if o.prefix == prefix and o.iid == iid
      then
         return o
      end
   end
end

function pa:add_or_update_asp(prefix, iid, rid)
   self:a(self.ridr[rid], 'sanity-check failed - rid not reachable', rid)
   local o = self:get_asp(prefix, iid, rid)
   if o
   then
      -- mark it valid if it's remote
      if o:is_remote()
      then
         o.valid = true
      end
      return
   end
   asp:new{prefix=prefix, iid=iid, rid=rid, parent=self, valid=true}
end
