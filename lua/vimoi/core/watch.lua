local M = {}
local util = require("vimoi.core.util")

---@class VimoiWatchRule
---@field path? string
---@field pattern? string Pattern matched against a slash-bounded source-relative path.
---@field scope VimoiCacheScope
---@field watch? "tree"|"parent"

---@class VimoiWatchOptions
---@field buffer_write_fallback? "auto"|boolean Auto falls back only for unmonitored directories; true always uses buffer writes.
---@field rules? VimoiWatchRule[] Source rules; replaces the defaults when supplied.

---@class VimoiWatchConfig: VimoiWatchOptions
---@field source_root string
---@field config_path string

---@type VimoiWatchConfig?
local config
-- Runtime state is not configuration. Watch directories rather than file inodes
-- so atomic replacement does not detach a watch; refresh discovers new folders.
-- Index only successfully started watchers by their directly monitored directory.
local watchers = {}
---@type VimoiCacheScope?
local pending_scope

-- First match wins. Tree rules cover a directory and descendants; parent rules
-- watch files through their directory. Rules without watch only filter events.
local default_rules = {
  { pattern = "/%.chezmoitemplates/", scope = "templates", watch = "tree" },
  { pattern = "/%.chezmoidata/", scope = "all", watch = "tree" },
  { pattern = "/%.chezmoidata%.[^/]+/$", scope = "all", watch = "parent" },
  -- Ignore rules affect managed-path lookups, not data or template execution.
  { pattern = "/%.chezmoiignore/$", scope = "paths", watch = "parent" },
}

---@return VimoiWatchRule?
local function matching_rule(path)
  if not config then
    return nil
  end
  local relative = vim.fs.relpath(config.source_root, path)
  local directory_path = relative and "/" .. relative .. "/"
  for _, rule in ipairs(config.rules) do
    if rule.path == path or (directory_path and rule.pattern and directory_path:match(rule.pattern)) then
      return rule
    end
  end
end

---Rebuild the best-effort watch list after explicit cache invalidation.
function M.refresh()
  if not config then
    return
  end
  for _, watcher in pairs(watchers) do
    watcher:stop()
    watcher:close()
  end
  watchers = {}
  local directories = { [config.source_root] = true }
  for _, rule in ipairs(config.rules) do
    if rule.path then
      directories[vim.fs.dirname(rule.path)] = true
    end
  end
  for name, kind in
    vim.fs.dir(config.source_root, {
      depth = math.huge,
      skip = function(directory)
        return vim.fs.basename(directory) ~= ".git"
      end,
    })
  do
    local path = vim.fs.joinpath(config.source_root, name)
    local rule = matching_rule(path)
    if rule and rule.watch then
      if kind == "directory" and rule.watch == "tree" then
        directories[path] = true
      end
      -- Watch parents too, so deleting/renaming a matched directory is observed.
      directories[vim.fs.dirname(path)] = true
    end
  end

  for directory in pairs(directories) do
    local watcher = vim.uv.new_fs_event()
    if watcher then
      local started = watcher:start(directory, {}, function(err, filename)
        if err then
          if watchers[directory] == watcher then
            watchers[directory] = nil
            watcher:stop()
            watcher:close()
          end
          return
        end
        ---@type VimoiCacheScope
        local scope = "all"
        if filename then
          local rule = matching_rule(vim.fs.joinpath(directory, filename))
          if not rule then
            return
          end
          scope = rule.scope
        end
        if pending_scope then
          -- A data/config event must not be lost behind a queued template event.
          if pending_scope ~= scope then
            pending_scope = "all"
          end
          return
        end
        -- Coalesce events without running chezmoi or rescanning the source tree.
        pending_scope = scope
        vim.schedule(function()
          local scope_to_invalidate = pending_scope
          pending_scope = nil
          require("vimoi.core.cli").invalidate(scope_to_invalidate)
        end)
      end)
      if started then
        watchers[directory] = watcher
      else
        -- No active entry: buffer writes automatically fall back for this directory.
        watcher:close()
      end
    end
  end
end

---@param opts VimoiWatchConfig
M.setup = util.once(function(opts)
  config = vim.tbl_extend("force", { rules = default_rules, buffer_write_fallback = "auto" }, opts)
  -- Always watch the selected config, without inserting into the caller's rules.
  config.rules = vim.list_extend({ { path = config.config_path, scope = "all", watch = "parent" } }, config.rules)
  M.refresh()
  local group = vim.api.nvim_create_augroup("vimoi-cli-cache", { clear = true })
  if config.buffer_write_fallback == false then
    return
  end
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(args)
      local path = util.normalize_path(args.file)
      if config.buffer_write_fallback == "auto" and watchers[vim.fs.dirname(path)] then
        return
      end
      local rule = matching_rule(path)
      if rule then
        require("vimoi.core.cli").invalidate(rule.scope)
      end
    end,
  })
end)

return M
