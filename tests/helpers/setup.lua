-- Share the fixture identity; custom-path tests override these options explicitly.
return function(opts)
  local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
  vim.env.VIMOI_TEST_CONFIG = vim.env.VIMOI_TEST_CONFIG or fixture .. "/empty.toml"
  vim.env.VIMOI_TEST_SOURCE = vim.env.VIMOI_TEST_SOURCE or fixture .. "/source"
  require("vimoi").setup(vim.tbl_extend("force", {
    chezmoi_source_dir = vim.env.VIMOI_TEST_SOURCE,
    chezmoi_config_path = vim.env.VIMOI_TEST_CONFIG,
    chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  }, opts or {}))
end
