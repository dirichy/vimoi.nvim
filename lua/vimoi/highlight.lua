local M = {}

local function apply()
  local background = require("vimoi").config.highlight.template_bg
  if type(background) == "table" then
    background = background[vim.o.background]
  end
  local statement = vim.api.nvim_get_hl(0, { name = "Statement", link = false })
  vim.api.nvim_set_hl(0, "VimoiTemplateAction", { bg = background, fg = statement.fg })
end

local initialize = require("vimoi.util").once(function()
  vim.treesitter.query.add_directive("vimoi-target-language!", function(_, _, source, _, metadata)
    if type(source) ~= "number" or not vim.api.nvim_buf_is_valid(source) then
      return
    end
    local language = vim.b[source].vimoi_template_language
    if language and language ~= "" then
      metadata["injection.language"] = language
      metadata["injection.combined"] = 1
    end
  end, { force = true })

  local group = vim.api.nvim_create_augroup("vimoi-highlight", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = apply })
  vim.api.nvim_create_autocmd("OptionSet", { group = group, pattern = "background", callback = apply })
end)

function M.setup()
  initialize()
  apply()
end

---@param buf integer
---@param filetype? string
function M.configure_template_buffer(buf, filetype)
  initialize()
  -- Health reads this snapshot without resolving paths or starting chezmoi.
  vim.b[buf].vimoi_template_filetype = filetype
  local language
  if filetype and filetype ~= "" and filetype ~= "gotmpl" and filetype ~= "template" then
    language = vim.treesitter.language.get_lang(filetype) or filetype
  end
  local has_host_parser = false
  if language then
    local ok, loaded = pcall(vim.treesitter.language.add, language)
    has_host_parser = ok and loaded == true
  end
  vim.b[buf].vimoi_template_language = has_host_parser and language or nil
  vim.b[buf].vimoi_template_configured = true
  if vim.bo[buf].filetype ~= "gotmpl" then
    vim.bo[buf].filetype = "gotmpl"
  end
  pcall(vim.treesitter.stop, buf)
  pcall(vim.treesitter.start, buf, "gotmpl")
  if has_host_parser or not filetype or filetype == "" or filetype == "gotmpl" then
    vim.bo[buf].syntax = "gotmpl"
  else
    -- Keep Go-template parsing, but use Vim syntax for a host language without
    -- a Tree-sitter parser (notably sh on installations without a sh parser).
    vim.bo[buf].syntax = filetype
  end
  -- Vim syntax provides the action background in both parser and fallback modes;
  -- Tree-sitter's higher-priority captures retain their more precise foregrounds.
  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[syntax region VimoiTemplateAction start=/{{-\?/ end=/-\?}}/ keepend contains=NONE containedin=ALL]])
  end)
end

return M
