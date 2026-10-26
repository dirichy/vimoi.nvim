local M = {}

---Discard selected cached results and rescan file watches.
---@param scope? VimoiCacheScope Defaults to all; data also clears templates.
function M.invalidate_cache(scope)
  require("vimoi.core.cli").invalidate(scope)
  require("vimoi.core.watch").refresh()
end

---Open the projected diff for the current buffer.
---@param opts? { source?: string, target?: string, validate?: boolean }
---@return nil
function M.diff(opts)
  require("vimoi.compare").open(opts)
end

---Open a projected diff for an explicit source and target pair.
---@param source string
---@param target string
---@param opts? { validate?: boolean }
---@return nil
function M.diff_files(source, target, opts)
  require("vimoi.compare").open(vim.tbl_extend("force", opts or {}, { source = source, target = target }))
end

---Compare a template buffer with a target buffer, including unnamed buffers.
---@param source_buf integer
---@param target_buf integer
---@param opts? { filetype?: string }
---@return nil
function M.diff_buffers(source_buf, target_buf, opts)
  require("vimoi.compare").open(vim.tbl_extend("force", opts or {}, {
    source_buf = source_buf,
    target_buf = target_buf,
  }))
end

---Preview the current or explicit source template without writing its rendered result.
---@class VimoiPreviewOptions
---@field source? string Defaults to the current buffer, including unsaved text.
---@param opts? VimoiPreviewOptions
---@return nil
function M.preview(opts)
  require("vimoi.compare").preview(opts)
end

---Switch between a managed source and target, without rendering or saving.
---@param path? string Open the counterpart of this path; defaults to the current buffer.
---@return string?
function M.toggle(path)
  local cli = require("vimoi.core.cli")
  local views = package.loaded["vimoi.compare"]
  local session = views and views.current()
  local destination, err
  if not path and session and session.preview and vim.api.nvim_get_current_win() == session.target_win then
    destination = vim.api.nvim_buf_get_name(session.source_buf) -- A rendered scratch buffer switches back to its source.
  else
    path = path or vim.api.nvim_buf_get_name(0)
    if path ~= "" then
      destination, err = cli.counterpart_path(path)
    end
  end
  if not destination or destination == "" then
    return require("vimoi.core.util").notify(
      err or "current buffer has no managed counterpart",
      "toggle",
      vim.log.levels.ERROR
    )
  end
  vim.cmd.edit(vim.fn.fnameescape(destination))
  return destination
end

---Pick a managed file and open its source without saving or applying.
function M.files()
  local cli = require("vimoi.core.cli")
  local util = require("vimoi.core.util")
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local changedtick = vim.api.nvim_buf_get_changedtick(buf)
  local function current()
    return vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_get_current_win() == win
      and vim.api.nvim_win_get_buf(win) == buf
      and vim.api.nvim_buf_get_changedtick(buf) == changedtick
  end
  cli.run({ "managed", "--include=files,symlinks", "--path-style=source-absolute", "--nul-path-separator" }, {
    text = false,
    callback = function(output, err)
      if not current() then
        return
      end
      if not output then
        util.notify(err, "files", vim.log.levels.ERROR)
        return
      end
      local paths = vim.split(output, "\0", { plain = true, trimempty = true })
      if #paths == 0 then
        util.notify("no managed files", "files", vim.log.levels.INFO)
        return
      end
      vim.ui.select(paths, {
        prompt = "Vimoi source:",
        format_item = function(path)
          return vim.fn.strtrans(vim.fs.relpath(cli.source_root, path) or path)
        end,
      }, function(path)
        if path and current() then
          local ok, edit_error = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
          if not ok then
            util.notify(tostring(edit_error), "files", vim.log.levels.ERROR)
          end
        end
      end)
    end,
  })
end

---Put the current hunk into the other diff window, rendering template output as needed.
---@return boolean?
function M.put_hunk()
  return require("vimoi.merge").put_hunk()
