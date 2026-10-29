local M = {}
local api = vim.api
local client = require("open-compleat.client")
local prompt = require("open-compleat.prompt")
local progress = require("open-compleat.progress")
local armed, active, pending
local frontend

local function notify(message)
  vim.notify(message, vim.log.levels.WARN, { title = "open-compleat" })
end

local function insert_mode()
  -- nvim_get_mode includes completion submodes (ic/ix), which are still Insert.
  return api.nvim_get_mode().mode:sub(1, 1) == "i"
end

local function valid(record)
  return record.input.current() and api.nvim_buf_is_valid(record.bufnr)
    and api.nvim_get_current_buf() == record.bufnr and api.nvim_get_current_win() == record.win
    and insert_mode()
    and api.nvim_buf_get_changedtick(record.bufnr) == record.tick
    and vim.deep_equal(api.nvim_win_get_cursor(0), record.cursor)
end

function M.dismiss()
  local visible = active
  armed, active = nil, nil
  local old = pending
  pending = nil
  if old and old.job then pcall(old.job.kill, old.job, 15) end
  if frontend then frontend.action.dismiss() end
  if old then progress.finish("canceled") elseif visible then progress.finish("dismissed") end
end

function M.reset()
  M.dismiss()
  progress.reset()
end

function M.status() return progress.status() end
function M.statusline() return progress.statusline() end

local function setup()
  local ok, minuet = pcall(require, "minuet")
  if not ok then
    notify("Minuet is required for suggestions; add the dependency shown in README.md")
    return false
  end
  if minuet.config and minuet.config.provider ~= "open_compleat" then
    notify("Minuet is already configured by something else; open-compleat will not overwrite it")
    return false
  end
  if frontend then return true end
  minuet.setup({
    provider = "open_compleat",
    provider_options = { open_compleat = { name = "OpenCode" } },
    n_completions = 1,
    cmp = { enable_auto_complete = false },
    blink = { enable_auto_complete = false },
    virtualtext = { auto_trigger_ft = {} },
    lsp = { enabled_ft = {}, completion = { enable = false } },
    before_cursor_filter_length = 0,
    after_cursor_filter_length = 0,
  })
  frontend = require("minuet.virtualtext")
  api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "WinLeave" }, {
    group = api.nvim_create_augroup("OpenCompleatCompletion", { clear = true }),
    callback = M.dismiss,
  })
  api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "CursorMovedI" }, {
    group = "OpenCompleatCompletion",
    callback = function()
      if (pending and not valid(pending)) or (active and not valid(active)) then M.dismiss() end
    end,
  })
  return true
end

---@param input table
---@return boolean
function M.suggest(input)
  if not insert_mode() then
    notify("Request suggestions from Insert mode using an insert-mode mapping")
    return false
  end
  if vim.bo.buftype ~= "" or not vim.bo.modifiable then
    notify("Suggestions are only available in editable file buffers")
    return false
  end
  if not setup() then return false end
  M.dismiss()
  require("minuet").config.context_window = input.context_window
  armed = input
  frontend.action.next()
  return true
end

--- Called by Minuet after it captures the buffer prefix/suffix.
function M.complete(context, callback)
  local input = armed
  armed = nil
  -- Direct Minuet commands/automatic triggers are not authorization to generate.
  if not input then callback({}); return end
  local record = {
    input = input,
    bufnr = api.nvim_get_current_buf(),
    win = api.nvim_get_current_win(),
    tick = api.nvim_buf_get_changedtick(0),
    cursor = api.nvim_win_get_cursor(0),
  }
  if not valid(record) then callback({}); return end
  local prefix, suffix = context.lines_before, context.lines_after
  local line_count = api.nvim_buf_line_count(record.bufnr)
  -- Minuet adds a separator even when there are no preceding/following lines.
  -- Do not represent those synthetic boundary newlines as actual buffer text.
  if record.cursor[1] == 1 and not context.opts.is_incomplete_before then prefix = prefix:sub(2) end
  if record.cursor[1] == line_count and not context.opts.is_incomplete_after then suffix = suffix:sub(1, -2) end
  local text = prompt.build(input, {
    filename = api.nvim_buf_get_name(0),
    directory = input.directory,
    language = vim.bo.filetype,
    cursor = { row = record.cursor[1], byte_column = record.cursor[2],
      byte_offset = api.nvim_buf_get_offset(record.bufnr, record.cursor[1] - 1) + record.cursor[2] },
    line_count = line_count,
    endofline = vim.bo[record.bufnr].endofline,
    indentation = { expandtab = vim.bo.expandtab, shiftwidth = vim.bo.shiftwidth, tabstop = vim.bo.tabstop },
    prefix = prefix,
    suffix = suffix,
    truncated = context.opts,
  })
  pending = record
  progress.start(record.bufnr)
  record.job = client.generation_path(input.config, input.connection, function(path_err, path)
    if pending ~= record then return end
    if not valid(record) then M.dismiss(); return end
    if path_err then
      pending = nil
      progress.finish("error", path_err)
      notify(path_err)
      callback({})
      return
    end
    record.job = client.generate(input.config, input.connection, path, text, input.model, function(err, result)
      if pending ~= record then return end
      pending = nil
      if not valid(record) then progress.finish("canceled"); return end
      if err then
        progress.finish("error", err)
        notify(err)
        callback({})
        return
      end
      local suggestion, reason = prompt.clean(result)
      if suggestion ~= "" then active, record.remaining = record, suggestion end
      callback(suggestion == "" and {} or { suggestion })
      progress.finish(reason and "rejected" or suggestion == "" and "empty" or "ready", reason)
      if reason then notify(reason) end
    end)
  end)
end

---@param line? boolean Accept one line rather than the entire suggestion.
---@return boolean
function M.accept(line)
  if not frontend or not active or not valid(active) or not frontend.action.is_visible() then
    M.dismiss()
    return false
  end
  local record = active
  local parts = vim.split(record.remaining, "\n", { plain = true })
  local accepted = line and (parts[1] == "" and 2 or 1) or #parts
  local all = accepted >= #parts
  if not all then record.remaining = "\n" .. table.concat(vim.list_slice(parts, accepted + 1), "\n") end
  if line then frontend.action.accept_line() else frontend.action.accept() end
  -- Minuet schedules insertion. Update the guard after its edit, so accepting a
  -- line does not invalidate the remaining suggestion as if it were user typing.
  vim.schedule(function()
    if active ~= record then return end
    if not record.input.current() or api.nvim_get_current_buf() ~= record.bufnr then
      M.dismiss()
    elseif all then
      active = nil
      progress.finish("accepted")
    else
      record.tick = api.nvim_buf_get_changedtick(record.bufnr)
      record.cursor = api.nvim_win_get_cursor(0)
    end
  end)
  return true
end

return M
