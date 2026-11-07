local M = {}

-- Byte length of the UTF-8 character starting at the 1-based byte index `i`.
function M.utf8_len(str, i)
  local byte = str:byte(i)

  if byte < 0x80 then
    return 1
  elseif byte < 0xE0 then
    return 2
  elseif byte < 0xF0 then
    return 3
  end

  return 4
end

-- Split a string into its UTF-8 characters.
function M.chars(str)
  local chars = {}
  local i = 1

  while i <= #str do
    local len = M.utf8_len(str, i)

    chars[#chars + 1] = str:sub(i, i + len - 1)
    i = i + len
  end

  return chars
end

return M
