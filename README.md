# open-compleat

A Neovim bridge between an OpenCode planning conversation and inline completion.

**Current scope: read-only context and completion-model selection.** You can select
an OpenCode session, refresh an in-memory cache, inspect the portable text that will
feed completion later, and choose a separate completion model. There are no model
calls, conversation writes, background polling, or changes to project files.
Minuet integration comes in the next milestone.

## Requirements

- Neovim 0.10+ and `curl`.
- A running OpenCode V2 server. Tested against OpenCode 2.1.4 and Neovim 0.12.6.

## Try it locally

With lazy.nvim:

```lua
{
  dir = vim.fn.expand("~/code/open-compleat"),
  main = "open-compleat",
  opts = {},
}
```

Or add this repository to `runtimepath` and call `require("open-compleat").setup()`.
The plugin registers `:OpenCompleat` when loaded through Neovim's plugin mechanism.
No default keymaps are installed.

## Usage

1. Start or open your planning conversation in any OpenCode frontend.
2. Run `:OpenCompleat select` and choose the session.
3. Run `:OpenCompleat inspect` to view the cached context. Press `q` to close.
4. After changing the conversation, run `:OpenCompleat refresh`, then inspect again.

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
```

Tests use clean headless Neovim, synthetic conversations, a loopback HTTP server,
and temporary files under `/tmp/opencode`. They do not access real OpenCode
sessions, use model providers, install dependencies, or load your Neovim config.

## API references

- [OpenCode V2 API](https://opencode.ai/v2/docs/api/): session listing, session
  lookup, active context, and filtered message history. Only `GET` is used.
- [Service registration](https://opencode.ai/v2/docs/troubleshooting/#service-files).
- [Compaction and its portability limits](https://opencode.ai/v2/docs/compaction/).
- [Model availability, catalog IDs, and variants](https://opencode.ai/v2/docs/models/).

The installed server's `/openapi.json` is the compatibility reference. Completion
generation and editing provider/model settings are intentionally not implemented yet.
