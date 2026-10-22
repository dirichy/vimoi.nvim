local M = {}

---Configure vimoi.nvim. This and the functions below form the user-facing API.
---@param opts? VimoiConfig
function M.setup(opts)
  return require("vimoi").setup(opts)
end

---Discard selected cached results and rescan file watches.
---@param scope? VimoiCacheScope Defaults to all; data also clears templates.
function M.invalidate_cache(scope)
  require("vimoi.cli").invalidate(scope)
  require("vimoi.watch").refresh()
end

---Open the projected diff for the current buffer.
---@param opts? { source?: string, target?: string, validate?: boolean }
---@return nil
function M.diff(opts)
  require("vimoi.gotmpl").open(opts)
end

---Open a projected diff for an explicit source and target pair.
---@param source string
---@param target string
---@param opts? { validate?: boolean }
---@return nil
function M.diff_files(source, target, opts)
  require("vimoi.gotmpl").open(vim.tbl_extend("force", opts or {}, { source = source, target = target }))
end

---Preview the current or explicit source template without writing its rendered result.
---@class VimoiPreviewOptions
---@field source? string Defaults to the current buffer, including unsaved text.
---@param opts? VimoiPreviewOptions
---@return nil
function M.preview(opts)
  require("vimoi.gotmpl").preview(opts)
end

---Switch between a managed source and target, without rendering or saving.
---@param path? string Open the counterpart of this path; defaults to the current buffer.
---@return string?
function M.toggle(path)
  local cli = require("vimoi.cli")
  local views = package.loaded["vimoi.gotmpl.session"]
  local session = views and views.by_window[vim.api.nvim_get_current_win()]
  if session and not views.is_valid(session) then
    views.close(session)
    session = nil
  end
  local destination, err
  if not path and session and session.preview and vim.api.nvim_get_current_win() == session.target_win then
    destination = session.source_path -- A rendered scratch buffer switches back to its source.
  else
    path = path or vim.api.nvim_buf_get_name(0)
    if path ~= "" then
      destination, err = cli.counterpart_path(path)
    end
  end
  if not destination or destination == "" then
    return require("vimoi.util").notify(
      err or "current buffer has no managed counterpart",
      "toggle",
      vim.log.levels.ERROR
    )
  end
  vim.cmd.edit(vim.fn.fnameescape(destination))
  return destination
end

---Merge the hunk under the cursor into the source template.
---@return boolean?
function M.put_hunk()
  return require("vimoi.gotmpl.merge").put_hunk()
end

---Apply the hunk under the cursor from rendered output to target.
---@return boolean?
function M.apply_hunk()
  return require("vimoi.gotmpl.merge").apply_hunk()
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
  return require("vimoi.readd").readd(path)
end

---Run a source-map-aware fold command in both diff windows.
---@param command "zo"|"zc"|"za"|"zO"|"zC"|"zA"|"zR"|"zM"
function M.fold(command)
  return require("vimoi.gotmpl").fold(command)
end

---Open the chezmoi-aware path under the cursor.
---@param opts? { line?: boolean } Set line to recognize :line[:column].
function M.goto_file(opts)
  return require("vimoi.util").async(function()
    return require("vimoi.goto").open(opts)
  end)
end

---Cancel the only running command, or pick one when several are running.
function M.cancel_command()
  require("vimoi.job").cancel()
end

---Register commands and global entry mappings during plugin setup.
---@private
M.register = require("vimoi.util").once(function()
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
      require("vimoi.util").notify(
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
    desc = "Put the current target hunk into the chezmoi source template",
  })

  vim.api.nvim_create_user_command("VimoiDiffApply", function()
    M.apply_hunk()
  end, {
    desc = "Apply the current rendered hunk to the chezmoi target buffer",
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
