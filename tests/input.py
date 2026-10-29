"""One-shot direction input tested with real Snacks and mock-only generation."""

from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
import integration as fixture
from nvim_rpc import Nvim

MINUET = Path(os.environ["MINUET_RTP"]).resolve()
SNACKS = Path(os.environ["SNACKS_RTP"]).resolve()
count = 0


def passed(name):
    global count
    count += 1
    print("PASS: " + name, flush=True)


def payload(prompt):
    return json.loads(prompt.split("\n<open_compleat_context>\n", 1)[1].split("\n</open_compleat_context>\n", 1)[0])


server = ThreadingHTTPServer(("127.0.0.1", 0), fixture.Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="completion-input-tests-", dir="/tmp/opencode") as scratch:
        env = os.environ | {"XDG_DATA_HOME": scratch + "/data", "XDG_STATE_HOME": scratch + "/state",
                            "XDG_CACHE_HOME": scratch + "/cache"}
        nvim = Nvim(env=env)
        try:
            url = f"http://127.0.0.1:{server.server_port}"
            nvim.lua(r"""
              local minuet, snacks, server, scratch = ...
              vim.opt.runtimepath:prepend(vim.fn.getcwd())
              vim.opt.runtimepath:append(minuet)
              vim.opt.runtimepath:append(snacks)
              require('snacks').setup({input={enabled=true}})
              vim.cmd('runtime plugin/open-compleat.lua')
              P=require('open-compleat')
              options={server=server,password='fixture-password',timeout_ms=1000}
              notices={}
              vim.notify=function(message) notices[#notices+1]=message end
              local system=vim.system
              vim.system=function(args, opts, callback)
                if args[1]=='curl' then
                  assert(table.concat(args,' '):find(server,1,true), 'HTTP must use only the mock server')
                end
                return system(args,opts,callback)
              end
              function configure()
                P.setup(options)
                vim.ui.select=function(items,_,choose) choose(items[1]) end
                P.select('ses_A'); P.model()
              end
              vim.keymap.set('i','<C-b>',function()
                return (vim.fn.pumvisible()==1 and '<C-e>' or '') .. '<Cmd>OpenCompleat prompt<CR>'
              end,{expr=true})
              function snap()
                local ns=vim.api.nvim_get_namespaces()['minuet.virtualtext']
                local valid=source_buf and vim.api.nvim_buf_is_valid(source_buf)
                return {mode=vim.api.nvim_get_mode().mode, filetype=vim.bo.filetype,
                  current_buf=vim.api.nvim_get_current_buf(), source_buf=source_buf,
                  source_lines=valid and vim.api.nvim_buf_get_lines(source_buf,0,-1,false) or {},
                  source_cursor=source_win and vim.api.nvim_win_is_valid(source_win) and vim.api.nvim_win_get_cursor(source_win) or {},
                  marks=valid and ns and vim.api.nvim_buf_get_extmarks(source_buf,ns,0,-1,{}) or {},notices=notices}
              end
            """, str(MINUET), str(SNACKS), url, scratch)

            def snap():
                return nvim.lua("return snap()")

            def configure():
                nvim.lua("configure()")
                nvim.wait(lambda: nvim.lua("return P.get_context() ~= nil and P.status().completion_model ~= nil"), "mock selections")

            def case(lines=None, row=1, col=14):
                nvim.call("nvim_input", "<Esc>")
                nvim.wait(lambda: snap()["mode"] == "n", "Normal mode")
                nvim.lua("""
                  local name, lines, row = ...
                  P.dismiss()
                  source_buf=vim.api.nvim_create_buf(true,false)
                  vim.api.nvim_set_current_buf(source_buf)
                  source_win=vim.api.nvim_get_current_win()
                  vim.api.nvim_buf_set_name(source_buf,name)
                  vim.api.nvim_buf_set_lines(source_buf,0,-1,false,lines)
                  vim.api.nvim_win_set_cursor(source_win,{row,0})
                  vim.bo.filetype='lua'
                """, str(Path(scratch) / f"unsaved-{time.monotonic_ns()}.lua"), lines or ["local value = ", "-- suffix"], row)
                nvim.call("nvim_input", "A")
                nvim.wait(lambda: snap()["mode"] == "i", "Insert mode")
                nvim.lua("vim.api.nvim_win_set_cursor(0, {...})", row, col)

            def open_input():
                nvim.call("nvim_input", "<C-b>")
                nvim.wait(lambda: snap()["filetype"] == "snacks_input" and snap()["mode"] == "i", "Snacks direction input")

            def confirm(text=""):
                if text:
                    nvim.call("nvim_paste", text, False, -1)
                nvim.call("nvim_input", "<CR>")

            def visible():
                try:
                    return nvim.wait(lambda: snap()["marks"], "source ghost text")
                except AssertionError as err:
                    raise AssertionError(f"{err}: {snap()}, generations={len(fixture.generations)}") from err

            configure()
            case()
            before = len(fixture.generations)
            planning = nvim.lua("return P.get_context()")
            nvim.lua("vim.o.completeopt='menuone'; vim.fn.complete(15, {'COQ_TEMPORARY_ITEM', 'other'})")
            nvim.wait(lambda: nvim.lua("return vim.fn.pumvisible()") == 1, "completion popup")
            open_input()
            placement = nvim.lua("return vim.api.nvim_win_get_config(0)")
            assert placement["relative"] == "editor"
            assert abs(placement["row"] + (placement["height"] + 2) / 2 - 16) <= 2
            assert abs(placement["col"] + (placement["width"] + 2) / 2 - 50) <= 2
            time.sleep(0.12)
            assert len(fixture.generations) == before
            assert snap()["source_lines"] == ["local value = ", "-- suffix"]
            direction = 'finish the parser using "αβ" and \\ escapes'
            confirm(direction)
            visible()
            result = payload(fixture.generations[-1]["prompt"])
            assert result["completion_direction"] == direction
            assert result["planning_context"] == planning
            assert result["editor"]["prefix"] == "local value = " and result["editor"]["suffix"] == "\n-- suffix"
            assert result["editor"]["cursor"] == {"row": 1, "byte_column": 14, "byte_offset": 14}
            assert result["editor"]["filename"].startswith(scratch)
            assert snap()["current_buf"] == snap()["source_buf"] and snap()["mode"] == "i"
            assert snap()["source_lines"] == ["local value = ", "-- suffix"]
            assert nvim.lua("return P.get_context()") == planning
            passed("Ctrl+b cancels COQ's item, opens Snacks without generating, then sends the one-shot direction with the original source cursor")

            case()
            open_input()
            assert nvim.lua("return table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),'')") == ""
            confirm()
            visible()
            assert "completion_direction" not in payload(fixture.generations[-1]["prompt"])
            passed("empty Enter requests normal completion and does not reuse the previous direction")

            case()
            before = len(fixture.generations)
            open_input()
            nvim.call("nvim_input", "discard this direction<Esc>")
            nvim.wait(lambda: snap()["current_buf"] == snap()["source_buf"] and snap()["mode"] == "i", "cancel restores source Insert mode")
            time.sleep(0.15)
            assert len(fixture.generations) == before
            assert snap()["source_cursor"] == [1, 14]
            assert snap()["source_lines"] == ["local value = ", "-- suffix"]
            passed("one Escape cancels without a model call or source edit and restores the exact Insert cursor")

            prefix = "local value = αβ"
            lines = ["-- heading", prefix + "tail"]
            case(lines, 2, len(prefix.encode()))
            open_input()
            confirm("complete this expression")
            visible()
            editor = payload(fixture.generations[-1]["prompt"])["editor"]
            assert editor["prefix"] == lines[0] + "\n" + prefix
            assert editor["suffix"] == "tail"
            assert editor["cursor"]["row"] == 2 and editor["cursor"]["byte_column"] == len(prefix.encode())
            passed("mid-line Unicode cursor resumes at the original position, not the end of the line")

            for name, change in [
                ("source edit", "vim.api.nvim_buf_set_text(source_buf,0,0,0,5,{'other'})"),
                ("source cursor movement", "vim.api.nvim_win_set_cursor(source_win,{1,0})"),
                ("planning clear", "P.clear()"),
                ("planning refresh", "P.refresh()"),
                ("model selection", "P.model()"),
                ("setup", "P.setup(options)"),
                ("source window buffer switch", "vim.api.nvim_win_set_buf(source_win,vim.api.nvim_create_buf(true,false))"),
            ]:
                configure()
                case()
                before = len(fixture.generations)
                open_input()
                nvim.lua(change)
                confirm("must not be generated")
                nvim.wait(lambda: snap()["filetype"] != "snacks_input", "input closed after invalidation")
                time.sleep(0.15)
                assert len(fixture.generations) == before, (name, snap(), payload(fixture.generations[-1]["prompt"])["editor"])
                passed("input cannot generate after " + name)

            configure()
            case()
            assert nvim.lua("return P.suggest('direct API direction')")
            visible()
            assert payload(fixture.generations[-1]["prompt"])["completion_direction"] == "direct API direction"
            case()
            assert nvim.lua("return P.suggest()")
            visible()
            assert "completion_direction" not in payload(fixture.generations[-1]["prompt"])
            passed("direct suggest API remains available and its optional direction is request-local")

            assert all(path in ("/api/experimental/generate", "/api/experimental/generate/text") for path in fixture.mutations)
            print(f"All {count} input tests passed; {len(fixture.generations)} mock generations")
        finally:
            nvim.close()
finally:
    server.shutdown()
    server.server_close()
