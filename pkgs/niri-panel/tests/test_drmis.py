from niri_panel import drmis


def test_parse_list():
    stdout = '[{"slug": "eagles", "family": "Teams", "current": true}, ' \
             '{"slug": "moss-violet", "family": "Lix", "current": false}]'
    got = drmis.parse_list(stdout)
    assert got[0] == {"slug": "eagles", "family": "Teams", "current": True}
    assert got[1]["slug"] == "moss-violet"
