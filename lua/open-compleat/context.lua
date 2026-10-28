local M = {}

---@param messages table[]
---@return string text
---@return string[] warnings
function M.render(messages)
  local sections, warnings, seen = {}, {}, {}
  local function warn(message)
    if not seen[message] then
      seen[message] = true
      warnings[#warnings + 1] = message
    end
  end
  local function add(title, text)
    if type(text) == "string" and text:find("%S") then
      sections[#sections + 1] = "## " .. title .. "\n\n" .. text
    end
  end
  for _, message in ipairs(messages) do
    if message.type == "assistant" then
      for _, part in ipairs(message.content or {}) do
        if part.type == "text" then
          add("Assistant", part.text)
        elseif part.type == "tool" then
          local state = part.state or {}
          local title = "Research tool: " .. (part.name or "unknown")
          if state.input then
            add(title .. " — input", vim.json.encode(state.input))
          end
          if state.status == "completed" then
            for _, content in ipairs(state.content or {}) do
              if content.type == "text" then
                add(title .. " — result", content.text)
              else
                warn("Non-text tool attachments were omitted; referenced files were not opened.")
              end
            end
          else
            warn("Some tool calls are incomplete or failed; their results are not available.")
          end
        elseif part.type == "reasoning" then
          warn("Model reasoning and provider-native state are not included.")
        else
          warn("An unsupported assistant content type was omitted.")
        end
      end
    elseif message.type == "compaction" and message.status == "completed" then
      if type(message.summary) == "string" and message.summary:find("%S") then
        add("Compaction summary", message.summary)
        warn("Earlier conversation is represented by OpenCode's compaction summary, not its full history.")
      else
        warn("A compaction checkpoint has no portable text summary; earlier context may be missing.")
      end
    elseif message.type == "shell" then
      add("Shell command", message.command)
      if message.output then
        add("Shell output", message.output.output)
        if message.output.truncated then
          warn("OpenCode has truncated some shell output.")
        end
      end
    elseif message.type == "user" or message.type == "system"
        or message.type == "synthetic" or message.type == "skill" then
      add(message.type, message.text)
      if message.files and #message.files > 0 then
        warn("Message attachments were omitted; this preview contains text only.")
      end
    elseif message.type ~= "idle" and message.type ~= "agent-switched"
        and message.type ~= "model-switched" and message.type ~= "location-switched" then
      warn("An unsupported message type was omitted.")
    end
  end
  return table.concat(sections, "\n\n"), warnings
end

return M
