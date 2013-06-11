#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: elsa_pa.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Wed Oct  3 11:47:19 2012 mstenber
-- Last modified: Tue Jun 11 12:15:21 2013 mstenber
-- Edit time:     840 min
--

-- the main logic around with prefix assignment within e.g. BIRD works
-- 
-- elsa_pa is given skv instance, elsa instance, and should roll on
-- it's way.
--
-- the main difference is that this code assumes that there are LSAs;
-- pa code just deals with rid, asp, usp, if abstractions

-- #define LSA_T_AC        0xBFF0 /* Auto-Configuration LSA */
--  /* function code 8176(0x1FF0): experimental, U-bit=1, Area Scope */

-- TODO - document the API between elsa (wrapper), elsa_pa

-- => lsa_changed(lsa)
-- => lsa_deleting(lsa)
-- <= ???

require 'mst'
require 'mst_skiplist'
require 'ospf_codec'
require 'ssloop'

local pa = require 'pa'

module(..., package.seeall)

-- LSA type used for storing the auto-configuration LSA
-- Benjamin
--AC_TYPE=0xBFF0

-- 0xAC0F Jari
AC_TYPE=0xAC0F

FORCE_SKV_AC_CHECK_INTERVAL=60

-- New scheme for encoding the received PD/6RD/DHCPv4 in the SKV is as
-- follows:

-- <source>.<ifname> = { {key1=value1, key2=value2}, {key3=value3, key4=value4, ..} }

PD_SKVPREFIX='pd.'
DHCPV4_SKVPREFIX='dhcp.'
TUNNEL_SKVPREFIX='tunnel.'

-- these keys are used within the objects to describe found information
PREFIX_KEY='prefix'
DNS_KEY='dns'
DNS_SEARCH_KEY='dns_search'
NH_KEY='nh'
IFLIST_KEY='iflist' -- allow overriding of active interfaces for source type

-- extra info fields not used directly, but used in e.g. pm handlers
PREFIX_CLASS_KEY='pclass'
PREFERRED_KEY='pref' -- both of these are absolute timestamps
VALID_KEY='valid'

-- list of keys which are passed verbatim from 
-- IF-specific prefix SKV [=> JSON_USP_INFO_KEY] => LAP/USP SKV lists
PREFIX_INFO_SKV_KEYS={PREFIX_CLASS_KEY}

-- locally as-is passed fields
PREFIX_INFO_LOCAL_SKV_KEYS={PREFERRED_KEY, VALID_KEY}

-- used to indicate that interface shouldn't be assigned to (nor used
-- in general - this includes starting any daemon on it)
DISABLE_SKVPREFIX='disable.'

-- used to indicate that no IPv4 prefix assignment on the interface
DISABLE_V4_SKVPREFIX='disable-pa-v4.'

-- SKV 'singleton' keys
OSPF_RID_KEY='ospf-rid' -- OSPF router ID
OSPF_LAP_KEY='ospf-lap' -- PA alg locally assigned prefixes
OSPF_USP_KEY='ospf-usp' -- usable prefixes from PA alg
OSPF_ASP_KEY='ospf-asp' -- assigned prefixes from PA alg
OSPF_ASA_KEY='ospf-asa' -- assigned addresses from PA alg
OSPF_RNAME_KEY='ospf-rname' -- rid -> rname mapping
OSPF_IFLIST_KEY='ospf-iflist' -- active set of interfaces
-- IPv6 DNS 
OSPF_DNS_KEY='ospf-dns' 
OSPF_DNS_SEARCH_KEY='ospf-dns-search'
-- IPv4 DNS 
OSPF_IPV4_DNS_KEY='ospf-v4-dns'
OSPF_IPV4_DNS_SEARCH_KEY='ospf-v4-dns-search'
-- locally owned (owner) interfaces' cache rr data
MDNS_OWN_SKV_KEY='mdns'
-- other nodes' cache data skv key
MDNS_OSPF_SKV_KEY='ospf-mdns'

-- allow for configuration of prefix assignment algorithm
-- via skv too
PA_CONFIG_SKV_KEY='pa-config'

-- JSON fields within jsonblob AC TLV
JSON_ASA_KEY='asa'
JSON_DNS_KEY='dns'
JSON_DNS_SEARCH_KEY='dns-search'
JSON_IPV4_DNS_KEY='ipv4-dns'
JSON_IPV4_DNS_SEARCH_KEY='ipv4-dns-search'
JSON_RNAME_KEY='rname'

-- local mdns rr cache
JSON_MDNS_KEY='mdns'
-- extra USP information
JSON_USP_INFO_KEY='usp-info'

-- from the draft; time from boot to wait iff no other routers around
-- before starting new assignments
NEW_PREFIX_ASSIGNMENT=20

-- from the draft; time from boot to wait iff no other routers around
-- before generating ULA
NEW_ULA_PREFIX=20

-- =~ TERMINATE_PREFIX_ASSIGNMENT in the draft
LAP_DEPRACATE_TIMEOUT=240

