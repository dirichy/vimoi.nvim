-- Run coroutine-based synchronous-looking helpers to completion in a test.
-- Runtime workflows return to Neovim immediately; tests wait for assertions.
return function(work, ...)
  local args, result = { n = select("#", ...), ... }, nil
  local thread = coroutine.create(function()
    local function save(...)
      result = { n = select("#", ...), ... }
    end
    save(work(unpack(args, 1, args.n)))
  end)
  local ok, err = coroutine.resume(thread)
  assert(ok, err)
  assert(
    vim.wait(10000, function()
      return coroutine.status(thread) == "dead"
    end, 5),
    "asynchronous helper did not complete"
  )
  assert(result, "asynchronous helper failed before returning")
  return unpack(result, 1, result.n)
end
