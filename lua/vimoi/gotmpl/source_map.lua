-- Map template source ranges to rendered output using sentinel markers.
local M = {}
local cli = require("vimoi.cli")

---Zero-based, half-open byte offsets [start_byte, end_byte); equal ends mark an insertion anchor.
---@class VimoiByteRange
---@field start_byte integer
---@field end_byte integer

---@class VimoiTemplateTagRange: VimoiByteRange
---@field left_trim boolean
---@field right_trim boolean

---Literal text between template tags, after trim, including empty text.
---@class VimoiLiteralPart
---@field source VimoiByteRange
---@field text string Source text after adjacent tags' whitespace trimming.
---@field output_ranges { start_byte: integer, end_byte: integer, execution_order: integer }[] Empty when skipped; multiple ranges when repeated.

---@class VimoiTemplateTag: VimoiTemplateTagRange
---@field text string Complete template tag, including its delimiters.
---@field control? string Control keyword used for merge-boundary choices.
---@field skeleton_start_byte? integer Tag start in the prepared skeleton; absent on parse-only results.

---Source order alternates literal_parts[i], template_tags[i], ending with one last literal part.
---@class VimoiTemplateParts
---@field source string
---@field template_tags VimoiTemplateTag[]
---@field literal_parts VimoiLiteralPart[]

---Prepared source structure. Output fields appear together after sentinel decoding.
---@class VimoiPreparedTrace: VimoiTemplateParts
---@field skeleton string Template tags with each literal part replaced by a sentinel.
---@field prefix string Context-injection actions included at the start of the skeleton.
---@field init boolean
---@field context_generation integer
---@field output? string Absent before rendering; present on a reused complete trace.
---@field rendered_skeleton? string

---Temporary complete render/merge input; repeated executions share a literal part.
---@class VimoiSourceMapTrace: VimoiPreparedTrace
---@field output string
---@field rendered_skeleton string

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

-- Include touching boundaries for zero-width edits so insertion/deletion cannot leave stale tags.
local function overlaps(start_byte, end_byte, other_start_byte, other_end_byte)
  if start_byte == end_byte or other_start_byte == other_end_byte then
    return start_byte <= other_end_byte and end_byte >= other_start_byte
  end
  return start_byte < other_end_byte and end_byte > other_start_byte
end

-- Definitions and blocks stay opaque so their output belongs to the call site.
-- Other control nodes are split into sibling delimiter pairs, preserving body slots.
-- Partial scans start at complete cached tags or new syntax ranges reported by the parser.
---@param node TSNode
---@param result VimoiTemplateTagRange[] Append complete tags in source order.
---@param range_start_byte? integer
---@param range_end_byte? integer
---@return integer visited_nodes
local function collect_tags(node, result, range_start_byte, range_end_byte)
  if node:type() == "define_action" or node:type() == "block_action" then
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
    return nil, "gotmpl Tree-sitter parser is required: " .. tostring(parser)
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

---Extract template tags and trimmed literal text before rendering.
---Only dirty syntax is walked; returned ranges and occurrence lists are fresh objects.
---@param source string
---@param buf? integer
---@return VimoiTemplateParts?
---@return string? error
---@return integer? visited_nodes Recursive visits and tag endpoints, excluding sibling searches and binary-search probes.
function M.parse(source, buf)
  local cached_tags, err, visited_nodes = parse_tags(source, buf)
  if not cached_tags then
    return nil, err
  end
  -- Export fresh objects so later byte shifts cannot mutate an existing trace.
  local template_tags = {}
  local controls = { ["if"] = true, range = true, with = true, ["else"] = true, ["end"] = true }
  for _, tag in ipairs(cached_tags) do
    local text = source:sub(tag.start_byte + 1, tag.end_byte)
    local keyword = text:match("^{{%-?%s*([%a]+)")
    template_tags[#template_tags + 1] = {
      start_byte = tag.start_byte,
      end_byte = tag.end_byte,
      left_trim = tag.left_trim,
      right_trim = tag.right_trim,
      text = text,
      control = controls[keyword] and keyword or nil,
    }
  end
  local literal_parts = {}
  -- Keep empty slots at file ends and between adjacent tags for boundary insertions and sentinels.
  for index = 1, #template_tags + 1 do
    local previous_tag, following_tag = template_tags[index - 1], template_tags[index]
    local start_byte = previous_tag and previous_tag.end_byte or 0
    local end_byte = following_tag and following_tag.start_byte or #source
    local untrimmed_text = source:sub(start_byte + 1, end_byte)
    -- Go trim removes only these four ASCII whitespace bytes; both sides may consume the whole slot.
    if previous_tag and previous_tag.right_trim then
      start_byte = start_byte + #(untrimmed_text:match("^[ \t\r\n]*") or "")
    end
    if following_tag and following_tag.left_trim then
      end_byte = end_byte - #(untrimmed_text:match("[ \t\r\n]*$") or "")
    end
    end_byte = math.max(start_byte, end_byte)
    literal_parts[#literal_parts + 1] = {
      source = { start_byte = start_byte, end_byte = end_byte },
      text = source:sub(start_byte + 1, end_byte),
      output_ranges = {},
    }
  end
  return { source = source, template_tags = template_tags, literal_parts = literal_parts }, nil, visited_nodes
