local M = {}
local util = require("vimoi.core.util")
local job = require("vimoi.core.job")

-- The source root and init mapping are fixed at setup. Other query results
-- stay cached until invalidated. Template output is cached only when requested;
-- `cat` and ordinary commands always run.
local chezmoi_command = { "chezmoi" }
-- Preserve the setup-time init mapping when ordinary query results are cleared.
local initial_paths = {}
local cache = { paths = {}, data = {}, templates = {}, template_order = {}, directories = {} }
-- Cached asynchronous template requests are shared by views and diagnostics.
-- Each caller owns a cancellable subscription; only the final cancellation kills the process.
---@class VimoiTemplateRequest
---@field job? VimoiCommand
---@field clients { command: VimoiCommand, callback: fun(output: string?, error: string?) }[]
---@type table<string, VimoiTemplateRequest>
local template_jobs = {}
-- Consumers use this version to reject derived results from an old context.
M.context_generation = 0

---@class VimoiData: table
---@field [string] any
---@field chezmoi { sourceDir: string, destDir: string, configFile: string }

---@alias VimoiCacheScope "all"|"paths"|"data"|"templates"

---Data invalidation also clears template results that may depend on that data.
---@param scope? VimoiCacheScope Defaults to all.
function M.invalidate(scope)
  scope = scope or "all"
  if scope ~= "all" and scope ~= "paths" and scope ~= "data" and scope ~= "templates" then
    error("unknown chezmoi cache scope: " .. tostring(scope))
  end
  cache.directories = {}
  if scope == "all" or scope == "paths" then
    cache.paths = vim.deepcopy(initial_paths)
  end
  if scope == "all" or scope == "data" then
    cache.data = {}
  end
  if scope ~= "paths" then
    cache.templates, cache.template_order, template_jobs = {}, {}, {}
    M.context_generation = M.context_generation + 1
    vim.api.nvim_exec_autocmds("User", { pattern = "VimoiCacheInvalidated", modeline = false })
  end
end

---Discover the source root and config path and initialize query caches.
---@param executable string
---@param config_path? string
M.setup = util.once(function(executable, config_path)
  config_path = config_path and util.normalize_path(config_path)
  chezmoi_command = config_path and { executable, "--config", config_path } or { executable }
  local output, err = M.run({ "source-path" })
  if not output then
    error(err, 0)
  end
  if vim.trim(output) == "" then
    error("chezmoi source-path returned an empty path", 0)
  end
  local source_root = util.normalize_path(vim.trim(output))
  if not config_path then
    local config_error
    config_path, config_error = M.run({ "execute-template", "{{ .chezmoi.configFile }}" })
    if not config_path then
      error(config_error, 0)
    end
    if vim.trim(config_path) == "" then
      error("chezmoi execute-template returned an empty config path", 0)
    end
    config_path = util.normalize_path(vim.trim(config_path))
  end
  local source
  for _, name in ipairs(vim.fn.sort(vim.tbl_keys(require("vimoi.core.source").init_template_names))) do
    local candidate = vim.fs.joinpath(source_root, name)
    if vim.uv.fs_stat(candidate) then
      source = candidate
      break
    end
  end
  if source then
    initial_paths[source], initial_paths[config_path] = config_path, source
  end
  M.source_root = source_root
  M.invalidate()
  M.config_path = config_path
end)

---Run one chezmoi command; higher-level methods decide whether to cache it.
---@overload fun(args: string[], opts: { callback: fun(output: any, error: string?), decode_json?: boolean, stdin?: string, timeout?: integer, text?: boolean, mode?: "notify"|"modal" }): VimoiCommand
---@overload fun(args: string[], opts: { decode_json: true, stdin?: string, timeout?: integer }): any?, string?
---@param args string[]
---@param opts? { decode_json?: boolean, callback?: fun(output: any, error: string?), stdin?: string, timeout?: integer, text?: boolean, mode?: "notify"|"modal" }
---@return string? output
---@return string? error
function M.run(args, opts)
  opts = opts or {}
  local argv = vim.list_extend(vim.list_slice(chezmoi_command), args)
  -- Path/config identity queries do not render user templates. Everything that
  -- can consult data/password helpers gets cancellable, asynchronous execution.
  local slow = args[1] == "data" or args[1] == "cat" or args[1] == "execute-template"
  if args[1] == "execute-template" and args[2] == "{{ .chezmoi.configFile }}" then
    slow = false
  end
  local command_opts = {
    text = opts.text ~= false,
    stdin = opts.stdin,
    timeout = opts.timeout,
    label = "chezmoi " .. args[1],
    mode = slow and (opts.mode or (opts.callback and "notify" or "modal")) or nil,
  }
  local function finish(result)
    if result.code ~= 0 then
      local message = result.stderr and result.stderr ~= "" and result.stderr or result.stdout
      return nil, ("%s failed (%d): %s"):format(table.concat(argv, " "), result.code, vim.trim(message or ""))
    end
    local output = result.stdout or ""
    if not opts.decode_json then
      return output
    end
    local ok, decoded = pcall(vim.json.decode, output)
    if not ok then
      return nil, "cannot decode JSON from `" .. table.concat(argv, " ") .. "`: " .. tostring(decoded)
    end
    return decoded
  end
  if opts.callback then
    command_opts.callback = function(result)
      opts.callback(finish(result))
    end
    return job.run(argv, command_opts)
  end
  return finish(job.run(argv, command_opts))
