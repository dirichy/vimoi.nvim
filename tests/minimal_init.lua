vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.env.VIMOI_TEST_DESTINATION = vim.env.VIMOI_TEST_DESTINATION or vim.fn.tempname()
