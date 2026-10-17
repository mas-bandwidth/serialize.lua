--[[
    serialize.lua: serialize_int128.lua

    Copyright © 2016 - 2026, Más Bandwidth LLC.

    Redistribution and use in source and binary forms, with or without modification, are permitted
    provided that the conditions of the BSD 3-Clause license are met (see the LICENSE file).

    The int128 family's serializeUint128 arm only. The 128-bit value is
    { lo = <low 64>, hi = <high 64> } (DESIGN.md (c)). The low 64-bit half is
    written first, then the high half, each half exactly as serialize_bits64 of
    64 (STANDARD.md, uint128). This file carries only the raw 128-bit wire arm;
    the ranged int128 arm and the 128-bit arithmetic belong to the int card.
]]

local math, error = math, error
local mathtype = math.type

local function uint128Err()
  error("serialize: a 128-bit value is a table { lo, hi } of integers", 2)
end

local function checkValue(value)
  if type(value) ~= "table" then uint128Err() end
  if mathtype(value.lo) ~= "integer" or mathtype(value.hi) ~= "integer" then
    uint128Err()
  end
end

local M = {}

M.methods = {
  serializeUint128 = {
    checkValue = checkValue,
    write = function(stream, value)
      if not stream:_writeBits(value.lo, 64) then return false end
      return stream:_writeBits(value.hi, 64)
    end,
    read = function(stream)
      local lo = stream:_readBits(64)
      if lo == nil then return false end
      local hi = stream:_readBits(64)
      if hi == nil then return false end
      return true, { lo = lo, hi = hi }
    end,
    measure = function(stream)
      return stream:_measure(128)
    end,
  },
}

return M
