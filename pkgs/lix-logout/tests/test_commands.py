import pytest

from lix_logout import commands


def test_lock_command():
    assert commands.command_for("lock") == ["bash", "-c", "pidof hyprlock || hyprlock"]


def test_logout_command():
    assert commands.command_for("logout") == ["niri", "msg", "action", "quit", "-s"]


def test_reboot_command():
    assert commands.command_for("reboot") == ["systemctl", "reboot"]


def test_shutdown_command():
    assert commands.command_for("shutdown") == ["systemctl", "poweroff"]


def test_unknown_action_raises():
    with pytest.raises(ValueError):
        commands.command_for("nuke-from-orbit")
