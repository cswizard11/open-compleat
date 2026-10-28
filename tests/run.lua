vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/open-compleat.lua")

local plugin = require("open-compleat")
local client = require("open-compleat.client")
local render = require("open-compleat.context").render
local options = { service_file = assert(vim.env.OC_TEST_SERVICE), timeout_ms = 2000 }
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
local count = 0

local function test(name, run)
  local ok, err = pcall(run)
  if not ok then
    io.stderr:write("FAIL: " .. name .. "\n" .. tostring(err) .. "\n")
    vim.cmd("cquit 1")
  end
  count = count + 1
  print("PASS: " .. name)
end

local function wait_for(predicate)
  assert(vim.wait(4000, predicate, 10), "Timed out waiting for asynchronous operation")
end

local function selected(id)
  plugin.select(id)
  wait_for(function()
    local status = plugin.status()
    return status.session_id == id and not status.loading
  end)
end

test("registration discovery and configuration validation", function()
  plugin.setup(options)
  local connection = assert(client.connection(options))
  assert(connection.url == vim.env.OC_TEST_URL)
  assert(connection.password == "fixture-password")
  assert(not client.connection({ service_file = "/does/not/exist" }))
  assert(not client.connection({ server = "http://user:secret@localhost" }))
  assert(not pcall(plugin.setup, { timeout_ms = 0 }))
  assert(not pcall(plugin.setup, { unexpected = true }))
  assert(vim.fn.exists(":OpenCompleat") == 2)
end)

