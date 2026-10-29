if vim.g.loaded_open_compleat then return end
vim.g.loaded_open_compleat = true

vim.api.nvim_create_user_command("OpenCompleat", function(opts)
  require("open-compleat").command(opts)
end, {
  nargs = "*",
  bang = true,
  desc = "Select OpenCode planning context and request manual inline suggestions",
  complete = function(lead, line)
    if #vim.split(line, "%s+") > 2 then return {} end
    return vim.tbl_filter(function(action) return vim.startswith(action, lead) end,
      { "select", "model", "refresh", "inspect", "status", "clear", "prompt", "suggest", "accept", "accept_line", "dismiss" })
  end,
})
