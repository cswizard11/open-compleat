local M = {}

---@class open_compleat.Connection
---@field url string
---@field password? string
---@field local_service? boolean

---@param config table
---@return open_compleat.Connection?, string?
function M.connection(config)
  local url, password = config.server, config.password
  if url and type(password) == "function" then
    local ok, value = pcall(password)
    if not ok then
      return nil, "Could not read the configured OpenCode password"
    end
    password = value
  end
  if not url then
    local file = io.open(config.service_file, "r")
    if not file then
      return nil, "OpenCode service registration not found; start OpenCode or configure server"
    end
    local contents = file:read("*a")
    file:close()
    local ok, registration = pcall(vim.json.decode, contents)
    if not ok or type(registration) ~= "table" then
      return nil, "Invalid OpenCode service registration"
    end
    url, password = registration.url, registration.password
  end
  if type(url) ~= "string" or url:find("[%s%c]") or not url:match("^https?://[^/?#@]+/?$") then
    return nil, "OpenCode server must be an http(s) origin without credentials or a path"
  end
  if password ~= nil and (type(password) ~= "string" or password == "") then
    return nil, "OpenCode password must be a nonempty string or nil"
  end
  return { url = url:gsub("/$", ""), password = password, local_service = config.server == nil }
end

local function encode(value)
  return tostring(value):gsub("[^%w%._~%-]", function(byte)
    return string.format("%%%02X", byte:byte())
  end)
end

---@param config table
---@param connection open_compleat.Connection
---@param path string
---@param query table
---@param callback fun(err: string?, response: table?)
function M.get(config, connection, path, query, callback)
  local parameters = {}
  for key, value in pairs(query) do
    parameters[#parameters + 1] = encode(key) .. "=" .. encode(value)
  end
  table.sort(parameters)
  local url = connection.url .. path
  if #parameters > 0 then
    url = url .. "?" .. table.concat(parameters, "&")
  end
  local args = {
    "curl", "--disable", "--silent", "--show-error", "--fail-with-body",
    "--max-time", tostring(config.timeout_ms / 1000), "--request", "GET",
    "--config", "-", "--url", url,
  }
  if connection.local_service then
    -- Do not route local service credentials through an environment HTTP proxy.
    vim.list_extend(args, { "--noproxy", "*" })
  end
  local stdin = ""
  if connection.password then
    -- Keep service credentials out of process arguments and temporary files.
    stdin = 'header = "Authorization: Basic '
      .. vim.base64.encode("opencode:" .. connection.password) .. '"\n'
  end
  local ok, job = pcall(vim.system, args, { text = true, stdin = stdin }, vim.schedule_wrap(function(result)
    if result.code ~= 0 then
      local message = result.code == 28 and "OpenCode request timed out"
        or "OpenCode request failed: " .. vim.trim(result.stderr or "curl exit " .. result.code)
      callback(message)
      return
    end
    local decoded, response = pcall(vim.json.decode, result.stdout or "")
    if not decoded or type(response) ~= "table" or type(response.data) ~= "table" then
      callback("OpenCode returned an unexpected response (expected JSON with data)")
      return
    end
    callback(nil, response)
  end))
  if not ok then
    vim.schedule(function() callback("Could not start curl; check that it is installed") end)
    return nil
  end
  return job
end

function M.session(config, connection, id, callback)
  return M.get(config, connection, "/api/session/" .. encode(id), {}, callback)
end

--- Return text-capable models without exposing provider settings to the picker.
---@param callback fun(err: string?, models: table[]?)
function M.models(config, connection, directory, callback)
  M.get(config, connection, "/api/model", { ["location[directory]"] = directory }, function(err, response)
    if err then callback(err); return end
    if not vim.islist(response.data) then
      callback("OpenCode returned an unexpected model list")
      return
    end
    local models = {}
    for _, model in ipairs(response.data) do
      if type(model) ~= "table" then
        callback("OpenCode returned an invalid model entry")
        return
      end
      if model.enabled == true and (model.type == nil or model.type == "chat") then
        local capabilities = model.capabilities
        if type(model.id) ~= "string" or model.id == "" or type(model.providerID) ~= "string"
            or model.providerID == "" or type(capabilities) ~= "table"
            or not vim.islist(capabilities.input) or not vim.islist(capabilities.output)
            or not vim.islist(model.variants) then
          callback("OpenCode returned invalid model metadata")
          return
        end
        if vim.tbl_contains(capabilities.input, "text") and vim.tbl_contains(capabilities.output, "text") then
          local variants = {}
          for _, variant in ipairs(model.variants) do
            if type(variant) ~= "table" or type(variant.id) ~= "string" or variant.id == "" then
              callback("OpenCode returned an invalid model variant")
              return
            end
            variants[#variants + 1] = { id = variant.id }
          end
          models[#models + 1] = {
            id = model.id,
            providerID = model.providerID,
            name = type(model.name) == "string" and model.name or model.id,
            variants = variants,
          }
        end
      end
    end
    callback(nil, models)
  end)
end

---@param config table
---@param connection open_compleat.Connection
---@param path string
---@param query table
---@param callback fun(err: string?, items: table[]?)
function M.list(config, connection, path, query, callback)
  local items, seen = {}, {}
  local function page()
    M.get(config, connection, path, query, function(err, response)
      if err then
        callback(err)
        return
      end
      if not vim.islist(response.data) then
        callback("OpenCode returned an unexpected list")
        return
      end
      vim.list_extend(items, response.data)
      if type(response.cursor) ~= "table" then
        callback("OpenCode returned a list without pagination information")
        return
      end
      local cursor = response.cursor.next
      if not cursor or cursor == vim.NIL then
        callback(nil, items)
      elseif type(cursor) ~= "string" or seen[cursor] then
        callback("OpenCode returned an invalid or repeated pagination cursor")
      else
        seen[cursor] = true
        query = vim.tbl_extend("force", query, { cursor = cursor })
        query.order = nil
        page()
      end
    end)
  end
  page()
end

---@param config table
---@param connection open_compleat.Connection
---@param id string
---@param callback fun(err: string?, messages: table[]?)
function M.context(config, connection, id, callback)
  local path = "/api/session/" .. encode(id)
  M.get(config, connection, path .. "/context", {}, function(err, response)
    if err then
      callback(err)
      return
    end
    local messages = response.data
    if not vim.islist(messages) then
      callback("OpenCode returned an unexpected context list")
      return
    end
    for _, message in ipairs(messages) do
      if type(message) ~= "table" then
        callback("OpenCode returned an invalid context message")
        return
      end
      if message.type == "compaction" and message.status == "completed" then
        callback(nil, messages)
        return
      end
    end
    -- The context endpoint is described as messages after the last compaction.
    -- Retrieve the last completed checkpoint if it is not included there.
    M.list(config, connection, path .. "/message", { type = "compaction", order = "desc", limit = 100 }, function(list_err, checkpoints)
      if list_err then
        callback(list_err)
        return
      end
      for _, checkpoint in ipairs(checkpoints) do
        if type(checkpoint) ~= "table" then
          callback("OpenCode returned an invalid compaction checkpoint")
          return
        end
        if checkpoint.status == "completed" then
          table.insert(messages, 1, checkpoint)
          break
        end
      end
      callback(nil, messages)
    end)
  end)
end

return M