end

---Map a source file to its target, or a target file back to its source.
---@param path string
---@return string? counterpart
---@return string? error
function M.counterpart_path(path)
  path = util.normalize_path(path)
  local source_root = M.source_root
  if not source_root then
    return nil, "vimoi.nvim is not initialized"
  end
  local is_source = vim.fs.relpath(source_root, path) ~= nil
  local paths = cache.paths
  local cached = paths[path]
  if cached and vim.uv.fs_stat(is_source and path or cached) then
    return cached
  end
  local output, err = M.run({ is_source and "target-path" or "source-path", path })
  if not output then
    return nil, err
  end
  local counterpart = vim.trim(output)
  if counterpart == "" then
    return "" -- Never cache absence: the file may be added later.
  end
  counterpart = util.normalize_path(counterpart)

  if is_source then
    -- target-path also returns plausible paths for ignored and special source
    -- files. Only a reverse source-path lookup confirms an active target.
    local active_source, reverse_error = M.run({ "source-path", counterpart })
    if not active_source then
      return nil, reverse_error
    end
    if util.normalize_path(vim.trim(active_source)) ~= path then
      return nil, "chezmoi target does not map back to this source file"
    end
  end

  if vim.uv.fs_stat(is_source and path or counterpart) then
    paths[path] = counterpart
    paths[counterpart] = path
  end
  return counterpart
end

---Resolve a managed source/target pair; path identity and caches belong here.
---@param path string
---@return string? source
---@return string? target
---@return string? error
function M.resolve_paths(path)
  if path == "" then
    return nil, nil, "current buffer has no file path"
  end
  path = util.normalize_path(path)
  local counterpart, err = M.counterpart_path(path)
  if not counterpart or counterpart == "" then
    return nil, nil, err or "current file is not managed by chezmoi"
  end
  if vim.fs.relpath(M.source_root, path) ~= nil then
    return path, counterpart
  end
  return counterpart, path
end

---@return VimoiData? data
---@return string? error
function M.data()
  if cache.data.value then
    return cache.data.value
  end
  return util.await(function(done)
    M.data_async(done, "modal")
  end)
end

-- Subscribers are independent: one failing continuation must not strand the
-- others. Deliver every result before propagating the first callback error.
---@param callbacks function[]
local function deliver_results(callbacks, ...)
  local failed, first_error = false, nil
  for _, callback in ipairs(callbacks) do
    local ok, err = pcall(callback, ...)
    if not ok and not failed then
      failed, first_error = true, err
    end
  end
  if failed then
    error(first_error, 0)
  end
end

