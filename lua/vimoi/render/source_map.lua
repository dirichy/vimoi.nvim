-- Locate source and output bytes through ordered sentinel occurrences.
local M = {}
local cli = require("vimoi.core.cli")

---Zero-based, half-open byte offsets [start_byte, end_byte); equal ends mark an insertion anchor.
---@class VimoiByteRange
---@field start_byte integer
---@field end_byte integer

-- Source slots share parallel arrays; REPEATED marks multiple executions of one literal.
M.LITERAL, M.REPEATED, M.TAG, M.TRIMMED, M.BOUNDARY = 1, 2, 3, 4, 5

---@class VimoiTemplateParts
---@field source string Temporary source snapshot, absent from the published map.
---@field source_bytes integer[] Source-ordered starts, including zero-length BOF/EOF; one extra entry is EOF.
---@field source_types integer[] LITERAL, REPEATED, TAG, TRIMMED or BOUNDARY.
---@field trim_flags integer[] TAG slots: 1 = left trim, 2 = right, 3 = both.

---@class VimoiSourceMap
---@field source_bytes integer[]
---@field source_types integer[]
---@field trim_flags integer[]
---@field output_indices integer[] Literal: first execution or zero. TAG/TRIMMED: earliest execution to the right.
---@field output_bytes integer[] Output-ordered positions, including virtual BOF/EOF anchors.
---@field output_slots integer[] Source slot for each output position.
---@field source_size integer
---@field output_size integer

---@class VimoiPreparedTrace: VimoiTemplateParts
---@field skeleton string Actions with literals replaced by stable ordinal sentinels.
---@field skeleton_starts table<integer, integer> TAG positions for template errors.
---@field sentinel_slots integer[] Ordinal-to-source-slot lookup, independent of trim slot count.
---@field prefix string
---@field init boolean
---@field context_generation integer
---@field output? string Present after decoding; restoration is idempotent.

---@class VimoiSourceMapTrace: VimoiPreparedTrace, VimoiSourceMap
---@field sentinel_slots? integer[] Only prepared renders need ordinal decoding data.
---@field skeleton_starts? table<integer, integer> Only prepared renders need template-error positions.
---@field output string
---@field rendered_skeleton string
---@field source_starts? integer[] Source line starts.
---@field output_starts? integer[] Output line starts.

---@class VimoiSyntaxEdit
---@field start_byte integer
---@field old_end_byte integer
---@field new_end_byte integer

---@class VimoiSyntaxCache
---@field parser vim.treesitter.LanguageTree
---@field tick? integer
---@field eol? boolean
---@field template_tags? VimoiTemplateTagRange[]
---@field dirty_ranges VimoiByteRange[] Current buffer coordinates.
---@field pending_edits VimoiSyntaxEdit[] Coordinates at the time of each edit.

-- Cached tag ranges belong to the buffer, not the rendered context. They remain
-- valid across data/config invalidation and are released when its parser detaches.
---@type table<integer, VimoiSyntaxCache>
local buffer_syntax_cache = {}
local delimiter_is_opening = { ["{{"] = true, ["{{-"] = true, ["}}"] = false, ["-}}"] = false }
-- Go's empty-definition check uses Unicode whitespace; trim markers below
-- remove only the four ASCII whitespace bytes.
local definition_space = " \t\r\n\v\f"
  .. vim.fn.list2str({ 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 })
  .. vim.fn.list2str(vim.fn.range(0x2000, 0x200A))

-- Include touching boundaries for zero-width edits so insertion/deletion cannot leave stale tags.
local function overlaps(start_byte, end_byte, other_start_byte, other_end_byte)
  if start_byte == end_byte or other_start_byte == other_end_byte then
    return start_byte <= other_end_byte and end_byte >= other_start_byte
  end
  return start_byte < other_end_byte and end_byte > other_start_byte
end

