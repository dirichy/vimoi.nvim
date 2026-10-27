-- Experimental tag collection only; expression validation remains with chezmoi.
local M = {}
local space = "[ \t\r\n]"
local blocks = { ["if"] = true, range = true, with = true, define = true, block = true }

---@class VimoiTemplateTagRange
---@field start_byte integer Zero-based, inclusive.
---@field end_byte integer Zero-based, exclusive.
---@field left_trim boolean
---@field right_trim boolean

---@param source string
---@param first integer One-based opening quote.
---@return integer? after_quote
local function quoted_end(source, first)
  local quote = source:sub(first, first)
  if quote == "`" then
    local last = source:find("`", first + 1, true)
    return last and last + 1
  end
  local position = first + 1
  while position <= #source do
    local next_byte = source:find("[" .. quote .. "\\\n]", position)
    if not next_byte then
      return
    end
    local char = source:sub(next_byte, next_byte)
    if char == quote then
      return next_byte + 1
    elseif char == "\n" or source:sub(next_byte + 1, next_byte + 1) == "\n" then
      return
    end
    position = next_byte + 2
  end
end

-- Stream only effective delimiters; quoted/comment contents are opaque.
-- Plain template text needs only a native substring search, not byte iteration.
---@param source string
---@return fun(): string?, integer, integer, string? next_token One-based token bounds, inclusive.
local function tokenize(source)
  local position, opening, inside, comment = 1, 0, false, false
  return function()
    if not inside then
      local first = source:find("{{", position, true)
      if not first then
        return nil, 0, 0
      end
      local trim = source:sub(first + 2, first + 2) == "-" and source:sub(first + 3, first + 3):match(space) ~= nil
      position = first + (trim and 4 or 2)
      opening, inside = first, true
      comment = source:sub(position, position + 1) == "/*"
      return trim and "{{-" or "{{", first, first + (trim and 2 or 1)
    end
    local closing
    if comment then
      local last = source:find("*/", position + 2, true)
      if not last then
        return nil, 0, 0, "unclosed template comment at byte " .. opening - 1
      end
      closing = last + 2
      if source:sub(closing, closing):match(space) and source:sub(closing + 1, closing + 3) == "-}}" then
        closing = closing + 2
      elseif source:sub(closing, closing + 1) ~= "}}" then
        return nil, 0, 0, "template comment must end at a closing delimiter at byte " .. closing - 1
      end
    else
      while position <= #source do
        local next_byte = source:find("[}\"'`]", position)
        if not next_byte then
          break
        end
        local char = source:sub(next_byte, next_byte)
        if char == "}" then
          if source:sub(next_byte + 1, next_byte + 1) == "}" then
            closing = next_byte
            break
          end
          position = next_byte + 1
        else
          local after_quote = quoted_end(source, next_byte)
          if not after_quote then
            return nil, 0, 0, "unclosed template string at byte " .. next_byte - 1
          end
          position = after_quote
        end
      end
    end
    if not closing then
      return nil, 0, 0, "unclosed template action at byte " .. opening - 1
    end
    local trim = source:sub(closing - 1, closing - 1) == "-"
      and source:sub(closing - 2, closing - 2):match(space) ~= nil
    position, inside = closing + 2, false
    return trim and "-}}" or "}}", closing - (trim and 1 or 0), closing + 1
  end
end

---Collect only action boundaries and opaque define/block ranges.
---Offsets are zero-based and end-exclusive, matching the Tree-sitter collector.
---@param source string
---@return VimoiTemplateTagRange[]? tags
---@return string? error
function M.collect_template_tags(source)
  local next_token = tokenize(source)
  local tags = {}
  local opening, body, left_trim, opaque, depth = 0, 0, false, nil, 0
  while true do
    local token, first, last, err = next_token()
    if err then
      return nil, err
    elseif not token then
      break
    elseif token == "{{" or token == "{{-" then
      opening, body, left_trim = first, last + 1, token == "{{-"
    else
      local tag = {
        start_byte = opening - 1,
        end_byte = last,
        left_trim = left_trim,
        right_trim = token == "-}}",
      }
      if not opaque then
        tags[#tags + 1] = tag
      end
      local keyword, after = source:match("^[ \t\r\n]*([%a_][%w_]*)()", body)
      -- A Unicode identifier beginning with 'if'/'define' is not a keyword.
      if after and (source:byte(after) or 0) >= 128 then
        keyword = nil
      end
      -- Only opaque definitions need nesting; ordinary control tags stay separate.
      if opaque then
        if blocks[keyword] then
          depth = depth + 1
        elseif keyword == "end" then
          depth = depth - 1
          if depth == 0 then
            opaque.end_byte, opaque.right_trim = tag.end_byte, tag.right_trim
            opaque = nil
          end
        end
      elseif keyword == "define" or keyword == "block" then
        opaque, depth = tag, 1
      end
    end
  end
  if opaque then
    return nil, "unclosed template definition/block at byte " .. opaque.start_byte
  end
  return tags
end

return M
