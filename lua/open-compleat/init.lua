local M = {}
local api = vim.api
local client = require("open-compleat.client")
local context = require("open-compleat.context")
local defaults = {
  service_file = (vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")) .. "/opencode/service.json",
  timeout_ms = 10000,
}
local config = vim.deepcopy(defaults)
local bindings = {}

local function binding()
  local tab = api.nvim_get_current_tabpage()
  local directory = vim.fn.getcwd()
  if not bindings[tab] or bindings[tab].directory ~= directory then
    bindings[tab] = { directory = directory, revision = 0, selection_revision = 0, model_revision = 0 }
  end
  return bindings[tab], tab
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "open-compleat" })
end

local function model_label(model)
  if not model then return "Not selected" end
  return model.providerID .. "/" .. model.id .. (model.variant and "#" .. model.variant or "")
end

local function open_panel(lines)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modeline = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].filetype = "markdown"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_open_win(buf, true, { split = "below", win = -1, height = math.max(1, vim.o.helpheight) })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, desc = "Close open-compleat panel" })
end

---@param opts? table
function M.setup(opts)
  opts = opts or {}
  local allowed = { service_file = true, server = true, password = true, timeout_ms = true }
  for key in pairs(opts) do
    assert(allowed[key], "Unknown open-compleat option: " .. key)
  end
  local candidate = vim.tbl_extend("force", defaults, opts)
  assert(type(candidate.service_file) == "string", "service_file must be a path")
  assert(type(candidate.timeout_ms) == "number" and candidate.timeout_ms > 0, "timeout_ms must be positive")
  assert(candidate.server == nil or type(candidate.server) == "string", "server must be a URL")
  assert(candidate.password == nil or type(candidate.password) == "string"
    or type(candidate.password) == "function", "password must be a string or function")
  config = candidate
  bindings = {}
end

api.nvim_create_autocmd("TabClosed", {
  group = api.nvim_create_augroup("OpenCompleat", { clear = true }),
  callback = function()
    for tab in pairs(bindings) do
      if not api.nvim_tabpage_is_valid(tab) then bindings[tab] = nil end
    end
  end,
})

