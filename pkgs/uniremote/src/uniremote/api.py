from __future__ import annotations
import socket
import threading
import xml.etree.ElementTree as ET
from pathlib import Path

import requests
from samsungtvws import SamsungTVWS
from samsungtvws.exceptions import ConnectionFailure, UnauthorizedError
from websocket import WebSocketException

SAMSUNG_WS_PORT = 8002  # TLS; 2016+ sets refuse remote keys on the plain 8001 socket
SAMSUNG_REST_PORT = 8001
WS_TIMEOUT = 5


class SamsungAPI:
    """The TV's own LAN WebSocket. The TV asks once to allow the client; the
    token it hands back lives in token_file and doesn't expire, unlike a
    SmartThings token."""

    def __init__(self, ip: str, token_file: Path):
        self.ip = ip
        self.token_file = Path(token_file)
        self._ws = SamsungTVWS(host=ip, port=SAMSUNG_WS_PORT,
                               token_file=str(self.token_file), name="Uniremote",
                               timeout=WS_TIMEOUT, key_press_delay=0)
        # one socket, shared by the GUI's worker threads
        self._lock = threading.Lock()

    @property
    def paired(self) -> bool:
        return self.token_file.exists() and self.token_file.stat().st_size > 0

    def pair(self, timeout: float = 30):
        """Open the socket so the TV shows its allow prompt; waits up to
        timeout for someone to accept it."""
        self.token_file.parent.mkdir(parents=True, exist_ok=True)
        with self._lock:
            self._ws.close()
            self._ws.timeout = timeout
            try:
                self._ws.open()
            finally:
                self._ws.timeout = WS_TIMEOUT

    def send_key(self, key: str):
        with self._lock:
            try:
                self._ws.send_key(key)
            except UnauthorizedError:
                raise
            except (OSError, WebSocketException, ConnectionFailure):
                # the TV drops idle sockets; reconnect once
                self._ws.close()
                self._ws.send_key(key)

    def device_info(self) -> dict:
        resp = requests.get(f"http://{self.ip}:{SAMSUNG_REST_PORT}/api/v2/", timeout=3)
        resp.raise_for_status()
        return resp.json().get("device", {})

    def power(self, state: str, mac: str = ""):  # state: "on" or "off"
        try:
            current = self.device_info().get("PowerState", "on")
        except requests.RequestException:
            current = None  # off the network: only Wake-on-LAN reaches it
        if state == "on":
            if current is None:
                if not mac:
                    raise RuntimeError("TV is off the network and no MAC is set for Wake-on-LAN")
                wake_on_lan(mac)
            elif current == "standby":
                self.send_key("KEY_POWER")
        elif current == "on":
            self.send_key("KEY_POWER")


def wake_on_lan(mac: str, broadcast: str = "255.255.255.255"):
    raw = bytes.fromhex(mac.replace(":", "").replace("-", ""))
    if len(raw) != 6:
        raise ValueError(f"not a MAC address: {mac!r}")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.sendto(b"\xff" * 6 + raw * 16, (broadcast, 9))


class RokuAPI:
    def __init__(self, ip: str):
        self.base = f"http://{ip}:8060"

    def keypress(self, key: str):
        requests.post(f"{self.base}/keypress/{key}", timeout=3).raise_for_status()

    def list_apps(self) -> list[tuple[str, str]]:
        resp = requests.get(f"{self.base}/query/apps", timeout=5)
        resp.raise_for_status()
        root = ET.fromstring(resp.text)
        return [(app.get("id", ""), app.text or "") for app in root.findall("app")]

    def launch_app(self, app_id: str):
        requests.post(f"{self.base}/launch/{app_id}", timeout=3).raise_for_status()

    def icon(self, app_id: str) -> bytes:
        resp = requests.get(f"{self.base}/query/icon/{app_id}", timeout=5)
        resp.raise_for_status()
        return resp.content

    def search(self, query: str):
        requests.post(
            f"{self.base}/search/browse",
            params={"keyword": query, "launch": "true"},
            timeout=3,
        ).raise_for_status()

    def device_info(self) -> dict[str, str]:
        resp = requests.get(f"{self.base}/query/device-info", timeout=3)
        resp.raise_for_status()
        return {child.tag: (child.text or "") for child in ET.fromstring(resp.text)}


SSDP_ADDR = "239.255.255.250"
SSDP_PORT = 1900
SSDP_MX = 2
ROKU_ST = "roku:ecp"
SAMSUNG_ST = "urn:samsung.com:device:RemoteControlReceiver:1"


def _ssdp_msg(st: str) -> bytes:
    return (
        "M-SEARCH * HTTP/1.1\r\n"
        f"HOST: {SSDP_ADDR}:{SSDP_PORT}\r\n"
        "MAN: \"ssdp:discover\"\r\n"
        f"MX: {SSDP_MX}\r\n"
        f"ST: {st}\r\n"
        "\r\n"
    ).encode()


def _ssdp_discover(st: str, timeout: int) -> str | None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    try:
        sock.settimeout(timeout)
        sock.sendto(_ssdp_msg(st), (SSDP_ADDR, SSDP_PORT))
        while True:
            try:
                data, _ = sock.recvfrom(1024)
                response = data.decode(errors="ignore")
                if st.lower() in response.lower():
                    for line in response.splitlines():
                        if line.lower().startswith("location:"):
                            url = line.split(":", 1)[1].strip()
                            # url like http://192.168.1.77:8060/
                            ip = url.split("//")[1].split(":")[0]
                            return ip
            except (TimeoutError, OSError):
                return None
    finally:
        sock.close()


def discover_roku(timeout: int = 3) -> str | None:
    return _ssdp_discover(ROKU_ST, timeout)


def discover_samsung(timeout: int = 3) -> str | None:
    return _ssdp_discover(SAMSUNG_ST, timeout)
