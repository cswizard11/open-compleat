local M = {}
local api = vim.api
local uv = vim.uv or vim.loop
local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local value = { state = "idle" }
local timer, started, frame

local function stop()
  if timer then
    timer:stop()
    if not timer:is_closing() then timer:close() end
    timer = nil
  end
end

function M.status()
  local result = vim.deepcopy(value)
  if value.state == "generating" then result.elapsed_ms = math.floor((uv.hrtime() - started) / 1e6) end
  return result
end

local function changed()
  local snapshot = M.status()
  vim.schedule(function()
    -- Consumers receive lifecycle data, never prompts or generated source.
    pcall(api.nvim_exec_autocmds, "User", { pattern = "OpenCompleatProgress", modeline = false, data = snapshot })
    vim.cmd("redrawstatus")
  end)
end

function M.start(bufnr)
  stop()
  started, frame = uv.hrtime(), 1
  value = { state = "generating", bufnr = bufnr }
  changed()
  timer = assert(uv.new_timer())
  timer:start(100, 100, vim.schedule_wrap(function()
    if value.state ~= "generating" then return end
    frame = frame % #frames + 1
    changed()
  end))
end

function M.finish(state, message)
  stop()
  if started then value.elapsed_ms = math.floor((uv.hrtime() - started) / 1e6) end
  value.state, value.message = state, message
  changed()
end

function M.reset()
  stop()
  value, started = { state = "idle" }, nil
  changed()
end

function M.statusline()
  if value.bufnr ~= api.nvim_get_current_buf() then return "" end
  if value.state == "generating" then return "OC " .. frames[frame] .. " Generating" end
  local labels = { ready = "Ready", empty = "No suggestion", rejected = "Response rejected",
    error = "Error", canceled = "Canceled", dismissed = "Dismissed", accepted = "Accepted" }
  return labels[value.state] and "OC: " .. labels[value.state] or ""
end

api.nvim_create_autocmd("VimLeavePre", {
  group = api.nvim_create_augroup("OpenCompleatProgress", { clear = true }),
  callback = stop,
})

return M
