from uniremote.config import Config

def test_default_config_created(tmp_path):
    cfg = Config(path=tmp_path / "config.toml")
    assert cfg.samsung_token == ""
    assert cfg.samsung_device_id == ""
    assert cfg.roku_ip == ""

def test_save_and_reload(tmp_path):
    path = tmp_path / "config.toml"
    cfg = Config(path=path)
    cfg.samsung_token = "tok123"
    cfg.samsung_device_id = "dev456"
    cfg.roku_ip = "192.168.1.50"
    cfg.save()

    cfg2 = Config(path=path)
    assert cfg2.samsung_token == "tok123"
    assert cfg2.samsung_device_id == "dev456"
    assert cfg2.roku_ip == "192.168.1.50"

def test_config_file_written(tmp_path):
    path = tmp_path / "config.toml"
    cfg = Config(path=path)
    cfg.samsung_token = "t"
    cfg.save()
    content = path.read_text()
    assert "[samsung]" in content
    assert "[roku]" in content

def test_recent_roku_apps_default_empty(tmp_path):
    cfg = Config(path=tmp_path / "config.toml")
    assert cfg.recent_roku_apps == []

def test_recent_roku_apps_round_trip(tmp_path):
    path = tmp_path / "config.toml"
    cfg = Config(path=path)
    cfg.recent_roku_apps = ["12", "551012", "2285"]
    cfg.save()

    cfg2 = Config(path=path)
    assert cfg2.recent_roku_apps == ["12", "551012", "2285"]

def test_recent_roku_apps_serialised_as_toml_array(tmp_path):
    path = tmp_path / "config.toml"
    cfg = Config(path=path)
    cfg.recent_roku_apps = ["12", "2285"]
    cfg.save()
    assert 'recent = ["12", "2285"]' in path.read_text()

def test_empty_recent_roku_apps_serialised_as_empty_array(tmp_path):
    path = tmp_path / "config.toml"
    cfg = Config(path=path)
    cfg.save()
    assert "recent = []" in path.read_text()

def test_existing_string_fields_still_round_trip_with_recent(tmp_path):
    path = tmp_path / "config.toml"
    cfg = Config(path=path)
    cfg.samsung_token = "tok"
    cfg.roku_ip = "10.0.0.5"
    cfg.recent_roku_apps = ["31012"]
    cfg.save()

    cfg2 = Config(path=path)
    assert cfg2.samsung_token == "tok"
    assert cfg2.roku_ip == "10.0.0.5"
    assert cfg2.recent_roku_apps == ["31012"]
