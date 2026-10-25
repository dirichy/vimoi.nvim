-- One source session owns rendered state and its attached views.
-- Windows remain Neovim resources; destroying a view only exits plugin mode.
local M = {}
local api = vim.api
local edits = require("vimoi.gotmpl.buffer_edits")
local util = require("vimoi.util")
local cli = require("vimoi.cli")

---@class VimoiOutputMap
---@field tick integer Source buffer version represented by this map.
---@field validate boolean
---@field validation_target? string
---@field context_generation integer Rendering context represented by this map.
---@field path string Source path represented by this map.
---@field source_size integer
---@field output_size integer
---@field source_eol boolean
---@field source_starts integer[]
---@field output_starts integer[]
---@field template_tags VimoiTemplateTag[]
---@field literal_parts VimoiLiteralPart[]
---@field regions VimoiRenderedRegion[]

---@class VimoiSessionOptions
---@field once? boolean Unregister after the first result.
---@field initial? boolean Deliver an already current result; defaults to true.
---@field validate? boolean Override the source session’s validation mode.
---@field target? string Explicit cat target when overriding validation for a file pair.

---@class VimoiSourceSession
---@field buf integer Read-only rendered buffer shared by all consumers.
---@field views table<VimoiTemplateView, boolean> Attached window views.
---@field map? VimoiOutputMap Last successful mapping; complete text stays in buffers.
---@field subscribers table<function, VimoiSessionOptions> Output-change callbacks.
---@field automatic? fun(cancel_render?: boolean) Combined automatic subscription.
---@field check? function Shared debounced render computation.
---@field tick? integer Source version represented by prepared/root.
---@field root? TSNode Current syntax tree for template diagnostics.
---@field prepared? VimoiPreparedTrace Temporary input while rendering.
---@field error_tags? VimoiTemplateTag[] Tag positions in a failed skeleton.
---@field skeleton? string Current execution cache key, including context prelude.
---@field prefix? string
---@field init? boolean
---@field context_generation? integer Execution cache version, including failures.
---@field rendered_skeleton? string Cached execution of skeleton.
---@field reported? boolean Whether the current error was reported.
---@field error? string Current render failure; map/output retain the last success.
---@field request? table Identity of the current render request.
---@field cancelled? boolean Explicit cancellation also blocks a queued render.
---@field validate boolean
---@field validation_target? string Explicit cat target; otherwise use the managed target.
---@field target_path? string Managed target corresponding to source_path.
---@field initialized? boolean Nil while constructing; false caches construction failure, true enables rendering.
---@field validation_started? integer Start time of the last cat validation.
---@field validation_ms? number Extra cat wait after baseline rendering; parallel time is counted as rendering.
---@field job? { cancel: fun(), cancelled?: boolean }
---@field source_path? string Source path used for native host root discovery.

---@type table<integer, VimoiSourceSession>
local buffers = {}
local diagnostics_enabled, host_enabled, rendered_enabled, configured_validation

---@param source integer
---@return VimoiSourceSession
function M.get(source)
  local state = buffers[source]
  if state and api.nvim_buf_is_valid(state.buf) and not api.nvim_buf_is_loaded(state.buf) then
    api.nvim_buf_delete(state.buf, { force = true })
  end
  local source_path = api.nvim_buf_get_name(source)
  if not state or not api.nvim_buf_is_loaded(state.buf) then
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].undolevels = -1
    vim.bo[buf].readonly = true
    vim.bo[buf].modifiable = false
    vim.b[buf].vimoi_output_source = source
    api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = function()
        util.notify("rendered buffers cannot be saved", "output", vim.log.levels.ERROR)
      end,
    })
    state = state or { subscribers = {}, views = {}, validate = require("vimoi").config.diff.validate }
    state.buf, state.map, state.source_path = buf, nil, nil
    buffers[source] = state
  end
  if state.source_path ~= source_path then
    local path = source_path:match("^%a[%w+.-]*://") and "" or source_path
    local target = path ~= ""
        and cli.source_root
        and vim.fs.relpath(cli.source_root, path)
        and cli.counterpart_path(path)
      or nil
    path = target and target ~= "" and target or path:gsub("%.tmpl$", "")
    local directory = path ~= "" and vim.fs.dirname(path) or vim.fn.getcwd()
    local basename = path ~= "" and vim.fs.basename(path) or "buffer"
    api.nvim_buf_set_name(state.buf, directory .. "/.vimoi-" .. source .. "-" .. basename)
    state.source_path, state.target_path = source_path, target
  end
  local target = state.validation_target or state.target_path
  local init = require("vimoi.filetype").init_template_names[vim.fs.basename(source_path)]
  if state.initialized == nil and (not state.validate or not target or target == "" or init) then
    state.initialized = true
  end
  return state
