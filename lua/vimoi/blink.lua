local util = require("vimoi.core.util")
local cli = require("vimoi.core.cli")

local CompletionItemKind = vim.lsp.protocol.CompletionItemKind

local builtin_completions = {
  { "if", CompletionItemKind.Keyword, "Go template action" },
  { "else", CompletionItemKind.Keyword, "Go template action" },
  { "end", CompletionItemKind.Keyword, "Go template action" },
  { "range", CompletionItemKind.Keyword, "Go template action" },
  { "with", CompletionItemKind.Keyword, "Go template action" },
  { "define", CompletionItemKind.Keyword, "Go template action" },
  { "block", CompletionItemKind.Keyword, "Go template action" },
  { "template", CompletionItemKind.Keyword, "Go template action" },
  { "and", CompletionItemKind.Function, "Go template function" },
  { "or", CompletionItemKind.Function, "Go template function" },
  { "not", CompletionItemKind.Function, "Go template function" },
  { "eq", CompletionItemKind.Function, "Go template function" },
  { "ne", CompletionItemKind.Function, "Go template function" },
  { "lt", CompletionItemKind.Function, "Go template function" },
  { "le", CompletionItemKind.Function, "Go template function" },
  { "gt", CompletionItemKind.Function, "Go template function" },
  { "ge", CompletionItemKind.Function, "Go template function" },
  { "len", CompletionItemKind.Function, "Go template function" },
  { "index", CompletionItemKind.Function, "Go template function" },
  { "slice", CompletionItemKind.Function, "Go template function" },
  { "print", CompletionItemKind.Function, "Go template function" },
  { "printf", CompletionItemKind.Function, "Go template function" },
  { "println", CompletionItemKind.Function, "Go template function" },
  { "call", CompletionItemKind.Function, "Go template function" },
  { "html", CompletionItemKind.Function, "Go template function" },
  { "js", CompletionItemKind.Function, "Go template function" },
  { "urlquery", CompletionItemKind.Function, "Go template function" },
  { "abortEmpty", CompletionItemKind.Function, "chezmoi function" },
  { "comment", CompletionItemKind.Function, "chezmoi function" },
  { "completion", CompletionItemKind.Function, "chezmoi function" },
  { "debugf", CompletionItemKind.Function, "chezmoi function" },
  { "decrypt", CompletionItemKind.Function, "chezmoi function" },
  { "deleteValueAtPath", CompletionItemKind.Function, "chezmoi function" },
  { "encrypt", CompletionItemKind.Function, "chezmoi function" },
  { "ensureLinePrefix", CompletionItemKind.Function, "chezmoi function" },
  { "eqFold", CompletionItemKind.Function, "chezmoi function" },
  { "exec", CompletionItemKind.Function, "chezmoi function" },
  { "include", CompletionItemKind.Function, "chezmoi function" },
  { "includeTemplate", CompletionItemKind.Function, "chezmoi function" },
  { "joinPath", CompletionItemKind.Function, "chezmoi function" },
  { "glob", CompletionItemKind.Function, "chezmoi function" },
  { "globCaseInsensitive", CompletionItemKind.Function, "chezmoi function" },
  { "stat", CompletionItemKind.Function, "chezmoi function" },
  { "lstat", CompletionItemKind.Function, "chezmoi function" },
  { "lookPath", CompletionItemKind.Function, "chezmoi function" },
  { "findExecutable", CompletionItemKind.Function, "chezmoi function" },
  { "findOneExecutable", CompletionItemKind.Function, "chezmoi function" },
  { "isExecutable", CompletionItemKind.Function, "chezmoi function" },
  { "output", CompletionItemKind.Function, "chezmoi function" },
  { "outputList", CompletionItemKind.Function, "chezmoi function" },
  { "jq", CompletionItemKind.Function, "chezmoi function" },
  { "hexDecode", CompletionItemKind.Function, "chezmoi function" },
  { "hexEncode", CompletionItemKind.Function, "chezmoi function" },
  { "fromIni", CompletionItemKind.Function, "chezmoi function" },
  { "fromJson", CompletionItemKind.Function, "chezmoi/Sprig function" },
  { "fromJsonc", CompletionItemKind.Function, "chezmoi function" },
  { "toJson", CompletionItemKind.Function, "chezmoi/Sprig function" },
  { "toPrettyJson", CompletionItemKind.Function, "chezmoi function" },
  { "fromToml", CompletionItemKind.Function, "chezmoi function" },
  { "fromYaml", CompletionItemKind.Function, "chezmoi function" },
  { "toIni", CompletionItemKind.Function, "chezmoi function" },
  { "toYaml", CompletionItemKind.Function, "chezmoi function" },
  { "toToml", CompletionItemKind.Function, "chezmoi function" },
  { "toString", CompletionItemKind.Function, "chezmoi function" },
  { "toStrings", CompletionItemKind.Function, "chezmoi function" },
  { "quoteList", CompletionItemKind.Function, "chezmoi function" },
  { "shellQuote", CompletionItemKind.Function, "chezmoi function" },
  { "shellQuoteList", CompletionItemKind.Function, "chezmoi function" },
  { "replaceAllRegex", CompletionItemKind.Function, "chezmoi function" },
  { "setValueAtPath", CompletionItemKind.Function, "chezmoi function" },
  { "pruneEmptyDicts", CompletionItemKind.Function, "chezmoi function" },
  { "stdinIsATTY", CompletionItemKind.Function, "chezmoi function" },
  { "warnf", CompletionItemKind.Function, "chezmoi function" },
  { "gitHubKeys", CompletionItemKind.Function, "chezmoi GitHub function" },
  { "gitHubLatestRelease", CompletionItemKind.Function, "chezmoi GitHub function" },
  { "gitHubLatestTag", CompletionItemKind.Function, "chezmoi GitHub function" },
  { "gitHubRelease", CompletionItemKind.Function, "chezmoi GitHub function" },
  { "gitHubReleases", CompletionItemKind.Function, "chezmoi GitHub function" },
  { "gitHubTags", CompletionItemKind.Function, "chezmoi GitHub function" },
  { "default", CompletionItemKind.Function, "Sprig function" },
  { "dict", CompletionItemKind.Function, "Sprig function" },
  { "list", CompletionItemKind.Function, "Sprig function" },
  { "get", CompletionItemKind.Function, "Sprig function" },
  { "hasKey", CompletionItemKind.Function, "Sprig function" },
  { "keys", CompletionItemKind.Function, "Sprig function" },
  { "values", CompletionItemKind.Function, "Sprig function" },
  { "merge", CompletionItemKind.Function, "Sprig function" },
  { "ternary", CompletionItemKind.Function, "Sprig function" },
  { "coalesce", CompletionItemKind.Function, "Sprig function" },
  { "empty", CompletionItemKind.Function, "Sprig function" },
  { "trim", CompletionItemKind.Function, "Sprig function" },
  { "trimAll", CompletionItemKind.Function, "Sprig function" },
  { "trimPrefix", CompletionItemKind.Function, "Sprig function" },
  { "trimSuffix", CompletionItemKind.Function, "Sprig function" },
  { "quote", CompletionItemKind.Function, "Sprig function" },
  { "squote", CompletionItemKind.Function, "Sprig function" },
  { "lower", CompletionItemKind.Function, "Sprig function" },
  { "upper", CompletionItemKind.Function, "Sprig function" },
  { "title", CompletionItemKind.Function, "Sprig function" },
  { "untitle", CompletionItemKind.Function, "Sprig function" },
  { "camelcase", CompletionItemKind.Function, "Sprig function" },
  { "kebabcase", CompletionItemKind.Function, "Sprig function" },
  { "snakecase", CompletionItemKind.Function, "Sprig function" },
  { "replace", CompletionItemKind.Function, "Sprig function" },
  { "splitList", CompletionItemKind.Function, "Sprig function" },
  { "join", CompletionItemKind.Function, "Sprig function" },
  { "contains", CompletionItemKind.Function, "Sprig function" },
  { "hasPrefix", CompletionItemKind.Function, "Sprig function" },
  { "hasSuffix", CompletionItemKind.Function, "Sprig function" },
  { "regexMatch", CompletionItemKind.Function, "Sprig function" },
  { "semverCompare", CompletionItemKind.Function, "Sprig function" },
  { "sha256sum", CompletionItemKind.Function, "Sprig function" },
  { "b64enc", CompletionItemKind.Function, "Sprig function" },
  { "b64dec", CompletionItemKind.Function, "Sprig function" },
  { "now", CompletionItemKind.Function, "Sprig function" },
  { "date", CompletionItemKind.Function, "Sprig function" },
  { "add", CompletionItemKind.Function, "Sprig function" },
  { "add1", CompletionItemKind.Function, "Sprig function" },
  { "sub", CompletionItemKind.Function, "Sprig function" },
  { "mul", CompletionItemKind.Function, "Sprig function" },
  { "div", CompletionItemKind.Function, "Sprig function" },
  { "mod", CompletionItemKind.Function, "Sprig function" },
  { "max", CompletionItemKind.Function, "Sprig function" },
  { "min", CompletionItemKind.Function, "Sprig function" },
  { "until", CompletionItemKind.Function, "Sprig function" },
  { "untilStep", CompletionItemKind.Function, "Sprig function" },
  { "seq", CompletionItemKind.Function, "Sprig function" },
  { "uuidv4", CompletionItemKind.Function, "Sprig function" },
  { "promptBool", CompletionItemKind.Function, "chezmoi init-only function" },
  { "promptBoolOnce", CompletionItemKind.Function, "chezmoi init-only function" },
  { "promptChoice", CompletionItemKind.Function, "chezmoi init-only function" },
  { "promptChoiceOnce", CompletionItemKind.Function, "chezmoi init-only function" },
  { "promptInt", CompletionItemKind.Function, "chezmoi init-only function" },
  { "promptIntOnce", CompletionItemKind.Function, "chezmoi init-only function" },
  { "promptMultichoice", CompletionItemKind.Function, "chezmoi init-only function" },
  { "promptMultichoiceOnce", CompletionItemKind.Function, "chezmoi init-only function" },
  { "promptString", CompletionItemKind.Function, "chezmoi init-only function" },
  { "promptStringOnce", CompletionItemKind.Function, "chezmoi init-only function" },
}

