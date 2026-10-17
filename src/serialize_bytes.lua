--[[
    serialize.lua: serialize_bytes.lua

    Copyright © 2016 - 2026, Más Bandwidth LLC.

    Redistribution and use in source and binary forms, with or without modification, are permitted
    provided that the conditions of the BSD 3-Clause license are met (see the LICENSE file).

    The bytes family's serializeBytes arm only: a raw byte block, aligned to a
    byte boundary first (STANDARD.md, bytes; the design's "the bytes family
    aligns first"). The string and wide string arms belong to the strings card.
]]

local type, math, error = type, math, error
local mathtype = math.type

local M = {}

M.methods = {
  serializeBytes = {
    check = function(numBytes)
      if mathtype(numBytes) ~= "integer" or numBytes < 0 then
        error("serialize: a byte count is a non-negative integer", 2)
      end
    end,
    checkValue = function(value, numBytes)
      if type(value) ~= "string" then
        error("serialize: bytes value must be a string", 2)
      end
      if #value ~= numBytes then
        error("serialize: bytes value length must equal numBytes", 2)
      end
    end,
    write = function(stream, value, numBytes)
      if not stream:serializeAlign() then return false end
      return stream:_writeBytes(value)
    end,
    read = function(stream, numBytes)
      if not stream:serializeAlign() then return false end
      local s = stream:_readBytes(numBytes)
      if s == nil then return false end
      return true, s
    end,
    measure = function(stream, value, numBytes)
      if not stream:serializeAlign() then return false end
      return stream:_measure(numBytes * 8)
    end,
  },
}

return M
