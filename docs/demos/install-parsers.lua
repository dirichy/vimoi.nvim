-- CI bootstrap; parser versions follow the pinned nvim-treesitter checkout.
vim.opt.runtimepath:prepend(assert(vim.env.VIMOI_DEMO_TREESITTER, "set VIMOI_DEMO_TREESITTER"))
local languages = vim.fn.readfile("tests/parsers.txt")
require("nvim-treesitter").install(languages):wait(300000)
-- Refresh runtime lookup after creating parser/query directories for the first time.
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/site")
dofile("tests/helpers/check_parsers.lua")