end

-- One sentinel prefix per renderer keeps skeleton keys stable across literal edits.
local sentinel_prefix = ("__VIMOI_%x_%x__"):format(vim.uv.hrtime(), math.random(0, 0x7fffffff))
-- Only managed files have a target context. Keep raw strings, source-only files,
-- and init templates in execute-template's native context.
---@param buf? integer
---@param init boolean
---@return string
local function context_prefix(buf, init)
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

-- Replace each literal slot with its stable ID; unchanged tags/slot count reuse the rendered skeleton.
-- Complete text results are temporary; buffer-owned caches live in gotmpl/session.lua.
---@param source string
---@param opts? VimoiTraceOptions
---@return VimoiPreparedTrace?
---@return string? error
function M.prepare(source, opts)
  opts = opts or {}
  local init = opts.init == true
  local prefix = opts.prefix or context_prefix(opts.buf, init)
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
  for literal_part_id, _ in ipairs(template_parts.literal_parts) do
    local following_tag = template_parts.template_tags[literal_part_id]
    -- Every literal part gets a token, even between adjacent tags. Parsing has already
    -- applied ASCII whitespace trim to its text; the tokens cannot be trimmed.
    local sentinel = sentinel_prefix .. literal_part_id .. sentinel_prefix
    skeleton_parts[#skeleton_parts + 1] = sentinel
    skeleton_bytes = skeleton_bytes + #sentinel
    if following_tag then
      following_tag.skeleton_start_byte = skeleton_bytes
      skeleton_parts[#skeleton_parts + 1] = following_tag.text
      skeleton_bytes = skeleton_bytes + #following_tag.text
    end
  end
  local skeleton = table.concat(skeleton_parts)
  return {
    source = source,
    skeleton = skeleton,
    prefix = prefix,
    init = init,
    context_generation = cli.context_generation,
    literal_parts = template_parts.literal_parts,
    template_tags = template_parts.template_tags,
  }
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
  local byte_delta, execution_order = 0, 0
  local decode_error
  local output = rendered_skeleton:gsub(
    "()" .. sentinel_prefix .. "(%d+)" .. sentinel_prefix,
    function(position, literal_part_id)
      local literal_part = prepared_trace.literal_parts[tonumber(literal_part_id)]
      if not literal_part then
        decode_error = "unknown sentinel in rendered output"
        return ""
      end
      execution_order = execution_order + 1
      -- gsub positions refer to the original skeleton; accumulate replacement deltas for final output offsets.
      local start_byte = position - 1 + byte_delta
      literal_part.output_ranges[#literal_part.output_ranges + 1] =
        { start_byte = start_byte, end_byte = start_byte + #literal_part.text, execution_order = execution_order }
      byte_delta = byte_delta + #literal_part.text - (#sentinel_prefix * 2 + #literal_part_id)
      -- Replacement strings are not scanned again: literal {{ stays literal.
      return literal_part.text
    end
  )
  if decode_error then
    return nil, decode_error
  end
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
  if buf and context_prefix(buf, trace.init) ~= trace.prefix then
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
  local replacements, tag_index, edit_index, byte_delta = {}, 1, 1, 0
  for literal_id = 1, #trace.literal_parts do
    local following_tag = trace.template_tags[literal_id]
    local boundary = following_tag and following_tag.start_byte or #trace.source
    while edits[edit_index] and edits[edit_index].end_byte <= boundary do
      local edit = edits[edit_index]
      byte_delta = byte_delta + #edit.replacement - (edit.end_byte - edit.start_byte)
      edit_index = edit_index + 1
    end
    local new_boundary = boundary + byte_delta
    local replacement = {}
    while true do
      replacement[#replacement + 1] = sentinel_prefix .. tag_index .. sentinel_prefix
      local tag = prepared.template_tags[tag_index]
      if not tag or tag.start_byte >= new_boundary then
        break
      end
      -- The encoder only inserts these constant-string actions, never dynamic code.
      local braces = tag.text:match('^{{ "({+)" }}$')
      if not braces then
        return nil, "static edit changed a template tag"
      end
      replacement[#replacement + 1] = braces
      tag_index = tag_index + 1
    end
    replacements[literal_id] = table.concat(replacement)
    if following_tag then
      local tag = prepared.template_tags[tag_index]
      if not tag or tag.start_byte ~= new_boundary or tag.text ~= following_tag.text then
        return nil, "static edit changed a template tag"
      end
      tag_index = tag_index + 1
    end
  end
  local rendered_skeleton = trace.rendered_skeleton:gsub(sentinel_prefix .. "(%d+)" .. sentinel_prefix, function(id)
    return replacements[tonumber(id)]
  end)
  return M.restore(prepared, rendered_skeleton)
end

---Predict a literal edit using the same structure reconstruction as diff refresh.
---@param trace VimoiSourceMapTrace
---@param source string
---@return string?
function M.predict_literal_edit(trace, source)
  local updated_trace = M.rebuild(trace, source)
  return updated_trace and updated_trace.output
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
  local prepared_trace, prepare_error = M.prepare(source, opts)
  if not prepared_trace then
    vim.schedule(function()
      callback(nil, prepare_error)
    end)
    return
  end
  if #prepared_trace.template_tags == 0 then
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

-- Literal slots carry the source map, including zero-width insertion anchors.
-- Fill their intervening output with dynamic regions; preserve execution order
-- when several empty parts share one output byte position.
---@param trace VimoiSourceMapTrace
---@return VimoiRenderedRegion[]
function M.rendered_regions(trace)
  local occurrences = {}
  for _, literal_part in ipairs(trace.literal_parts) do
    for _, output_range in ipairs(literal_part.output_ranges) do
      occurrences[#occurrences + 1] = {
        output_range = output_range,
        source = literal_part.source,
        kind = #literal_part.output_ranges > 1 and "repeated" or "static",
      }
    end
  end
  table.sort(occurrences, function(a, b)
    if a.output_range.start_byte == b.output_range.start_byte then
      if a.output_range.end_byte == b.output_range.end_byte then
        return a.output_range.execution_order < b.output_range.execution_order
      end
      return a.output_range.end_byte < b.output_range.end_byte
    end
    return a.output_range.start_byte < b.output_range.start_byte
  end)

  local regions = {}
  local previous_output_end = 0
  local previous_source_end = 0
  for _, occurrence in ipairs(occurrences) do
    local source_end_byte = occurrence.source.start_byte
    local kind = "dynamic"
    if source_end_byte < previous_source_end then
      source_end_byte = previous_source_end
      kind = "ambiguous"
    end
    regions[#regions + 1] = {
      output_range = { start_byte = previous_output_end, end_byte = occurrence.output_range.start_byte },
      source = { start_byte = previous_source_end, end_byte = source_end_byte },
      kind = kind,
    }
    regions[#regions + 1] = occurrence
    previous_output_end = occurrence.output_range.end_byte
    previous_source_end = occurrence.source.end_byte
  end
  regions[#regions + 1] = {
    output_range = { start_byte = previous_output_end, end_byte = #trace.output },
    source = { start_byte = previous_source_end, end_byte = #trace.source },
    kind = "dynamic",
  }
  return regions
end

return M
