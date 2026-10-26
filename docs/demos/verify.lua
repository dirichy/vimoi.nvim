local ok, result = xpcall(function()
  -- Run after the tape's actual keystrokes, before quitting. No fixture mutations.
  local demo = vim.env.VIMOI_DEMO or "preview"
  local fixture = vim.g.vimoi_demo
  local observed = _G.vimoi_demo_observed
  local view = require("vimoi.compare").current()
  local source_buf = fixture.source_buf or vim.fn.bufnr(fixture.source)
  assert(vim.api.nvim_buf_is_loaded(source_buf), "source is no longer loaded")
  local source = table.concat(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "\n")
  assert(vim.v.errmsg == "" or (demo == "cancel" and vim.v.errmsg == "vimoi preview: command cancelled"), vim.v.errmsg)
  if demo == "navigation" then
    for _, name in ipairs({
      fixture.target_root .. "/app.yaml",
      fixture.source_root .. "/notes.txt",
      fixture.source_root .. "/.chezmoitemplates/settings.yaml",
    }) do
      assert(observed.visits[name], "navigation did not visit " .. name)
    end
    local target_buf = vim.fn.bufnr(fixture.target_root .. "/app.yaml")
    assert(source:find("unsaved source note", 1, true) and vim.bo[source_buf].modified)
    assert(
      table.concat(vim.api.nvim_buf_get_lines(target_buf, 0, -1, false), "\n"):find("unsaved target note", 1, true)
    )
    assert(vim.bo[target_buf].modified, "toggle saved the target")
    assert(vim.g.loaded_matchup == 1, "real vim-matchup was not loaded")
    assert(observed.matches[12] and observed.matches[14], "% did not visit else/end")
  elseif demo == "plain" then
    local target_buf = vim.fn.bufnr(fixture.target_root .. "/.zshrc")
    assert(vim.bo[source_buf].filetype == "zsh", "target filetype was not detected")
    assert(source == table.concat(vim.api.nvim_buf_get_lines(target_buf, 0, -1, false), "\n"))
    assert(source:find("unsaved target note", 1, true) and not source:find("unsaved source note", 1, true))
    assert(vim.bo[source_buf].modified and vim.bo[target_buf].modified, "plain write-back saved a buffer")
    assert(table.concat(vim.fn.readfile(fixture.source), "\n"):find("EDITOR=nvim", 1, true), "source was saved")
    assert(not view and vim.wo.diff, "plain files did not use native diff")
  elseif demo == "buffers" then
    assert(view and view.buffer_pair and not view.loading, "scratch diff is not ready")
    assert(vim.api.nvim_buf_get_name(source_buf) == "" and vim.api.nvim_buf_get_name(view.target_buf) == "")
    assert(source == "name: {{ .name | quote }}\ntheme: dark", "scratch ReAdd lost the expression or static edit")
    local source_pos = vim.api.nvim_win_get_position(view.source_win)
    local target_pos = vim.api.nvim_win_get_position(view.target_win)
    assert(source_pos[1] < target_pos[1] and source_pos[2] == target_pos[2], "diff is not horizontal")
  elseif demo == "cancel" then
    assert(_G.vimoi_demo_cancel_job and _G.vimoi_demo_cancel_job.cancelled, "slow render was not cancelled")
    assert(view and view.preview and not view.loading, "preview did not recover after cancellation")
    assert(not source:find("sleep", 1, true), "slow function was not removed")
    assert(table.concat(vim.api.nvim_buf_get_lines(view.target_buf, 0, -1, false), "\n"):find("theme: dark", 1, true))
    assert(
      table.concat(vim.fn.readfile(fixture.source), "\n"):find("theme: light", 1, true),
      "cancellation saved source"
    )
  elseif demo == "completion" then
    assert(observed.completion_menus >= 5, "not all five completion menus opened")
    assert(source:find(".name", 1, true) and source:find("quoted: {{ quote .name }}", 1, true))
    assert(#vim.diagnostic.get(source_buf) == 0, "completed source still has errors")
    assert(source:find("$greeting", 1, true) and source:find('"settings.yaml"', 1, true))
    assert(source:find("{{%-? if ") and source:find("{{%-? end }}"), "block snippet did not expand")
  elseif demo == "diagnostics" then
    local template_error, host_error = false, false
    for message in pairs(observed.diagnostics) do
      template_error = template_error or message:find("[gotmpl]", 1, true) ~= nil
      host_error = host_error or message:find("[host:lua]", 1, true) ~= nil
    end
    assert(template_error, "no actual template diagnostic was shown")
    assert(host_error, "no actual host diagnostic was shown")
    assert(observed.host_lines[2], "generated Lua error did not map back to line 3")
    assert(observed.host_lines[4], "literal Lua error did not map back to line 5")
    assert(#vim.diagnostic.get(source_buf) == 0, "repaired source still has diagnostics")
  elseif demo == "diff" or demo == "readd" then
    assert(view and not view.preview and not view.loading, "file diff is not ready")
    if demo == "diff" then
      local target = table.concat(vim.api.nvim_buf_get_lines(view.target_buf, 0, -1, false), "\n")
      assert(target:find("theme: light", 1, true), "do did not get rendered source into target")
      assert(target:find("search: true", 1, true) and not source:find("search: true", 1, true), "insertion undo failed")
    else
      assert(source:find("notifications: false", 1, true))
      assert(source:find("{{ .name | quote }}", 1, true), "dynamic expression was lost")
    end
  else
    assert(view and view.preview and not view.loading, "preview is not ready")
    local output = table.concat(vim.api.nvim_buf_get_lines(view.target_buf, 0, -1, false), "\n")
    if demo == "dependencies" then
      assert(output:find('name: "laptop"', 1, true) and output:find("theme: dark", 1, true), output)
    elseif demo == "injection" or demo == "disabled" then
      assert(require("vimoi").config.highlight.mode == demo)
      assert(source:find("{{ if false }}", 1, true) and not output:find("features:", 1, true))
      assert(vim.bo[source_buf].filetype == "gotmpl", "template highlighting was lost")
    elseif demo == "highlighting" then
      assert(require("vimoi").config.highlight.mode == "rendered")
      assert(require("vimoi").config.highlight.template_bg == "Visual")
      assert(source:find("{{ if true }}", 1, true), "undo did not restore the highlighted branch")
      assert(output:find("features:", 1, true), "restored branch is absent from rendered output")
    elseif demo == "preview" then
      assert(output:find("theme: dark", 1, true) and output:find("features:", 1, true))
    end
  end
  if demo == "diff" or demo == "preview" or demo == "readd" then
    for _, side in ipairs({ "source", "output" }) do
      assert(observed.scroll[side] and observed.scroll[side].moved, side .. " scroll did not move its peer viewport")
    end
  end
  local result = {
    demo = demo,
    scroll = observed.scroll,
    background = ("#%06x"):format(vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg),
    verified = true,
    source = source,
    completion_menus = observed.completion_menus,
    diagnostics = vim.tbl_keys(observed.diagnostics),
    host_lines = vim.tbl_keys(observed.host_lines or {}),
    visits = vim.tbl_keys(observed.visits),
    matches = vim.tbl_keys(observed.matches),
  }
  return result
end, debug.traceback)
if not ok then
  result = { verified = false, error = result }
end
local result_path = assert(vim.env.VIMOI_DEMO_RESULT, "record through docs/demos/build.py")
vim.fn.writefile({ vim.json.encode(result) }, result_path)
