-- Rendered host colors, drawn on literal template text through source_map.
-- Native Tree-sitter captures or Vim syntax groups share the same projection.
local M = {}
local api = vim.api
local util = require("vimoi.core.util")
local sessions = require("vimoi.render")
local namespace = api.nvim_create_namespace("vimoi-host-highlight")

---@class VimoiHostHighlight
---@field map VimoiOutputMap
---@field parser? vim.treesitter.LanguageTree
---@field output_buf integer Persistent scratch buffer driving native host highlighting.
---@field language? string
---@field syntax? string Vim syntax used on output when no host parser is available.
---@field regions VimoiRenderedRegion[] Exact literal mappings, ordered by output byte.
---@field inactive VimoiByteRange[] Literal source ranges not executed in this snapshot.
---@field generation integer
---@field windows table<integer, table> Persistent decorations owned by each visible window.

---@type table<integer, VimoiHostHighlight>
local buffers = {}

---@param buf integer
---@param cached table
local function clear_window(buf, cached)
  for _, mark in ipairs(cached.marks) do
    api.nvim_buf_del_extmark(buf, namespace, mark.id)
  end
end

api.nvim_create_autocmd("WinClosed", {
  group = api.nvim_create_augroup("vimoi-host-highlight", { clear = true }),
  callback = function(args)
    for buf, state in pairs(buffers) do
      local cached = state.windows[tonumber(args.match)]
      if cached then
        clear_window(buf, cached)
      end
      state.windows[tonumber(args.match)] = nil
    end
  end,
})

---@param buf integer
function M.clear(buf)
  local state = buffers[buf]
  buffers[buf] = nil
  if state then
    api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
    api.nvim__redraw({ buf = buf, valid = false })
  end
end

