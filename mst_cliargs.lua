#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mst_cliargs.lua $
--
-- Author: Markus Stenberg <mstenber@cisco.com>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed Jul 17 15:15:29 2013 mstenber
-- Last modified: Thu Jul 18 15:13:46 2013 mstenber
-- Edit time:     60 min
--

-- My variant on CLI argument parsing.

-- Notable features:

-- - ~similar to cliargs

-- - handles multiple optional arguments

-- - uses dictionaries instead of lists as arguments, and has somewhat
-- simpler API

-- basic idea:

-- mst_cliargs.parse{o} => args

-- parse arguments contain following:

-- process='process name'

-- error=<what to do on error; by default, call os.exit(1)

-- options = {{[name='option name']
-- [,alias='alias name']
-- [,desc='description for help']
-- [,flag='is a flag?']
-- [,value='value description']
-- [,default='default value']
-- [,min=N]
-- [,max=N]}...}
    
-- note: All options should have name, except for one. 

-- TODO:

-- value-only option should be sorted to be last s.t. it is used as default
-- (and presence of only one should be checked)

require 'mst'

module(..., package.seeall)

-- -name=
-- -f
-- --name=
-- --flag
-- VALUE
function option_to_prefix_i(opt, n, eqsign)
   -- specific option
   if n
   then
      eqsign = eqsign or '='
      local eq = opt.flag and "" or eqsign
      local prefix = #n == 1 and '' or '-'
      return string.format('-%s%s%s', prefix, n, eq)
   end
   -- default argument
   return ''
end

function option_to_prefix(opt)
   if opt.alias
   then
      -- show shorter first; the longer later
      local shorter = #opt.name > #opt.alias and opt.alias or opt.name
      local longer = #opt.name <= #opt.alias and opt.alias or opt.name

      return option_to_prefix_i(opt, shorter, '') .. '/' ..
         option_to_prefix_i(opt, longer)
   end
   return option_to_prefix_i(opt, opt.name)
end

-- this wraps prefix[=VALUE] with optionality constraints
function option_to_sdesc(opt)
   local p = option_to_prefix(opt)
   local optional
   if opt.flag
   then
      optional = true
   elseif not opt.min
   then 
      optional = true
   end
   if not opt.flag
   then
      local value = opt.value or opt.name
      mst.a(value, 'no value for non-flag option', opt)
      p = p .. string.upper(value)
   end
   if optional
   then
      return string.format('[%s]', p)
   end
   return p
end

function option_to_desc(opt)
   local l = {option_to_sdesc(opt)}
   if opt.desc
   then
      table.insert(l, opt.desc)
   end
   if opt.default
   then
      table.insert(l, string.format('[default=%s]', 
                                    mst.repr(opt.default)))
   end
   if opt.min and opt.max
   then
      table.insert(l, string.format('[%d-%d]', opt.min, opt.max))
   elseif opt.min
   then
      table.insert(l, string.format('[>=%d]', opt.min))
   elseif opt.max
   then
      table.insert(l, string.format('[<=%d]', opt.max))
   end
   if opt.default
   then
      table.insert(l, string.format('[default=%s]', 
                                    mst.repr(opt.default)))
   end
   return table.concat(l, ' ')
end

function show_help(o, opts)
   local args = o.arg or arg
   local process = o.process or args[0] or "?"
   local print = o.print or print

   print(string.format('%s %s', process,
                       table.concat(mst.array_map(opts,
                                                  option_to_sdesc), ' ')))
   for i, opt in ipairs(opts)
   do
      print('', option_to_desc(opt))
   end
end

function parse(o)
   local args = o.arg or arg
   mst.d('parsing arguments', args)
   local opts = o.options or {}
   opts = mst.table_deep_copy(opts)
   mst.d('opts', opts)

   local seen = {}
   local print = o.print or print

   -- add help handler
   table.insert(opts, {
                   name='help',
                   flag=1,
                   desc='Show help for the program',
                      })

   -- insert auto-generated one-letter aliases
   mst.d('generating aliases')
   for i, opt in ipairs(opts)
   do
      if opt.name and #opt.name == 1
      then
         seen[opt.name] = 1
      end
      if opt.alias and #opt.alias == 1
      then
         seen[opt.alias] = 1
      end
   end
   for i, opt in ipairs(opts)
   do
      if opt.name and #opt.name > 1
      then
         if not opt.alias
         then
            -- auto-generate alias _if possible_
            for i, v in mst.string_ipairs(opt.name)
            do
               if not seen[v]
               then
                  mst.d('added alias', v, opt)
                  seen[v] = 1
                  opt.alias = v
                  break
               end
            end
         end
      end
   end

   -- create a prefix list. it is ordered in the inverse length of the
   -- original option match, so that the default 'value' options
   -- (nothing to match) are handled last.
   local pl = {}
   for i, opt in ipairs(opts)
   do
      local p1 = option_to_prefix_i(opt, opt.name)
      local p2 = option_to_prefix_i(opt, opt.alias)
      table.insert(pl, {p1, opt})
      if #p2 > 0
      then
         table.insert(pl, {p2, opt})
      end
   end
   table.sort(pl, function (o1, o2)
                 return #o1[1] > #o2[1]
                  end)

   local r = {}

   local had_error
   for i, arg in ipairs(args)
   do
      local found
      for i, v in ipairs(pl)
      do
         local p, opt = unpack(v)
         found = mst.string_startswith(arg, p)
         mst.d('considering', arg, p, opt)
         if found
         then
            mst.d('matched', arg, opt, found)
            -- store the value, if applicable
            local n = opt.name or opt.value
            if opt.flag
            then
               r[n] = true
            elseif opt.min or opt.max
            then
               local l = r[n] or {}
               r[n] = l
               table.insert(l, found)
            else
               if r[n]
               then
                  print('multiple instances of option', n)
                  had_error = true
               else
                  r[n] = found
               end
            end
            break
         end
      end
      if not found
      then
         print('unable to parse', arg)
         had_error = true
      end
   end
   for i, opt in ipairs(opts)
   do
      local n = opt.name or opt.value
      if opt.min or opt.max
      then
         local l = r[n]
         if opt.min and opt.min>0
         then
            if not l or #l < opt.min
            then
               print('too few arguments to', n)
               had_error = true
            end
         end
         if opt.max
         then
            if l and #l > opt.max
            then
               print('too many arguments to', n)
               had_error = true
            end
         end
      end
   end
   local error = o.error or function ()
      os.exit(1)
                            end
   if r.help or had_error
   then
      mst.d('showing help', r.help, had_error)
      show_help(o, opts)
      error()
      -- in case error is nonfatal, we return nil
      return
   end
   -- set default values based on options
   for i, opt in ipairs(opts)
   do
      if opt.default
      then
         local n = opt.name or opt.value
         if not r[n]
         then
            r[n] = opt.default
         end
      end
   end
   return r
end