-- not in the draft; the amount we keep deprecated prefixes around (to
-- e.g. advertise via radvd with zero prefix lifetime, and to reuse
-- first if need be)
LAP_EXPIRE_TIMEOUT=300

ORIGINATE_MIN_INTERVAL=4 -- up to this point, we hold on spamming
ORIGINATE_MAX_INTERVAL=300 -- even without changes

-- TODO - TERMINATE_ULA_PREFIX timeout is a 'SHOULD', but we ignore it
-- for simplicity's sake; getting rid of floating prefixes ASAP is
-- probably good thing (and the individual interface-assigned prefixes
-- will be depracated => will disappear soon anyway)

-- elsa specific lap subclass
elsa_lap = pa.lap:new_subclass{class='elsa_lap',
                              }

local json_sources={[JSON_DNS_KEY]={prefix=PD_SKVPREFIX, 
                                    key=DNS_KEY, 
                                    ospf=OSPF_DNS_KEY},
                    [JSON_DNS_SEARCH_KEY]={prefix=PD_SKVPREFIX, 
                                           key=DNS_SEARCH_KEY, 
                                           ospf=OSPF_DNS_SEARCH_KEY},

                    [JSON_IPV4_DNS_KEY]={prefix=DHCPV4_SKVPREFIX,
                                         key=DNS_KEY, 
                                         ospf=OSPF_IPV4_DNS_KEY},
                    [JSON_IPV4_DNS_SEARCH_KEY]={prefix=DHCPV4_SKVPREFIX,
                                                key=DNS_SEARCH_KEY, 
                                                ospf=OSPF_IPV4_DNS_SEARCH_KEY},
}


function elsa_lap:start_depracate_timeout()
   self:d('start_depracate_timeout')
   self:a(not self.timeout)
   self.timeout = self.pa.time() + LAP_DEPRACATE_TIMEOUT
   self.pa.timeouts:insert(self)
end

function elsa_lap:stop_depracate_timeout()
   self:d('stop_depracate_timeout')
   self:a(self.timeout)
   self.pa.timeouts:remove_if_present(self)
   self.timeout = nil
end

function elsa_lap:start_expire_timeout()
   self:d('start_expire_timeout')
   self:a(not self.timeout)
   self.timeout = self.pa.time() + LAP_EXPIRE_TIMEOUT
   self.pa.timeouts:insert(self)
end

function elsa_lap:stop_expire_timeout()
   self:d('stop_expire_timeout')
   self:a(self.timeout)
   self.pa.timeouts:remove_if_present(self)
   self.timeout = nil
end


-- actual elsa_pa itself, which controls pa (and interfaces with
-- skv/elsa-wrapper
elsa_pa = mst.create_class{class='elsa_pa', 
                           mandatory={'skv', 'elsa'},
                           time=ssloop.time,
                           originate_min_interval=ORIGINATE_MIN_INTERVAL,
                          }

function elsa_pa:init()
   -- set of _all_ interface names we've _ever_ seen (used for
   -- checking SKV for tidbits). initialized only here so that it
   -- won't be screwed if pa reconfigure is called.

   self.all_seen_if_names = mst.set:new{}

   self.f = function (k, v) self:kv_changed(k, v) end
   self.skv:add_change_observer(self.f)

   -- overridable fields either using arguments to this class,
   -- or using the 'o' dict (priority-wise, o > class > defaults)
   local args = {new_prefix_assignment=NEW_PREFIX_ASSIGNMENT,
                 new_ula_prefix=NEW_ULA_PREFIX,
   }

   -- check if class has updates on any of the keys..
   for k, v in pairs(args)
   do
      local v2 = self[k]
      if v2
      then
         args[k] = v2
      end
   end

   self.pa_args = args

   self:reconfigure_pa()
end

function elsa_pa:reconfigure_pa(o)
   self:init_own()
   self:init_pa(o)
end

function elsa_pa:init_own()
   -- set various things to their default values
   self.ac_changes = 1
   self.lsa_changes = 1

   -- when did we consider originate/publish last
   self.last_publish = 0

   -- when did we last actually originate AC LSA
   self.last_originate = 0
   -- and what did it contain?
   self.last_body = ''
end

function elsa_pa:init_pa(o)
   local args = mst.table_copy(self.pa_args)
   
   -- copy over rid
   args.rid=self.rid

   -- then, use 'o' to override those
   if o
   then
      mst.table_copy(o, args)
   end

   -- these are always hardcoded - nobody should be able to change them
   args.client = self
   args.lap_class = elsa_lap
   args.time = self.time

   -- create the actual abstract prefix algorithm object we wrap
   -- (create shallow copy of args, so that we don't wind up re-using
   -- the object)
   self.pa = pa.pa:new(mst.table_copy(args))
   function timeout_is_less(o1, o2)
      return o1.timeout < o2.timeout
   end
   self.pa.timeouts = mst_skiplist.ipi_skiplist:new{p=2,
                                                    lt=timeout_is_less}
end

