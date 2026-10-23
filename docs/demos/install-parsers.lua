-- CI bootstrap; parser versions follow the pinned nvim-treesitter checkout.
vim.opt.runtimepath:prepend(assert(vim.env.VIMOI_DEMO_TREESITTER, "set VIMOI_DEMO_TREESITTER"))
require("nvim-treesitter").install({ "gotmpl", "yaml" }):wait(300000)
-- Refresh runtime lookup after creating parser/query directories for the first time.
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/site")
for _, language in ipairs({ "gotmpl", "yaml" }) do
  assert(vim.treesitter.language.add(language))
  assert(vim.treesitter.query.get(language, "highlights"), "missing highlights: " .. language)
end
