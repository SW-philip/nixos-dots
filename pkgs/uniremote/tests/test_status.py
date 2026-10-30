import requests
from unittest.mock import patch

from uniremote.api import RokuAPI, SamsungAPI
from uniremote.status import DeviceStatus, roku_status, samsung_status

IP = "192.168.1.100"


INFO = f"http://{IP}:8001/api/v2/"


def _samsung(tmp_path, paired=True):
    token = tmp_path / "samsung-token"
    if paired:
        token.write_text("12345678")
    with patch("uniremote.api.SamsungTVWS"):
        return SamsungAPI(IP, token)


def test_samsung_online_full(requests_mock, tmp_path):
    requests_mock.get(INFO, json={"device": {
        "name": "[TV] Living Room", "PowerState": "on", "modelName": "QN55Q60",
    }})
    got = samsung_status(_samsung(tmp_path))
    assert got == DeviceStatus("Living Room", "on · QN55Q60", True)


def test_samsung_name_is_unescaped(requests_mock, tmp_path):
    requests_mock.get(INFO, json={"device": {"name": "[TV] Phil&#39;s TV", "PowerState": "standby"}})
    got = samsung_status(_samsung(tmp_path))
    assert got == DeviceStatus("Phil's TV", "standby", True)


def test_samsung_missing_fields(requests_mock, tmp_path):
    requests_mock.get(INFO, json={"device": {}})
    assert samsung_status(_samsung(tmp_path)) == DeviceStatus("Samsung TV", "on", True)


def test_samsung_unreachable_is_offline(requests_mock, tmp_path):
    requests_mock.get(INFO, exc=requests.ConnectionError)
    assert samsung_status(_samsung(tmp_path)) == DeviceStatus("Samsung TV", "", False)


def test_samsung_http_error_is_offline(requests_mock, tmp_path):
    requests_mock.get(INFO, status_code=500)
    assert samsung_status(_samsung(tmp_path)) == DeviceStatus("Samsung TV", "", False)


def test_samsung_unpaired_says_so(requests_mock, tmp_path):
    requests_mock.get(INFO, json={"device": {"name": "[TV] Living Room", "PowerState": "on"}})
    got = samsung_status(_samsung(tmp_path, paired=False))
    assert got == DeviceStatus("Living Room", "not paired · ⋯ → Preferences", True)


def test_roku_online(requests_mock):
    requests_mock.get(f"http://{IP}:8060/query/device-info", text=(
        "<device-info><user-device-name>Bedroom Roku</user-device-name>"
        "<model-name>Roku Ultra</model-name><power-mode>Ready</power-mode></device-info>"))
    assert roku_status(RokuAPI(IP)) == DeviceStatus("Bedroom Roku", "ready · Roku Ultra", True)


def test_roku_unknown_power_mode_passes_through(requests_mock):
    requests_mock.get(f"http://{IP}:8060/query/device-info",
                      text="<device-info><power-mode>WeirdMode</power-mode></device-info>")
    assert roku_status(RokuAPI(IP)) == DeviceStatus("Roku", "weirdmode", True)


def test_roku_unreachable_is_offline(requests_mock):
    requests_mock.get(f"http://{IP}:8060/query/device-info", exc=requests.exceptions.ConnectionError)
    assert roku_status(RokuAPI(IP)) == DeviceStatus("Roku", "", False)


def test_roku_http_error_is_online_status_unavailable(requests_mock):
    requests_mock.get(f"http://{IP}:8060/query/device-info", status_code=403)
    assert roku_status(RokuAPI(IP)) == DeviceStatus("Roku", "status unavailable", True)


def test_roku_garbage_xml_is_offline(requests_mock):
    requests_mock.get(f"http://{IP}:8060/query/device-info", text="<not xml")
    assert roku_status(RokuAPI(IP)).online is False
