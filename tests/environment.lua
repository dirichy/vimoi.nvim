local root = vim.fn.getcwd()
local source_dir = root .. "/tests/fixtures/environment/source"
local config_file = root .. "/tests/fixtures/environment/empty.toml"
local destination_dir = vim.env.VIMOI_TEST_DESTINATION
local source_file = source_dir .. "/dot_probe.tmpl"
local target_file = destination_dir .. "/.probe"

local common = {
  "chezmoi",
  "--config",
  config_file,
  "--source",
  source_dir,
  "--destination",
  destination_dir,
}

local function run(extra, opts)
  local command = vim.list_extend(vim.deepcopy(common), extra)
  local result = vim.system(command, vim.tbl_extend("force", { text = true }, opts or {})):wait()
  assert(result.code == 0, result.stderr)
  return vim.json.decode(result.stdout)
end

local source = table.concat(vim.fn.readfile(source_file, "b"), "\n") .. "\n"
local cat = run({ "cat", target_file })
local stdin = run({ "execute-template" }, { stdin = source })
local file = run({ "execute-template", "--file", source_file })

-- Context that is preserved by all three execution modes.
for _, key in ipairs({ "configFile", "destDir", "include", "sourceDir", "stdinIsATTY", "workingTree" }) do
  assert(stdin[key] == cat[key], key .. " differs in stdin mode")
  assert(file[key] == cat[key], key .. " differs in --file mode")
end

-- includeTemplate inherits the caller's sourceFile, so stdin changes its result.
assert(cat.includeTemplate == "snippet=dot_probe.tmpl\n")
assert(stdin.includeTemplate == "snippet=stdin\n")
assert(file.includeTemplate == cat.includeTemplate)

-- Known semantic differences in execute-template.
assert(cat.sourceFile == "dot_probe.tmpl")
assert(stdin.sourceFile == "stdin")
assert(file.sourceFile == cat.sourceFile)
assert(cat.targetFile == target_file)
assert(stdin.targetFile == "")
assert(file.targetFile == "")
assert(cat.args[#cat.args - 1] == "cat")
assert(stdin.args[#stdin.args] == "execute-template")
assert(file.args[#file.args - 1] == "--file")

local all_source_file = source_dir .. "/dot_all_context.tmpl"
local all_source = table.concat(vim.fn.readfile(all_source_file, "b"), "\n") .. "\n"
local all_cat = run({ "cat", destination_dir .. "/.all_context" })
local all_stdin = run({ "execute-template" }, { stdin = all_source })
local all_file = run({ "execute-template", "--file", all_source_file })
local expected_differences = {
  args = true,
  command = true,
  sourceFile = true,
  targetFile = true,
}

for key, value in pairs(all_cat) do
  local differs = not vim.deep_equal(value, all_stdin[key]) or not vim.deep_equal(value, all_file[key])
  assert(differs == (expected_differences[key] == true), "unexpected .chezmoi difference: " .. key)
end