end

---@param source integer
---@param state VimoiSourceSession
---@return boolean
local function current(source, state)
  return state.initialized == true
    and api.nvim_buf_is_loaded(state.buf)
    and state.map ~= nil
    and not state.error
    and not state.request
    and state.map.validate == state.validate
    and state.map.validation_target == state.validation_target
    and state.map.tick == api.nvim_buf_get_changedtick(source)
    and state.map.source_eol == vim.bo[source].endofline
    and state.map.path == api.nvim_buf_get_name(source)
    and state.map.context_generation == cli.context_generation
end

---Whether this exact mapping still represents the current source and output.
---@param source integer
---@param map VimoiOutputMap
---@return boolean
function M.is_current(source, map)
  local state = buffers[source]
  return state ~= nil and state.map == map and current(source, state)
end

---Materialize text only for a render/merge operation, never retain it in state.
---@param source integer
---@return VimoiSourceMapTrace?
function M.snapshot(source)
  local state = M.get(source)
  if not current(source, state) then
    return
  end
  local map = assert(state.map)
  return {
    source = util.buffer_text(source),
    output = util.buffer_text(state.buf),
    template_tags = map.template_tags,
    literal_parts = map.literal_parts,
    regions = map.regions,
    output_starts = map.output_starts,
    source_starts = map.source_starts,
    skeleton = assert(state.skeleton),
    prefix = assert(state.prefix),
    init = state.init == true,
    context_generation = map.context_generation,
    rendered_skeleton = assert(state.rendered_skeleton),
  }
end

-- Snapshot callbacks so registering/unregistering inside a callback is safe.
local function publish(state, err)
  for _, callback in ipairs(vim.tbl_keys(state.subscribers)) do
    local opts = state.subscribers[callback]
    if opts then
      if opts.once then
        state.subscribers[callback] = nil
      end
      callback(not err and state or nil, err or state.error)
    end
  end
end

---@param state VimoiSourceSession
local function cancel_request(state)
  state.request = nil
  if state.job then
    state.job.cancel()
    state.job = nil
  end
end

---@param source integer
---@param trace VimoiSourceMapTrace Temporary completed render or merge candidate.
---@return VimoiSourceSession
function M.update(source, trace)
  local state = M.get(source)
  if current(source, state) then
    return state
  end
  if state.initialized ~= true then
    if state.check then
      state.check()
    end
    return state
  end
  cancel_request(state)
  local before = util.buffer_text(state.buf)
  if before ~= trace.output then
    vim.bo[state.buf].readonly, vim.bo[state.buf].modifiable = false, true
    local ok, err = pcall(edits.apply, state.buf, before, trace.output, edits.diff(before, trace.output))
    vim.bo[state.buf].modifiable, vim.bo[state.buf].readonly, vim.bo[state.buf].modified = false, true, false
    if not ok then
      error(err)
    end
  end
  state.map = {
    tick = api.nvim_buf_get_changedtick(source),
    validate = state.validate,
    validation_target = state.validation_target,
    path = api.nvim_buf_get_name(source),
    context_generation = trace.context_generation,
    source_size = #trace.source,
    output_size = #trace.output,
    source_eol = trace.source:sub(-1) == "\n",
    source_starts = util.line_starts(trace.source),
    output_starts = util.line_starts(trace.output),
    template_tags = trace.template_tags,
    literal_parts = trace.literal_parts,
    regions = require("vimoi.gotmpl.source_map").rendered_regions(trace),
  }
  state.skeleton, state.prefix, state.init = trace.skeleton, trace.prefix, trace.init
  state.context_generation, state.rendered_skeleton = trace.context_generation, trace.rendered_skeleton
  state.prepared, state.root, state.error_tags, state.error = nil, nil, nil, nil
  publish(state)
  return state