end

---Get the other window's hunk into the current diff window, preserving template structure.
---@return boolean?
function M.get_hunk()
  return require("vimoi.merge").get_hunk()
end

---Immediate re-add summary. Internal hunk/trace fields are not part of this contract.
---@class VimoiReAddResult
---@field merged integer Number of original hunks with applied edits.
---@field skipped integer Number of original hunks with skipped edits; a partially merged hunk may count in both.
---@field reasons { reason?: string }[] One explanation per skipped edit; several can belong to one hunk.

---Write target changes to source; preserve template structure when applicable.
---@param path? string Source or target path; defaults to the current buffer.
---@return VimoiReAddResult? Immediate completion only; nil while rendering or a choice is pending, or on failure.
function M.readd(path)
  return require("vimoi.merge").readd(path)
end

---Run a source-map-aware fold command in both diff windows.
---@param command "zo"|"zc"|"za"|"zO"|"zC"|"zA"|"zR"|"zM"
function M.fold(command)
  return require("vimoi.compare").fold(command)
end

---Open the chezmoi-aware path under the cursor.
---@param opts? { line?: boolean } Set line to recognize :line[:column].
function M.goto_file(opts)
  return require("vimoi.editor.goto").open(opts)
end

---Cancel the only running command, or pick one when several are running.
function M.cancel_command()
  require("vimoi.core.job").cancel()
end

---Register commands and global entry mappings during plugin setup.
---@private
M.register = require("vimoi.core.util").once(function()
  vim.api.nvim_create_user_command("VimoiFiles", M.files, { desc = "Pick a managed chezmoi source file" })
  vim.api.nvim_create_user_command("VimoiToggle", function(args)
    M.toggle(args.fargs[1])
  end, {
    nargs = "?",
    complete = "file",
    desc = "Switch between chezmoi source and target",
  })

  vim.api.nvim_create_user_command("VimoiPreview", function(args)
    M.preview({ source = args.fargs[1] })
  end, {
    nargs = "?",
    complete = "file",
    desc = "Preview the source template in a read-only split",
  })

  vim.api.nvim_create_user_command("VimoiDiff", function(args)
    if #args.fargs == 0 then
      M.diff()
    elseif #args.fargs == 2 then
      M.diff_files(args.fargs[1], args.fargs[2])
    else
      require("vimoi.core.util").notify(
        "VimoiDiff expects either no arguments or: source target",
        "diff",
        vim.log.levels.ERROR
      )
    end
  end, {
    nargs = "*",
    complete = "file",
    desc = "Compare the current target with its rendered chezmoi template",
  })

  vim.api.nvim_create_user_command("VimoiDiffPut", function()
    M.put_hunk()
  end, {
    desc = "Put the current hunk into the other chezmoi diff window",
  })

  vim.api.nvim_create_user_command("VimoiDiffGet", function()
    M.get_hunk()
  end, {
    desc = "Get the other chezmoi diff window's hunk into the current window",
  })

  vim.api.nvim_create_user_command("VimoiReAdd", function(args)
    M.readd(args.fargs[1])
  end, {
    nargs = "?",
    complete = "file",
    desc = "Re-add target changes to the chezmoi source buffer",
  })

  vim.api.nvim_create_user_command("VimoiCancel", M.cancel_command, {
    desc = "Select and cancel a running chezmoi command",
  })

  local keymaps = require("vimoi").config.keymaps
  for name, desc in pairs({
    readd = "Re-add target changes to chezmoi source",
    cancel_command = "Cancel running chezmoi command",
    diff = "Open chezmoi diff",
    preview = "Preview chezmoi template",
    toggle = "Switch between chezmoi source and target",
    files = "Pick a managed chezmoi source file",
    invalidate_cache = "Clear chezmoi caches and rescan watches",
  }) do
    local lhs = keymaps[name]
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, function()
        M[name]()
      end, { desc = desc })
    end
  end
end)

return M
