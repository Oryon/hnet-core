#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: json_codec_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Sun Nov  4 01:05:02 2012 mstenber
-- Last modified: Mon Apr 29 11:13:03 2013 mstenber
-- Edit time:     16 min
--

require 'busted'
require 'json_codec'

NUMBER_OF_BLOBS=100

describe("json_codec", function ()
            local c
            local s
            before_each(function ()
                           s = mst.array:new()
                           s.write = s.insert
                           c = json_codec.wrap_socket{s=s}
                           function c:repr_data()
                              return '?'
                           end
                        end)
            it("survives random sized data", function ()
                  -- first, produce outputs
                  for i=1,NUMBER_OF_BLOBS
                  do
                     c:write(i)
                  end
                  local str = table.concat(s)
                  local idx = 1
                  local s = 1
                  local cbs = 1

                  function c.callback(o)
                     mst.a(o == cbs, 'oddity', o, cbs)
                     cbs = cbs + 1
                  end

                  local iter = 1
                  mst.d('got bytes to read', #str)
                  while idx <= #str
                  do
                     mst.d('iteration', iter, idx)

                     local e = idx + iter
                     if e > #str then e = #str end
                     mst.a(e > idx)
                     local ss = string.sub(str, idx, e)
                     c:handle_data(ss)
                     idx = e + 1
                     iter = iter + 1
                  end
                  -- cbs == number of _next_ callback
                  mst.a((cbs - 1) == NUMBER_OF_BLOBS, 'got cbs', cbs)

                                             end)
end)
