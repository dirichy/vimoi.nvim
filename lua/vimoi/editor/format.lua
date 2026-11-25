local M = {}
local util = require("vimoi.core.util")
local buffer_edits = require("vimoi.core.buffer_edits")

local blocks = { if_action = true, range_action = true, with_action = true, define_action = true, block_action = true }
local keywords =
  { ["if"] = true, range = true, with = true, define = true, block = true, ["else"] = true, ["end"] = true }

---Format a snapshot without changing a buffer; shared by the command and formatter integrations.
---@param source string
---@param width integer
---@param buf integer Buffer context for native tab display widths; text comes only from source.
---@return string? updated
---@return string? error
---@return VimoiBufferEdit[]? edits
function M.format_text(source, width, buf)
  -- No boundary-only fallback: incomplete syntax must not drive formatting edits.
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, "gotmpl")
  if not ok or not parser then
    return nil, "formatting requires the gotmpl Tree-sitter parser"
  end
  local tree = parser:parse()[1]
  if not tree or tree:root():has_error() then
    return nil, "template contains Tree-sitter parse errors"
  end
  local lines = util.text_lines(source)
  ---@type VimoiBufferEdit[]
  local edits = {}
  ---@param node TSNode
  ---@param depth integer
  local function collect(node, depth)
    local is_block = blocks[node:type()]
    local index = 0
    while index < node:child_count() do
      local child = node:child(index)
      ---@cast child TSNode
      if child:type() == "{{" or child:type() == "{{-" then
        local body = node:child(index + 1)
        local closing_index = index + 1
        while closing_index < node:child_count() do
          local closing_type = node:child(closing_index):type()
          if closing_type == "}}" or closing_type == "-}}" then
            break
          end
          closing_index = closing_index + 1
        end
        local closing = node:child(closing_index)
        if body and closing then
          local row, col = child:start()
          local end_row = closing:end_()
          local _, _, opening = child:start()
          local left_trim = child:type() == "{{-"
          local comment = body:type() == "comment"
          -- Control delimiters belong to the block's own level; ordinary
          -- actions directly inside its body belong one level deeper.
          local action_depth = depth + (is_block and not keywords[body:type()] and 1 or 0)
          -- The {{- token includes its required following whitespace in this
          -- grammar. Locate the padding from the literal delimiter instead.
          local first = opening + (left_trim and 3 or 2)
          local _, _, last = body:start()
          -- Only the first single-line action on a line. Trailing host text
          -- stays untouched; external indentation changes only under left trim.
          if
            row == end_row
            and (not comment or left_trim)
            and lines[row + 1]:sub(1, col):match("^[ \t]*$")
            and source:sub(first + 1, last):match("^[ \t]*$")
          then
            local padding = " "
            if left_trim then
              local indent = string.rep(" ", action_depth * width)
              if lines[row + 1]:sub(1, col) ~= indent then
                edits[#edits + 1] = { start_byte = opening - col, end_byte = opening, replacement = indent }
              end
            else
              local outer_width = vim.api.nvim_buf_call(buf, function()
                return vim.fn.strdisplaywidth(lines[row + 1]:sub(1, col))
              end)
              -- Preserve output-bearing indentation, even when it already
              -- exceeds the desired depth. One separating space is not indentation.
              padding = string.rep(" ", 1 + math.max(0, action_depth * width - outer_width))
            end
            -- Comments require their own delimiter spacing. Only their
            -- trim-consumed external indentation may change.
            if not comment and source:sub(first + 1, last) ~= padding then
              edits[#edits + 1] = { start_byte = first, end_byte = last, replacement = padding }
            end
          end
        end
        -- The entire expression is opaque, including strings containing fake actions.
        index = closing_index + 1
      else
        collect(child, depth + (is_block and 1 or 0))
        index = index + 1
      end
    end
  end
  collect(tree:root(), 0)
  local updated = source
  for index = #edits, 1, -1 do
    local edit = edits[index]
    updated = updated:sub(1, edit.start_byte) .. edit.replacement .. updated:sub(edit.end_byte + 1)
  end
  return updated, nil, edits
end

---Indent line-leading actions without changing rendered text or trim markers.
---@param buf integer
---@return boolean? changed Nil on failure.
function M.format(buf)
  if not vim.bo[buf].modifiable or vim.bo[buf].readonly then
    util.notify("buffer is not writable", "format", vim.log.levels.ERROR)
    return
  end
  local source = util.buffer_text(buf)
  local updated, err, edits = M.format_text(source, vim.api.nvim_buf_call(buf, vim.fn.shiftwidth), buf)
  if not updated then
    util.notify(assert(err), "format", vim.log.levels.ERROR)
    return
  end
  if updated == source then
    return false
  end
  buffer_edits.apply(buf, source, updated, assert(edits))
  return true
end

return M
