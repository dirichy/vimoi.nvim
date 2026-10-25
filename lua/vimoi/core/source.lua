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
M.template_rules = {
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
  for _, rule in ipairs(M.template_rules) do
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
  for _, rule in ipairs(M.template_rules) do
    if rule.path_kind and filename:match("^" .. rule.pattern .. "$") then
      return rule.path_kind
    end
  end
  if vim.fs.basename(path):sub(1, #symlink_prefix) == symlink_prefix then
    return "symlink_target"
  end
end

return M
