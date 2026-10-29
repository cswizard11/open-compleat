local M = {}
local api = vim.api
local pending

local function cleanup(record)
  if record.autocmd then pcall(api.nvim_del_autocmd, record.autocmd); record.autocmd = nil end
  if record.source_autocmd then pcall(api.nvim_del_autocmd, record.source_autocmd); record.source_autocmd = nil end
  if record.timer and not record.timer:is_closing() then
    record.timer:stop()
    record.timer:close()
  end
end

function M.cancel()
  local old = pending
  pending = nil
  if old then cleanup(old) end
end

local function same_source(record)
  return record.input.current() and api.nvim_win_is_valid(record.win) and api.nvim_buf_is_valid(record.bufnr)
    and api.nvim_get_current_win() == record.win and api.nvim_win_get_buf(record.win) == record.bufnr
    and api.nvim_buf_get_changedtick(record.bufnr) == record.tick
    and api.nvim_buf_get_name(record.bufnr) == record.name
end

---@param input table
---@param submit fun(input: table): boolean
---@return boolean
function M.open(input, submit)
  if api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
    vim.notify("Request suggestions from Insert mode using an insert-mode mapping", vim.log.levels.WARN, { title = "open-compleat" })
    return false
  end
  if vim.bo.buftype ~= "" or not vim.bo.modifiable then
    vim.notify("Suggestions are only available in editable file buffers", vim.log.levels.WARN, { title = "open-compleat" })
    return false
  end
  M.cancel()
  local record = {
    input = input, win = api.nvim_get_current_win(), bufnr = api.nvim_get_current_buf(),
    cursor = api.nvim_win_get_cursor(0), tick = api.nvim_buf_get_changedtick(0), name = api.nvim_buf_get_name(0),
  }
  local column = math.max(0, record.cursor[2] - 1)
  local line = api.nvim_get_current_line()
  while column > 0 and line:byte(column + 1) >= 128 and line:byte(column + 1) < 192 do column = column - 1 end
  record.normal_cursor = { record.cursor[1], column }
  pending = record
  record.source_autocmd = api.nvim_create_autocmd({ "BufDelete", "BufWipeout", "BufUnload" }, {
    buffer = record.bufnr, once = true,
    callback = function() if pending == record then M.cancel() end end,
  })
  local function abort(message)
    if pending ~= record then return end
    M.cancel()
    if message then vim.notify(message, vim.log.levels.WARN, { title = "open-compleat" }) end
  end
  local ok = pcall(vim.ui.input, {
    prompt = "Completion direction (optional)", default = "",
    -- Snacks defaults to leaving Insert mode on the first Escape. For this
    -- dialog, one Escape must cancel. Other vim.ui.input providers ignore win.
    win = {
      relative = "editor", row = false, col = false, -- Snacks centers unset/false coordinates.
      keys = {
        i_esc = { "<Esc>", "cancel", mode = "i" }, n_esc = { "<Esc>", "cancel", mode = "n" },
      },
    },
  }, function(value)
    if pending ~= record or record.confirmed then return end
    record.confirmed = true
    vim.schedule(function()
      if pending ~= record then return end
      local cursor = api.nvim_win_is_valid(record.win) and api.nvim_win_get_cursor(record.win)
      if not same_source(record) or not (vim.deep_equal(cursor, record.baseline) or vim.deep_equal(cursor, record.cursor)
          or vim.deep_equal(cursor, record.normal_cursor)) then
        abort(value ~= nil and "Completion canceled: source editor or planning/model selection changed while the input was open" or nil)
        return
      end
      local function restored()
        vim.schedule(function()
          if pending ~= record then return end
          if not same_source(record) or api.nvim_get_mode().mode:sub(1, 1) ~= "i" then abort(); return end
          -- Normal-mode cursor clamping can move an end-of-line Insert cursor
          -- one character left. Restore the exact position after Insert mode resumes.
          api.nvim_win_set_cursor(record.win, record.cursor)
          vim.schedule(function()
            if pending ~= record then return end
            if not same_source(record) or api.nvim_get_mode().mode:sub(1, 1) ~= "i"
                or not vim.deep_equal(api.nvim_win_get_cursor(0), record.cursor) then abort(); return end
            M.cancel()
            if value ~= nil then
              local direction = vim.trim(value)
              input.direction = direction ~= "" and direction or nil
              submit(input)
            end
          end)
        end)
      end
      if api.nvim_get_mode().mode:sub(1, 1) == "i" then
        restored()
      else
        record.autocmd = api.nvim_create_autocmd("InsertEnter", { buffer = record.bufnr, once = true, callback = restored })
        record.timer = vim.defer_fn(function() abort("Completion canceled: could not restore Insert mode") end, 1000)
        vim.cmd("startinsert")
      end
    end)
  end)
  if not ok then abort("Could not open the completion direction input"); return false end
  if pending == record and api.nvim_win_is_valid(record.win) then record.baseline = api.nvim_win_get_cursor(record.win) end
  return true
end

return M