---@param state VimoiHostHighlight
---@param top integer
---@param bottom integer End-exclusive source row.
---@return table[]
local function decorations(state, top, bottom)
  local map = state.map
  local source_first = map.source_starts[top + 1] or map.source_size
  local source_last = map.source_starts[bottom + 1] or map.source_size
  local visible, ranges = {}, {}
  for _, region in ipairs(state.regions) do
    local first = math.max(source_first, region.source.start_byte)
    local last = math.min(source_last, region.source.end_byte)
    if first < last then
      local output_first = region.output_range.start_byte + first - region.source.start_byte
      local output_last = region.output_range.start_byte + last - region.source.start_byte
      visible[#visible + 1] = { region = region, first = output_first, last = output_last }
      local row = util.byte_to_position(nil, output_first, map.output_starts)
      local end_row = util.byte_to_position(nil, output_last - 1, map.output_starts) + 1
      local previous = ranges[#ranges]
      if previous and row <= previous[2] then
        previous[2] = math.max(previous[2], end_row)
      else
        ranges[#ranges + 1] = { row, end_row }
      end
    end
  end
  local marks, seen = {}, {}
  for _, range in ipairs(state.inactive) do
    local first = math.max(source_first, range.start_byte)
    local last = math.min(source_last, range.end_byte)
    if first < last then
      local row, col = util.byte_to_position(nil, first, map.source_starts)
      local end_row, end_col = util.byte_to_position(nil, last, map.source_starts)
      marks[#marks + 1] = {
        row = row,
        col = col,
        opts = {
          end_row = end_row,
          end_col = end_col,
          hl_group = "Comment",
          priority = vim.hl.priorities.treesitter,
        },
      }
    end
  end
  ---@param first integer Output byte, inclusive.
  ---@param last integer Output byte, exclusive.
  ---@param style vim.api.keyset.set_extmark
  local function project(first, last, style)
    -- Both lists are ordered by output bytes. Skip unrelated literal
    -- slots without scanning the entire source map for every capture.
    local low, high = 1, #visible
    while low <= high do
      local middle = math.floor((low + high) / 2)
      if visible[middle].last <= first then
        low = middle + 1
      else
        high = middle - 1
      end
    end
    for index = low, #visible do
      local part = visible[index]
      if part.first >= last then
        break
      end
      local a, b = math.max(first, part.first), math.min(last, part.last)
      if a < b then
        local offset = part.region.source.start_byte - part.region.output_range.start_byte
        local row, col = util.byte_to_position(nil, a + offset, map.source_starts)
        local end_row, end_col = util.byte_to_position(nil, b + offset, map.source_starts)
        local mark = {
          row = row,
          col = col,
          opts = vim.tbl_extend("force", style, { end_row = end_row, end_col = end_col }),
        }
        -- Equal-priority persistent marks have no query-order tie
        -- breaker. Stack coincident captures in one mark so later
        -- captures (e.g. @property over @variable) reliably win.
        local key = table.concat({
          a + offset,
          b + offset,
          style.priority,
          tostring(style.spell),
          tostring(mark.opts.conceal),
          tostring(style.url),
        }, "\0")
        local previous = seen[key]
        if previous then
          local groups = previous.opts.hl_group
          if type(groups) ~= "table" then
            groups = { groups }
          end
          -- Disjoint query ranges can yield the same capture again.
          if not vim.list_contains(groups, mark.opts.hl_group) then
            groups[#groups + 1] = mark.opts.hl_group
            previous.opts.hl_group = groups
          end
        else
          seen[key] = mark
          marks[#marks + 1] = mark
        end
      end
    end
  end
  if not state.parser then
    if state.syntax then
      api.nvim_buf_call(state.output_buf, function()
        for _, part in ipairs(visible) do
          local row = util.byte_to_position(nil, part.first, map.output_starts)
          local position = part.first
          while position < part.last do
            local line = api.nvim_buf_get_lines(state.output_buf, row, row + 1, false)[1] or ""
            local finish = math.min(part.last, map.output_starts[row + 1] + #line)
            local group, first = 0, position
            for byte = position, finish - 1 do
              local current = vim.fn.synID(row + 1, byte - map.output_starts[row + 1] + 1, 1)
              if current ~= group then
                if group ~= 0 then
                  project(first, byte, { hl_group = group, priority = vim.hl.priorities.syntax })
                end
                group, first = current, byte
              end
            end
            if group ~= 0 then
              project(first, finish, { hl_group = group, priority = vim.hl.priorities.syntax })
            end
            row = row + 1
            position = map.output_starts[row + 1] or part.last
          end
        end
      end)
    end
    return marks
  end
  state.parser:for_each_tree(function(tree, language_tree)
    local language = language_tree:lang()
    local query = vim.treesitter.query.get(language, "highlights")
    if not query then
      return
    end
    local included = tree:included_ranges(true)
    for _, rows in ipairs(ranges) do
      for capture, node, metadata, match in query:iter_captures(tree:root(), state.output_buf, rows[1], rows[2]) do
        local name = query.captures[capture]
        if name:sub(1, 1) ~= "_" then
          local range = vim.treesitter.get_range(node, state.output_buf, metadata[capture])
          local capture_metadata = metadata[capture] or {}
          local priority = tonumber(metadata.priority or capture_metadata.priority) or vim.hl.priorities.treesitter
          local spell
          if name == "spell" then
            spell = true
          elseif name == "nospell" then
            spell = false
            priority = priority + 1
          end
          local url = capture_metadata.url
          if type(url) == "number" then
            local nodes = match:captures()[url]
            url = nodes and vim.treesitter.get_node_text(nodes[1], state.output_buf, { metadata = metadata[url] })
          end
          ---@cast url string?
          for _, included_range in ipairs(included) do
            local first = math.max(range[3], included_range[3])
            local last = math.min(range[6], included_range[6])
            project(first, last, {
              hl_group = "@" .. name .. "." .. language,
              priority = priority,
              spell = spell,
              conceal = metadata.conceal or capture_metadata.conceal,
              url = url,
            })
          end
        end
      end
    end
  end)
  return marks
end

api.nvim_set_decoration_provider(namespace, {
  on_win = function(_, win, buf, top, bottom)
    local state = buffers[buf]
    if not state or require("vimoi").config.highlight.mode ~= "rendered" or vim.bo[buf].filetype ~= "gotmpl" then
      return false
    end
    -- on_win's bottom is inclusive; cache queries until this viewport changes.
    local cached = state.windows[win]
    local current = sessions.is_current(buf, state.map)
    if
      current and (not cached or cached.generation ~= state.generation or cached.top ~= top or cached.bottom ~= bottom)
    then
      local marks = decorations(state, top, bottom + 1)
      -- Install the complete new viewport before retiring the previous result.
      for _, mark in ipairs(marks) do
        mark.opts.right_gravity = false
        mark.opts.end_right_gravity = true
        mark.opts.invalidate = true
        mark.id = api.nvim_buf_set_extmark(buf, namespace, mark.row, mark.col, mark.opts)
      end
      if cached then
        clear_window(buf, cached)
      end
      state.windows[win] = { top = top, bottom = bottom, generation = state.generation, marks = marks }
    end
    -- While rendering is pending, native extmarks keep the last successful
    -- styles and follow source edits without querying stale source coordinates.
    return false
  end,
})

---@param buf integer
---@param map VimoiOutputMap
function M.update(buf, map)
  local language = vim.b[buf].vimoi_template_language
  local syntax = not language and vim.b[buf].vimoi_template_filetype or nil
  if syntax == "" or syntax == "gotmpl" or syntax == "template" then
    syntax = nil
  end
  ---@type VimoiHostHighlight?
  local state = buffers[buf]
  if state and (state.language ~= language or state.syntax ~= syntax) then
    M.clear(buf)
    state = nil
  end
  local rendered = sessions.get(buf).buf
  local parser = language and vim.treesitter.get_parser(rendered, language) or nil
  if syntax and vim.bo[rendered].syntax ~= syntax then
    vim.bo[rendered].syntax = syntax
  end
  if parser then
    parser:parse(true)
  end
  local inactive = {}
  for _, part in ipairs(map.literal_parts) do
    if #part.output_ranges == 0 and part.source.start_byte < part.source.end_byte then
      inactive[#inactive + 1] = part.source
    end
  end
  local regions, seen = {}, {}
  for _, region in ipairs(map.regions) do
    if region.kind == "static" or region.kind == "repeated" then
      local key = region.source.start_byte .. ":" .. region.source.end_byte
      -- A loop body can have conflicting colors between executions. Use its
      -- first occurrence rather than stacking contradictory decorations.
      if not seen[key] then
        seen[key] = true
        regions[#regions + 1] = region
      end
    end
  end
  buffers[buf] = {
    map = map,
    parser = parser,
    output_buf = rendered,
    language = language,
    syntax = syntax,
    generation = state and state.generation + 1 or 1,
    regions = regions,
    inactive = inactive,
    windows = state and state.windows or {},
  }
  -- Wake visible windows so their persistent decorations adopt this snapshot.
  api.nvim__redraw({ buf = buf, valid = false })
end

return M
