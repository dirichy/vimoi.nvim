---@diagnostic disable: duplicate-set-field -- Isolated dependency failures and captured health reports.
local original_health, original_system = vim.health, vim.system
local original_has, original_access = vim.fn.has, vim.uv.fs_access
local original_add, original_query = vim.treesitter.language.add, vim.treesitter.query.get
local reports = {}
vim.health = {}
for _, level in ipairs({ "start", "ok", "info", "warn", "error" }) do
  vim.health[level] = function(message)
    reports[#reports + 1] = { level = level, message = message }
  end
end
vim.system = function()
  error("health must not launch chezmoi, setup, rendering, or data/password helpers")
end
local plugin = require("vimoi")
local health = require("vimoi.health")
local function has(level, fragment)
  for _, report in ipairs(reports) do
    if report.level == level and report.message:find(fragment, 1, true) then
      return true
    end
  end
  return false
end
local function check()
  reports = {}
  health.check()
end

assert(package.loaded["vimoi.cli"] == nil)
check()
assert(has("warn", "setup() has not completed"))
assert(package.loaded["vimoi.cli"] == nil, "health must not initialize CLI state")
assert(package.loaded["vimoi.gotmpl"] == nil and package.loaded["vimoi.job"] == nil)

vim.fn.has = function(feature)
  if feature == "nvim-0.12" then
    return 0
  end
  return original_has(feature)
end
check()
assert(has("error", "Neovim 0.12 or newer is required"))
vim.fn.has = original_has

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local config_path = root .. "/config.toml"
vim.fn.writefile({ "# config contents need not be executed by health" }, config_path)
plugin.config.chezmoi_executable = vim.v.progpath
package.loaded["vimoi.cli"] = { source_root = root, config_path = config_path }
check()
assert(has("ok", "chezmoi executable:") and has("ok", "Source directory:") and has("ok", "chezmoi config file:"))
assert(has("ok", "gotmpl parser loads successfully"))
assert(has("ok", "gotmpl injections query loads successfully"))

vim.uv.fs_access = function()
  return nil, "EACCES"
end
check()
assert(has("error", "not readable/searchable"))
vim.uv.fs_access = original_access

plugin.config.chezmoi_executable = root .. "/missing-executable"
package.loaded["vimoi.cli"].source_root = root .. "/missing-source"
check()
assert(has("error", "not found or not executable") and has("error", "Source directory does not exist"))
package.loaded["vimoi.cli"].source_root = config_path
check()
assert(has("error", "not a directory"))
package.loaded["vimoi.cli"].source_root = root

vim.fn.delete(config_path)
check()
assert(has("info", "a config file is optional") and not has("error", "config file does not exist"))
plugin.config.chezmoi_config_path = config_path
check()
assert(has("error", "Configured chezmoi config file does not exist"))
package.loaded["vimoi.cli"].config_path = root
check()
assert(has("error", "not a readable file"))

vim.treesitter.language.add = function()
  return false
end
check()
assert(has("error", "gotmpl parser is unavailable"))
vim.treesitter.language.add = function(language)
  if language == "gotmpl" then
    error("incompatible parser ABI")
  end
  return original_add(language)
end
check()
assert(has("error", "incompatible parser ABI"))
vim.treesitter.language.add = original_add
vim.treesitter.query.get = function()
  error("broken query")
end
check()
assert(has("warn", "gotmpl highlights query is unavailable") and has("warn", "gotmpl injections query is unavailable"))
vim.treesitter.query.get = original_query

-- Optional host parsers are reported once per language; missing ones do not
-- disable template mapping. Merely checking health must not configure buffers.
for _ = 1, 2 do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname() .. ".yaml.tmpl")
  vim.bo[buf].filetype = "gotmpl"
  vim.b[buf].vimoi_template_filetype = "yaml"
end
require("vimoi.filetype").setup(root)
local managed_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(managed_buf, root .. "/dot_managed.yaml.tmpl")
vim.fn.writefile({ "value: {{ 1 }}" }, vim.api.nvim_buf_get_name(managed_buf))
vim.bo[managed_buf].filetype = "gotmpl"
-- No configured host yet: health must not resolve its uncached managed path.
package.loaded["vimoi.cli"].counterpart_path = function()
  error("health must not query a managed template's target path")
end
vim.treesitter.language.add = function(language)
  if language == "yaml" then
    return false
  end
  return original_add(language)
end
check()
assert(has("warn", "Optional host parser is unavailable: yaml"))
vim.treesitter.language.add = function(language)
  if language == "yaml" then
    return true
  end
  return original_add(language)
end
local missing_reports = reports
check()
assert(has("ok", "Optional host parser: yaml"))
reports = missing_reports
local missing_hosts = 0
for _, report in ipairs(reports) do
  if report.message == "Optional host parser is unavailable: yaml" then
    missing_hosts = missing_hosts + 1
  end
end
assert(missing_hosts == 1)

vim.health, vim.system = original_health, original_system
vim.treesitter.language.add, vim.treesitter.query.get = original_add, original_query
package.loaded["vimoi.cli"] = nil
vim.fn.delete(root, "rf")
-- Exercise native health discovery and report generation as well as direct calls.
vim.cmd("checkhealth vimoi")
local report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(report:find("vimoi.nvim", 1, true) and not report:find("Failed to run healthcheck", 1, true), report)
print("health: native discovery, setup/path/parser failures and no process side effects verified")
