require("vimoi").setup({ highlight = { template_bg = "#123456" } })
assert(vim.api.nvim_get_hl(0, { name = "VimoiTemplateAction", link = false }).bg == 0x123456)
vim.o.background = "light"
vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
assert(vim.api.nvim_get_hl(0, { name = "VimoiTemplateAction", link = false }).bg == 0x123456)
