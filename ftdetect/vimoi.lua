-- lazy.nvim sources ftdetect before loading ft-lazy plugins. Even requiring a
-- data-only module would trigger its loader. Preselect by suffix/chezmoi prefix;
-- the callback loads the single authoritative filename rules only when needed.
local function detect(path)
  return require("vimoi.filetype").detect(path)
end

vim.filetype.add({
  extension = { tmpl = detect },
  pattern = { [".*/%.chezmoi.*"] = detect },
})