end

---Refresh literal-only edits synchronously from the cached skeleton execution.
---Structural/context changes return nil and use the shared asynchronous request.
---@param source integer
---@return VimoiSourceMapTrace?
function M.rebuild(source)
  local state = M.get(source)
  if current(source, state) then
    return M.snapshot(source)
  end
  if
    state.error
    or state.initialized ~= true
    or not state.rendered_skeleton
    or not state.map
    or state.map.path ~= api.nvim_buf_get_name(source)
    or state.context_generation ~= cli.context_generation
  then
    return
  end
  local renderer = require("vimoi.gotmpl.source_map")
  local prepared = renderer.prepare(util.buffer_text(source), { buf = source, init = state.init })
  if not prepared or prepared.skeleton ~= state.skeleton then
    return
  end
  local trace = renderer.restore(prepared, state.rendered_skeleton)
  if trace then
    M.update(source, trace)
  end
  return trace
end

local function cancel(source, state)
  state.cancelled = true
  cancel_request(state)
  state.prepared = nil
  vim.schedule(function()
    if buffers[source] == state then
      publish(state, "command cancelled")
    end
  end)
end

-- Construction uses disk text and a private parser. Buffer edits only queue later rendering.
local function construct(source, state)
  if state.request then
    return
  end
  local request = {}
  state.request = request
  state.prepared, state.root, state.error_tags = nil, nil, nil
  vim.schedule(function()
    if buffers[source] ~= state or state.request ~= request then
      return
    end
    util.async(function()
      local renderer = require("vimoi.gotmpl.source_map")
      local target = assert(state.validation_target or state.target_path)
      local source_path = api.nvim_buf_get_name(source)
      local baseline, err = util.read_file(source_path)
      local trace, actual
      if baseline then
        state.validation_started = vim.uv.hrtime()
        trace, err, actual = util.await(function(done)
          local jobs, remaining, settled = {}, 2, false
          local render_error, cat_error, rendered_at, validated_at
          local construction = { cancelled = false }
          state.job = construction
          function construction.cancel()
            if settled then
              return
            end
            settled, construction.cancelled = true, true
            for _, job in pairs(jobs) do
              job.cancel()
            end
            done(nil, "command cancelled")
          end
          local function finish()
            if settled then
              return
            end
            for _, job in pairs(jobs) do
              if job.cancelled then
                return construction.cancel()
              end
            end
            remaining = remaining - 1
            local error = render_error or cat_error
            if remaining > 0 and not error then
              return
            end
            settled = true
            if error then
              for _, job in pairs(jobs) do
                job.cancel()
              end
            else
              state.validation_ms = math.max(0, validated_at - rendered_at) / 1e6
            end
            done(trace, error, actual)
          end
          -- Start cat first; its process runs while the skeleton is prepared/rendered.
          jobs[1] = cli.run({ "cat", target }, {
            text = false,
            callback = function(output, error)
              actual, cat_error, validated_at = output, error, vim.uv.hrtime()
              finish()
            end,
          })
          if not settled then
            jobs[2] = renderer.trace_async(
              baseline,
              { prefix = renderer.context_prefix(source, false) },
              function(result, error)
                trace, render_error, rendered_at = result, error, vim.uv.hrtime()
                finish()
              end
            )
          end
        end)
      end
      if buffers[source] ~= state or state.request ~= request then
        return
      end
      if trace and actual and actual ~= trace.output then
        err = "sentinel rendering differs from `chezmoi cat`; this template uses an unsupported render context"
      end
      if state.job and state.job.cancelled then
        cancel(source, state)
        return
      end
      state.job, state.request = nil, nil
      state.initialized, state.error = err == nil, err
      if err then
        state.check()
        return
      end
      if trace then
        state.skeleton, state.prefix, state.init = trace.skeleton, trace.prefix, trace.init
        state.context_generation, state.rendered_skeleton = trace.context_generation, trace.rendered_skeleton
      end
      if
        trace
        and trace.context_generation == cli.context_generation
        and source_path == api.nvim_buf_get_name(source)
        and trace.source == util.buffer_text(source)
      then
        M.update(source, trace)
      else
        state.check()
      end
    end)
  end)
