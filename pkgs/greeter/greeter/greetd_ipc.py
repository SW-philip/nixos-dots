"""Minimal greetd IPC client: length-prefixed JSON over a unix socket.

greetd owns the PAM conversation. This client only relays prompts/responses;
it never stores or validates credentials beyond the in-flight response string.
Protocol: https://man.sr.ht/~kennylevinsen/greetd/protocol.md
"""
from __future__ import annotations

import json
import os
import socket
import struct


class GreetdError(Exception):
    pass


class GreetdClient:
    def __init__(self, sock: socket.socket):
        self._sock = sock

    @classmethod
    def connect(cls, path: str | None = None) -> "GreetdClient":
        path = path or os.environ.get("GREETD_SOCK")
        if not path:
            raise GreetdError("GREETD_SOCK not set")
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(path)
        return cls(s)

    def _recv_exact(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            try:
                chunk = self._sock.recv(n - len(buf))
            except OSError as e:
                raise GreetdError(f"greetd socket error: {e}") from e
            if not chunk:
                raise GreetdError("greetd socket closed")
            buf += chunk
        return buf

    def request(self, obj: dict) -> dict:
        payload = json.dumps(obj).encode("utf-8")
        try:
            self._sock.sendall(struct.pack("=I", len(payload)) + payload)
        except OSError as e:
            raise GreetdError(f"greetd send failed: {e}") from e
        (n,) = struct.unpack("=I", self._recv_exact(4))
        return json.loads(self._recv_exact(n).decode("utf-8"))

    # --- protocol verbs ---
    def create_session(self, username: str) -> dict:
        return self.request({"type": "create_session", "username": username})

    def post_response(self, response: str | None) -> dict:
        return self.request({"type": "post_auth_message_response",
                             "response": response})

    def start_session(self, cmd: list[str], env: list[str] | None = None) -> dict:
        return self.request({"type": "start_session", "cmd": cmd,
                             "env": env or []})

    def cancel_session(self) -> dict:
        return self.request({"type": "cancel_session"})
