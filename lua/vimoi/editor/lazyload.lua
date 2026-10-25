local M = {}

local function attach_goto_keymaps(buf)
  if vim.b[buf].vimoi_gf then
    return
  end
  vim.b[buf].vimoi_gf = true
  local keymaps = require("vimoi").config.keymaps
  if keymaps.goto_file and keymaps.goto_file ~= "" then
    vim.keymap.set("n", keymaps.goto_file, function()
      require("vimoi.api").goto_file()
    end, { buffer = buf, desc = "Open chezmoi path under cursor" })
  end
  if keymaps.goto_file_line and keymaps.goto_file_line ~= "" then
    vim.keymap.set("n", keymaps.goto_file_line, function()
      require("vimoi.api").goto_file({ line = true })
    end, { buffer = buf, desc = "Open chezmoi path and line under cursor" })
  end
end

M.setup = require("vimoi.core.util").once(function()
  local group = vim.api.nvim_create_augroup("vimoi-buffers", { clear = true })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "gotmpl",
    callback = function(args)
      local buf = args.buf
      attach_goto_keymaps(buf)
      -- Syntax handlers may run later in this FileType event.
      vim.schedule(function()
        if
          vim.api.nvim_buf_is_valid(buf)
          and vim.bo[buf].filetype == "gotmpl"
          and not vim.b[buf].vimoi_template_configured
        then
          require("vimoi.editor.highlight").configure_template_buffer(
            buf,
            require("vimoi.editor.filetype").host_filetype(vim.api.nvim_buf_get_name(buf), buf)
          )
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = group,
    -- These are path-aware files but are not detected as gotmpl.
    pattern = require("vimoi.core.source").symlink_pattern,
    callback = function(args)
      attach_goto_keymaps(args.buf)
    end,
  })
end)

return M