---@param callback fun(data: VimoiData?, error: string?)
---@param mode? "notify"|"modal"
---@return VimoiCommand?
function M.data_async(callback, mode)
  local data = cache.data.value
  if data then
    vim.schedule(function()
      callback(data)
    end)
    return
  end
  if cache.data.waiters then
    cache.data.waiters[#cache.data.waiters + 1] = callback
    if mode == "modal" and cache.data.job and cache.data.job.progress then
      cache.data.job.progress.focus()
    end
    return cache.data.job
  end
  cache.data.waiters = { callback }
  -- Only data/all invalidation replaces this namespace. Template-only changes
  -- must not cancel unrelated data requests or consume their callbacks.
  local request_data_cache = cache.data
  request_data_cache.job = M.run({ "data", "--format=json" }, {
    decode_json = true,
    mode = mode,
    callback = function(loaded, err)
      if cache.data ~= request_data_cache then
        loaded, err = nil, "chezmoi cache invalidated; retry"
      elseif loaded ~= nil and (type(loaded) ~= "table" or type(loaded.chezmoi) ~= "table") then
        loaded, err = nil, "invalid `chezmoi data`: missing chezmoi object"
      elseif loaded then
        cache.data.value = loaded
      end
      local callbacks = request_data_cache.waiters
      request_data_cache.waiters, request_data_cache.job = nil, nil
      deliver_results(callbacks, loaded, err)
    end,
  })
  return request_data_cache.job
end

---Template results are uncached unless cache=true. Cached results are bounded
---to 32 inputs and invalidated with data/templates. Async hits remain scheduled.
---@overload fun(source: string, opts: { init?: boolean, timeout?: integer, cache?: boolean, callback: fun(output: string?, error: string?) }): VimoiCommand?
---@overload fun(source: string, opts: { init?: boolean, timeout?: integer, cache?: boolean, callback?: nil }): string?, string?
---@param source string
---@param opts? { init?: boolean, timeout?: integer, cache?: boolean, callback?: fun(output: string?, error: string?) }
---@return string|VimoiCommand? output
---@return string? error
function M.execute_template(source, opts)
  opts = opts or {}
  local args = { "execute-template", opts.init and "--init" or nil }
  -- Template output is byte-addressed; normalizing CRLF would corrupt the map.
  local run_options = { stdin = source, timeout = opts.timeout, callback = opts.callback, text = false }
  if not opts.cache then
    return M.run(args, run_options)
  end

  local request_templates = cache.templates
  local template_order = cache.template_order
  local cache_key = (opts.init and "init\0" or "normal\0") .. source
  local cached_output = request_templates[cache_key]
  if cached_output ~= nil then
    if opts.callback then
      vim.schedule(function()
        opts.callback(cached_output)
      end)
      return
    end
    return cached_output
  end

  local function finish(output, err)
    -- An old request may return its snapshot, but must not refill a new cache.
    if output ~= nil and cache.templates == request_templates then
      if request_templates[cache_key] == nil then
        template_order[#template_order + 1] = cache_key
        if #template_order > 32 then
          request_templates[table.remove(template_order, 1)] = nil
        end
      end
      request_templates[cache_key] = output
    end
    return output, err
  end
  if opts.callback then
    local jobs = template_jobs
    local pending_key = cache_key .. "\0" .. tostring(opts.timeout)
    local request = jobs[pending_key]
    local first = not request
    if not request then
      request = { clients = {} }
      jobs[pending_key] = request
    end
    local command = setmetatable({ label = "chezmoi execute-template", finished = false, cancelled = false }, {
      __index = function(_, key)
        return request.job and request.job[key]
      end,
    })
    local callback = assert(opts.callback)
    function command.cancel()
      if command.finished then
        return
      end
      command.cancelled, command.finished = true, true
      vim.schedule(function()
        callback(nil, "command cancelled")
      end)
      for _, client in ipairs(request.clients) do
        if not client.command.finished then
          return
        end
      end
      if jobs[pending_key] == request then
        jobs[pending_key] = nil
      end
      if request.job then
        request.job.cancel()
      end
    end
    request.clients[#request.clients + 1] = { command = command, callback = callback }
    if first then
      run_options.callback = function(output, err)
        output, err = finish(output, err)
        if jobs[pending_key] == request then
          jobs[pending_key] = nil
        end
        local callbacks = {}
        for _, client in ipairs(request.clients) do
          if not client.command.finished then
            client.command.finished = true
            client.command.cancelled = request.job and request.job.cancelled or false
            callbacks[#callbacks + 1] = client.callback
          end
        end
        deliver_results(callbacks, output, err)
      end
      local template_job = M.run(args, run_options)
      ---@cast template_job VimoiCommand
      request.job = template_job
    end
    return command
  end
  return finish(M.run(args, run_options))
end

---Cache shared-template directory discovery until a filesystem/cache invalidation.
---@param source_dir string
---@return string[]
function M.template_directories(source_dir)
  source_dir = util.normalize_path(source_dir)
  if not cache.directories[source_dir] then
    cache.directories[source_dir] = vim.fs.find(".chezmoitemplates", {
      path = source_dir,
      type = "directory",
      limit = math.huge,
    })
  end
  return cache.directories[source_dir]
end

return M