---@type { label: string, body: string }[]
local block_snippets = {
  { label = "if", body = "{{ if ${1:true} }}\n\t$0\n{{ end }}" },
  { label = "ifelse", body = "{{ if ${1:true} }}\n\t${2}\n{{ else }}\n\t$0\n{{ end }}" },
  { label = "range", body = "{{ range ${1:.items} }}\n\t$0\n{{ end }}" },
  { label = "with", body = "{{ with ${1:.} }}\n\t$0\n{{ end }}" },
  { label = "define", body = '{{ define "${1:name}" }}\n\t$0\n{{ end }}' },
  { label = "block", body = '{{ block "${1:name}" ${2:.} }}\n\t$0\n{{ end }}' },
  { label = "comment", body = "{{/* ${1:comment} */}}$0" },
}

local function completion_item(label, kind, detail, row, start_col, end_col, new_text)
  return {
    label = label,
    kind = kind,
    detail = detail,
    textEdit = {
      newText = new_text or label,
      range = {
        start = { line = row, character = start_col },
        ["end"] = { line = row, character = end_col },
      },
    },
  }
end

-- Read real delimiter tokens, including incomplete actions. Strings and comments
-- may contain braces, so searching source text for the last {{ / }} is unsafe.
local function regex_completion_syntax(buf, row, col)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local before = line:sub(1, col)
  local opening = before:match(".*(){{%-?")
  if not opening then
    return
  end
  local closing = before:match(".*()%-?}}")
  if closing and closing > opening then
    return
  end
  return vim.api.nvim_buf_get_offset(buf, row) + opening - 1, nil, vim.api.nvim_buf_get_offset(buf, row) + col
