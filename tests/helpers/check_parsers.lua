-- Share the test dependency contract with the CI installer; fail before running the suite.
local missing = {}
for _, language in ipairs(vim.fn.readfile("tests/parsers.txt")) do
  local loaded, parser = pcall(vim.treesitter.language.add, language)
  if not loaded or not parser then
    missing[#missing + 1] = language .. " parser"
  else
    local queried, highlights = pcall(vim.treesitter.query.get, language, "highlights")
    if not queried or not highlights then
      missing[#missing + 1] = language .. " highlights query"
    end
  end
end
assert(#missing == 0, "Missing test dependencies: " .. table.concat(missing, ", ") .. "; see tests/parsers.txt")
print("Test parsers and highlight queries are ready")
