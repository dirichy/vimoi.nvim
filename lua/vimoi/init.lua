local M = {}

local defaults = {
  chezmoi_executable = "chezmoi",
  chezmoi_config_path = nil,
  split = "vertical",
  watch = {
    buffer_write_fallback = "auto",
  },
  diff = {
    validate = false,
  },
  completion = {
    enabled = true,
  },
  diagnostics = {
    enabled = true,
    host = true,
  },
  highlight = {
    mode = "rendered",
    template_bg = "NormalFloat",
  },
  ---@type VimoiKeymaps
  keymaps = {
    cancel_command = "<leader>cx",
    diff = "<leader>cd",
    preview = "<leader>cp",
    invalidate_cache = "<leader>cr",
    readd = "<leader>ca",
    toggle = "<leader>ct",
    goto_file = "gf",
    goto_file_line = "gF",
    diff_get = "do",
    diff_put = "dp",
    fold_open = "zo",
    fold_close = "zc",
    fold_toggle = "za",
    fold_open_recursive = "zO",
    fold_close_recursive = "zC",
    fold_toggle_recursive = "zA",
    fold_open_all = "zR",
    fold_close_all = "zM",
  },
}

M.config = vim.deepcopy(defaults)
local structural_config

---Configure vimoi.nvim.
---@class VimoiKeymaps
---@field cancel_command? string|false
---@field diff? string|false
---@field preview? string|false
---@field invalidate_cache? string|false
---@field readd? string|false
---@field toggle? string|false
---@field goto_file? string|false
---@field goto_file_line? string|false
---@field diff_get? string|false
---@field diff_put? string|false
---@field fold_open? string|false
---@field fold_close? string|false
---@field fold_toggle? string|false
---@field fold_open_recursive? string|false
---@field fold_close_recursive? string|false
---@field fold_toggle_recursive? string|false
---@field fold_open_all? string|false
---@field fold_close_all? string|false

---@class VimoiConfig
---@field chezmoi_executable? string
---@field chezmoi_config_path? string
---@field split? "vertical"|"horizontal" Orientation for newly created diff/preview splits.
---@field watch? VimoiWatchOptions
---@field diff? { validate?: boolean }
---@field completion? { enabled?: boolean }
---@field diagnostics? { enabled?: boolean, host?: boolean }
---@field highlight? { mode?: "injection"|"rendered"|"disabled", template_bg?: string|{ dark: string, light: string } }
---@field keymaps? VimoiKeymaps|false

---@param opts? VimoiConfig
function M.setup(opts)
  if vim.fn.has("nvim-0.12") == 0 then
    error("vimoi.nvim requires Neovim 0.12 or newer")
  end
  vim.validate("opts", opts, "table", true)
  local config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  -- Reject bad public settings before one-time CLI/watch/keymap initialization.
  vim.validate("chezmoi_executable", config.chezmoi_executable, "string")
  vim.validate("chezmoi_config_path", config.chezmoi_config_path, "string", true)
  for _, name in ipairs({ "completion", "diagnostics" }) do
    vim.validate(name, config[name], "table")
    vim.validate(name .. ".enabled", config[name].enabled, "boolean")
  end
  vim.validate("diagnostics.host", config.diagnostics.host, "boolean")
  vim.validate("highlight", config.highlight, "table")
  assert(
    config.highlight.mode == "injection" or config.highlight.mode == "rendered" or config.highlight.mode == "disabled",
    "highlight.mode must be injection, rendered or disabled"
  )
  vim.validate("diff", config.diff, "table")
  vim.validate("diff.validate", config.diff.validate, "boolean")
  vim.validate("watch", config.watch, "table")
  local fallback = config.watch.buffer_write_fallback
  assert(fallback == "auto" or type(fallback) == "boolean", "watch.buffer_write_fallback must be auto, true or false")
  if config.keymaps ~= false then
    vim.validate("keymaps", config.keymaps, "table")
    for name, key in pairs(config.keymaps) do
      assert(defaults.keymaps[name] ~= nil, "unknown keymap: " .. tostring(name))
      assert(type(key) == "string" or key == false, "keymaps." .. name .. " must be a string or false")
    end
  end
  assert(config.split == "vertical" or config.split == "horizontal", "split must be vertical or horizontal")
  if config.keymaps == false then
    config.keymaps = {}
    for name in pairs(defaults.keymaps) do
      config.keymaps[name] = false
    end
  end
  -- These options own process identity, watchers, and installed buffer mappings.
  -- Omitted structural settings retain their setup-time values on later calls.
  local structural = {}
  for _, key in ipairs({ "chezmoi_executable", "chezmoi_config_path", "watch", "keymaps" }) do
    if structural_config and (not opts or opts[key] == nil) then
      config[key] = vim.deepcopy(structural_config[key])
    end
    structural[key] = config[key]
  end
  if structural_config and not vim.deep_equal(structural, structural_config) then
    error("vimoi process, watch, and keymap settings cannot change after setup; restart Neovim", 0)
  end
  local cli = require("vimoi.cli")
  cli.setup(config.chezmoi_executable, config.chezmoi_config_path)
  require("vimoi.watch").setup(vim.tbl_extend("force", config.watch, {
    source_root = cli.source_root,
    config_path = cli.config_path,
  }))
  structural_config = vim.deepcopy(structural)
  M.config = config
  require("vimoi.highlight").setup()
  require("vimoi.filetype").setup(cli.source_root)
  require("vimoi.lazyload").setup()
  require("vimoi.gotmpl.session").setup()
  require("vimoi.api").register()
end

return M
