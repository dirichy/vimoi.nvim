local M = {}

local function apply()
  local background = require("vimoi").config.highlight.template_bg
  if type(background) == "table" then
    background = background[vim.o.background]
  end
  local ctermbg
  if vim.fn.hlexists(background) == 1 then
    local group = vim.api.nvim_get_hl(0, { name = background, link = false })
    if group.reverse then
      background, ctermbg = group.fg, group.ctermfg
    else
      background, ctermbg = group.bg, group.ctermbg
    end
  end
  local statement = vim.api.nvim_get_hl(0, { name = "Statement", link = false })
  vim.api.nvim_set_hl(0, "VimoiTemplateAction", { bg = background, ctermbg = ctermbg, fg = statement.fg })
end

local initialize = require("vimoi.core.util").once(function()
  vim.treesitter.query.add_directive("vimoi-target-language!", function(_, _, source, _, metadata)
    if type(source) ~= "number" or not vim.api.nvim_buf_is_valid(source) then
      return
    end
    local language = vim.b[source].vimoi_template_language
    if language and language ~= "" and require("vimoi").config.highlight.mode == "injection" then
      metadata["injection.language"] = language
    end
  end, { force = true })

  local group = vim.api.nvim_create_augroup("vimoi-highlight", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = apply })
  vim.api.nvim_create_autocmd("OptionSet", { group = group, pattern = "background", callback = apply })
end)

---@param buf integer
---@param parser? vim.treesitter.LanguageTree
local function configure_syntax(buf, parser)
  local filetype = vim.b[buf].vimoi_template_filetype
  if
    require("vimoi").config.highlight.mode ~= "injection"
    or (parser and vim.b[buf].vimoi_template_language)
    or not filetype
    or filetype == ""
    or filetype == "gotmpl"
  then
    vim.bo[buf].syntax = "gotmpl"
  else
    -- Injection falls back on source; rendered highlighting only reads output.
    vim.bo[buf].syntax = filetype
  end
  -- Vim syntax supplies action backgrounds; Tree-sitter keeps the foregrounds.
  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[syntax region VimoiTemplateAction start=/{{-\?/ end=/-\?}}/ keepend contains=NONE containedin=ALL]])
  end)
end

function M.setup()
  initialize()
  apply()
end

---@param buf integer
---@param filetype? string
function M.configure_template_buffer(buf, filetype)
  initialize()
  local previous_language = vim.b[buf].vimoi_template_language
  local previous_filetype = vim.b[buf].vimoi_template_filetype
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
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "gotmpl")
  if not ok then
    parser = nil
  end
  if parser and previous_language ~= vim.b[buf].vimoi_template_language then
    -- FileType handlers may have parsed before host detection. Restarting only
    -- the highlighter reuses those cached trees without updating injections.
    parser:invalidate()
  end
  if parser then
    pcall(vim.treesitter.start, buf, "gotmpl")
  elseif vim.g.syntax_on ~= 1 then
    -- Initialize native Syntax autocommands without enabling it on every buffer.
    vim.cmd.runtime({ "syntax/synload.vim", bang = true })
  end
  configure_syntax(buf, parser)
  if previous_filetype ~= filetype then
    vim.api.nvim_exec_autocmds("User", { pattern = "VimoiHostFiletypeChanged", data = { buf = buf } })
  end
end

return M
