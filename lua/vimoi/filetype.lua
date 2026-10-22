local M = {}

local symlink_prefix = "symlink_"
M.symlink_pattern = symlink_prefix .. "*"

M.init_template_names = {}
local formats = { json = true, jsonc = true, toml = true, yaml = true, yml = true }
for format in pairs(formats) do
  M.init_template_names[".chezmoi." .. format .. ".tmpl"] = true
end

-- Only ignore/remove override the host language; other templates use normal detection.
---@class VimoiTemplateFileRule
---@field pattern string Lua filename pattern.
---@field host_filetype? string Override normal host-language detection.
---@field format? boolean The pattern capture must be a supported data format.
---@field path_kind? "target_patterns" File contents list patterns relative to the destination root.
---@type VimoiTemplateFileRule[]
local template_rules = {
  { pattern = ".*/%.chezmoiignore", host_filetype = "gitignore", path_kind = "target_patterns" },
  { pattern = ".*/%.chezmoiremove", host_filetype = "gitignore", path_kind = "target_patterns" },
  { pattern = ".*/%.chezmoiexternal%.([^./]+)", format = true },
  { pattern = ".*/%.chezmoitemplates/.+" },
  { pattern = ".*/%.chezmoiexternals/.+" },
}

---Match filename rules independently of source-root membership or setup.
---@param path string
---@return boolean
function M.is_template(path)
  if path:sub(-5) == ".tmpl" then
    return true
  end
  for _, rule in ipairs(template_rules) do
    local match = path:match("^" .. rule.pattern .. "$")
    if match and (not rule.format or formats[match]) then
      return true
    end
  end
  return false
end

---How this source file's contents refer to other paths; independent of setup.
---@param path string
---@return "target_patterns"|"symlink_target"?
function M.path_kind(path)
  local filename = path:gsub("%.tmpl$", "")
  for _, rule in ipairs(template_rules) do
    if rule.path_kind and filename:match("^" .. rule.pattern .. "$") then
      return rule.path_kind
    end
  end
  if vim.fs.basename(path):sub(1, #symlink_prefix) == symlink_prefix then
    return "symlink_target"
  end
end

-- Fixed at setup; filename rules also serve CLI queries before initialization.
---@type string?
local source_root

---Recognize template filenames inside the configured source root.
---@param path string
---@return string?
function M.detect(path)
  return source_root and M.is_template(path) and vim.fs.relpath(source_root, path) ~= nil and "gotmpl" or nil
end

local filetype_patterns = {}
for _, rule in ipairs(template_rules) do
  filetype_patterns[rule.pattern] = M.detect
end

local registration = {
  extension = { tmpl = M.detect },
  pattern = filetype_patterns,
}

---@param root string Configured chezmoi source directory.
M.setup = require("vimoi.util").once(function(root)
  source_root = root
  vim.filetype.add(registration)
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = vim.api.nvim_create_augroup("vimoi-source-filetypes", { clear = true }),
    callback = function(args)
      local path = vim.api.nvim_buf_get_name(args.buf)
      if
        path == ""
        or vim.bo[args.buf].buftype ~= ""
        or vim.fs.relpath(root, path) == nil
        or M.is_template(path)
        or M.path_kind(path) == "symlink_target"
      then
        return
      end
      local filetype, on_detect = M.host_filetype(path, args.buf)
      if filetype and filetype ~= vim.bo[args.buf].filetype then
        if on_detect then
          on_detect(args.buf)
        end
        vim.bo[args.buf].filetype = filetype
      end
    end,
  })
end)

---@param path string
---@param buf? integer
---@return string?
---@return function? on_detect Neovim's buffer initialization for the detected type.
function M.host_filetype(path, buf)
  local filename = path:gsub("%.tmpl$", "")
  local source_only = false
  for _, rule in ipairs(template_rules) do
    if filename:match("^" .. rule.pattern .. "$") then
      if rule.host_filetype then
        return rule.host_filetype
      end
      source_only = true
    end
  end

  if not source_only and source_root and vim.fs.relpath(source_root, path) ~= nil then
    -- Let chezmoi resolve attributes and renamed paths; CLI owns the shared cache.
    local target = require("vimoi.cli").counterpart_path(path)
    if target and target ~= "" then
      filename = target
    end
  end

  local filetype, on_detect = vim.filetype.match({ filename = filename, buf = buf })
  if filetype == "gotmpl" or filetype == "template" then
    -- Our own filename rule won the first match. Probe with a neutral name so
    -- the extension (or shebang for extensionless scripts) can select the host.
    local extension = filename:match("%.([^./]+)$")
    local probe = extension and "vimoi-host." .. extension or "vimoi-host"
    filetype, on_detect = vim.filetype.match({ filename = probe, buf = buf })
  end
  if filetype and filetype ~= "gotmpl" and filetype ~= "template" then
    return filetype, on_detect
  end

  -- Neovim's shell detector can return nil inside a FileType autocmd.
  local extension = filename:match("%.([^./]+)$")
  return ({ sh = "sh", bash = "bash", zsh = "zsh", ksh = "ksh", fish = "fish" })[extension]
end

return M
