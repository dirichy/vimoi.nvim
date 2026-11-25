-- Optional Conform formatter. Return a new snapshot; Conform owns buffer edits,
-- undo, dry runs, range filtering and stale-result checks.
return {
  inherit = false,
  ---@param ctx { shiftwidth: integer, buf: integer }
  ---@param lines string[]
  ---@param callback fun(err: string?, lines?: string[])
  format = function(_, ctx, lines, callback)
    local updated, err = require("vimoi.editor.format").format_text(table.concat(lines, "\n"), ctx.shiftwidth, ctx.buf)
    if not updated then
      callback(err)
      return
    end
    callback(nil, vim.split(updated, "\n", { plain = true }))
  end,
}
