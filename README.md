# open-compleat

A Neovim bridge between an OpenCode planning conversation and inline completion.

**Milestone 2: manually requested inline suggestions.** Select a planning session
and an independent completion model, then request a short suggestion in Insert
mode. Minuet displays ghost text; nothing enters the buffer until you accept it.
There are no automatic suggestions, planning-conversation writes, or background polling.

## Requirements

- Neovim 0.10+ and `curl`.
- A running OpenCode V2 server. Tested against OpenCode 2.1.4 and Neovim 0.12.6.
- [Minuet](https://github.com/milanglacier/minuet-ai.nvim), pinned below. Context
  inspection/model selection work without it; suggestions require it.

## Try it locally

With lazy.nvim:

```lua
{
  dir = vim.fn.expand("~/code/open-compleat"),
  main = "open-compleat",
  dependencies = {
    {
      "milanglacier/minuet-ai.nvim",
      commit = "50bf63b031c0391e926fdf0b3d044d37846e6e34",
    },
  },
  opts = {},
}
```

Or add this repository to `runtimepath` and call `require("open-compleat").setup()`.
The plugin registers `:OpenCompleat` when loaded through Neovim's plugin mechanism.
No default keymaps are installed.
Do not set up Minuet separately: open-compleat configures it lazily on the first
suggestion, with automatic completion disabled. It refuses to overwrite a Minuet
configuration using another provider. The custom backend uses Minuet's internal
provider interface, so keep the tested pin until compatibility is verified.

## Usage

1. Start or open your planning conversation in any OpenCode frontend.
2. Run `:OpenCompleat select` and choose the session.
3. Run `:OpenCompleat inspect` to view the cached context. Press `q` to close.
4. After changing the conversation, run `:OpenCompleat refresh`, then inspect again.
5. Run `:OpenCompleat model` to select the separate completion model.
6. Enter Insert mode and request a suggestion. Enter an optional direction, leave
   it empty for normal completion, or press Esc to cancel.

| Command | Purpose |
| --- | --- |
| `:OpenCompleat select` | Pick an unarchived root session from the current working directory |
| `:OpenCompleat! select` | Pick from all directories on the connected server |
| `:OpenCompleat select ses_...` | Select a specific session ID |
| `:OpenCompleat model` | Pick a completion model and, when available, a variant |
| `:OpenCompleat refresh` | Refresh the selected session's cached context |
| `:OpenCompleat inspect` | Open a read-only context snapshot in a bottom split |
| `:OpenCompleat status` | Show selection, cache size, refresh time, and errors in a bottom split |
| `:OpenCompleat clear` | Forget the planning session and cache, keeping the completion model |
| `:OpenCompleat prompt` | Ask for an optional direction, then request a suggestion from the original Insert cursor |
| `:OpenCompleat suggest` | Request one suggestion; invoke through an Insert-mode `<Cmd>` mapping |
| `:OpenCompleat accept` | Accept the visible suggestion in Insert mode |
| `:OpenCompleat accept_line` | Accept the next line, keeping the remaining ghost text |
| `:OpenCompleat dismiss` | Dismiss ghost text and cancel a pending request |

Selections are independent per tab and reset if its working directory changes.
They are not persisted across Neovim restarts. The picker reads every result page,
not just the server's first page. Nothing is selected automatically.

Lua equivalents are `select(id, all)`, `model()`, `refresh(callback)`, `inspect()`, `status()`,
and `clear()` on `require("open-compleat")`. `get_context()` returns cached text,
or `nil, reason` if missing, refreshing, or stale after an error. The inspection
window is a snapshot; it does not update an already open preview.

Both panels open across the bottom of the tab, use `'helpheight'` for their initial
height, and close with `q`. In Lua, `status()` returns data without opening a window;
`show_status()` opens the status panel. Session selection uses `vim.ui.select`,
including Snacks when it is configured as your selection UI.

## Manual suggestions

Example opt-in mappings (choose keys that do not conflict with your configuration):

```lua
vim.keymap.set("i", "<M-/>", function()
  return (vim.fn.pumvisible() == 1 and "<C-e>" or "") .. "<Cmd>OpenCompleat prompt<CR>"
end, { expr = true, desc = "Request planning-aware suggestion" })
vim.keymap.set("i", "<M-y>", function() require("open-compleat").accept() end,
  { desc = "Accept suggestion" })
vim.keymap.set("i", "<M-l>", function() require("open-compleat").accept_line() end,
  { desc = "Accept suggestion line" })
vim.keymap.set("i", "<M-e>", function() require("open-compleat").dismiss() end,
  { desc = "Dismiss suggestion" })
```

The suggestion mapping cancels an open completion popup without accepting its
selected item, then opens `vim.ui.input` (Snacks-backed when enabled) for a one-shot
direction. **Enter with text** directs only that generation; **empty Enter** makes
a normal request; **Esc** cancels without a model call. The Snacks completion dialog
is centered in the editor without changing other input dialogs. The input starts empty
each time. No request is sent until confirmation, and the original editable buffer
and exact Insert cursor are restored before capturing code. A changed source,
session/model selection, or planning snapshot invalidates the pending input.

The per-request direction is separate from the planning transcript and does not
change its cache or write to the planning conversation. It focuses the insertion
without changing the code-only output rules. Open-compleat does not reuse it on
later requests; your UI provider may maintain its own input history.

For a direct request without a dialog, use `suggest()` or
`suggest("one-time direction")` from an Insert-mode Lua mapping, or
`"<Cmd>OpenCompleat suggest<CR>"`. Typing either command at an ordinary
`:` prompt leaves Insert mode and is deliberately refused. Lua APIs also recognize
Insert completion submodes (`ic`/`ix`) as Insert mode.
Use open-compleat's APIs/mappings, not Minuet's own trigger/accept mappings.
`suggest()`, `prompt()`, `accept()`, and `accept_line()` return a boolean indicating
whether the action was started (`prompt()` means the input opened, not that a model
request has been sent). `dismiss()` also cancels a pending direction confirmation.

**Each suggestion can make a paid model call.** It sends the cached portable
conversation plus the current buffer's unsaved prefix/suffix, filename, directory,
filetype, indentation settings, and cursor position to OpenCode and the selected
provider. Refreshing context and selecting a model do not generate text. No extra
files, LSP information, or diagnostics are collected in this milestone.

Example limits, all positive integers:

```lua
require("open-compleat").setup({
  context_window = 16000,    -- Minuet's prefix + suffix budget, in characters
  timeout_ms = 10000,        -- per HTTP request, including generation
})
```

The current unsaved file is split into exact prefix/suffix text at the cursor.
Cursor metadata includes a 1-based row, 0-based UTF-8 byte column, and 0-based
UTF-8 file byte offset, alongside total line count and the final-newline setting.
Minuet shortens editor context to `context_window` and reports truncation flags
in the prompt. The full cached planning text is included without a plugin-imposed
prompt-byte cap or additional truncation. The selected model's context limits and
any server/provider request limits still apply; large conversations can increase
cost and latency. There is no output-line cap: complete blocks are not clipped.
The server API does not accept an output-token cap here. Markdown-fenced responses
and obvious conversational introductions are rejected; blank responses produce no
suggestion. These checks are not a language parser or a guarantee of model quality.
Responses are displayed after the full request finishes,
not token by token. Raise `timeout_ms` if the chosen model needs longer.

Typing, moving the cursor, leaving Insert mode, changing buffer/window/tab or
directory, refreshing/clearing context, and selecting a new session/model invalidate
suggestions. A new manual request supersedes the old one. Line acceptance reuses
the existing remainder without another model call. Cancellation stops local curl
and ignores late results; it does not guarantee that provider work or billing stops.
Ghost text is hidden while a completion menu is open. The mapping above closes an
existing menu first; later menu activity that changes the buffer still invalidates
the pending suggestion. Popup cancellation and Insert-completion mode are covered
by mock integration tests; other completion-plugin interactions may still vary.

### Completion instructions

The prompt explicitly requests **only the text to insert at the cursor**, not a
reply to the planning conversation. It defines the resulting file as
`prefix + insertion + suffix`, asks for the smallest coherent local block, and
includes examples of completing a partial HTML opening tag, filling content when
the closing tag already exists, and implementing a function body before an
existing closing brace. It tells the model to use the latest explicit user decisions,
prefer current unsaved code over older file snapshots, match indentation, and avoid
unrelated features, placeholders, duplicate prefix/suffix text, and conversational
wrappers. The insertion-only reminder is repeated after the full context.
The model is explicitly instructed to provide a non-empty, best-effort insertion,
not to abstain or ask a question. A provider can still return empty text; that is
reported as `No suggestion`, not hidden or retried with another paid request.

This improves the instructions, but different models can still respond differently;
mock tests verify the prompt and insertion behavior, not live model quality.

### Loading indicator

`require("open-compleat").statusline()` returns an animated `OC … Generating`
indicator during discovery/generation, then `OC: Ready`, `OC: No suggestion`,
`OC: Response rejected`, `OC: Error`, or `OC: Canceled`. It also reports acceptance
and dismissal. It is empty before the first request and outside the request's
buffer. No token-by-token progress is claimed.

Add this function as a component in your statusline (for example, a lualine section).
For immediate lualine updates, refresh it on the `User OpenCompleatProgress` event:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "OpenCompleatProgress",
  callback = function() require("lualine").refresh({ place = { "statusline" } }) end,
})
```

`status().completion` exposes the request state, buffer number, elapsed milliseconds,
and any failure/rejection message. Progress events contain lifecycle data, never
planning text or generated code. `:OpenCompleat status` also shows the request state.

## Completion model

Run `:OpenCompleat model` to choose an enabled model with text input/output from
the connected server's catalog for the current directory. If the model has
variants, a second picker offers those exact variant IDs and **Default (model
settings)**. Default is not the same as a variant named `none`; it leaves the
model's settings unchanged. Canceling either picker keeps the previous selection.

The selection is independent of the planning session and can be made before
selecting a session. It is stored per tab/current directory, is visible in
`:OpenCompleat status`, and is not persisted across restarts. Selecting it does not
change the planner's model or make a generation request. `status().completion_model`
returns a copy of the API reference: `{ providerID = "...", id = "...", variant = "..." }`,
with `variant` omitted for Default or a model without variants. Catalog IDs are
preserved even when the provider's underlying model ID differs.

## Connection

By default the plugin reads the service registration at
`$XDG_STATE_HOME/opencode/service.json`, or `~/.local/state/opencode/service.json`.
It uses that registration's URL and password without copying provider credentials.
It does not start, restart, or reconfigure OpenCode. Start OpenCode first if the
registration is missing or points to a stopped server.

For an explicit local or remote server:

```lua
require("open-compleat").setup({
  server = "https://opencode.example.com",
  password = function() return vim.env.OPENCODE_PASSWORD end,
  timeout_ms = 10000,
})
```

`server` must be an HTTP(S) origin, without a path or embedded credentials. Use
HTTPS for remote traffic outside a trusted network. `password` may be a string or
function; omit it for an explicitly configured server with no authentication.
`service_file` overrides the registration path. Service credentials are passed to
curl through stdin, not command-line arguments or temporary files. Requests do not
follow redirects or load `.curlrc`; local service connections bypass environment
HTTP proxies. Context is kept in memory and in disposable inspection buffers.
Generation prompts are also sent through curl-config stdin, not temporary files.

## What the preview means

The preview is **not OpenCode's exact model prompt**. It renders user/assistant
text, textual research-tool inputs/results, system/skill/synthetic text, shell
output, and a completed compaction summary when available. It does not replay tools
or open file references. Reasoning, native provider state, and attachments are
omitted with warnings. There is no additional summarization or silent size limit.
Output already shortened by OpenCode cannot be reconstructed from this projection.

The plugin reads the active context endpoint and, if no completed checkpoint is
included, retrieves the latest completed compaction from message history. Native
encrypted checkpoints are not portable; an empty summary produces a warning.
Separate API reads are not a transactional snapshot. Refresh again if the planner
is actively changing or compacting its conversation. Earlier retained messages and
dynamic instruction sources are not guaranteed to match the planner's model input.

Changing or clearing a selection invalidates older asynchronous replies. A failed
refresh retains the last snapshot for inspection but makes `get_context()` refuse
to return it as fresh input.

## Tests

```sh
python3 tests/integration.py
MINUET_RTP=/path/to/pinned/minuet-ai.nvim python3 tests/completion.py
MINUET_RTP=/path/to/pinned/minuet-ai.nvim SNACKS_RTP=/path/to/snacks.nvim python3 tests/input.py
```

Tests use clean headless Neovim, synthetic conversations, a loopback HTTP server,
and temporary files under `/tmp/opencode`. They do not access real OpenCode
sessions, use model providers, install dependencies, or load your Neovim config.
Completion tests require Python's `msgpack` package and an existing Minuet checkout.
Input tests additionally require an existing Snacks checkout and isolate its history
under their temporary test directory.
They drive real Insert mode through Neovim's embedded RPC interface and test ghost
text, incremental acceptance, prompt/model transport, invalidation, and failures.

## API references

- [OpenCode V2 API](https://opencode.ai/v2/docs/api/): session/catalog/context reads,
  plus stateless text generation. No session-mutation endpoint is used.
- [Service registration](https://opencode.ai/v2/docs/troubleshooting/#service-files).
- [Compaction and its portability limits](https://opencode.ai/v2/docs/compaction/).
- [Model availability, catalog IDs, and variants](https://opencode.ai/v2/docs/models/).

The installed server's `/openapi.json` is the compatibility reference. Generation
discovers `/api/experimental/generate/text`, falling back to
`/api/experimental/generate` when advertised. These are experimental APIs.
On the tested server, stateless generation uses **base server configuration**, not
the selected planning session's project configuration. A model/provider available
only in a project's catalog may therefore fail to generate; there is no silent
fallback to another model. The request explicitly passes the chosen model/variant
and does not append the prompt or response to the planning conversation.
Editing provider/model settings is not implemented.
