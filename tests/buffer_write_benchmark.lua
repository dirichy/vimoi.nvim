-- Compare the previous full-buffer setter with the production local writer.
-- Includes normal allocation/GC, but excludes merge planning, rendering, diff, and UI.
local util = require("vimoi.util")
local source_map = require("vimoi.gotmpl.source_map")
local buffer_edits = require("vimoi.gotmpl.buffer_edits")
local function median(t)
  table.sort(t)
  return t[math.ceil(#t / 2)]
end
for _, count in ipairs({ 100, 400, 1600 }) do
  local head = ("setting=value\n{{ if true }}nested=value{{ end }}\n"):rep(count)
  local original = head .. "tail=AAAA"
  local changed = head .. "tail=BBBB"
  print(("case %d blocks: %d bytes"):format(count, #original))
  for _, parse in ipairs({ false, true }) do
    local variants, measurements = {}, { full = {}, range = {} }
    for _, name in ipairs({ "full", "range" }) do
      local buf = vim.api.nvim_create_buf(false, true)
      util.set_buffer_text(buf, original)
      if parse then
        assert(source_map.parse(original, buf))
      end
      local alternate = false
      local function edit()
        alternate = not alternate
        if name == "full" then
          util.set_buffer_text(buf, alternate and changed or original)
        else
          buffer_edits.apply(
            buf,
            alternate and original or changed,
            alternate and changed or original,
            { { start_byte = #original - 4, end_byte = #original, replacement = alternate and "BBBB" or "AAAA" } }
          )
        end
        if parse then
          local _, err, visits = source_map.parse(util.buffer_text(buf), buf)
          assert(not err, err)
          return visits
        end
        return 0
      end
      for _ = 1, 8 do
        edit()
      end
      variants[name] = { edit = edit, buf = buf }
    end
    for round = 1, 9 do
      for _, name in ipairs(round % 2 == 0 and { "full", "range" } or { "range", "full" }) do
        collectgarbage("collect")
        local started = vim.uv.hrtime()
        for _ = 1, 20 do
          variants[name].edit()
        end
        measurements[name][#measurements[name] + 1] = (vim.uv.hrtime() - started) / 1e6 / 20
      end
    end
    print(
      ("%s full=%.4fms range=%.4fms visits=%s/%s"):format(
        parse and "write + parse" or "write only",
        median(measurements.full),
        median(measurements.range),
        tostring(variants.full.edit()),
        tostring(variants.range.edit())
      )
    )
    for _, variant in pairs(variants) do
      vim.api.nvim_buf_delete(variant.buf, { force = true })
    end
  end
end
