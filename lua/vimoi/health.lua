local M = {}

---Inspect dependencies and already-discovered paths without initializing or rendering.
function M.check()
  local health = vim.health
  health.start("vimoi.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.11 or newer is required")
  end

  local config = require("vimoi").config
  local executable = config.chezmoi_executable
  if vim.fn.executable(executable) == 1 then
    health.ok("chezmoi executable: " .. vim.fn.exepath(executable))
  else
    health.error("chezmoi executable not found or not executable: " .. executable, {
      "Install chezmoi or set chezmoi_executable to an executable/wrapper path in setup().",
    })
  end

  -- Loading health must not run setup, data helpers, or password prompts. Paths
  -- are available only after CLI setup succeeded; a missing config is valid.
  local cli = package.loaded["vimoi.core.cli"]
  if cli and cli.source_root then
    health.ok("CLI setup completed")
    local source = cli.source_root
    local stat = vim.uv.fs_stat(source)
    if not stat or stat.type ~= "directory" then
      health.error("Source directory does not exist or is not a directory: " .. source, {
        "Check chezmoi sourceDir and restart Neovim after correcting setup-time paths.",
      })
    elseif not vim.uv.fs_access(source, "RX") then
      health.error("Source directory is not readable/searchable: " .. source)
    else
      health.ok("Source directory: " .. source)
    end
  else
    health.warn("setup() has not completed; source paths are unavailable", {
      'Call require("vimoi").setup() with your options.',
      "If setup failed, inspect the startup error; this report uses the last successful settings or defaults.",
    })
  end

  local config_path = (cli and cli.config_path) or config.chezmoi_config_path
  if config_path then
    config_path = require("vimoi.core.util").normalize_path(config_path)
    local stat = vim.uv.fs_stat(config_path)
    if not stat then
      if config.chezmoi_config_path then
        health.error("Configured chezmoi config file does not exist: " .. config_path)
      else
        health.info("No chezmoi config file at " .. config_path .. " (a config file is optional)")
      end
    elseif stat.type ~= "file" or vim.fn.filereadable(config_path) ~= 1 then
      health.error("chezmoi config path is not a readable file: " .. config_path)
    else
      health.ok("chezmoi config file: " .. config_path)
    end
  else
    health.info("Config path has not been discovered; health does not run chezmoi to discover it")
  end

  health.start("vimoi.nvim: Tree-sitter")
  local loaded, available = pcall(vim.treesitter.language.add, "gotmpl")
  if not loaded or not available then
    health.warn("gotmpl parser is unavailable" .. (not loaded and ": " .. tostring(available) or ""), {
      "Experimental tag collection is used for rendering and source mapping; chezmoi validates expressions.",
      "Install a gotmpl parser for full template colors, syntax-aware completion and template-reference navigation.",
      "With nvim-treesitter, use :TSInstall gotmpl. nvim-treesitter itself is optional.",
    })
  else
    health.ok("gotmpl parser loads successfully")
    for _, name in ipairs({ "highlights", "injections" }) do
      local ok, query = pcall(vim.treesitter.query.get, "gotmpl", name)
      if not ok or not query then
        health.warn("gotmpl " .. name .. " query is unavailable: " .. tostring(query), {
          "Check parser/query versions and ensure vimoi.nvim is on runtimepath.",
        })
      else
        health.ok("gotmpl " .. name .. " query loads successfully")
      end
    end
  end

  -- Check only languages actually used by open templates, without requiring
  -- every possible host parser or loading optional completion integrations.
  local host_languages = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "gotmpl" then
      local host = vim.b[buf].vimoi_template_filetype
      if host and host ~= "" and host ~= "gotmpl" and host ~= "template" then
        host_languages[vim.treesitter.language.get_lang(host) or host] = true
      end
    end
  end
  for _, language in ipairs(vim.fn.sort(vim.tbl_keys(host_languages))) do
    local ok, parser = pcall(vim.treesitter.language.add, language)
    if ok and parser then
      health.ok("Optional host parser: " .. language)
    else
      health.warn("Optional host parser is unavailable: " .. language, {
        "Rendered mode projects Vim syntax from output; injection mode uses Vim syntax on source.",
        "Template mapping uses gotmpl or the experimental tag collector.",
      })
    end
  end
  if not next(host_languages) then
    health.info("No host language to check; open a gotmpl buffer to check its optional host parser")
  end
  health.info("No template rendering, data/password helpers, source writes or target writes were performed")
end

return M