-- Defines stay opaque so their output belongs to the call site.
-- Other control nodes are split into sibling delimiter pairs, preserving body slots.
-- Partial scans start at complete cached tags or new syntax ranges reported by the parser.
---@param node TSNode
---@param result VimoiTemplateTagRange[] Append complete tags in source order.
---@param range_start_byte? integer
---@param range_end_byte? integer
---@return integer visited_nodes
local function collect_tags(node, result, range_start_byte, range_end_byte)
  if node:type() == "define_action" then
    local _, _, start_byte = node:start()
    local _, _, end_byte = node:end_()
    result[#result + 1] = {
      start_byte = start_byte,
      end_byte = end_byte,
      left_trim = node:child(0):type() == "{{-",
      right_trim = node:child(node:child_count() - 1):type() == "-}}",
    }
    return 1
  end
  if node:type() == "text" then
    return 1
  end
  local child_count, visited_nodes, index = node:child_count(), 1, 0
  if range_start_byte then
    local low, high = 0, child_count
    while low < high do
      local middle = math.floor((low + high) / 2)
      local _, _, child_end_byte = node:child(middle):end_()
      if
        child_end_byte < range_start_byte or (child_end_byte == range_start_byte and range_start_byte ~= range_end_byte)
      then
        low = middle + 1
      else
        high = middle
      end
    end
    index = low
  end
  while index < child_count do
    local child = node:child(index)
    ---@cast child TSNode
    if range_start_byte then
      local _, _, start_byte = child:start()
      if start_byte > range_end_byte or (start_byte == range_end_byte and range_start_byte ~= range_end_byte) then
        break
      end
    end
    if delimiter_is_opening[child:type()] == true then
      local _, _, start_byte = child:start()
      local closing_index = index + 1
      -- A valid tree guarantees the sibling closing delimiter; never enter an expression subtree.
      while delimiter_is_opening[node:child(closing_index):type()] ~= false do
        closing_index = closing_index + 1
      end
      local closing = node:child(closing_index)
      ---@cast closing TSNode
      local _, _, end_byte = closing:end_()
      result[#result + 1] = {
        start_byte = start_byte,
        end_byte = end_byte,
        left_trim = child:type() == "{{-",
        right_trim = closing:type() == "-}}",
      }
      index = closing_index + 1
      visited_nodes = visited_nodes + 2
    else
      visited_nodes = visited_nodes + collect_tags(child, result, range_start_byte, range_end_byte)
      index = index + 1
    end
  end
  return visited_nodes
end

-- Map a position through one edit. The two affinities conservatively include
-- inserted/replacement text when a cached fragment touches an edited boundary.
---@param byte integer
---@param edit VimoiSyntaxEdit
---@param stick_to_end boolean
---@return integer
local function map_byte_through_edit(byte, edit, stick_to_end)
  if byte < edit.start_byte or (byte == edit.start_byte and not stick_to_end) then
    return byte
  elseif byte >= edit.old_end_byte then
    return byte + edit.new_end_byte - edit.old_end_byte
  end
  return stick_to_end and edit.new_end_byte or edit.start_byte
end

