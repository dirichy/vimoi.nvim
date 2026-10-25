-- Deliver held render completions without taking focus from a merge wait window.
local await = dofile("tests/helpers/await.lua")
return function(renderer, source, opts)
  return await(require("vimoi.core.util").await, function(done)
    renderer.trace_async(source, opts, done)
  end)
end
