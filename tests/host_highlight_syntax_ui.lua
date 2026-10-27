-- Reuse the full native/projected display oracle with only the backend changed.
vim.env.VIMOI_TEST_HOST_SYNTAX = "1"
dofile("tests/host_highlight_ui.lua")