-- Buffer parses reuse tag ranges; string parses are independent snapshots without a cache.
-- When buf is given, source must be its current text so syntax and byte offsets agree.
local function parse_tags(source, buf)
  local ok, parser =
    pcall(buf and vim.treesitter.get_parser or vim.treesitter.get_string_parser, buf or source, "gotmpl")
  if not ok or not parser then
    local tags, err = require("vimoi.parser").collect_template_tags(source)
    return tags, err, tags and #tags or 0
  end
  local syntax_cache = buf and buffer_syntax_cache[buf]
  if buf and (not syntax_cache or syntax_cache.parser ~= parser) then
    syntax_cache = { parser = parser, dirty_ranges = {}, pending_edits = {} }
    buffer_syntax_cache[buf] = syntax_cache
    parser:register_cbs({
      on_bytes = function(_, _, _, _, byte, _, _, old_bytes, _, _, new_bytes)
        if not syntax_cache.template_tags then
          return
        end
        -- Byte events also catch literal edits that leave the syntax tree's shape unchanged.
        local edit = { start_byte = byte, old_end_byte = byte + old_bytes, new_end_byte = byte + new_bytes }
        for _, range in ipairs(syntax_cache.dirty_ranges) do
          range.start_byte = map_byte_through_edit(range.start_byte, edit, false)
          range.end_byte = map_byte_through_edit(range.end_byte, edit, true)
        end
        syntax_cache.pending_edits[#syntax_cache.pending_edits + 1] = edit
        syntax_cache.dirty_ranges[#syntax_cache.dirty_ranges + 1] = { start_byte = byte, end_byte = byte + new_bytes }
      end,
      on_changedtree = function(dirty_ranges)
        -- Parser changes may extend beyond edited bytes, e.g. after inserting a quote or delimiter.
        if syntax_cache.template_tags then
          for _, range in ipairs(dirty_ranges) do
            syntax_cache.dirty_ranges[#syntax_cache.dirty_ranges + 1] = { start_byte = range[3], end_byte = range[6] }
          end
        end
      end,
      on_detach = function()
        if buffer_syntax_cache[buf] == syntax_cache then
          buffer_syntax_cache[buf] = nil
        end
      end,
    })
  end
  local tree = parser:parse()[1]
  local root = tree and tree:root()
  if not root or root:has_error() then
    -- Partial syntax cannot safely delimit tags; recovery must rebuild from a valid tree.
    if syntax_cache then
      syntax_cache.template_tags, syntax_cache.tick = nil, nil
      syntax_cache.dirty_ranges, syntax_cache.pending_edits = {}, {}
    end
    return nil, "template contains Tree-sitter parse errors"
  end
  if
    syntax_cache
    and syntax_cache.tick == vim.api.nvim_buf_get_changedtick(buf)
    and syntax_cache.eol == vim.bo[buf].endofline
  then
    syntax_cache.dirty_ranges, syntax_cache.pending_edits = {}, {}
    return syntax_cache.template_tags, nil, 0
  end

  local template_tags, visited_nodes = {}, 0
  if not syntax_cache or not syntax_cache.template_tags or #syntax_cache.pending_edits == 0 then
    -- First use, string input, or a reload without byte events needs a full walk.
    visited_nodes = collect_tags(root, template_tags)
  else
    -- Positions must move even in unchanged syntax. Do not mutate any exported
    -- parts/trace: these private raw fragments are separate from their objects.
    for _, edit in ipairs(syntax_cache.pending_edits) do
      local byte_delta = edit.new_end_byte - edit.old_end_byte
      if byte_delta ~= 0 then
        for _, tag in ipairs(syntax_cache.template_tags) do
          if tag.start_byte > edit.old_end_byte then
            tag.start_byte = tag.start_byte + byte_delta
            tag.end_byte = tag.end_byte + byte_delta
          elseif tag.end_byte >= edit.start_byte then
            tag.start_byte = map_byte_through_edit(tag.start_byte, edit, false)
            tag.end_byte = map_byte_through_edit(tag.end_byte, edit, true)
          end
        end
      end
    end
    -- Coalesce byte edits and parser changes before rescanning; deletions may be zero-width.
    table.sort(syntax_cache.dirty_ranges, function(a, b)
      return a.start_byte < b.start_byte
    end)
    local dirty_ranges = {}
    for _, range in ipairs(syntax_cache.dirty_ranges) do
      local previous_range = dirty_ranges[#dirty_ranges]
      local start_byte, end_byte = math.max(0, math.min(#source, range.start_byte)), math.min(#source, range.end_byte)
      if previous_range and start_byte <= previous_range.end_byte then
        previous_range.end_byte = math.max(previous_range.end_byte, end_byte)
      else
        dirty_ranges[#dirty_ranges + 1] = { start_byte = start_byte, end_byte = end_byte }
      end
    end
    for _, range in ipairs(dirty_ranges) do
      local start_byte, end_byte = range.start_byte, range.end_byte
      -- Expand once to complete cached tags. Newly inserted/changed
      -- tags contribute their full new ranges below.
      local low, high = 1, #syntax_cache.template_tags + 1
      while low < high do
        local middle = math.floor((low + high) / 2)
        if syntax_cache.template_tags[middle].end_byte < start_byte then
          low = middle + 1
        else
          high = middle
        end
      end
      for index = low, #syntax_cache.template_tags do
        local tag = syntax_cache.template_tags[index]
        if tag.start_byte > end_byte then
          break
        end
        if overlaps(tag.start_byte, tag.end_byte, start_byte, end_byte) then
          range.start_byte = math.min(range.start_byte, tag.start_byte)
          range.end_byte = math.max(range.end_byte, tag.end_byte)
        end
      end
      local changed_tags = {}
      visited_nodes = visited_nodes + collect_tags(root, changed_tags, range.start_byte, range.end_byte)
      for _, tag in ipairs(changed_tags) do
        range.start_byte = math.min(range.start_byte, tag.start_byte)
        range.end_byte = math.max(range.end_byte, tag.end_byte)
        template_tags[#template_tags + 1] = tag
      end
    end
    -- Sort only the newly collected tags. Sorting all cached tags on every
    -- keystroke costs more than the local syntax walk we just avoided.
    table.sort(template_tags, function(a, b)
      return a.start_byte < b.start_byte or (a.start_byte == b.start_byte and a.end_byte < b.end_byte)
    end)
    -- Two expanded dirty ranges may capture the same new tag.
    table.sort(dirty_ranges, function(a, b)
      return a.start_byte < b.start_byte
    end)
    local replaced_ranges = {}
    for _, range in ipairs(dirty_ranges) do
      local previous_range = replaced_ranges[#replaced_ranges]
      if previous_range and range.start_byte <= previous_range.end_byte then
        previous_range.end_byte = math.max(previous_range.end_byte, range.end_byte)
      else
        replaced_ranges[#replaced_ranges + 1] = range
      end
    end
    -- Drop cached tags covered by the expanded rescans, retaining the rest in source order.
    local unchanged_tags, replaced_range_index = {}, 1
    for _, tag in ipairs(syntax_cache.template_tags) do
      while replaced_ranges[replaced_range_index] and replaced_ranges[replaced_range_index].end_byte < tag.start_byte do
        replaced_range_index = replaced_range_index + 1
      end
      local replaced_range = replaced_ranges[replaced_range_index]
      if
        not replaced_range
        or not overlaps(tag.start_byte, tag.end_byte, replaced_range.start_byte, replaced_range.end_byte)
      then
        unchanged_tags[#unchanged_tags + 1] = tag
      end
    end
    -- Merge the two sorted lists linearly and deduplicate tags captured by overlapping rescans.
    local merged_tags, changed_tag_index, unchanged_tag_index = {}, 1, 1
    while template_tags[changed_tag_index] or unchanged_tags[unchanged_tag_index] do
      local changed_tag, unchanged_tag = template_tags[changed_tag_index], unchanged_tags[unchanged_tag_index]
      local tag
      if changed_tag and (not unchanged_tag or changed_tag.start_byte <= unchanged_tag.start_byte) then
        tag = changed_tag
        changed_tag_index = changed_tag_index + 1
      else
        tag = unchanged_tag
        unchanged_tag_index = unchanged_tag_index + 1
      end
      local previous_tag = merged_tags[#merged_tags]
      if
        not previous_tag
        or previous_tag.start_byte ~= tag.start_byte
        or previous_tag.end_byte ~= tag.end_byte
        or previous_tag.left_trim ~= tag.left_trim
        or previous_tag.right_trim ~= tag.right_trim
      then
        merged_tags[#merged_tags + 1] = tag
      end
    end
    template_tags = merged_tags
  end
  if syntax_cache then
    syntax_cache.template_tags, syntax_cache.tick, syntax_cache.eol =
      template_tags, vim.api.nvim_buf_get_changedtick(buf), vim.bo[buf].endofline
    syntax_cache.dirty_ranges, syntax_cache.pending_edits = {}, {}
  end
  return template_tags, nil, visited_nodes
end

---Read the leading action identifier, preserving Unicode identifier boundaries.
---@param text string Complete action, including delimiters.
---@return string?
function M.action_keyword(text)
  local keyword, after = text:match("^{{%-?%s*([%a_][%w_]*)()")
  if after and (text:byte(after) or 0) >= 128 then
    return nil
  end
  return keyword
end

---Extract template tags and trimmed literal text before rendering.
---Only dirty syntax is walked; the returned slot arrays are fresh snapshots.
---@param source string
---@param buf? integer
---@return VimoiTemplateParts?
---@return string? error
---@return integer? visited_nodes Tree-sitter visits/endpoints, or collected tag count in fallback; excludes sibling searches and binary-search probes.
function M.parse(source, buf)
  local cached_tags, err, visited_nodes = parse_tags(source, buf)
  if not cached_tags then
    return nil, err
  end
  -- Export fresh objects so later byte shifts cannot mutate an existing trace.
  local template_tags, stack = {}, {}
  local blocks = { ["if"] = true, range = true, with = true, block = true }
  for index, tag in ipairs(cached_tags) do
    local text = source:sub(tag.start_byte + 1, tag.end_byte)
    local keyword = M.action_keyword(text)
    local frame = stack[#stack]
    if frame and frame.empty then
      local previous = cached_tags[index - 1]
      -- A comment is empty; any other action or non-whitespace text makes
      -- the block nonempty. Nested controls mark their parent before being pushed.
      if
        vim.fn.trim(source:sub(previous.end_byte + 1, tag.start_byte), definition_space) ~= ""
        or (keyword ~= "end" and not text:match("^{{%-?%s*/%*"))
      then
        frame.empty = false
      end
    end
    template_tags[#template_tags + 1] = tag
    if blocks[keyword] then
      stack[#stack + 1] = { index = #template_tags, keyword = keyword, empty = keyword == "block" }
    elseif keyword == "end" and frame then
      table.remove(stack)
      if frame.empty then
        -- Keep empty block definitions opaque so tokens cannot change Go's
        -- whitespace/comment-only redefinition semantics.
        local opening = template_tags[frame.index]
        template_tags[frame.index] = {
          start_byte = opening.start_byte,
          end_byte = tag.end_byte,
          left_trim = opening.left_trim,
          right_trim = tag.right_trim,
        }
        for inner = #template_tags, frame.index + 1, -1 do
          template_tags[inner] = nil
        end
      end
    end
  end
  for _, frame in ipairs(stack) do
    if frame.keyword == "block" then
      return nil, "unclosed template definition/block at byte " .. template_tags[frame.index].start_byte
    end
  end
  local starts, types, trims = { 0 }, { M.BOUNDARY }, {}
  for index = 1, #template_tags + 1 do
    local previous, following = template_tags[index - 1], template_tags[index]
    local first = previous and previous.end_byte or 0
    local last = following and following.start_byte or #source
    local text = source:sub(first + 1, last)
    local trimmed_first = first + (previous and previous.right_trim and #(text:match("^[ \t\r\n]*") or "") or 0)
    local trimmed_last = last - (following and following.left_trim and #(text:match("[ \t\r\n]*$") or "") or 0)
    trimmed_last = math.max(trimmed_first, trimmed_last)
    if first < trimmed_first then
      starts[#types + 1], types[#types + 1] = first, M.TRIMMED
    end
    -- Empty literals remain execution anchors between adjacent actions and at EOF.
    starts[#types + 1], types[#types + 1] = trimmed_first, M.LITERAL
    if trimmed_last < last then
      starts[#types + 1], types[#types + 1] = trimmed_last, M.TRIMMED
    end
    if following then
      local id = #types + 1
      starts[id], types[id] = following.start_byte, M.TAG
      trims[id] = (following.left_trim and 1 or 0) + (following.right_trim and 2 or 0)
    end
  end
  starts[#types + 1], types[#types + 1] = #source, M.BOUNDARY
  starts[#types + 1] = #source
  return { source = source, source_bytes = starts, source_types = types, trim_flags = trims }, nil, visited_nodes
end

-- 0xFF cannot occur in valid UTF-8 output and survives execute-template unchanged.
-- Keep it fixed so skeleton keys remain stable across literal edits.
local sentinel_prefix = "\255"
-- Only managed files have a target context. Keep raw strings, source-only files,
-- and init templates in execute-template's native context.
---@param buf? integer
---@param init boolean
---@return string
function M.context_prefix(buf, init)
  if init or not buf or not cli.source_root then
    return ""
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local source_file = path ~= "" and vim.fs.relpath(cli.source_root, path)
  if not source_file then
    return ""
  end
  local target = cli.counterpart_path(path)
  if not target or target == "" then
    return ""
  end
  target = vim.json.encode(target)
  -- Empty if bodies discard set's return value without declaring variables or
  -- emitting whitespace. Preserve the real CLI/wrapper arguments before cat.
  return '{{if set .chezmoi "sourceFile" '
    .. vim.json.encode(source_file)
    .. '}}{{end}}{{if set .chezmoi "targetFile" '
    .. target
    .. '}}{{end}}{{if set .chezmoi "command" "cat"}}{{end}}'
    .. '{{if set .chezmoi "args" (append (append (initial .chezmoi.args) "cat") '
    .. target
    .. " | toStrings)}}{{end}}"
end

---@class VimoiTraceOptions
---@field init? boolean
---@field buf? integer
---@field timeout? integer
---@field prefix? string Captured context reused by local inference without a live buffer.
---@field prepared? VimoiPreparedTrace Reuse session input in trace_async; restoration completes the same object.

-- Replace each literal slot with its stable ID; unchanged tags/slot count reuse the rendered skeleton.
-- Complete text results are temporary; buffer-owned caches live in render/init.lua.
---@param source string
---@param opts? VimoiTraceOptions
---@return VimoiPreparedTrace?
---@return string? error
function M.prepare(source, opts)
  opts = opts or {}
  local init = opts.init == true
  local prefix = opts.prefix or M.context_prefix(opts.buf, init)
  if
    source:find("chezmoi:template:left-delimiter", 1, true)
    or source:find("chezmoi:template:right-delimiter", 1, true)
  then
    return nil, "custom template delimiters are not supported"
  end
  if source:find(sentinel_prefix, 1, true) then
    return nil, "template contains the renderer's reserved sentinel prefix"
  end

  local template_parts, parse_error = M.parse(source, opts.buf)
  if not template_parts then
    return nil, parse_error
  end
  local skeleton_parts, skeleton_bytes = { prefix }, #prefix
  local sentinel_slots, skeleton_starts = {}, {}
  for id, kind in ipairs(template_parts.source_types) do
    if kind == M.LITERAL then
      sentinel_slots[#sentinel_slots + 1] = id
      local sentinel = sentinel_prefix .. #sentinel_slots .. sentinel_prefix
      skeleton_parts[#skeleton_parts + 1] = sentinel
      skeleton_bytes = skeleton_bytes + #sentinel
    elseif kind == M.TAG then
      local text = source:sub(template_parts.source_bytes[id] + 1, template_parts.source_bytes[id + 1])
      skeleton_starts[id] = skeleton_bytes
      skeleton_parts[#skeleton_parts + 1] = text
      skeleton_bytes = skeleton_bytes + #text
    end
  end
  ---@cast template_parts VimoiPreparedTrace
  template_parts.skeleton = table.concat(skeleton_parts)
  template_parts.skeleton_starts, template_parts.sentinel_slots = skeleton_starts, sentinel_slots
  template_parts.prefix, template_parts.init = prefix, init
  template_parts.context_generation = cli.context_generation
  return template_parts
end

-- A skipped branch leaves no token; loops repeat tokens. Decode each occurrence into an output range.
---@param prepared_trace VimoiPreparedTrace
---@param rendered_skeleton string?
---@param render_error? string
---@return VimoiSourceMapTrace?
---@return string? error
function M.restore(prepared_trace, rendered_skeleton, render_error)
  if prepared_trace.output ~= nil then
    ---@cast prepared_trace VimoiSourceMapTrace
    return prepared_trace
  end
  if not rendered_skeleton then
    return nil, render_error
  end
  local byte_delta = 0
  local starts, types = prepared_trace.source_bytes, prepared_trace.source_types
  local output_bytes, output_slots, indices, texts = { 0 }, { 1 }, {}, {}
  for slot = 1, #types do
    indices[slot] = 0
  end
  indices[1] = 1
  local decode_error
  local output = rendered_skeleton:gsub(
    "()" .. sentinel_prefix .. "(%d+)" .. sentinel_prefix,
    function(position, ordinal)
      local slot = prepared_trace.sentinel_slots[tonumber(ordinal)]
      if not slot then
        decode_error = "unknown sentinel in rendered output"
        return ""
      end
      local text = texts[slot]
      if not text then
        text = prepared_trace.source:sub(starts[slot] + 1, starts[slot + 1])
        texts[slot] = text
      end
      local execution = #output_bytes + 1
      output_bytes[execution], output_slots[execution] = position - 1 + byte_delta, slot
      if indices[slot] == 0 then
        indices[slot] = execution
      else
        types[slot] = M.REPEATED
      end
      byte_delta = byte_delta + #text - (#sentinel_prefix * 2 + #ordinal)
      return text -- Replacement strings are not scanned again: literal {{ stays literal.
    end
  )
  if decode_error then
    return nil, decode_error
  end
  -- Virtual anchors do not change the CLI skeleton or empty-definition semantics.
  local eof = #output_bytes + 1
  output_bytes[eof], output_slots[eof], indices[#types] = #output, #types, eof
  local right = eof
  for slot = #types, 1, -1 do
    local kind, execution = types[slot], indices[slot]
    if kind == M.TAG or kind == M.TRIMMED then
      indices[slot] = right
    elseif execution > 0 then
      right = math.min(right, execution)
    end
  end
  prepared_trace.output_indices = indices
  prepared_trace.output_bytes, prepared_trace.output_slots = output_bytes, output_slots
  prepared_trace.source_size, prepared_trace.output_size = #prepared_trace.source, #output
  prepared_trace.output = output
  prepared_trace.rendered_skeleton = rendered_skeleton
  ---@cast prepared_trace VimoiSourceMapTrace
  return prepared_trace
end

---Rebuild all ranges from a previously rendered structure, without a process.
---Returns nil if template tags changed or the rendering context was invalidated.
---@param trace VimoiSourceMapTrace
---@param source string
---@param buf? integer
---@return VimoiSourceMapTrace?
function M.rebuild(trace, source, buf)
  if trace.context_generation ~= cli.context_generation then
    return nil
  end
  if buf and M.context_prefix(buf, trace.init) ~= trace.prefix then
    return nil
  end
  if trace.source == source then
    return trace
  end
  local prepared_trace = M.prepare(source, { init = trace.init, buf = buf, prefix = trace.prefix })
  -- Identical skeletons preserve dynamic output and execution order; only literal text/ranges need rebuilding.
  if not prepared_trace or prepared_trace.skeleton ~= trace.skeleton then
    return nil
  end
  return M.restore(prepared_trace, trace.rendered_skeleton)
end

---Reconstruct a static merge, including the constant brace tags added by escaping.
---Old tags retain their execution; each old literal sentinel expands to the new
---literal sentinels and known brace output in that same execution position.
---@param trace VimoiSourceMapTrace
---@param source string
---@param edits VimoiBufferEdit[] Ascending, escaped edits confined to old literal slots.
---@return VimoiSourceMapTrace?
---@return string? error
function M.rebuild_after_edits(trace, source, edits)
  if trace.context_generation ~= cli.context_generation then
    return nil, "rendering context changed"
  end
  local prepared, prepare_error = M.prepare(source, { init = trace.init, prefix = trace.prefix })
  if not prepared then
    return nil, prepare_error
  end
  local replacements, slot, new_ordinal, edit_index, byte_delta = {}, 1, 0, 1, 0
  local ordinal = 0
  for old_slot, old_kind in ipairs(trace.source_types) do
    if old_kind == M.LITERAL or old_kind == M.REPEATED then
      ordinal = ordinal + 1
      local following = old_slot + 1
      while trace.source_types[following] == M.TRIMMED do
        following = following + 1
      end
      local boundary = trace.source_bytes[following]
      while edits[edit_index] and edits[edit_index].end_byte <= boundary do
        local edit = edits[edit_index]
        byte_delta = byte_delta + #edit.replacement - (edit.end_byte - edit.start_byte)
        edit_index = edit_index + 1
      end
      local new_boundary, replacement = boundary + byte_delta, {}
      while prepared.source_types[slot] do
        local kind = prepared.source_types[slot]
        if kind == M.TAG then
          if prepared.source_bytes[slot] >= new_boundary then
            break
          end
          local text = source:sub(prepared.source_bytes[slot] + 1, prepared.source_bytes[slot + 1])
          local braces = text:match('^{{ "({+)" }}$')
          if not braces then
            return nil, "static edit changed a template tag"
          end
          replacement[#replacement + 1] = braces
        elseif kind == M.LITERAL then
          new_ordinal = new_ordinal + 1
          replacement[#replacement + 1] = sentinel_prefix .. new_ordinal .. sentinel_prefix
        end
        slot = slot + 1
      end
      replacements[ordinal] = table.concat(replacement)
      if trace.source_types[following] == M.TAG then
        if
          prepared.source_bytes[slot] ~= new_boundary
          or source:sub(prepared.source_bytes[slot] + 1, prepared.source_bytes[slot + 1])
            ~= trace.source:sub(trace.source_bytes[following] + 1, trace.source_bytes[following + 1])
        then
          return nil, "static edit changed a template tag"
        end
        slot = slot + 1
      end
    end
  end
  local rendered_skeleton = trace.rendered_skeleton:gsub(sentinel_prefix .. "(%d+)" .. sentinel_prefix, function(id)
    return replacements[tonumber(id)]
  end)
  return M.restore(prepared, rendered_skeleton)
end

---Render structure once, then restore current literal text and source ranges.
---@param source string
---@param opts? VimoiTraceOptions
---@return VimoiSourceMapTrace? trace
---@return string? error
function M.trace(source, opts)
  opts = opts or {}
  local prepared_trace, prepare_error = M.prepare(source, opts)
  if not prepared_trace then
    return nil, prepare_error
  end
  local rendered_skeleton, render_error = cli.execute_template(prepared_trace.skeleton, {
    init = prepared_trace.init,
    timeout = opts.timeout,
    cache = true,
  })
  -- No callback is supplied, so this overload returns text rather than a process handle.
  ---@cast rendered_skeleton string?
  return M.restore(prepared_trace, rendered_skeleton, render_error)
end

---Asynchronously build the same mapping as trace(); even cached results invoke the callback later.
---@param source string
---@param opts? VimoiTraceOptions
---@param callback fun(trace: VimoiSourceMapTrace?, error: string?)
---@return VimoiCommand?
function M.trace_async(source, opts, callback)
  opts = opts or {}
  local prepared_trace, prepare_error = opts.prepared, nil
  if not prepared_trace then
    prepared_trace, prepare_error = M.prepare(source, opts)
  end
  if not prepared_trace then
    vim.schedule(function()
      callback(nil, prepare_error)
    end)
    return
  end
  if next(prepared_trace.skeleton_starts) == nil then
    vim.schedule(function()
      callback(M.restore(prepared_trace, prepared_trace.skeleton:sub(#prepared_trace.prefix + 1)))
    end)
    return
  end
  local command = cli.execute_template(prepared_trace.skeleton, {
    init = prepared_trace.init,
    timeout = opts.timeout,
    cache = true,
    callback = function(rendered_skeleton, render_error)
      callback(M.restore(prepared_trace, rendered_skeleton, render_error))
    end,
  })
  -- The callback overload returns a cancellable job, or nil on a cache hit.
  ---@cast command VimoiCommand?
  return command
end

---@class VimoiRenderedRegion
---@field output_range VimoiByteRange Rendered-output bytes.
---@field source VimoiByteRange Template-source bytes.
---@field kind "static"|"repeated"|"dynamic"|"ambiguous"

-- Regions are transient projections between neighboring sentinel points. The
-- persistent map stores no expanded static/dynamic range table.
---@param map VimoiSourceMap
---@param index integer Odd: gap before a sentinel; even: its restored literal.
---@return VimoiRenderedRegion
local function region_at(map, index)
  local execution = math.floor((index + 1) / 2)
  local slot = map.output_slots[execution]
  if index % 2 == 0 then
    return {
      source = { start_byte = map.source_bytes[slot], end_byte = map.source_bytes[slot + 1] },
      output_range = {
        start_byte = map.output_bytes[execution],
        end_byte = map.output_bytes[execution] + (map.source_bytes[slot + 1] - map.source_bytes[slot]),
      },
      kind = map.source_types[slot] == M.REPEATED and "repeated" or "static",
    }
  end
  local previous = map.output_slots[execution - 1]
  local first, last = map.source_bytes[previous + 1], map.source_bytes[slot]
  return {
    source = { start_byte = first, end_byte = math.max(first, last) },
    output_range = {
      start_byte = map.output_bytes[execution - 1] + (map.source_bytes[previous + 1] - map.source_bytes[previous]),
      end_byte = map.output_bytes[execution],
    },
    kind = last < first and "ambiguous" or "dynamic",
  }
end

---Project output intervals locally, keeping both sides of zero-width insertion anchors.
---@param map VimoiSourceMap
---@param first? integer
---@param last? integer
---@return fun(): VimoiRenderedRegion?
function M.regions(map, first, last)
  -- BOF/EOF records bound real regions; they do not add editable static ranges.
  local low, high = 3, #map.output_bytes * 2 - 1
  if first then
    while low <= high do
      local middle = math.floor((low + high) / 2)
      local execution = math.floor((middle + 1) / 2)
      local end_byte = map.output_bytes[execution]
      if middle % 2 == 0 then
        local slot = map.output_slots[execution]
        end_byte = end_byte + (map.source_bytes[slot + 1] - map.source_bytes[slot])
      end
      if end_byte < first then
        low = middle + 1
      else
        high = middle - 1
      end
    end
  end
  local index, finish = low, #map.output_bytes * 2 - 1
  return function()
    if index > finish then
      return
    end
    local region = region_at(map, index)
    if last and region.output_range.start_byte > last then
      return
    end
    index = index + 1
    return region
  end
end

---Find the containing slot; equal starts choose the last slot, skipping empty anchors.
---@param map VimoiTemplateParts|VimoiSourceMap
---@param byte integer
---@return integer
function M.source_slot(map, byte)
  local low, high = 1, #map.source_types
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if map.source_bytes[middle] <= byte then
      low = middle + 1
    else
      high = middle - 1
    end
  end
  return high
end

---Iterate visible literals without scanning slots before the viewport.
---@param map VimoiSourceMap
---@param first integer
---@param last integer Exclusive.
---@return fun(): integer?
function M.source_parts(map, first, last)
  local index = math.max(1, M.source_slot(map, first)) - 1
  return function()
    while index < #map.source_types do
      index = index + 1
      if map.source_bytes[index] >= last then
        return
      end
      local kind = map.source_types[index]
      if kind == M.LITERAL or kind == M.REPEATED then
        return index
      end
    end
  end
end

---Map a source position through its first literal execution or adjacent dynamic boundaries.
---@param map VimoiSourceMap
---@param byte integer
---@return integer? first
---@return integer? last Exclusive.
---@return boolean? literal
function M.source_span(map, byte)
  if byte < 0 or byte > map.source_size then
    return nil
  end
  local slot = M.source_slot(map, byte)
  local kind, execution = map.source_types[slot], map.output_indices[slot]
  if kind == M.BOUNDARY then
    local position = map.output_bytes[execution]
    return position, position, false
  end
  if kind == M.LITERAL or kind == M.REPEATED then
    if execution > 0 then
      local output = map.output_bytes[execution]
      return output + byte - map.source_bytes[slot],
        output + (map.source_bytes[slot + 1] - map.source_bytes[slot]),
        true
    end
    -- Every literal is followed by an action, trim slot or EOF anchor.
    execution = map.output_indices[slot + 1]
  end
  local right, left = map.output_slots[execution], map.output_slots[execution - 1]
  local source_first = map.source_bytes[left + 1]
  local source_last = map.source_bytes[right]
  if byte >= source_first and byte < source_last then
    return map.output_bytes[execution - 1] + (map.source_bytes[left + 1] - map.source_bytes[left]),
      map.output_bytes[execution],
      false
  end
end

---@param map VimoiSourceMap
---@param byte integer
---@return integer source_byte
function M.output_position(map, byte)
  if byte < 0 then
    return 0
  end
  if byte >= map.output_size then
    return map.source_size
  end
  local low, high = 1, #map.output_bytes
  while low <= high do
    local middle = math.floor((low + high) / 2)
    if map.output_bytes[middle] <= byte then
      low = middle + 1
    else
      high = middle - 1
    end
  end
  local left, right = map.output_slots[high], map.output_slots[high + 1]
  local output_first = map.output_bytes[high] + (map.source_bytes[left + 1] - map.source_bytes[left])
  if byte < output_first then
    return map.source_bytes[left] + byte - map.output_bytes[high]
  end
  local source_first, source_last = map.source_bytes[left + 1], map.source_bytes[right]
  return source_first + math.min(byte - output_first, math.max(0, source_last - source_first))
end

---Materialize a complete projection only when explicitly requested.
---@param map VimoiSourceMap
---@return VimoiRenderedRegion[]
function M.rendered_regions(map)
  local regions = {}
  for region in M.regions(map) do
    regions[#regions + 1] = region
  end
  return regions
end

return M
