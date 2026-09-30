import json
import socket
import struct
import threading

from greeter.greetd_ipc import GreetdClient, GreetdError


def _read_msg(sock):
    raw = b""
    while len(raw) < 4:
        raw += sock.recv(4 - len(raw))
    (n,) = struct.unpack("=I", raw)
    body = b""
    while len(body) < n:
        body += sock.recv(n - len(body))
    return json.loads(body.decode())


def _write_msg(sock, obj):
    payload = json.dumps(obj).encode()
    sock.sendall(struct.pack("=I", len(payload)) + payload)


def test_framing_roundtrip():
    a, b = socket.socketpair()
    client = GreetdClient(a)

    def server():
        msg = _read_msg(b)
        assert msg == {"type": "create_session", "username": "philip"}
        _write_msg(b, {"type": "auth_message",
                       "auth_message_type": "secret",
                       "auth_message": "Password:"})

    t = threading.Thread(target=server)
    t.start()
    resp = client.create_session("philip")
    t.join()
    assert resp["type"] == "auth_message"
    assert resp["auth_message_type"] == "secret"


def test_post_response_and_success():
    a, b = socket.socketpair()
    client = GreetdClient(a)

    def server():
        msg = _read_msg(b)
        assert msg == {"type": "post_auth_message_response", "response": "hunter2"}
        _write_msg(b, {"type": "success"})

    t = threading.Thread(target=server)
    t.start()
    resp = client.post_response("hunter2")
    t.join()
    assert resp["type"] == "success"


def test_closed_socket_raises():
    a, b = socket.socketpair()
    client = GreetdClient(a)
    b.close()
    try:
        client.create_session("philip")
        assert False, "expected GreetdError"
    except GreetdError:
        pass
