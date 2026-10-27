-- Keep the native Vim syntax display oracle, with neither template nor host parsers.
vim.env.VIMOI_TEST_TEMPLATE_FALLBACK = "1"
vim.env.VIMOI_TEST_HOST_SYNTAX = "1"
dofile("tests/host_highlight_ui.lua")
