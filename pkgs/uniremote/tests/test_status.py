import requests
from uniremote.api import RokuAPI, SmartThingsAPI
from uniremote.status import DeviceStatus, roku_status, samsung_status

ST = "https://api.smartthings.com/v1/devices/dev1/status"
IP = "192.168.1.100"


def test_samsung_online_full(requests_mock):
    requests_mock.get(ST, json={"components": {"main": {
        "switch": {"switch": {"value": "on"}},
        "audioVolume": {"volume": {"value": 14}},
        "mediaInputSource": {"inputSource": {"value": "HDMI2"}},
    }}})
    got = samsung_status(SmartThingsAPI("t", "dev1"), "Living Room TV")
    assert got == DeviceStatus("Living Room TV", "on · vol 14 · HDMI2", True)


def test_samsung_missing_capabilities(requests_mock):
    requests_mock.get(ST, json={"components": {"main": {"switch": {"switch": {"value": "off"}}}}})
    got = samsung_status(SmartThingsAPI("t", "dev1"), "")
    assert got == DeviceStatus("Samsung TV", "off", True)


def test_samsung_http_error_is_offline(requests_mock):
    requests_mock.get(ST, status_code=500)
    got = samsung_status(SmartThingsAPI("t", "dev1"), "Living Room TV")
    assert got == DeviceStatus("Living Room TV", "", False)


def test_samsung_401_reports_token_rejected(requests_mock):
    requests_mock.get(ST, status_code=401)
    got = samsung_status(SmartThingsAPI("t", "dev1"), "Living Room TV")
    assert got == DeviceStatus("Living Room TV", "token rejected · ⋯ → Preferences", False)


def test_samsung_403_reports_token_rejected(requests_mock):
    requests_mock.get(ST, status_code=403)
    got = samsung_status(SmartThingsAPI("t", "dev1"), "TV")
    assert got == DeviceStatus("TV", "token rejected · ⋯ → Preferences", False)


def test_samsung_timeout_is_offline(requests_mock):
    requests_mock.get(ST, exc=requests.exceptions.ConnectTimeout)
    assert samsung_status(SmartThingsAPI("t", "dev1"), "TV").online is False


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