test("paged session picker and compaction fallback", function()
  local offered
  vim.ui.select = function(items, _, choose) offered = items; choose(items[1]) end
  plugin.select()
  wait_for(function() return plugin.status().refreshed_at ~= nil end)
  assert(#offered == 2 and offered[2].id == "ses_B")
  local text = assert(plugin.get_context())
  assert(text:find("Keep the existing architecture.", 1, true))
  assert(text:find("The documented API.", 1, true))
  assert(text:find("https://example.test/docs", 1, true))
  assert(text:find("αβ", 1, true))
  assert(not text:find("PRIVATE_REASONING_MARKER", 1, true))
  assert(#plugin.status().warnings >= 2)
end)

test("manual refresh observes changed conversation", function()
  local before = assert(plugin.get_context())
  local done, err
  plugin.refresh(function(value) done, err = true, value end)
  wait_for(function() return done end)
  assert(not err)
  assert(plugin.get_context() ~= before)
end)

test("inspector is a non-writable scratch buffer", function()
  vim.cmd("vsplit")
  local windows = #vim.api.nvim_list_wins()
  plugin.inspect()
  local buf = vim.api.nvim_get_current_buf()
  assert(#vim.api.nvim_list_wins() == windows + 1)
  assert(vim.bo[buf].buftype == "nofile" and not vim.bo[buf].modifiable)
  assert(not vim.bo[buf].swapfile and not vim.bo[buf].modeline)
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "# open-compleat context")
  local layout = vim.fn.winlayout()
  assert(layout[1] == "col" and layout[2][#layout[2]][2] == vim.api.nvim_get_current_win())
  assert(vim.api.nvim_win_get_width(0) == vim.o.columns)
  vim.cmd("close")
  assert(not vim.api.nvim_buf_is_valid(buf))
  vim.cmd("close")
end)

test("status opens a read-only bottom panel without notifying", function()
  local notifications = #notices
  local helpheight = vim.o.helpheight
  vim.o.helpheight = 7
  vim.cmd("OpenCompleat status")
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(lines[1] == "# open-compleat status")
  assert(table.concat(lines, "\n"):find("Session: ses_A", 1, true))
  assert(vim.bo[buf].buftype == "nofile" and not vim.bo[buf].modifiable)
  assert(vim.api.nvim_win_get_height(0) == 7)
  local layout = vim.fn.winlayout()
  assert(layout[1] == "col" and layout[2][#layout[2]][2] == vim.api.nvim_get_current_win())
  assert(#notices == notifications)
  assert(vim.fn.maparg("q", "n", false, true).buffer == 1)
  vim.cmd("close")
  assert(not vim.api.nvim_buf_is_valid(buf))
  vim.o.helpheight = helpheight
end)

test("status can display an unselected tab", function()
  vim.cmd("tabnew")
  plugin.show_status()
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(text:find("Session: Not selected", 1, true))
  assert(text:find("Cache: Not loaded", 1, true))
  vim.cmd("close")
  vim.cmd("tabclose")
end)

test("explicit selection and tab isolation", function()
  local original = plugin.status().session_id
  vim.cmd("tabnew")
  assert(not plugin.get_context())
  selected("ses_B")
  assert(plugin.status().session_id == "ses_B")
  vim.cmd("tabclose")
  assert(plugin.status().session_id == original)
end)

test("working directory changes invalidate a tab's selection", function()
  vim.cmd("tcd " .. vim.fn.fnameescape(vim.env.OC_TEST_SCRATCH))
  assert(not plugin.get_context())
  assert(not plugin.status().session_id)
  vim.cmd("tcd -")
end)

test("picker can explicitly search across directories", function()
  plugin.select(nil, true)
  wait_for(function() return plugin.status().refreshed_at ~= nil end)
end)

test("late context replies cannot overwrite a newer selection", function()
  plugin.select("ses_Slow")
  wait_for(function() return plugin.status().session_id == "ses_Slow" end)
  selected("ses_A")
  vim.wait(400, function() return false end, 10)
  assert(plugin.status().session_id == "ses_A")
  assert(plugin.get_context():find("Decision", 1, true))
end)

test("clear rejects in-flight context replies", function()
  plugin.select("ses_Slow")
  wait_for(function() return plugin.status().session_id == "ses_Slow" end)
  plugin.clear()
  vim.wait(400, function() return false end, 10)
  assert(not plugin.status().session_id and not plugin.get_context())
end)

test("canceling a picker does not strand a refresh in loading state", function()
  selected("ses_Slow")
  local done
  plugin.refresh(function() done = true end)
  vim.ui.select = function(_, _, choose) choose(nil) end
  plugin.select()
  wait_for(function() return done end)
  assert(not plugin.status().loading and plugin.get_context())
  vim.ui.select = function(items, _, choose) choose(items[1]) end
end)

test("request failures are visible and do not return stale text", function()
  selected("ses_Error")
  local text, err = plugin.get_context()
  assert(not text and err:find("503", 1, true))
  assert(plugin.status().error)
end)

test("failed refresh retains an inspectable snapshot but refuses stale input", function()
  selected("ses_Flaky")
  assert(plugin.get_context())
  local done, err
  plugin.refresh(function(value) done, err = true, value end)
  wait_for(function() return done end)
  assert(err and not plugin.get_context())
  plugin.inspect()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(table.concat(lines, "\n"):find("STALE:", 1, true))
  vim.cmd("close")
end)

test("malformed context messages fail without crashing the editor", function()
  selected("ses_Malformed")
  local text, err = plugin.get_context()
  assert(not text and err:find("invalid context message", 1, true))
end)

test("large context is read completely rather than silently truncated", function()
  selected("ses_Large")
  local text = assert(plugin.get_context())
  assert(text == "## Compaction summary\n\nKeep the existing architecture.\n\n## user\n\n" .. string.rep("αβ ", 150000))
end)

test("compaction already in active context is not duplicated", function()
  selected("ses_Checkpoint")
  assert(plugin.get_context() == "## Compaction summary\n\nAlready included.")
end)

test("formatter reports omissions and preserves plain text literally", function()
  local text, warnings = render({
    { type = "user", text = "{{{literal}}}", files = { { mime = "image/png" } } },
    { type = "compaction", status = "completed", summary = "" },
    { type = "shell", command = "inspect", output = { output = "short output", truncated = true } },
    { type = "assistant", content = { { type = "tool", name = "read", state = {
      status = "completed", content = { { type = "file", uri = "file:///must-not-be-opened" } },
    } } } },
  })
  assert(text:find("{{{literal}}}", 1, true))
  assert(text:find("short output", 1, true))
  assert(#warnings == 4)
end)

test("malformed responses and repeated cursors fail cleanly", function()
  local connection = assert(client.connection(options))
  for _, path in ipairs({ "/invalid", "/repeat", "/missing-cursor" }) do
    local done, err
    if path ~= "/invalid" then
      client.list(options, connection, path, {}, function(value) done, err = true, value end)
    else
      client.get(options, connection, path, {}, function(value) done, err = true, value end)
    end
    wait_for(function() return done end)
    assert(err)
  end
end)

test("timeouts and explicit server authentication", function()
  local config = { server = vim.env.OC_TEST_URL, password = function() return "fixture-password" end, timeout_ms = 100 }
  local connection = assert(client.connection(config))
  local done, err
  client.get(config, connection, "/timeout", {}, function(value) done, err = true, value end)
  wait_for(function() return done end)
  assert(err:find("timed out", 1, true))
end)

test("repeated setup resets prior server overrides", function()
  plugin.setup({ server = "http://127.0.0.1:1" })
  plugin.setup(options)
  selected("ses_A")
  assert(plugin.get_context())
end)

test("model picker filters the catalog and selects an explicit variant", function()
  local session_id = plugin.status().session_id
  local text = plugin.get_context()
  local pickers = 0
  vim.ui.select = function(items, opts, choose)
    pickers = pickers + 1
    if pickers == 1 then
      assert(opts.prompt == "OpenCode completion model")
      assert(#items == 2)
      assert(items[1].id == "fast-alias" and not items[1].modelID)
      assert(not items[1].headers and not items[1].variants[1].body)
      assert(opts.format_item(items[1]):find("fixture/fast-alias", 1, true))
      choose(items[1])
    else
      assert(opts.prompt == "Completion model variant" and #items == 3)
      assert(items[1].id == nil and items[2].id == "none")
      choose(items[2])
    end
  end
  vim.cmd("OpenCompleat model")
  wait_for(function() return plugin.status().completion_model ~= nil end)
  assert(pickers == 2)
  assert(vim.deep_equal(plugin.status().completion_model, { providerID = "fixture", id = "fast-alias", variant = "none" }))
  assert(plugin.status().session_id == session_id and plugin.get_context() == text)
  plugin.show_status()
  local rendered = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  assert(rendered:find("Completion model: fixture/fast-alias#none", 1, true))
  vim.cmd("close")
  local copy = plugin.status().completion_model
  copy.id = "changed outside the plugin"
  assert(plugin.status().completion_model.id == "fast-alias")
end)

test("canceling either model picker preserves the previous choice", function()
  local previous = plugin.status().completion_model
  for _, cancel_at in ipairs({ 1, 2 }) do
    local pickers, done = 0, false
    vim.ui.select = function(items, _, choose)
      pickers = pickers + 1
      if pickers == cancel_at then choose(nil); done = true else choose(items[1]) end
    end
    plugin.model()
    wait_for(function() return done end)
    assert(vim.deep_equal(plugin.status().completion_model, previous))
  end
end)

test("default variant clears an earlier variant without changing the model", function()
  local done
  vim.ui.select = function(items, opts, choose)
    choose(items[1])
    if opts.prompt == "Completion model variant" then done = true end
  end
  plugin.model()
  wait_for(function() return done end)
  assert(vim.deep_equal(plugin.status().completion_model, { providerID = "fixture", id = "fast-alias" }))
end)

test("models without variants need only one picker", function()
  local done, pickers = false, 0
  vim.ui.select = function(items, _, choose)
    pickers = pickers + 1
    choose(items[2])
    done = true
  end
  plugin.model()
  wait_for(function() return done end)
  assert(pickers == 1)
  assert(vim.deep_equal(plugin.status().completion_model, { providerID = "other", id = "vendor/basic" }))
end)

test("model selections are independent per tab and need no planning session", function()
  local previous = plugin.status().completion_model
  vim.cmd("tabnew")
  assert(not plugin.status().session_id and not plugin.status().completion_model)
  vim.ui.select = function(items, _, choose) choose(items[1]) end
  plugin.model()
  wait_for(function() return plugin.status().completion_model ~= nil end)
  assert(plugin.status().completion_model.id == "fast-alias")
  vim.cmd("tabclose")
  assert(vim.deep_equal(plugin.status().completion_model, previous))
end)

test("clearing planning context preserves the independent completion model", function()
  local previous = plugin.status().completion_model
  plugin.clear()
  assert(not plugin.status().session_id and not plugin.get_context())
  assert(vim.deep_equal(plugin.status().completion_model, previous))
end)

test("a model picker cannot apply its result to a different tab", function()
  local previous = plugin.status().completion_model
  local choose_later, models
  vim.ui.select = function(items, _, choose) models, choose_later = items, choose end
  plugin.model()
  wait_for(function() return choose_later ~= nil end)
  vim.cmd("tabnew")
  choose_later(models[1])
  assert(not plugin.status().completion_model)
  vim.cmd("tabclose")
  assert(vim.deep_equal(plugin.status().completion_model, previous))
end)

test("a newer model picker invalidates an older pending choice", function()
  local callbacks, choices = {}, {}
  vim.ui.select = function(items, _, choose)
    choices[#choices + 1], callbacks[#callbacks + 1] = items, choose
  end
  plugin.model()
  wait_for(function() return #callbacks == 1 end)
  plugin.model()
  wait_for(function() return #callbacks == 2 end)
  callbacks[2](choices[2][2])
  callbacks[1](choices[1][1])
  assert(#callbacks == 2)
  assert(plugin.status().completion_model.id == "vendor/basic")
end)

test("empty and malformed model catalogs fail without opening a picker", function()
  for _, name in ipairs({ "no-models", "bad-models" }) do
    local directory = vim.env.OC_TEST_SCRATCH .. "/" .. name
    vim.fn.mkdir(directory, "p")
    vim.cmd("tcd " .. vim.fn.fnameescape(directory))
    assert(not plugin.status().completion_model)
    local notifications = #notices
    vim.ui.select = function() error("An unusable catalog must not open a picker") end
    plugin.model()
    wait_for(function() return #notices > notifications end)
    assert(not plugin.status().completion_model)
    vim.cmd("tcd -")
  end
end)

print(string.format("All %d tests passed", count))
