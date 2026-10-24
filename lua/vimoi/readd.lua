-- User-triggered target-to-source writeback, with template-specific merging delegated.
local M = {}
local util = require("vimoi.util")
local cli = require("vimoi.cli")
local filetype = require("vimoi.filetype")

---@param path? string Source or target path; defaults to the current buffer/session.
---@return VimoiReAddResult?
function M.readd(path)
  local sessions = package.loaded["vimoi.gotmpl.view"]
  local session = sessions and sessions.by_window[vim.api.nvim_get_current_win()]
  if path and session then
    path = util.normalize_path(path)
    if
      path ~= vim.api.nvim_buf_get_name(session.source_buf) and path ~= vim.api.nvim_buf_get_name(session.target_buf)
    then
      session = nil
    end
  end
  if session and not sessions.is_valid(session) then
    sessions.close(session)
    session = nil
  end
  if session and not session.preview then
    return require("vimoi.gotmpl.merge").readd()
  end
  local source, target, resolve_error =
    cli.resolve_paths(session and vim.api.nvim_buf_get_name(session.source_buf) or path or vim.api.nvim_buf_get_name(0))
  if not source then
    return util.notify(assert(resolve_error), "re-add", vim.log.levels.ERROR)
  end
  if filetype.is_template(source) then
    if require("vimoi.gotmpl").open({ source = source, target = target }) then
      return require("vimoi.gotmpl.merge").readd()
    end
    return
  end

  -- These source files encode an operation or ciphertext, not the target's text.
  local name = vim.fs.basename(source):gsub("^create_", "")
  if
    filetype.path_kind(source) == "symlink_target"
    or name:match("^encrypted_")
    or name:match("^modify_")
    or name:match("^run_")
  then
    return util.notify(
      "re-add supports ordinary text files and templates; this source type needs manual editing",
      "re-add",
      vim.log.levels.ERROR
    )
  end
  local buffers = {}
  for _, filename in ipairs({ source, target }) do
    -- bufadd uses an exact name and retains existing unsaved buffer contents.
    local buf = vim.fn.bufadd(filename)
    if not vim.api.nvim_buf_is_loaded(buf) then
      local stat = vim.uv.fs_stat(filename)
      if not stat or stat.type ~= "file" or not vim.uv.fs_access(filename, "R") then
        return util.notify("cannot read file: " .. filename, "re-add", vim.log.levels.ERROR)
      end
      vim.fn.bufload(buf)
    end
    if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" then
      return util.notify("cannot load a file buffer: " .. filename, "re-add", vim.log.levels.ERROR)
    end
    buffers[#buffers + 1] = buf
  end
  local source_buf, target_buf = buffers[1], buffers[2]
  if not vim.bo[source_buf].modifiable then
    return util.notify("source buffer is not modifiable", "re-add", vim.log.levels.ERROR)
  end
  require("vimoi.gotmpl").open({ source = source, target = target })
  local source_text, target_text = util.buffer_text(source_buf), util.buffer_text(target_buf)
  local buffer_edits = require("vimoi.gotmpl.buffer_edits")
  local edits = buffer_edits.diff(source_text, target_text)
  if #edits > 0 then
    buffer_edits.apply(source_buf, source_text, target_text, edits)
    vim.cmd("diffupdate")
  end
  util.notify(("re-added %d hunks to source buffer; write the source to save"):format(#edits), "re-add")
  return { merged = #edits, skipped = 0, reasons = {} }
end

return M
