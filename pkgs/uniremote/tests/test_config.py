from uniremote.config import Config

def test_default_config_created(tmp_path):
    cfg = Config(path=tmp_path / "config.toml")
    assert cfg.samsung_ip == ""
    assert cfg.samsung_mac == ""
    assert cfg.roku_ip == ""

def test_save_and_reload(tmp_path):
    path = tmp_path / "config.toml"
    cfg = Config(path=path)
    cfg.samsung_ip = "192.168.1.60"
    cfg.samsung_mac = "aa:bb:cc:dd:ee:ff"
    cfg.roku_ip = "192.168.1.50"
    cfg.save()

    cfg2 = Config(path=path)
    assert cfg2.samsung_ip == "192.168.1.60"
    assert cfg2.samsung_mac == "aa:bb:cc:dd:ee:ff"
    assert cfg2.roku_ip == "192.168.1.50"

def test_config_file_written(tmp_path):
    path = tmp_path / "config.toml"
    cfg = Config(path=path)
    cfg.samsung_ip = "10.0.0.9"
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
    cfg.samsung_ip = "10.0.0.9"
    cfg.roku_ip = "10.0.0.5"
    cfg.recent_roku_apps = ["31012"]
    cfg.save()

    cfg2 = Config(path=path)
    assert cfg2.samsung_ip == "10.0.0.9"
    assert cfg2.roku_ip == "10.0.0.5"
    assert cfg2.recent_roku_apps == ["31012"]

def test_old_smartthings_keys_are_ignored(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text('[samsung]\ntoken = "old"\ndevice_id = "dev"\n')
    cfg = Config(path=path)
    assert cfg.samsung_ip == ""

def test_token_file_sits_next_to_config(tmp_path):
    cfg = Config(path=tmp_path / "config.toml")
    assert cfg.samsung_token_file == tmp_path / "samsung-token"
