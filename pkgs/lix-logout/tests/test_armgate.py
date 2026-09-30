from lix_logout.armgate import ARM_WINDOW_SECONDS, ArmGate


def test_first_click_arms_not_fires():
    gate = ArmGate()
    assert gate.click("reboot", now=0.0) is False


def test_second_click_within_window_fires():
    gate = ArmGate()
    gate.click("reboot", now=0.0)
    assert gate.click("reboot", now=1.0) is True


def test_second_click_after_window_rearms_instead_of_firing():
    gate = ArmGate()
    gate.click("reboot", now=0.0)
    assert gate.click("reboot", now=ARM_WINDOW_SECONDS + 0.1) is False


def test_different_action_does_not_confirm_armed_one():
    gate = ArmGate()
    gate.click("reboot", now=0.0)
    assert gate.click("shutdown", now=0.5) is False


def test_is_armed_reflects_window():
    gate = ArmGate()
    gate.click("reboot", now=0.0)
    assert gate.is_armed("reboot", now=1.0) is True
    assert gate.is_armed("reboot", now=ARM_WINDOW_SECONDS + 0.1) is False


def test_firing_clears_armed_state():
    gate = ArmGate()
    gate.click("reboot", now=0.0)
    gate.click("reboot", now=1.0)  # fires
    assert gate.is_armed("reboot", now=1.1) is False
