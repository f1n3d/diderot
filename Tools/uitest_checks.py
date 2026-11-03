"""What the server checks of Tools/run-uitests.sh share: which tests ran, and how their results are reported."""
import os

# The tests the run selected (ONLY, also set by AREA): a class ("HomeUITests") or one of its tests
# ("EditorUITests/test16_ExitListKeepsKeyboard"). None selected: the whole suite ran.
SELECTED = [test for test in os.environ.get("ONLY", "").split(",") if test]


def ran(test):
    """Whether `test` ("EditorUITests/test1_TapParagraphTypeAndBold") was part of the run."""
    return not SELECTED or any(test == selected or test.startswith(selected + "/") for selected in SELECTED)


def report(checks):
    """Prints the checks, (test, label, passed) each, of the tests that ran and returns whether they all passed. The
    others are left out: what their test would have changed isn't there."""
    counted = [(label, passed) for test, label, passed in checks if ran(test)]
    for label, passed in counted:
        print(("OK     " if passed else "MISSING") + " " + label)
    if len(counted) < len(checks):
        print(f"Checks of tests that didn't run, left out: {len(checks) - len(counted)}")
    return all(passed for _, passed in counted)