end

---@param buf integer
---@param state VimoiSourceSession
---@return { tick: integer, eol: boolean, syntax?: boolean, cached?: boolean }?
local function check(buf, state)
  M.get(buf)
  if state.initialized == nil then
    return
  end
  if current(buf, state) then
    return { tick = assert(state.map).tick, eol = state.map.source_eol, cached = true }
  end
  local source_map = require("vimoi.gotmpl.source_map")
  local source = util.buffer_text(buf)
  local eol = vim.bo[buf].endofline
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "gotmpl")
  if not ok or not parser then
    cancel_request(state)
    state.root, state.prepared, state.skeleton = nil, nil, nil
    state.error = "gotmpl parser is required; run :checkhealth vimoi"
    return { tick = api.nvim_buf_get_changedtick(buf), eol = eol }
  end
  local tree = parser:parse()[1]
  local root = tree and tree:root()
  if not root then
    return
  end
  if state.initialized == false then
    state.root = root
    return { tick = api.nvim_buf_get_changedtick(buf), eol = eol }
  end
  if root:has_error() then
    cancel_request(state)
    state.root, state.prepared, state.rendered_skeleton, state.skeleton = root, nil, nil, nil
    return { tick = vim.api.nvim_buf_get_changedtick(buf), eol = eol, syntax = true }
  end
  local filetype = require("vimoi.filetype")
  local init = filetype.init_template_names[vim.fs.basename(vim.api.nvim_buf_get_name(buf))] == true
  local prepared, prepare_error = source_map.prepare(source, { buf = buf, init = init })
  if not prepared then
    cancel_request(state)
    state.root, state.prepared, state.error, state.skeleton = root, nil, prepare_error, nil
    return { tick = api.nvim_buf_get_changedtick(buf), eol = eol }
  end
  state.prepared, state.root, state.tick = prepared, root, vim.api.nvim_buf_get_changedtick(buf)
  if
    state.skeleton ~= prepared.skeleton
    or state.init ~= prepared.init
    or state.context_generation ~= cli.context_generation
  then
    cancel_request(state)
    state.rendered_skeleton, state.error, state.reported = nil, nil, nil
  end
  state.skeleton, state.prefix, state.init = prepared.skeleton, prepared.prefix, prepared.init
  state.context_generation = prepared.context_generation
  if state.rendered_skeleton ~= nil or state.error then
    return { tick = state.tick, eol = assert(state.prepared).source:sub(-1) == "\n" }
  end
  if state.request then
    return
  end
  local request, context_generation = {}, cli.context_generation
  state.request = request
  -- The renderer completes prepared in place; newer edits may replace state.prepared.
  local rendered_skeleton, err = util.await(function(done)
    state.job = source_map.trace_async(source, { init = init, buf = buf, prepared = prepared }, function(trace, err)
      done(trace and trace.rendered_skeleton, err)
    end)
  end)
  -- Always retire this request before deciding whether to publish.
  -- An old completion must never clear a newer request's state.
  if buffers[buf] ~= state or state.request ~= request then
    return
  end
  local cancelled = state.job and state.job.cancelled
  state.job, state.request = nil, nil
  if cancelled then
    cancel(buf, state)
    return
  end
  if context_generation ~= cli.context_generation then
    return
  end
  state.error, state.rendered_skeleton = err, rendered_skeleton
  return { tick = state.tick, eol = assert(state.prepared).source:sub(-1) == "\n" }
