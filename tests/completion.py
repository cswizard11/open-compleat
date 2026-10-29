"""Mock-only completion tests. Requires MINUET_RTP and Python msgpack."""

from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import sys

sys.dont_write_bytecode = True
import integration as fixture
from nvim_rpc import Nvim


MINUET = Path(os.environ["MINUET_RTP"]).resolve()
assert (MINUET / "lua/minuet/init.lua").is_file(), "MINUET_RTP must point to a Minuet checkout"
count = 0


def passed(name):
    global count
    count += 1
    print("PASS: " + name, flush=True)


def payload(prompt):
    return json.loads(prompt.split("\n<open_compleat_context>\n", 1)[1].split("\n</open_compleat_context>\n", 1)[0])


server = ThreadingHTTPServer(("127.0.0.1", 0), fixture.Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
nvim = Nvim()
try:
    with tempfile.TemporaryDirectory(prefix="completion-tests-", dir="/tmp/opencode") as scratch:
        registration = Path(scratch) / "service.json"
        registration.write_text(json.dumps({"url": f"http://127.0.0.1:{server.server_port}", "password": fixture.PASSWORD}))
        nvim.lua("""
          local minuet, registration, scratch = ...
          vim.opt.runtimepath:prepend(vim.fn.getcwd())
          vim.opt.runtimepath:append(minuet)
          vim.cmd('runtime plugin/open-compleat.lua')
          P = require('open-compleat')
          options = { service_file = registration, timeout_ms = 1000 }
          notices = {}
          vim.notify = function(message) notices[#notices + 1] = message end
          local system = vim.system
          vim.system = function(args, opts, callback)
            local argv = table.concat(args, ' ')
            assert(not argv:find('fixture-password', 1, true))
            assert(not argv:find('Basic ', 1, true))
            assert(not argv:find('planning_context', 1, true))
            assert(not argv:find(scratch, 1, true))
            return system(args, opts, callback)
          end
          function configure(extra)
            P.setup(vim.tbl_extend('force', options, extra or {}))
            vim.ui.select = function(items, opts, choose)
              choose(items[opts.prompt == 'Completion model variant' and 2 or 1])
            end
            P.select('ses_A')
            P.model()
          end
          function snapshot()
            local ns = vim.api.nvim_get_namespaces()['minuet.virtualtext']
            return { mode = vim.api.nvim_get_mode().mode,
              lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
              marks = ns and vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true }) or {},
              notices = notices, progress = P.status().completion, statusline = P.statusline() }
          end
        """, str(MINUET), str(registration), scratch)

        def snap():
            return nvim.lua("return snapshot()")

        def configure(extra=None):
            nvim.lua("configure(...)", extra or {})
            nvim.wait(lambda: nvim.lua("local s=P.status(); return s.completion_model ~= nil and s.refreshed_at ~= nil and not s.loading"), "planning context and model")

        def case(lines=None):
            nvim.call("nvim_input", "\x1b")
            nvim.wait(lambda: snap()["mode"] == "n", "Normal mode")
            nvim.lua("""
              P.dismiss()
              local b = vim.api.nvim_create_buf(true, false)
              vim.api.nvim_set_current_buf(b)
              vim.api.nvim_buf_set_name(b, (...))
              vim.api.nvim_buf_set_lines(b, 0, -1, false, select(2, ...))
              vim.bo.filetype = 'lua'
              vim.bo.expandtab = true
              vim.bo.shiftwidth = 4
            """, str(Path(scratch) / f"unsaved-{time.monotonic_ns()}.lua"), lines or ["local value = ", "-- suffix αβ \\"])
            nvim.call("nvim_input", "A")
            nvim.wait(lambda: snap()["mode"] == "i", "real Insert mode")

        def suggest():
            assert nvim.lua("return P.suggest()")

        def visible():
            return nvim.wait(lambda: snap()["marks"], "ghost text")

        def no_late_result():
            time.sleep(0.4)
            assert not snap()["marks"]
            assert not nvim.lua("return P.accept()")

        # No model/context is silently selected, and Normal-mode calls do not generate.
        nvim.lua("P.setup(options)")
        assert not nvim.lua("return P.suggest()")
        nvim.lua("P.select('ses_A')")
        nvim.wait(lambda: nvim.lua("return P.get_context() ~= nil"), "context without model")
        assert not nvim.lua("return P.suggest()")
        configure()
        assert not nvim.lua("return P.suggest()")
        assert not fixture.generations
        passed("explicit context, model, and Insert-mode prerequisites")

        case()
        time.sleep(0.15)
        assert not fixture.generations
        nvim.lua("vim.opt.runtimepath:remove(...)", str(MINUET))
        assert not nvim.lua("return P.suggest()")
        assert "Minuet is required" in snap()["notices"][-1]
        nvim.lua("vim.opt.runtimepath:append(...); package.loaded.minuet = {config={provider='other'}}", str(MINUET))
        assert not nvim.lua("return P.suggest()")
        assert "will not overwrite" in snap()["notices"][-1]
        nvim.lua("package.loaded.minuet = nil")
        assert not fixture.generations
        passed("missing Minuet and an existing unrelated Minuet setup fail safely")
        original = snap()["lines"]
        suggest()
        marks = visible()
        assert snap()["lines"] == original
        assert marks[0][3]["virt_text"][0][0] == "first()"
        assert len(marks[0][3]["virt_lines"]) == 2
        assert snap()["progress"]["state"] == "ready" and snap()["statusline"] == "OC: Ready"
        body = fixture.generations[-1]
        assert body["model"] == {"providerID": "fixture", "id": "fast-alias", "variant": "none"}
        data = payload(body["prompt"])
        assert "Decision" in data["planning_context"] and "Keep the existing architecture." in data["planning_context"]
        assert "The documented API." in data["planning_context"] and "PRIVATE_REASONING_MARKER" not in body["prompt"]
        assert data["editor"]["prefix"] == "local value = "
        assert data["editor"]["prefix"] + data["editor"]["suffix"] == "\n".join(original)
        assert "-- suffix αβ \\" in data["editor"]["suffix"]
        assert data["editor"]["language"] == "lua" and data["editor"]["indentation"]["shiftwidth"] == 4
        assert data["editor"]["cursor"] == {"row": 1, "byte_column": 14, "byte_offset": 14}
        assert data["editor"]["line_count"] == 2
        assert data["editor"]["filename"].startswith(scratch)
        passed("authenticated stateless generation with independent model, planning, and unsaved code; preview does not edit")

        before = len(fixture.generations)
        assert nvim.lua("return P.accept_line()")
        nvim.wait(lambda: snap()["lines"][0] == "local value = first()", "first line accepted")
        visible()
        assert nvim.lua("return P.accept_line()")
        nvim.wait(lambda: len(snap()["lines"]) == 3, "second line accepted")
        visible()
        assert nvim.lua("return P.accept()")
        nvim.wait(lambda: len(snap()["lines"]) == 4, "remainder accepted")
        assert snap()["lines"] == ["local value = first()", "    second()", "    third()", original[1]]
        assert len(fixture.generations) == before
        assert snap()["progress"]["state"] == "accepted"
        passed("line-by-line acceptance preserves multiline remainder and indentation without another request")

        case()
        server.generation_delay = 0.3
        before = len(fixture.generations)
        suggest()
        assert snap()["progress"]["state"] == "generating"
        assert "Generating" in snap()["statusline"]
        nvim.wait(lambda: len(fixture.generations) > before, "generation with loading indicator")
        initial = snap()["statusline"]
        time.sleep(0.12)
        assert snap()["progress"]["state"] == "generating" and snap()["statusline"] != initial
        visible()
        assert snap()["statusline"] == "OC: Ready"
        assert snap()["progress"]["elapsed_ms"] >= 250
        passed("animated statusline identifies generation in progress and completion")

        case()
        before = len(fixture.generations)
        suggest()
        nvim.wait(lambda: len(fixture.generations) > before, "request before cancellation")
        nvim.lua("P.dismiss()")
        assert snap()["progress"]["state"] == "canceled" and snap()["statusline"] == "OC: Canceled"
        no_late_result()
        assert snap()["progress"]["state"] == "canceled"
        server.generation_delay = 0
        passed("cancellation stops the loading indicator and late results cannot change it")

        case()
        nvim.lua("""
          vim.keymap.set('i', '<F5>', function()
            return (vim.fn.pumvisible() == 1 and '<C-e>' or '') .. '<Cmd>OpenCompleat suggest<CR>'
          end, {expr=true})
          vim.keymap.set('i', '<F6>', '<Cmd>OpenCompleat accept<CR>')
        """)
        nvim.call("nvim_input", "<F5>")
        visible()
        assert snap()["mode"] == "i"
        nvim.call("nvim_input", "<F6>")
        nvim.wait(lambda: snap()["lines"][0] == "local value = first()", "command-mapping acceptance")
        assert snap()["mode"] == "i"
        passed("Insert-mode command mappings request and accept without leaving Insert mode")

        case()
        nvim.lua("vim.o.completeopt = 'menuone'; vim.fn.complete(15, {'COQ_TEMPORARY_ITEM', 'other_item'})")
        nvim.wait(lambda: nvim.lua("return vim.fn.pumvisible() == 1"), "completion popup with provisional selection")
        assert snap()["mode"] == "ic"
        assert snap()["lines"][0] == "local value = COQ_TEMPORARY_ITEM"
        notices = len(snap()["notices"])
        before = len(fixture.generations)
        nvim.call("nvim_input", "<F5>")
        visible()
        assert nvim.lua("return vim.fn.pumvisible()") == 0
        assert snap()["lines"] == ["local value = ", "-- suffix αβ \\"]
        assert len(fixture.generations) == before + 1
        data = payload(fixture.generations[-1]["prompt"])
        assert data["editor"]["prefix"].endswith("local value = ")
        assert "COQ_TEMPORARY_ITEM" not in data["editor"]["prefix"]
        assert not any("Request suggestions from Insert mode" in message for message in snap()["notices"][notices:])
        passed("suggest mapping cancels the popup without accepting its item before capturing code")

        case()
        nvim.lua("""
          vim.o.completeopt = 'menuone,noinsert,noselect'
          require('minuet').config.virtualtext.show_on_completion_menu = true
          vim.fn.complete(15, {'popup_item', 'other_item'})
        """)
        nvim.wait(lambda: nvim.lua("return vim.fn.pumvisible() == 1"), "Insert-completion mode")
        assert snap()["mode"] == "ic"
        before = len(fixture.generations)
        suggest()
        visible()
        assert snap()["mode"] == "ic"
        assert len(fixture.generations) == before + 1
        assert snap()["lines"] == ["local value = ", "-- suffix αβ \\"]
        nvim.lua("P.dismiss(); require('minuet').config.virtualtext.show_on_completion_menu = false")
        nvim.call("nvim_input", "<C-e>")
        passed("direct API and response guard recognize ic as Insert mode without accepting popup text")

        case(['local s = "αβ\\quote\\\""', '-- suffix'])
        suggest()
        visible()
        data = payload(fixture.generations[-1]["prompt"])
        assert data["editor"]["prefix"].endswith('local s = "αβ\\quote\\\""')
        nvim.lua("P.dismiss()")
        assert not snap()["marks"]
        assert not nvim.lua("return P.accept()")
        passed("quotes, Unicode, backslashes, and newlines survive curl-config stdin; dismiss never edits")

        case([""])
        suggest()
        visible()
        editor = payload(fixture.generations[-1]["prompt"])["editor"]
        assert editor["prefix"] == "" and editor["suffix"] == ""
        assert editor["cursor"] == {"row": 1, "byte_column": 0, "byte_offset": 0}
        passed("empty-file context has the exact cursor boundary without synthetic newlines")

        lines = ["-- start αβ", 'local value = αβ"tail"']
        before_cursor = "local value = αβ"
        byte_column = len(before_cursor.encode())
        case(lines)
        nvim.lua("vim.api.nvim_win_set_cursor(0, {2, ...}); vim.bo.endofline = false", byte_column)
        suggest()
        visible()
        editor = payload(fixture.generations[-1]["prompt"])["editor"]
        assert editor["prefix"] == lines[0] + "\n" + before_cursor
        assert editor["suffix"] == '"tail"'
        assert editor["prefix"] + editor["suffix"] == "\n".join(lines)
        assert editor["cursor"] == {"row": 2, "byte_column": byte_column,
                                    "byte_offset": len((lines[0] + "\n" + before_cursor).encode())}
        assert editor["line_count"] == 2 and editor["endofline"] is False
        passed("last-line Unicode cursor and full unsaved file are transported exactly, without an invented trailing newline")

        case()
        nvim.lua("""
          input_callbacks={}
          vim.ui.input=function(opts, choose)
            assert(opts.default == '' and opts.prompt:find('optional',1,true))
            input_callbacks[#input_callbacks+1]=choose
          end
        """)
        before = len(fixture.generations)
        assert nvim.lua("return P.prompt()")
        assert len(fixture.generations) == before
        nvim.lua("input_callbacks[1]('a request-local direction')")
        visible()
        assert payload(fixture.generations[-1]["prompt"])["completion_direction"] == "a request-local direction"
        nvim.lua("input_callbacks[1]('must not generate twice')")
        time.sleep(0.1)
        assert len(fixture.generations) == before + 1
        passed("generic vim.ui.input submission works and a callback cannot authorize two requests")

        case()
        before = len(fixture.generations)
        assert nvim.lua("return P.prompt()")
        assert nvim.lua("return P.prompt()")
        nvim.lua("input_callbacks[2]('old input'); input_callbacks[3]('new input')")
        visible()
        assert len(fixture.generations) == before + 1
        assert payload(fixture.generations[-1]["prompt"])["completion_direction"] == "new input"
        passed("a newer input dialog invalidates an older pending confirmation")

        case()
        before = len(fixture.generations)
        assert nvim.lua("return P.prompt()")
        nvim.lua("P.dismiss(); input_callbacks[4]('canceled input')")
        time.sleep(0.1)
        assert len(fixture.generations) == before and not snap()["marks"]
        passed("explicit dismissal invalidates pending direction input without generation")

        # Direct Minuet calls cannot authorize a paid request.
        before = len(fixture.generations)
        nvim.lua("require('minuet.virtualtext').action.next()")
        nvim.call("nvim_input", "x")
        time.sleep(0.15)
        assert len(fixture.generations) == before and not snap()["marks"]
        passed("typing and direct Minuet triggers cannot generate unsolicited suggestions")

        for name, change in [
            ("typing", lambda: nvim.call("nvim_input", "x")),
            ("same-cursor edit", lambda: nvim.lua("vim.api.nvim_buf_set_text(0, 0, 0, 0, 5, {'other'})")),
            ("cursor movement", lambda: nvim.call("nvim_input", "<Left>")),
            ("InsertLeave", lambda: nvim.call("nvim_input", "\x1b")),
            ("buffer switch", lambda: nvim.lua("vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))")),
            ("refresh", lambda: nvim.lua("P.refresh()")),
            ("new session", lambda: nvim.lua("P.select('ses_B')")),
            ("new model", lambda: nvim.lua("P.model()")),
            ("clear", lambda: nvim.lua("P.clear()")),
            ("setup", lambda: nvim.lua("P.setup(options)")),
            ("tab switch", lambda: nvim.lua("vim.cmd('tabnew')")),
            ("directory change", lambda: nvim.lua("vim.cmd('tcd ' .. vim.fn.fnameescape(...))", scratch)),
        ]:
            configure()
            case()
            server.generation_delay = 0.25
            before = len(fixture.generations)
            suggest()
            nvim.wait(lambda: len(fixture.generations) > before, "delayed generation started")
            change()
            no_late_result()
            server.generation_delay = 0
            # Restore cwd/tab for the next isolated case.
            nvim.lua("if #vim.api.nvim_list_tabpages() > 1 then vim.cmd('tabclose!') end; vim.cmd('tcd ' .. vim.fn.fnameescape(...))", str(fixture.ROOT))
            passed("pending result rejected after " + name)

        for name, change in [
            ("matching typed text", lambda: nvim.call("nvim_input", "f")),
            ("cursor movement", lambda: nvim.call("nvim_input", "<Left>")),
            ("refresh", lambda: nvim.lua("P.refresh()")),
            ("clear", lambda: nvim.lua("P.clear()")),
        ]:
            configure()
            case()
            suggest()
            visible()
            change()
            nvim.wait(lambda: not snap()["marks"], "visible suggestion invalidated")
            assert not nvim.lua("return P.accept()")
            passed("visible suggestion discarded after " + name)

        configure()
        case()
        server.generation_delay = 0.25
        before = len(fixture.generations)
        suggest()
        nvim.wait(lambda: len(fixture.generations) > before, "old request started")
        server.generation_delay = 0
        server.generation_response = {"data": {"text": "newest()"}}
        suggest()
        assert visible()[0][3]["virt_text"][0][0] == "newest()"
        time.sleep(0.4)
        assert snap()["marks"][0][3]["virt_text"][0][0] == "newest()"
        assert snap()["progress"]["state"] == "ready"
        passed("new manual request supersedes an older response")

        for name, response, status in [
            ("server failure", {"error": "PRIVATE_PROVIDER_ERROR"}, 503),
            ("malformed response", {"data": {"wrong": "shape"}}, 200),
            ("fenced response", {"data": {"text": "```lua\nwrong()\n```"}}, 200),
            ("conversational response", {"data": {"text": "Sure, here's the code:\n<div></div>"}}, 200),
            ("empty response", {"data": {"text": " \n"}}, 200),
        ]:
            case()
            server.generation_response, server.generation_status = response, status
            before = len(fixture.generations)
            suggest()
            nvim.wait(lambda: len(fixture.generations) > before, name)
            no_late_result()
            expected = "error" if status != 200 or name == "malformed response" else "empty" if name == "empty response" else "rejected"
            assert snap()["progress"]["state"] == expected
            assert all("PRIVATE_PROVIDER_ERROR" not in message for message in snap()["notices"])
            passed(name + " leaves the buffer untouched")

        server.generation_status = 200
        server.generation_response = {"data": {"text": "one()\n    two()\n    three()\n    four()"}}
        case()
        suggest()
        assert len(visible()[0][3]["virt_lines"]) == 3
        assert nvim.lua("return P.accept()")
        nvim.wait(lambda: "four()" in "\n".join(snap()["lines"]), "unclipped acceptance")
        assert snap()["progress"]["state"] == "accepted"
        passed("displayed and accepted output has no line cap")

        block = ' class="hero">\n    <h1>Welcome</h1>\n    <p>Explore our work.</p>\n    <a href="/work">See our work</a>\n  </div>'
        server.generation_response = {"data": {"text": block}}
        case(["<main>", "  <div", "</main>"])
        nvim.lua("vim.api.nvim_win_set_cursor(0, {2, 6}); vim.bo.filetype = 'html'")
        suggest()
        visible()
        data = payload(fixture.generations[-1]["prompt"])
        assert data["editor"]["prefix"].endswith("<main>\n  <div")
        assert data["editor"]["suffix"].endswith("\n</main>")
        assert nvim.lua("return P.accept()")
        expected = ["<main>", '  <div class="hero">', "    <h1>Welcome</h1>", "    <p>Explore our work.</p>",
                    '    <a href="/work">See our work</a>', "  </div>", "</main>"]
        nvim.wait(lambda: snap()["lines"] == expected, "whole HTML block inserted without clipping")
        passed("opening-tag continuation, content, and closing tag are inserted intact before the suffix")

        server.generation_response = {"data": {"text": "<h1>Welcome</h1>\n  <p>Explore our work.</p>"}}
        case(['<div class="hero">', "  ", "</div>"])
        nvim.lua("vim.api.nvim_win_set_cursor(0, {2, 2}); vim.bo.filetype = 'html'")
        suggest()
        visible()
        assert nvim.lua("return P.accept_line()")
        nvim.wait(lambda: "<h1>Welcome</h1>" in snap()["lines"][1], "first HTML line")
        visible()
        assert nvim.lua("return P.accept_line()")
        nvim.wait(lambda: snap()["progress"]["state"] == "accepted", "last line accepted")
        assert snap()["lines"] == ['<div class="hero">', "  <h1>Welcome</h1>", "  <p>Explore our work.</p>", "</div>"]
        passed("existing closing tag is preserved and accepting the last remaining line marks completion accepted")

        configure()
        nvim.lua("P.select('ses_Large')")
        nvim.wait(lambda: nvim.lua("local s=P.status(); return s.session_id == 'ses_Large' and not s.loading and P.get_context() ~= nil"), "large planning context")
        planning = nvim.lua("return P.get_context()")
        assert len(planning.encode()) > 64000
        case()
        before = len(fixture.generations)
        suggest()
        visible()
        assert len(fixture.generations) == before + 1
        body = fixture.generations[-1]
        assert len(body["prompt"].encode()) > 64000
        data = payload(body["prompt"])
        assert data["planning_context"] == planning
        assert snap()["lines"] == ["local value = ", "-- suffix αβ \\"]
        passed("large planning conversations reach generation intact, without a plugin prompt-byte cap")

        configure({"context_window": 40})
        case(["-- earlier code " * 20, "local value = ", "-- suffix " * 20])
        nvim.lua("vim.api.nvim_win_set_cursor(0, {2, 14})")
        suggest()
        visible()
        data = payload(fixture.generations[-1]["prompt"])
        editor = data["editor"]
        assert len(editor["prefix"]) + len(editor["suffix"]) <= 40
        assert editor["truncated"]["is_incomplete_before"] and editor["truncated"]["is_incomplete_after"]
        passed("editor context is bounded independently, with truncation flags in the prompt")

        configure()
        case()
        registration.write_text(json.dumps({"url": f"http://127.0.0.1:{server.server_port}", "password": "wrong"}))
        before = len(fixture.generations)
        notices = len(snap()["notices"])
        suggest()
        nvim.wait(lambda: len(snap()["notices"]) > notices, "authentication failure")
        no_late_result()
        assert len(fixture.generations) == before
        registration.write_text(json.dumps({"url": f"http://127.0.0.1:{server.server_port}", "password": fixture.PASSWORD}))
        passed("generation authentication failure is visible and does not fall back")

        configure({"timeout_ms": 60})
        case()
        server.generation_delay = 0.25
        suggest()
        nvim.wait(lambda: "timed out" in snap()["notices"][-1], "generation timeout")
        no_late_result()
        passed("generation timeout is visible and cannot insert a late result")

        # Different origin avoids cached discovery; prefer the newer path.
        other = ThreadingHTTPServer(("127.0.0.1", 0), fixture.Handler)
        other.generation_paths = ["/api/experimental/generate/text", "/api/experimental/generate"]
        threading.Thread(target=other.serve_forever, daemon=True).start()
        try:
            configure({"server": f"http://127.0.0.1:{other.server_port}", "password": fixture.PASSWORD})
            case()
            suggest()
            visible()
            assert fixture.mutations[-1] == "/api/experimental/generate/text"
            passed("OpenAPI discovery prefers the newer text route, with legacy fallback tested above")
        finally:
            other.shutdown()
            other.server_close()

        other = ThreadingHTTPServer(("127.0.0.1", 0), fixture.Handler)
        other.generation_paths = []
        threading.Thread(target=other.serve_forever, daemon=True).start()
        try:
            configure({"server": f"http://127.0.0.1:{other.server_port}", "password": fixture.PASSWORD})
            case()
            before = len(fixture.generations)
            suggest()
            nvim.wait(lambda: "supported stateless" in snap()["notices"][-1], "unsupported route warning")
            no_late_result()
            assert len(fixture.generations) == before
            passed("missing stateless route is refused without a session-generation fallback")
        finally:
            other.shutdown()
            other.server_close()

        assert all(path in ("/api/experimental/generate", "/api/experimental/generate/text") for path in fixture.mutations)
        passed("no planning-session mutation routes used")
        print(f"All {count} completion tests passed; {len(fixture.generations)} mock generations")
finally:
    nvim.close()
    server.shutdown()
    server.server_close()