function elsa_pa:uninit()
   self.skv:remove_change_observer(self.f)

   -- we don't 'own' skv or 'elsa', so we don't do anything here,
   -- except clean up our own state, which is basically the pa object
   self.pa:done()
end

function elsa_pa:kv_changed(k, v)
   -- handle configuration changes explicitly here
   if k == PA_CONFIG_SKV_KEY
   then
      self:reconfigure_pa(v)
      return
   end
   -- implicitly add the tunnel interfaces to the all_seen_if_names
   -- (someone plays with stuff that starts with TUNNEL_SKVPREFIX ->
   -- stuff happens)
   local r = mst.string_startswith(k, TUNNEL_SKVPREFIX)
   if r
   then
      if r ~= IFLIST_KEY
      then
         self.all_seen_if_names:insert(r)
      end
   end

   -- invalidate caches that have if info
   self.skvp = nil
   self.ext_set = nil
end

function elsa_pa:lsa_changed(lsa)
   local lsatype = lsa.type
   if lsa.rid == self.rid
   then
      -- ignore us, if BIRD calls us about it.. we don't
      -- 'see' our own changes
      return
   end
   if lsatype == AC_TYPE
   then
      self:d('ac lsa changed at', lsa.rid)
      self.ac_changes = self.ac_changes + 1
   else
      self:d('other lsa changed at', lsa.rid, lsatype)
      self.lsa_changes = self.lsa_changes + 1
   end
end

function elsa_pa:lsa_deleting(lsa)
   -- for the time being, we don't note a difference between the two
   self:lsa_changed(lsa)
end

function elsa_pa:ospf_changed()
   -- emulate to get the old behavior.. shouldn't be called!
   self:d('deprecated ospf_changed called')
   self.ac_changes = self.ac_changes + 1
   self.lsa_changes = self.lsa_changes + 1
end

function elsa_pa:repr_data()
   return '-'
end

function elsa_pa:get_rname_base()
   local n = mst.read_filename_to_string('/proc/sys/kernel/hostname') or 'r'
   n = mst.string_strip(n)
   self:d('get_rname_base', n)
   return n
end

function elsa_pa:get_hwf(rid)
   rid = rid or self.rid
   local hwf = self.elsa:get_hwf(rid)
   mst.a(hwf)
   return hwf
end