end

local function completion_syntax(buf, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "gotmpl")
  if not ok or not parser then
    return regex_completion_syntax(buf, row, col)
  end
  local tree = parser:parse()[1]
  if not tree then
    return
  end
  local cursor_byte = vim.api.nvim_buf_get_offset(buf, row) + col
  local function last_delimiter(node)
    local _, _, start_byte = node:start()
    if start_byte >= cursor_byte or node:missing() then
      return nil
    end
    local kind = node:type()
    if kind == "{{" or kind == "{{-" then
      local _, _, end_byte = node:end_()
      return end_byte
    elseif kind == "}}" or kind == "-}}" then
      return false
    elseif kind == "comment" then
      local _, _, end_byte = node:end_()
      if cursor_byte <= end_byte then
        return false
      end
      return nil
    end
    -- The closest delimiter decides; do not walk the whole preceding template.
    for index = node:child_count() - 1, 0, -1 do
      local delimiter = last_delimiter(node:child(index))
      if delimiter ~= nil then
        return delimiter
      end
    end
  end
  return last_delimiter(tree:root()), tree:root(), cursor_byte
end

-- Fallback for environments without a gotmpl parser. This intentionally favors
-- useful candidates over scope accuracy.
-- TODO(vimoi): cache these names with the prepared skeleton.
local function regex_variable_completions(buf, prefix, row, start_col, end_col)
  local names = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    for name in line:gmatch("%$([%w_]+)") do
      names[name] = true
    end
  end
  local items = {}
  for name in pairs(names) do
    if name:sub(1, #prefix) == prefix then
      items[#items + 1] = completion_item(
        "$" .. name,
        CompletionItemKind.Variable,
        "template variable",
        row,
        start_col,
        end_col
      )
    end
  end
  table.sort(items, function(a, b)
    return a.label < b.label
  end)
  return items
end

local function path_completions(base_directory, prefix, kind, row, end_col, detail)
  if not base_directory or base_directory == "" then
    return {}
  end
  local directory, filename_prefix = prefix:match("^(.*[/\\])([^/\\]*)$")
  directory, filename_prefix = directory or "", filename_prefix or prefix
  local path = directory == "" and base_directory or vim.fs.joinpath(base_directory, directory)
  local result = {}
  local handle = vim.uv.fs_scandir(path)
  if not handle then
    return result
  end
  while true do
    local name, entry_type = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:sub(1, #filename_prefix) == filename_prefix then
      local value = directory .. name .. (entry_type == "directory" and "/" or "")
      result[#result + 1] = completion_item(
        value,
        entry_type == "directory" and CompletionItemKind.Folder or kind,
        detail,
        row,
        end_col - #prefix,
        end_col,
        value
      )
    end
  end
  table.sort(result, function(a, b)
    return a.label < b.label
  end)
  return result
end

local function template_path_completions(source_dir, prefix, row, col)
  local items, seen = {}, {}
  if not source_dir then
    return items
  end
  for _, directory in ipairs(cli.template_directories(source_dir)) do
    for _, item in ipairs(path_completions(directory, prefix, CompletionItemKind.File, row, col, "chezmoi template")) do
      if not seen[item.label] then
        seen[item.label] = true
        items[#items + 1] = item
      end
    end
  end
  table.sort(items, function(a, b)
    return a.label < b.label
  end)
  return items
end

-- Follow syntax tokens rather than parent blocks: unfinished control blocks
-- are often ERROR nodes while typing, but their keywords/declarations survive.
local function variable_completions(buf, root, cursor_byte, row, prefix, start_col, end_col)
  local token_byte = cursor_byte - (end_col - start_col)
  -- Each control keeps header variables across else, while branch locals reset.
  local scopes = { { variables = {}, header_variables = {} } }
  local in_header, after_else = false, false
  local function walk(node)
    local _, _, first = node:start()
    local _, _, last = node:end_()
    if first >= token_byte or node:missing() then
      return
    end
    local kind = node:type()
    if kind == "{{" or kind == "{{-" then
      in_header, after_else = false, false
    elseif kind == "}}" or kind == "-}}" then
      in_header = false
    elseif kind == "if" or kind == "range" or kind == "with" or kind == "define" or kind == "block" then
      if not after_else then
        scopes[#scopes + 1] = { variables = {}, header_variables = {}, isolated = kind == "define" or kind == "block" }
      end
      in_header = true
    elseif kind == "else" then
      local scope = scopes[#scopes]
      scope.variables = vim.deepcopy(scope.header_variables)
      after_else = true
    elseif kind == "end" then
      if #scopes > 1 then
        table.remove(scopes)
      end
    elseif kind == "variable_definition" or kind == "range_variable_definition" then
      if last <= token_byte then
        local scope = scopes[#scopes]
        for _, field in ipairs({ "variable", "index", "element" }) do
          for _, variable in ipairs(node:field(field)) do
            local name = vim.treesitter.get_node_text(variable, buf):match("^%$(.*)$")
            if name then
              scope.variables[name] = true
              if in_header then
                scope.header_variables[name] = true
              end
            end
          end
        end
      end
    elseif kind ~= "comment" and kind ~= "interpreted_string_literal" and kind ~= "raw_string_literal" then
      for child in node:iter_children() do
        walk(child)
      end
    end
  end
  walk(root)
  local found = {}
  for index = #scopes, 1, -1 do
    for name in pairs(scopes[index].variables) do
      found[name] = true
    end
    if scopes[index].isolated then
      break
    end
  end
  local items = {}
  for name in pairs(found) do
    if name:sub(1, #prefix) == prefix then
      items[#items + 1] =
        completion_item("$" .. name, CompletionItemKind.Variable, "template variable", row, start_col, end_col)
    end
  end
  table.sort(items, function(a, b)
    return a.label < b.label
  end)
  return items
end

-- Copy only the displayed portion; filtering must not mutate the shared data cache.
local function data_value_preview(value, key, policy, depth, budget)
  if cli.is_runtime_value(value) then
    return "[runtime value]"
  end
  budget.remaining = budget.remaining - 1
  if policy == "hint" or policy == true or (type(policy) == "function" and policy(key)) then
    return "[ masked]", true
  end
  if type(value) == "string" then
    local text = vim.fn.strcharpart(value, 0, 200)
    return #text < #value and text .. "…" or value
  end
  if type(value) ~= "table" then
    return value
  end
  if depth == 4 then
    return "…"
  end
  local list = vim.islist(value)
  local preview = list and {} or vim.empty_dict()
  for child_key, child in (list and ipairs or pairs)(value) do
    if budget.remaining <= 0 then
      preview[list and (#preview + 1) or "…"] = "…"
      break
    end
    preview[child_key] = data_value_preview(child, key .. "." .. child_key, policy, depth + 1, budget)
  end
  return preview
end

local function data_field_completions(data, expression, row, col)
  local field_path = vim.split(expression:sub(2), ".", { plain = true, trimempty = false })
  local prefix = table.remove(field_path) or ""
  local data_scope = data
  local policy = require("vimoi").config.completion.mask
  local path = ""
  for _, part in ipairs(field_path) do
    data_scope = type(data_scope) == "table" and data_scope[part] or nil
    path = path == "" and part or path .. "." .. part
    if type(policy) == "function" and policy(path) then
      policy = true
    end
  end
  if type(data_scope) ~= "table" then
    return {}
  end
  local items = {}
  for key, value in pairs(data_scope) do
    if type(key) == "string" and key:sub(1, #prefix) == prefix then
      local value_type = vim.islist(value) and "list" or type(value)
      local item =
        completion_item(key, CompletionItemKind.Field, "chezmoi data · " .. value_type, row, col - #prefix, col)
      local key_path = path == "" and key or path .. "." .. key
      local preview, masked = data_value_preview(value, key_path, policy, 0, { remaining = 40 })
      item.documentation = {
        kind = "markdown",
        value = masked and (preview .. (policy == "hint" and "\n\nSee :help vimoi-completion-mask." or ""))
          or ("```lua\n" .. vim.inspect(preview) .. "\n```"),
      }
      items[#items + 1] = item
    end
  end
  table.sort(items, function(a, b)
    return a.label < b.label
  end)
  return items
end

---Generate candidates; blink owns filtering, sorting, and displaying them.
---@param buf integer
---@param row integer Zero-based row.
---@param col integer Byte column.
---@param callback fun(items: lsp.CompletionItem[])
local function complete(buf, row, col, callback)
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local before = line:sub(1, col)
  local opening_byte, root, cursor_byte = completion_syntax(buf, row, col)
  if not opening_byte then
    local node = root and root:named_descendant_for_range(row, math.max(col - 1, 0), row, col)
    while node do
      if node:type() == "comment" then
        callback({})
        return
      end
      node = node:parent()
    end
    local word = before:match("([%w_]*)$") or ""
    if word == "" and before:find("%S") then
      callback({})
      return
    end
    local items = {}
    for _, snippet in ipairs(block_snippets) do
      if snippet.label:sub(1, #word) == word then
        local item = completion_item(
          snippet.label,
          CompletionItemKind.Snippet,
          "Go template block",
          row,
          col - #word,
          col,
          snippet.body
        )
        item.insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet
        items[#items + 1] = item
      end
    end
    callback(items)
    return
  end

  local opening_row, opening_col = util.byte_to_position(util.buffer_text(buf), opening_byte)
  local action_before = table.concat(vim.api.nvim_buf_get_text(buf, opening_row, opening_col, row, col, {}), "\n")
  if action_before:match("^%s*/%*") then
    callback({}) -- An unfinished comment may still be an ERROR node in Tree-sitter.
    return
  end
  local function_name, prefix = action_before:match('([%w]+)%s+["`]([^"`\n]*)$')
  local expression = before:match("([.][%w_.]*)$")
  local variable = before:match("%$([%w_]*)$")
  if variable then
    if root then
      callback(variable_completions(buf, root, cursor_byte, row, variable, col - #variable - 1, col))
    else
      callback(regex_variable_completions(buf, variable, row, col - #variable - 1, col))
    end
    return
  end
  if not function_name and not expression then
    local word = before:match("([%w_]*)$") or ""
    local items = {}
    for _, candidate in ipairs(builtin_completions) do
      -- blink performs fuzzy filtering, including useful typo correction such
      -- as includeTemplete -> includeTemplate.
      items[#items + 1] = completion_item(candidate[1], candidate[2], candidate[3], row, col - #word, col)
    end
    callback(items)
    return
  end

  cli.data_async(function(data)
    if not data then
      callback({})
      return
    end
    data = cli.data_for_completion(data, buf)
    if function_name == "include" then
      callback(
        path_completions(data.chezmoi.sourceDir, prefix, CompletionItemKind.File, row, col, "chezmoi source file")
      )
    elseif function_name == "template" or function_name == "includeTemplate" then
      callback(template_path_completions(data.chezmoi.sourceDir, prefix, row, col))
    elseif function_name == "glob" then
      callback(
        path_completions(data.chezmoi.destDir, prefix, CompletionItemKind.File, row, col, "chezmoi destination path")
      )
    elseif expression then
      callback(data_field_completions(data, expression, row, col))
    else
      callback({})
    end
  end)
end

local Source = {}
Source.__index = Source

function Source.new()
  return setmetatable({}, Source)
end

function Source:enabled()
  return require("vimoi").config.completion.enabled and vim.bo.filetype == "gotmpl"
end

function Source:get_trigger_characters()
  return { ".", "$", "/", '"', "`" }
end

---@class VimoiBlinkCompletionResponse
---@field items lsp.CompletionItem[]
---@field is_incomplete_forward boolean
---@field is_incomplete_backward boolean

---@param context { bufnr?: integer, cursor?: integer[] } Cursor uses a one-based row and byte column.
---@param callback fun(response: VimoiBlinkCompletionResponse)
---@return fun() cancel Suppresses delivery; the shared data lookup may still finish.
function Source:get_completions(context, callback)
  local position = context.cursor
  local row = position and (position[1] - 1) or vim.api.nvim_win_get_cursor(0)[1] - 1
  local col = position and position[2] or vim.api.nvim_win_get_cursor(0)[2]
  local cancelled = false
  complete(context.bufnr or vim.api.nvim_get_current_buf(), row, col, function(items)
    if cancelled then
      return
    end
    callback({
      is_incomplete_forward = false,
      is_incomplete_backward = false,
      items = items,
    })
  end)
  return function()
    cancelled = true
  end
end

return Source
