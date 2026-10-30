from unittest.mock import MagicMock, patch

import pytest
from samsungtvws.exceptions import UnauthorizedError
from uniremote.api import SamsungAPI, discover_samsung, wake_on_lan
from websocket import WebSocketConnectionClosedException

IP = "192.168.1.100"
INFO = f"http://{IP}:8001/api/v2/"
MAC = "aa:bb:cc:dd:ee:ff"


@pytest.fixture
def ws():
    with patch("uniremote.api.SamsungTVWS") as cls:
        yield cls.return_value


def _api(tmp_path):
    return SamsungAPI(IP, tmp_path / "samsung-token")


def test_client_uses_tls_socket_without_key_delay(tmp_path):
    with patch("uniremote.api.SamsungTVWS") as cls:
        _api(tmp_path)
    kwargs = cls.call_args.kwargs
    assert kwargs["port"] == 8002
    assert kwargs["key_press_delay"] == 0
    assert kwargs["token_file"] == str(tmp_path / "samsung-token")


def test_send_key(ws, tmp_path):
    _api(tmp_path).send_key("KEY_UP")
    ws.send_key.assert_called_once_with("KEY_UP")


def test_send_key_reconnects_once_after_dropped_socket(ws, tmp_path):
    ws.send_key.side_effect = [WebSocketConnectionClosedException(), None]
    _api(tmp_path).send_key("KEY_UP")
    ws.close.assert_called_once()
    assert ws.send_key.call_count == 2


def test_send_key_unauthorized_is_not_retried(ws, tmp_path):
    ws.send_key.side_effect = UnauthorizedError({})
    with pytest.raises(UnauthorizedError):
        _api(tmp_path).send_key("KEY_UP")
    assert ws.send_key.call_count == 1


def test_paired_needs_a_non_empty_token_file(ws, tmp_path):
    api = _api(tmp_path)
    assert not api.paired
    api.token_file.write_text("")
    assert not api.paired
    api.token_file.write_text("12345678")
    assert api.paired


def test_pair_opens_with_long_timeout_then_restores(ws, tmp_path):
    seen = []
    ws.open.side_effect = lambda: seen.append(ws.timeout)
    _api(tmp_path).pair(timeout=30)
    assert seen == [30]
    assert ws.timeout == 5


def test_device_info(ws, tmp_path, requests_mock):
    requests_mock.get(INFO, json={"device": {"PowerState": "on", "wifiMac": MAC}})
    assert _api(tmp_path).device_info() == {"PowerState": "on", "wifiMac": MAC}


def test_power_on_from_standby_sends_power_key(ws, tmp_path, requests_mock):
    requests_mock.get(INFO, json={"device": {"PowerState": "standby"}})
    _api(tmp_path).power("on", MAC)
    ws.send_key.assert_called_once_with("KEY_POWER")


def test_power_on_when_already_on_does_nothing(ws, tmp_path, requests_mock):
    requests_mock.get(INFO, json={"device": {"PowerState": "on"}})
    with patch("uniremote.api.wake_on_lan") as wol:
        _api(tmp_path).power("on", MAC)
    ws.send_key.assert_not_called()
    wol.assert_not_called()


def test_power_on_unreachable_sends_wake_on_lan(ws, tmp_path, requests_mock):
    requests_mock.get(INFO, exc=__import__("requests").ConnectionError)
    with patch("uniremote.api.wake_on_lan") as wol:
        _api(tmp_path).power("on", MAC)
    wol.assert_called_once_with(MAC)
    ws.send_key.assert_not_called()


def test_power_on_unreachable_without_mac_raises(ws, tmp_path, requests_mock):
    requests_mock.get(INFO, exc=__import__("requests").ConnectionError)
    with pytest.raises(RuntimeError, match="MAC"):
        _api(tmp_path).power("on", "")


def test_power_off_only_when_on(ws, tmp_path, requests_mock):
    requests_mock.get(INFO, json={"device": {"PowerState": "standby"}})
    _api(tmp_path).power("off")
    ws.send_key.assert_not_called()
    requests_mock.get(INFO, json={"device": {"PowerState": "on"}})
    _api(tmp_path).power("off")
    ws.send_key.assert_called_once_with("KEY_POWER")


def test_wake_on_lan_magic_packet():
    sock = MagicMock()
    with patch("socket.socket") as cls:
        cls.return_value.__enter__.return_value = sock
        wake_on_lan(MAC)
    packet, addr = sock.sendto.call_args.args
    assert packet == b"\xff" * 6 + bytes.fromhex("aabbccddeeff") * 16
    assert addr == ("255.255.255.255", 9)


def test_wake_on_lan_rejects_bad_mac():
    with pytest.raises(ValueError):
        wake_on_lan("aa:bb:cc")


def test_discover_finds_samsung():
    sock = MagicMock()
    sock.recvfrom.side_effect = [
        ((b"HTTP/1.1 200 OK\r\n"
          b"ST: urn:samsung.com:device:RemoteControlReceiver:1\r\n"
          b"LOCATION: http://192.168.1.100:7676/smp_15_\r\n\r\n"), (IP, 1900)),
        TimeoutError(),
    ]
    with patch("socket.socket", return_value=sock):
        assert discover_samsung(timeout=1) == IP