end

-- Source edits share one debounce; cached output needs no new notification.
local function refresh(source)
  local state = buffers[source]
  if state and next(state.subscribers) then
    M.get(source)
    if not current(source, state) then
      state.cancelled = nil
      if state.initialized == nil then
        construct(source, state)
      else
        assert(state.check)()
      end
    end
  end
end

---Register output changes; stop(true) also cancels the shared source render.
---@param source integer
---@param callback fun(output: VimoiSourceSession?, error: string?)
---@param opts? VimoiSessionOptions
---@return fun(cancel_render?: boolean) stop
function M.register(source, callback, opts)
  local state = M.get(source)
  opts = opts or {}
  state.subscribers[callback] = opts
  if
    opts.validate ~= nil
    and (
      state.validate ~= opts.validate
      or (opts.validate and opts.target and (state.validation_target or state.target_path) ~= opts.target)
    )
  then
    cancel_request(state)
    if state.initialized == false then
      state.error, state.reported = nil, nil
    end
    state.validate, state.validation_target, state.initialized = opts.validate, opts.target, nil
  end
  if not state.check then
    local revision = 0
    local function is_active()
      return buffers[source] == state
        and not state.cancelled
        and next(state.subscribers) ~= nil
        and api.nvim_buf_is_loaded(source)
    end
    state.check = function()
      revision = revision + 1
      local queued_revision = revision
      vim.defer_fn(function()
        if queued_revision ~= revision or not is_active() then
          return
        end
        util.async(function()
          local result = check(source, state)
          if not result or not is_active() then
            return
          end
          if result.tick ~= api.nvim_buf_get_changedtick(source) or result.eol ~= vim.bo[source].endofline then
            -- A newer queued edit already covers this retry; keep its debounce.
            if queued_revision == revision then
              state.check()
            end
            return
          end
          if result.syntax then
            state.error = "template contains Tree-sitter parse errors"
          elseif result.cached then
            publish(state)
          elseif not state.error then
            local trace, err =
              require("vimoi.gotmpl.source_map").restore(assert(state.prepared), state.rendered_skeleton)
            state.error = err
            if trace then
              M.update(source, trace)
            end
          end
          if state.error then
            state.error_tags = state.prepared and state.prepared.template_tags
            state.prepared = nil
            publish(state)
          end
        end)
      end, 120)
    end
    api.nvim_buf_attach(source, false, {
      on_lines = function()
        refresh(source)
      end,
      on_reload = function()
        refresh(source)
      end,
    })
  end
  if opts.initial ~= false and current(source, state) then
    vim.schedule(function()
      if buffers[source] ~= state or not state.subscribers[callback] then
        return
      end
      if current(source, state) then
        if opts.once then
          state.subscribers[callback] = nil
        end
        callback(state)
      else
        refresh(source)
      end
    end)
  else
    refresh(source)
  end
  return function(cancel_render)
    if not state.subscribers[callback] then
      return
    end
    state.subscribers[callback] = nil
    if cancel_render then
      cancel(source, state)
    elseif not next(state.subscribers) then
      -- A synchronous view replacement can register the same source again.
      vim.schedule(function()
        if buffers[source] == state and not next(state.subscribers) then
          cancel_request(state)
          state.prepared = nil
        end
      end)
    end
  end
end

-- Automatic features share one subscription; explicit views keep their own users.
local function detach_automatic(source, state)
  if state.automatic then
    state.automatic()
    state.automatic = nil
    require("vimoi.diagnostic").clear(source, true)
    if package.loaded["vimoi.host_highlight"] then
      require("vimoi.host_highlight").clear(source)
    end
  end
end

