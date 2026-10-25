local ok, result = xpcall(function()
  -- Run after the tape's actual keystrokes, before quitting. No fixture mutations.
  local demo = vim.env.VIMOI_DEMO or "preview"
  local fixture = vim.g.vimoi_demo
  local observed = _G.vimoi_demo_observed
  local view = require("vimoi.gotmpl.view").current()
  local source_buf = vim.fn.bufnr(fixture.source)
  assert(vim.api.nvim_buf_is_loaded(source_buf), "source is no longer loaded")
  local source = table.concat(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "\n")
  assert(vim.v.errmsg == "", vim.v.errmsg)
  if demo == "completion" then
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
    elseif demo == "highlighting" then
      assert(require("vimoi").config.highlight.mode == "rendered")
      assert(require("vimoi").config.highlight.template_bg == "Visual")
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
  }
  return result
end, debug.traceback)
if not ok then
  result = { verified = false, error = result }
end
local result_path = assert(vim.env.VIMOI_DEMO_RESULT, "record through docs/demos/build.py")
vim.fn.writefile({ vim.json.encode(result) }, result_path)