function elsa_pa:get_padded_hwf(rid)
   local hwf = self:get_hwf(rid)
   mst.a(hwf, 'unable to get hwf')
   local d = ospf_codec.MINIMUM_AC_TLV_RHF_LENGTH
   if #hwf < d
   then
      hwf = hwf .. string.rep('1', d - #hwf)
   end
   mst.a(#hwf >= d)
   return hwf
end

function elsa_pa:check_conflict(bonus_lsa)
   local my_hwf = self:get_padded_hwf()
   local other_hwf = nil
   local lsas = 0
   local tlvs = 0
   function consider_lsa(lsa)
      lsas = lsas + 1
      if lsa.rid ~= self.rid then return end
      local found = nil
      for i, tlv in ipairs(ospf_codec.decode_ac_tlvs(lsa.body))
      do
         tlvs = tlvs + 1
         if tlv.type == ospf_codec.AC_TLV_RHF
         then
            found = tlv.body
         end
      end
      if found and found ~= my_hwf
      then
         other_hwf = found
      end
   end

   if bonus_lsa then consider_lsa(bonus_lsa) end
   self:iterate_ac_lsa(consider_lsa)

   self:d('check_conflict considered', lsas, tlvs)
   if not other_hwf then return end
   self:d('found conflict', my_hwf, other_hwf)

   -- we have conflict; depending on what the hwf looks like,
   -- we either have to change our rid.. or not.

   -- if our hwf is greater, we don't need to change, but the other does
   if my_hwf > other_hwf
   then
      self:d('we have precedence, wait for other to renumber')

      return
   end

   self:d('trying to change local rid, as we lack precedence')


   -- uh oh, our hwf < other hwf -> have to change
   self.elsa:change_rid(self.rid)

   self.ac_changes = 0
   self.lsa_changes = 0

   self.had_conflict = true

   return true
end

-- API to check from outside if run() should be called yet (strict
-- test runner won't call it unless it has to; however, in case of
-- elsa stuff, we typically call it in tick() functions or so so this
-- is mostly useful for unit testing)
function elsa_pa:should_run()
   local lap = self.pa.timeouts:get_first()
   if lap and lap.timeout <= self.time() then return true end
   if self.ac_changes > 0 or self.pa:should_run()
   then
      return true
   end
   local s = self:get_mutable_state()
   return self:should_publish{s=s,
                              ac_changes=self.ac_changes, 
                              lsa_changes=self.lsa_changes}
end

function elsa_pa:next_time()
   if self:should_run()
   then
      return 0
   end
   -- there are two cases:
   -- - either delayed publish (self.last_publish == 0)
   -- or
   -- - timeout
   local lap = self.pa.timeouts:get_first()
   local nt
   if lap then nt = lap.timeout end
   if self.last_publish == 0
   then
      local next = self.last_originate + self.originate_min_interval
      if not nt or nt > next
      then
         nt = next
      end
   end
   return nt
end



function elsa_pa:should_publish(d)
   local r
   -- if pa.run() said there's changes, yep, we should
   if d.r 
   then 
      self:d('should publish due to d.r')
      r = true 
   end

   -- if the publish state representation has changed, we should
   if d.s and d.s ~= self.s 
   then 
      self:d('should publish state due to state repr change')
      r = true
   end
   
   -- if ac or lsa changed, we should
   if d.ac_changes and d.ac_changes > 0 
   then 
      self:d('should publish state due to ac_changes > 0')
      r = true
   end
   if d.lsa_changes and d.lsa_changes > 0 
   then 
      self:d('should publish state due to lsa_changes > 0')
      r = true
   end
   
   -- finally, if the FORCE_SKV_AC_CHECK_INTERVAL was passed, we do
   -- this (but this is paranoia, shouldn't be necessary)
   if  (self.time() - self.last_publish) > FORCE_SKV_AC_CHECK_INTERVAL 
   then 
      self:d(' should publish state due to FORCE_SKV_AC_CHECK_INTERVAL exceeded', self.time(), self.last_publish)

      r = true
   end

   if r
   then
      local now = self.time()
      local delta = now - self.last_originate
      -- don't spam, but ensure we publish as soon as interval is done
      -- by setting the last_publish to 0
      if delta < self.originate_min_interval
      then
         if self.last_publish and self.last_publish > 0
         then
            self:d(' .. but avoidin publish due to spam limitations')
            self.last_publish = 0
         end
         r = false
      end
   end



   return r
end

function elsa_pa:get_mutable_state()
   local s = table.concat{mst.repr{self.pa.ridr}, 
                          self.skvp_repr,
                          mst.repr(self.skv:get(MDNS_OWN_SKV_KEY))}
   s = mst.create_hash_if_fast(s)
   return s
end

function elsa_pa:run()
   self:d('run starting')

   local now = self.time()
   while true
   do
      local lap = self.pa.timeouts:get_first()
      if not lap or lap.timeout > now then break end
      -- run the timeout (should remove itself, hopefully?)
      lap.sm:Timeout()
   end

   -- let's check first that there is no conflict; that is,
   -- nobody else with different hw fingerprint, but same rid
   --
   -- if someone like that exists, either we (or they) have to change
   -- their router id..
   if self.ac_changes == 0 
   then
      if self.had_conflict
      then
         self:d('had conflict, no changes => still have conflict')
         return
      end
   else
      if self:check_conflict() then return end
   end
   
   local ac_changes = self.ac_changes
   local lsa_changes = self.lsa_changes
   self.ac_changes = 0
   self.lsa_changes = 0

   -- our rid may have changed -> change that of the pa too, just in case
   self.pa.rid = self.rid

   -- consider if either ospf change occured (we got callback), pa
   -- itself is in turbulent state, or the if state changed
   local r
   if self.pa:should_run() or ac_changes > 0
   then
      r = self.pa:run{checked_should=true}
      self:d('pa.run result', r)
   end

   local now = self.time()

   local s = self:get_mutable_state()

   if self:should_publish{s=s, r=r, ac_changes=ac_changes, lsa_changes=lsa_changes}
   then
      self.last_publish = self.time()
      
      self:d('run doing skv/lsa update',  r)

      -- store the current local state
      self.s = s

      self:run_handle_new_lsa()

      self:run_handle_skv_publish()
   end
   self:d('run done')
end

function elsa_pa:run_handle_new_lsa()
   -- originate LSA (or try to, there's duplicate prevention, or should be)
   local body = self:generate_ac_lsa(false)
   mst.a(body and #body, 'empty generated LSA?!?')
   local now = self.time()

   -- send duplicate if and only if we haven't sent anything in a long
   -- while
   if body == self.last_body
   then
      local delta = now - self.last_originate
      if delta < ORIGINATE_MAX_INTERVAL
      then
         return
      end
   end
   -- store the old 'reference' body for further use
   -- (the new body is generated with relative timestamps, and is _always_
   -- different, so not worth storing..)
   self.last_body = body
   
   local body = self:generate_ac_lsa(true)

   self:d('originating ac lsa for real')

   self.last_originate = now

   self.elsa:originate_lsa{type=AC_TYPE, 
                           rid=self.rid,
                           body=body}

end

local function non_empty(x)
   if not x then return end
   local t = type(x)
   if t == 'number' then return x end
   mst.a(t == 'string', 'non-string', t, x)
   if #x == 0 then return end
   return x
end

function relative_to_absolute(v, o_lsa, now)
   mst.a(now, 'no now')
   if not v then return end
   v = v + now - (o_lsa and o_lsa.age or 0)
   return math.floor(v)
end

function absolute_to_relative(v, now)
   mst.a(now, 'no now')
   if not v then return end
   v = v - now
   return math.floor(v)
end

function elsa_pa:copy_prefix_info_to_o(prefix, dst)
   self:a(type(prefix) == 'string', 'non-string prefix', prefix)
   self:d('copy_prefix_info_to_o', prefix)

   -- given ascii USP prefix p, we have to find the 'extra'
   -- information about it, and dump it to object o

   -- two options: 
   -- - local skv prefix
   -- - 'some' jsonblob AC TLV with the information we want
   local o
   local o_lsa
   self:iterate_skv_prefix(function (p)
                              if p.prefix == prefix
                              then
                                 o = p
                                 self:d('found from local', o)
                              end
                           end)
   if not o
   then

      -- backup plan - look for JSONBLOB with corresponding
      -- JSON_USP_INFO_KEY and prefix key
      self:iterate_ac_lsa_tlv(function (json, lsa)
                                 local t = json.table
                                 local h = t[JSON_USP_INFO_KEY]
                                 self:d('considering', t)

                                 if not h then return end
                                 local v = h[prefix]
                                 if v
                                 then
                                    o = v
                                    o_lsa = o
                                    self:d('found from remote', o)
                                 end
                              end, {type=ospf_codec.AC_TLV_JSONBLOB})
   end
   if not o then return end
   for _, key in ipairs(PREFIX_INFO_SKV_KEYS)
   do
      dst[key] = o[key]
   end
   if not o_lsa
   then
      -- this is local information, copy it verbatim
      for _, key in ipairs(PREFIX_INFO_LOCAL_SKV_KEYS)
      do
         dst[key] = o[key]
      end
   else
      -- we have an LSA => it's remote one.  for the time being, we
      -- mainly deal with timestamps, which should be _relative_ in
      -- OSPF, but _locally_ they're absolute. convert them at this
      -- point in time.
      local now = self.time()
      dst[PREFERRED_KEY] = relative_to_absolute(o[PREFERRED_KEY], o_lsa, now)
      dst[VALID_KEY] = relative_to_absolute(o[VALID_KEY], o_lsa, now)
   end
end

function elsa_pa:find_usp_for_ascii_prefix(p, iid)
   local asp = self.pa:get_asp(p, iid, self.rid)
   if asp and asp.usp
   then
      return asp.usp
   end

   -- failure.. look at all usp's instead, and see which one this
   -- prefix belongs to (this is brute-force, but oh well)
   local o
   p = ipv6s.new_prefix_from_ascii(p)
   self.pa.usp:foreach(function (rid, usp)
                          self:a(usp.prefix, 'no prefix?', usp)
                          if usp.prefix:contains(p)
                          then
                             o = usp
                          end
                       end)
   return o
end

function elsa_pa:run_handle_skv_publish()
   -- store the rid to SKV too
   self.skv:set(OSPF_RID_KEY, self.rid)

   -- set up the locally assigned prefix field
   local t = mst.array:new()
   local dumped_if_ipv4 = {}
   for i, lap in ipairs(self.pa.lap:values())
   do
      local iid = lap.iid
      local ifo = self.pa.ifs[iid]
      if not ifo
      then
         self:d('zombie interface', lap)
         ifo = {}
      end
      if lap.address
      then
         self:a(not dumped_if_ipv4[lap.ifname],
                'system state somehow screwed up [>1 v4 address per if] ',
                self.pa.usp, self.pa.asp, self.pa.lap)
         dumped_if_ipv4[lap.ifname] = true
      end
      local p = lap.ascii_prefix
      local o = {ifname=lap.ifname, 
                 prefix=p,
                 iid=iid,
                 depracate=lap.depracated and 1 or nil,
                 owner=lap.owner,
                 address=lap.address and lap.address:get_ascii() or nil,
                 external=ifo.external,
      } 
      local usp = self:find_usp_for_ascii_prefix(p, iid)
      if usp
      then
         local p2 = usp.ascii_prefix
         self:a(p2, 'no ascii_prefix in usp')
         self:copy_prefix_info_to_o(p2, o)
      else
         self:d('no usp?', lap)
      end
      t:insert(o)
   end
   self.skv:set(OSPF_LAP_KEY, t)

   -- set up the interface list
   local t = mst.array:new{}
   for iid, ifo in pairs(self.pa.ifs)
   do
      -- if it's disabled interface, don't let pm know about it either
      if not ifo.disable
      then
         t:insert(ifo.name)
      end
   end
   self.skv:set(OSPF_IFLIST_KEY, t)

   -- handle assorted 'gather info across the net' fields
   for jsonkey, o in pairs(json_sources)
   do
      local l = self:get_local_field_array(o.prefix, o.key)
      self.skv:set(o.ospf, self:get_field_array(jsonkey, l))
   end

   -- copy over mdns records, if any
   local l = self:get_field_array(JSON_MDNS_KEY, nil, mst.array)
   self.skv:set(MDNS_OSPF_SKV_KEY, l)

   -- toss in the usp's too
   local t = mst.array:new{}
   local dumped = mst.set:new{}

   self:d('creating usp list')
   for i, usp in ipairs(self.pa.usp:values())
   do
      local rid = usp.rid
      local p = usp.ascii_prefix
      if not dumped[p]
      then
         self:d(' usp', p)
         dumped:insert(p)
         local o = {prefix=p, rid=rid}
         if usp.prefix:is_ula() or usp.prefix:is_ipv4()
         then
            -- no route info for ula/ipv4 prefixes
         else
            -- look up the local SKV prefix if available
            -- (pa code doesn't pass-through whole objects, intentionally)
            local skvp = self:get_skvp()
            local n = skvp[p]
            if not n or not n.ifname
            then
               n = self:route_to_rid(rid) or {}
            end
            o.nh = non_empty(n.nh)
            o.ifname = n.ifname
         end
         self:copy_prefix_info_to_o(p, o)
         t:insert(o)
      end
   end
   self.skv:set(OSPF_USP_KEY, t)

   -- toss in the asp's too
   local t = mst.array:new{}

   self:d('creating asp list')
   for i, asp in ipairs(self.pa.asp:values())
   do
      t:insert{iid=asp.iid, rid=asp.rid, prefix=asp.ascii_prefix}
   end
   self.skv:set(OSPF_ASP_KEY, t)

   -- and ASA (just as-is)
   self.skv:set(OSPF_ASA_KEY, self:get_asa_array())

   -- rid->rname map
   self.skv:set(OSPF_RNAME_KEY, self:get_json_map(JSON_RNAME_KEY, self.pa.rname))
end

function elsa_pa:iterate_ac_lsa(f, criteria)
   criteria = criteria or {}

   -- make sure this object isn't being reused - 
   -- we intentionally minimize number of copies, but if there
   -- is type selector already, this is a second call with same table
   -- (and potentially problematic)
   mst.a(not criteria.type)

   criteria.type = AC_TYPE
   self.elsa:iterate_lsa(self.rid, f, criteria)
end

function elsa_pa:iterate_ac_lsa_tlv(f, criteria)
   function inner_f(lsa) 
      -- don't bother with own rid
      if lsa.rid == self.rid
      then
         return
      end
      xpcall(function ()
                for i, tlv in ipairs(ospf_codec.decode_ac_tlvs(lsa.body))
                do
                   if not criteria or mst.table_contains(tlv, criteria)
                   then
                      f(tlv, lsa)
                   end
                end
             end,
             function (...)
                if mst.enable_debug
                then
                   print(debug.traceback())
                   mst.debug_print('!!! lsa body handling failed', ...)
                   mst.debug_print('invalid lsa in hex', lsa.rid, lsa.type, mst.string_to_hex(lsa.body))
                end
             end)
   end
   self:iterate_ac_lsa(inner_f)
end

-- get route to the rid, if any
function elsa_pa:route_to_rid(rid)
   local r = self.elsa:route_to_rid(self.rid, rid) or {}
   return r
end

--  iterate_rid(rid, f) => callback with rid
function elsa_pa:iterate_rid(rid, f)
   -- get a map of rid => rname
   local rid2rname = self:get_json_map(JSON_RNAME_KEY)

   -- we're always reachable (duh), but no next-hop/if
   f{rid=rid, rname=self.pa.rname}

   -- the rest, we look at LSADB 
   self:iterate_ac_lsa(function (lsa) 
                          f{rid=lsa.rid, rname=rid2rname[lsa.rid]}
                       end)
end

--  iterate_asp(rid, f) => callback with prefix, iid, rid
function elsa_pa:iterate_asp(rid, f)
   self:iterate_ac_lsa_tlv(function (asp, lsa) 
                              self:a(lsa and asp)
                              self:a(rid ~= lsa.rid, 'own asp in iterate?')
                              f{prefix=asp.prefix, iid=asp.iid, rid=lsa.rid}
                           end, {type=ospf_codec.AC_TLV_ASP})
end

--  iterate_asa(rid, f) => callback with {prefix=, rid=}
function elsa_pa:iterate_asa(rid, f)
   for i, o in ipairs(self:get_asa_array())
   do
      f{rid=o.rid, prefix=ipv6s.new_prefix_from_ascii(o.prefix)}
   end
end

--  iterate_usp(rid, f) => callback with prefix, rid
function elsa_pa:iterate_usp(rid, f)
   self:iterate_skv_prefix(function (o)
                              f{prefix=o.prefix, 
                                --ifname=o.ifname,
                                --nh=o.nh,
                                rid=rid, 
                               }
                           end)
   self:iterate_ac_lsa_tlv(function (usp, lsa)
                              -- for our own rid, we 
                              -- should get the data from SKV, 
                              -- not LSAs
                              self:a(lsa and usp)
                              self:a(rid ~= lsa.rid, 'own asp in iterate?')
                              f{prefix=usp.prefix, rid=lsa.rid}
                           end, {type=ospf_codec.AC_TLV_USP})
end

function elsa_pa:get_external_ifname_set()
   self:d('get_external_ifname_set')
   if not self.ext_set
   then
      local ext_set = mst.set:new{}
      -- determine the interfaces for which we don't want to provide
      -- interface callback (if we're using local interface-sourced
      -- delegated prefix, we don't want to offer anything there)
      self:iterate_skv_prefix(function (o)
                                 local ifname = o.ifname
                                 self:d('in use ifname', ifname)
                                 ext_set:insert(ifname)
                              end)
      self.ext_set = ext_set
   end
   return self.ext_set
end

function elsa_pa:add_seen_if(ifname)
   if self.all_seen_if_names[ifname]
   then
      return
   end
   self.all_seen_if_names:insert(ifname)

   -- invalidate caches that have if info
   self.skvp = nil
   self.ext_set = nil
end

--  iterate_if(rid, f) => callback with ifo
function elsa_pa:iterate_if(rid, f)
   self:d('called iterate_if')
   self.elsa:iterate_if(rid, function (ifo)
                           self:a(ifo)
                           self:add_seen_if(ifo.name)
                           local ext_set = self:get_external_ifname_set()
                           if ext_set[ifo.name]
                           then
                              ifo.external = true
                              --mst.d('marking ext')
                           end
                           -- set up the static variable on the ifo
                           ifo.disable = self.skv:get(DISABLE_SKVPREFIX .. ifo.name)
                           ifo.disable_v4 = self.skv:get(DISABLE_V4_SKVPREFIX .. ifo.name)
                           f(ifo)
                             end)
end

--   iterate_ifo_neigh(rid, if-object, f) => callback with iid, rid
function elsa_pa:iterate_ifo_neigh(rid, ifo, f)
   -- just forward for the time being
   self.elsa:iterate_ifo_neigh(rid, ifo, f)
end


function elsa_pa:iterate_skv_prefix(f)
   local skvp = self:get_skvp()
   for k, v in pairs(skvp)
   do
      f(v)
   end
end

function elsa_pa:get_skvp()
   if not self.skvp
   then
      self.skvp = mst.map:new()
      self:iterate_all_skv_prefixes(function (p)
                                       self.skvp[p.prefix] = p
                                    end)
      self.skvp_repr = mst.repr(self.skvp)
   end
   return self.skvp
end

function elsa_pa:iterate_all_skv_prefixes(f)
   function create_metric_callback(metric)
      function g(o, ifname)
         -- enter to the fallback lottery - the interface set we check
         -- should NOT decrease in size
         self.all_seen_if_names:insert(ifname)
         
         -- old prefixes don't exist
         --if o.valid and o.valid < self.time()
         --then
         --   return
         --end

         -- may be non-prefix information too
         local p = o[PREFIX_KEY]
         if not p
         then
            return
         end
         local o2 = {prefix=p, ifname=ifname, nh=o[NH_KEY], metric=metric}
         -- copy over all other fields too, if applicable
         for _, k in ipairs(PREFIX_INFO_SKV_KEYS)
         do
            o2[k] = non_empty(o[k])
         end
         for _, k in ipairs(PREFIX_INFO_LOCAL_SKV_KEYS)
         do
            o2[k] = non_empty(o[k])
         end
         f(o2)
      end
      return g
   end
   self:iterate_skvprefix_o(PD_SKVPREFIX, create_metric_callback(1000))
   self:iterate_skvprefix_o(TUNNEL_SKVPREFIX, create_metric_callback(2000))
end

function elsa_pa:get_json_map(jsonfield, localo)
   local s = mst.map:new{}
   s[self.rid] = localo
   self:iterate_ac_lsa_tlv(function (json, lsa)
                              local o = json.table[jsonfield]
                              s[lsa.rid] = o
                           end, {type=ospf_codec.AC_TLV_JSONBLOB})
   self:d('get_json_map', jsonfield, s)
   return s
end

function elsa_pa:get_field_array(jsonfield, locala, cl, get_keys)
   local cl = cl or mst.set
   local s = cl:new{}
   local get_keys = get_keys or (cl == mst.set)
   
   -- get local ones
   for i, v in ipairs(locala or {})
   do
      s:insert(v)
   end

   -- get global ones
   self:iterate_ac_lsa_tlv(function (json, lsa)
                              for i, v in ipairs(json.table[jsonfield] or {})
                              do
                                 s:insert(v)
                              end
                           end, {type=ospf_codec.AC_TLV_JSONBLOB})


   if get_keys
   then
      -- return set as array

      -- obviously the order is arbitrary; however, without changes in
      -- the table, it won't change, so the no-change constraint can be
      -- still verified. in practise it would be nice to transmit across
      -- sub-table deltas instead of whole tables, but as long as we
      -- don't, this is good enough.
      s = s:keys()
   end
   return s
end


-- iterate callback called with object + name of interface (possibly N
-- times per interface name)
function elsa_pa:iterate_skvprefix_o(prefix, f, l)
   for i, ifname in ipairs(l or self.skv:get(prefix .. IFLIST_KEY) 
                           or self.all_seen_if_names:keys())
   do
      local l = self.skv:get(string.format('%s%s', 
                                           prefix, ifname))
      if l
      then
         for i, o in ipairs(l)
         do
            f(o, ifname)
         end
      end
   end
end

function elsa_pa:get_local_field_array(prefix, field)
   local t
   self:iterate_skvprefix_o(prefix,
                            function (o, ifname)
                               local v = non_empty(o[field])
                               -- don't forward empty strings - they can be created by 'stuff'
                               if not v
                               then
                                  return
                               end
                               if not t then t = mst.array:new{} end
                               t:insert(v)
                            end)
   return t
end

function elsa_pa:get_local_asa_array()
   -- bit different than the rest, as this originates within pa code
   -- => what we do, is look at what's within the lap, and toss
   -- non-empty addresses
   local t = mst.array:new{}
   local laps = self.pa.lap:values():filter(function (lap) return lap.address end)
   self:ph_list_sorted(laps)

   for i, lap in ipairs(laps)
   do
      t:insert({rid=self.rid, prefix=lap.address:get_ascii()})
   end
   return t
end

function elsa_pa:get_asa_array()
   return self:get_field_array(JSON_ASA_KEY, self:get_local_asa_array())
end

function elsa_pa:ph_list_sorted(l)
   local t = mst.table_copy(l or {})
   table.sort(t, function (o1, o2)
                 return o1.prefix:get_binary() < o2.prefix:get_binary()
                 end)
   return t
end

function elsa_pa:generate_ac_lsa(use_relative_timestamps)

   local _convert

   if use_relative_timestamps
   then
      -- convert to relative timestamps 
      local now = self.time()
      _convert = function (v)
         return absolute_to_relative(v, now)
      end
   else
      -- just use values as is (=absolute timestamps)
      _convert = function (v)
         return v
      end
   end

   -- adding these in deterministic order is mandatory; however, by
   -- default, the list ISN'T sorted in any sensible way.. so we have
   -- to do it
   self:d('generate_ac_lsa')

   local a = mst.array:new()

   -- generate RHF
   local hwf = self:get_padded_hwf(self.rid)
   self:d(' hwf', hwf)

   a:insert(ospf_codec.rhf_ac_tlv:encode{body=hwf})

   -- generate local USP-based TLVs

   --local uspl = self:ph_list_sorted(self.pa.usp[self.rid])
   local uspl = self.pa.usp[self.rid] or {}
   for i, usp in ipairs(uspl)
   do
      self:d(' usp', self.rid, usp.prefix)
      a:insert(ospf_codec.usp_ac_tlv:encode{prefix=usp.prefix})
   end

   -- generate (local) ASP-based TLVs
   --local aspl = self:ph_list_sorted(self.pa:get_local_asp_values())
   local aspl = self.pa:get_local_asp_values()
   for i, asp in ipairs(aspl)
   do
      self:d(' asp', self.rid, asp.iid, asp.prefix)
      a:insert(ospf_codec.asp_ac_tlv:encode{prefix=asp.prefix, iid=asp.iid})
   end

   -- generate 'FYI' blob out of local SKV state; right now, just the
   -- interface-specific DNS information, if any
   local t = mst.map:new{}

   for jsonkey, o in pairs(json_sources)
   do
      local l = self:get_local_field_array(o.prefix, o.key)
      t[jsonkey] = l
   end
   t[JSON_ASA_KEY] = self:get_local_asa_array()

   -- router name (if any)
   t[JSON_RNAME_KEY] = self.pa.rname

   -- format the own mdns cache entries, if any
   local o = self.skv:get(MDNS_OWN_SKV_KEY)
   if o and #o > 0
   then
      t[JSON_MDNS_KEY] = o
   end

   -- bonus USP prefix option list 
   local h
   self:iterate_skv_prefix(function (p)
                              -- may be non-prefixy thing in the
                              -- source, skip if so
                              if not p.prefix
                              then
                                 self:d(' .. ignoring, no prefix', p)
                                 return
                              end

                              -- ok, it really is prefix, let's see if
                              -- it has any extra usp info we might
                              -- want to propagate
                              local o = {}
                              for i, key in ipairs(PREFIX_INFO_SKV_KEYS)
                              do
                                 o[key] = non_empty(p[key])
                              end
                              -- in OSPF, we store relative timestamps;
                              -- so convert absolute timestamps to relative
                              o[VALID_KEY] = _convert(p[VALID_KEY])
                              o[PREFERRED_KEY] = _convert(p[PREFERRED_KEY])
                              if mst.table_count(o) > 0
                              then
                                 h = h or {}
                                 h[p.prefix] = o
                                 self:d(' .. gleaned', p.prefix, o)
                              else
                                 self:d(' .. nothing useful in', p)
                              end

                           end)
   if h
   then
      self:d('exporting usp info', h)
      t[JSON_USP_INFO_KEY] = h
   end

   if t:count() > 0
   then
      self:d(' json', t)
      a:insert(ospf_codec.json_ac_tlv:encode{table=t})
   end

   if #a
   then
      local s = table.concat(a)
      self:d('generated ac lsa of length', #s)
      return s
   end
end