local function update_automatic(source)
  if (diagnostics_enabled or rendered_enabled) and vim.bo[source].filetype == "gotmpl" then
    local state = M.get(source)
    if state.automatic then
      state.automatic()
    end
    state.automatic = M.register(source, function(rendered)
      if not rendered then
        return
      end
      if diagnostics_enabled then
        require("vimoi.diagnostic").update(source)
      end
      if rendered_enabled and not rendered.error and rendered.map then
        require("vimoi.host_highlight").update(source, rendered.map)
      end
    end)
  elseif buffers[source] then
    detach_automatic(source, buffers[source])
  end
end

---Apply automatic consumers without changing explicit view subscriptions.
function M.setup()
  local config = require("vimoi").config
  local diagnostics = config.diagnostics.enabled
  local host = diagnostics and config.diagnostics.host
  local rendered = config.highlight.mode == "rendered"
  local validation = config.diff.validate
  if
    diagnostics_enabled == diagnostics
    and host_enabled == host
    and rendered_enabled == rendered
    and configured_validation == validation
  then
    return
  end
  for source, state in pairs(buffers) do
    if configured_validation ~= validation then
      cancel_request(state)
      if state.initialized == false then
        state.error, state.reported = nil, nil
      end
      state.validate, state.validation_target, state.initialized = validation, nil, nil
      if state.check and next(state.subscribers) then
        refresh(source)
      end
    end
    if diagnostics_enabled and not diagnostics then
      require("vimoi.diagnostic").clear(source, true)
    elseif host_enabled and not host and package.loaded["vimoi.diagnostic"] then
      require("vimoi.diagnostic").clear_host(source, true)
    end
    if rendered_enabled and not rendered and package.loaded["vimoi.host_highlight"] then
      require("vimoi.host_highlight").clear(source)
    end
  end
  diagnostics_enabled, host_enabled, rendered_enabled, configured_validation = diagnostics, host, rendered, validation
  if rendered then
    require("vimoi.host_highlight")
  end
  for _, source in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(source) then
      update_automatic(source)
    end
  end
end

local group = api.nvim_create_augroup("vimoi-sessions", { clear = true })
api.nvim_create_autocmd("FileType", {
  group = group,
  callback = function(args)
    update_automatic(args.buf)
  end,
})
api.nvim_create_autocmd("User", {
  group = group,
  pattern = "VimoiHostFiletypeChanged",
  callback = function(args)
    if package.loaded["vimoi.host_highlight"] then
      require("vimoi.host_highlight").clear(args.data.buf)
    end
    local state = buffers[args.data.buf]
    if state and current(args.data.buf, state) then
      publish(state)
    else
      refresh(args.data.buf)
    end
  end,
})
api.nvim_create_autocmd({ "BufWritePost", "BufFilePost" }, {
  group = group,
  callback = function(args)
    refresh(args.buf)
  end,
})
api.nvim_create_autocmd("OptionSet", {
  group = group,
  pattern = "endofline",
  callback = function(args)
    refresh(args.buf)
  end,
})
api.nvim_create_autocmd("User", {
  group = group,
  pattern = "VimoiCacheInvalidated",
  callback = function()
    for source in pairs(buffers) do
      refresh(source)
    end
  end,
})
api.nvim_create_autocmd("BufUnload", {
  group = group,
  callback = function(args)
    local state = buffers[args.buf]
    if state then
      for view in pairs(state.views) do
        require("vimoi.gotmpl.view").close(view)
      end
      detach_automatic(args.buf, state)
      buffers[args.buf] = nil
      cancel_request(state)
      if api.nvim_buf_is_valid(state.buf) then
        api.nvim_buf_delete(state.buf, { force = true })
      end
    else
      local source = vim.b[args.buf].vimoi_output_source
      local owner = source and buffers[source]
      if owner and owner.buf == args.buf then
        owner.map = nil
        require("vimoi.diagnostic").clear(source, true)
        -- Let :bdelete/:bwipeout finish before replacing the shared buffer.
        vim.schedule(function()
          if buffers[source] == owner then
            refresh(source)
          end
        end)
      end
    end
  end,
})

return M
