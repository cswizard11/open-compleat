"""Small MessagePack driver: tests run in Neovim's real editor event loop."""

import os
from pathlib import Path
import select
import subprocess
import time

import msgpack


class Nvim:
    def __init__(self, env=None):
        self.process = subprocess.Popen(
            ["nvim", "--embed", "--headless", "-u", "NONE", "-i", "NONE", "-n"],
            cwd=Path(__file__).resolve().parents[1],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env,
        )
        self.unpacker = msgpack.Unpacker(raw=False, strict_map_key=False)
        self.serial = 0
        self.call("nvim_ui_attach", 100, 32, {"ext_linegrid": True})

    def call(self, method, *args):
        self.serial += 1
        request_id = self.serial
        self.process.stdin.write(msgpack.packb([0, request_id, method, args], use_bin_type=True))
        self.process.stdin.flush()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            for message in self.unpacker:
                if message[0] == 1 and message[1] == request_id:
                    if message[2] is not None:
                        raise RuntimeError(message[2])
                    return message[3]
            ready, _, _ = select.select([self.process.stdout], [], [], max(0, deadline - time.monotonic()))
            if ready:
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    raise RuntimeError("Neovim exited: " + self.process.stderr.read().decode())
                self.unpacker.feed(data)
        raise TimeoutError(method)

    def lua(self, code, *args):
        return self.call("nvim_exec_lua", code, args)

    def wait(self, predicate, description, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            time.sleep(0.01)
        raise AssertionError("Timed out: " + description)

    def close(self):
        self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()