--- Refresh the selected session. Older replies cannot replace newer selections.
---@param callback? fun(err: string?)
function M.refresh(callback)
  local state, tab = binding()
  if not state.session then
    if callback then callback("Select a planning session first: :OpenCompleat select") end
    return
  end
  state.revision = state.revision + 1
  local revision = state.revision
  local connection, err = client.connection(config)
  if not connection then
    state.error, state.loading = err, false
    if callback then callback(err) end
    return
  end
  state.loading, state.error = true, nil
  client.context(config, connection, state.session.id, function(fetch_err, messages)
    if bindings[tab] ~= state or state.revision ~= revision or not api.nvim_tabpage_is_valid(tab) then
      return
    end
    state.loading, state.error = false, fetch_err
    if not fetch_err then
      local ok, text, warnings = pcall(context.render, messages)
      if ok then
        state.cache = { text = text, warnings = warnings, message_count = #messages, refreshed_at = os.time() }
      else
        fetch_err = "Could not render context: the response does not match the supported V2 schema"
        state.error = fetch_err
      end
    end
    if callback then callback(fetch_err) end
  end)
end

--- Select a session explicitly, or open a picker. all=true removes the cwd filter.
---@param id? string
---@param all? boolean
function M.select(id, all)
  local state, tab = binding()
  state.selection_revision = state.selection_revision + 1
  local revision = state.selection_revision
  local connection, err = client.connection(config)
  if not connection then notify(err, vim.log.levels.ERROR); return end
  local function selected(session)
    if not session or bindings[tab] ~= state or state.selection_revision ~= revision
        or api.nvim_get_current_tabpage() ~= tab or vim.fn.getcwd() ~= state.directory then
      return
    end
    if type(session.id) ~= "string" or not session.id:match("^ses") then
      notify("OpenCode returned an invalid session ID", vim.log.levels.ERROR)
      return
    end
    state.session, state.cache, state.error = session, nil, nil
    M.refresh(function(refresh_err)
      notify(refresh_err or "Planning context loaded: " .. (session.title or session.id),
        refresh_err and vim.log.levels.ERROR or vim.log.levels.INFO)
    end)
  end
  if id then
    if type(id) ~= "string" or not id:match("^ses") then notify("Invalid OpenCode session ID", vim.log.levels.ERROR); return end
    client.session(config, connection, id, function(get_err, response)
      if get_err then notify(get_err, vim.log.levels.ERROR) else selected(response.data) end
    end)
  else
    local query = { parentID = "null", archived = "false", order = "desc", limit = 100 }
    if not all then query.directory = state.directory end
    client.list(config, connection, "/api/session", query, function(list_err, sessions)
      if bindings[tab] ~= state or state.selection_revision ~= revision
          or api.nvim_get_current_tabpage() ~= tab or vim.fn.getcwd() ~= state.directory then return end
      if list_err then notify(list_err, vim.log.levels.ERROR); return end
      if #sessions == 0 then notify("No sessions found; use :OpenCompleat! select to search all directories"); return end
      vim.ui.select(sessions, {
        prompt = "OpenCode planning session",
        format_item = function(session)
          return (session.title or "Untitled") .. " [" .. session.id .. "]"
        end,
      }, selected)
    end)
  end
end

--- Select the completion model without changing the planning session's model.
function M.model()
  local state, tab = binding()
  state.model_revision = state.model_revision + 1
  local revision = state.model_revision
  local connection, err = client.connection(config)
  if not connection then notify(err, vim.log.levels.ERROR); return end
  local function current()
    return bindings[tab] == state and state.model_revision == revision
      and api.nvim_get_current_tabpage() == tab and vim.fn.getcwd() == state.directory
  end
  client.models(config, connection, state.directory, function(list_err, models)
    if not current() then return end
    if list_err then notify(list_err, vim.log.levels.ERROR); return end
    if #models == 0 then
      notify("No enabled text models available for this directory; connect a provider or retry")
      return
    end
    vim.ui.select(models, {
      prompt = "OpenCode completion model",
      format_item = function(model) return model.name .. " [" .. model_label(model) .. "]" end,
    }, function(model)
      if not model or not current() then return end
      local function selected(variant)
        if not variant or not current() then return end
        state.completion_model = { providerID = model.providerID, id = model.id, variant = variant.id }
        notify("Completion model selected: " .. model_label(state.completion_model))
      end
      if #model.variants == 0 then
        selected({})
      else
        local variants = { { name = "Default (model settings)" } }
        for _, variant in ipairs(model.variants) do
          variants[#variants + 1] = { id = variant.id, name = variant.id }
        end
        vim.ui.select(variants, {
          prompt = "Completion model variant",
          format_item = function(variant) return variant.name end,
        }, selected)
      end
    end)
  end)
end

--- Return only successfully loaded text. A failed refresh makes the cache stale.
---@return string?, string?
function M.get_context()
  local state = binding()
  if state.error then return nil, state.error end
  if state.loading then return nil, "Planning context is refreshing" end
  if not state.cache then return nil, "No planning context loaded" end
  return state.cache.text
end

function M.clear()
  local state = binding()
  state.revision = state.revision + 1
  state.selection_revision = state.selection_revision + 1
  state.session, state.cache, state.error, state.loading = nil, nil, nil, false
end

function M.status()
  local state = binding()
  return {
    directory = state.directory,
    session_id = state.session and state.session.id,
    title = state.session and state.session.title,
    completion_model = state.completion_model and vim.deepcopy(state.completion_model),
    loading = state.loading or false,
    error = state.error,
    bytes = state.cache and #state.cache.text,
    message_count = state.cache and state.cache.message_count,
    refreshed_at = state.cache and state.cache.refreshed_at,
    warnings = state.cache and vim.deepcopy(state.cache.warnings) or {},
  }
end

function M.show_status()
  local status = M.status()
  local cache = status.loading and "Refreshing" or status.error and "Stale or unavailable"
    or status.refreshed_at and "Loaded" or "Not loaded"
  local lines = {
    "# open-compleat status", "",
    "Directory: " .. status.directory,
    "Session: " .. (status.session_id or "Not selected"),
    "Title: " .. (status.title or "—"),
    "Completion model: " .. model_label(status.completion_model),
    "Cache: " .. cache,
    "Messages: " .. (status.message_count or 0),
    "Text bytes: " .. (status.bytes or 0),
    "Refreshed: " .. (status.refreshed_at and os.date("%Y-%m-%d %H:%M:%S", status.refreshed_at) or "Never"),
  }
  if status.error then
    vim.list_extend(lines, { "", "## Error", "", status.error })
  end
  if #status.warnings > 0 then
    vim.list_extend(lines, { "", "## Context warnings", "" })
    for _, warning in ipairs(status.warnings) do lines[#lines + 1] = "- " .. warning end
  end
  open_panel(lines)
end

--- Open the cached text in a disposable, non-writable inspection buffer.
function M.inspect()
  local state = binding()
  if not state.cache then notify("No cached context; select a session first", vim.log.levels.WARN); return end
  local lines = {
    "# open-compleat context", "",
    "Session: " .. state.session.id, "Title: " .. (state.session.title or "Untitled"),
    "Refreshed: " .. os.date("%Y-%m-%d %H:%M:%S", state.cache.refreshed_at),
    "Text bytes: " .. #state.cache.text, "",
    "This is a portable text projection, not OpenCode's exact model prompt.",
  }
  if state.error then lines[#lines + 1] = "STALE: " .. state.error end
  if state.loading then lines[#lines + 1] = "STALE: Refresh in progress" end
  for _, warning in ipairs(state.cache.warnings) do lines[#lines + 1] = "- " .. warning end
  vim.list_extend(lines, { "", "---", "" })
  vim.list_extend(lines, vim.split(state.cache.text, "\n", { plain = true }))
  open_panel(lines)
end

function M.command(opts)
  local action, id = opts.fargs[1] or "status", opts.fargs[2]
  if #opts.fargs > 2 or (id and action ~= "select") then
    notify("Usage: :OpenCompleat[!] select [session_id] | model | refresh | inspect | status | clear", vim.log.levels.ERROR)
  elseif action == "select" then
    M.select(id, opts.bang)
  elseif action == "refresh" then
    M.refresh(function(err) notify(err or "Planning context refreshed", err and vim.log.levels.ERROR or nil) end)
  elseif action == "inspect" then
    M.inspect()
  elseif action == "status" then
    M.show_status()
  elseif action == "model" then
    M.model()
  elseif action == "clear" then
    M.clear()
    notify("Planning session cleared for this tab")
  else
    notify("Unknown OpenCompleat action: " .. action, vim.log.levels.ERROR)
  end
end

return M
