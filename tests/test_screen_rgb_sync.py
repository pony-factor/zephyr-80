import pathlib
import subprocess
import tempfile
import unittest


class ScreenRGBSyncTests(unittest.TestCase):
    def test_wake_brightness_policy(self):
        helper = pathlib.Path(__file__).resolve().parents[1] / "macOS/ScreenRGBSync.swift"
        policy = helper.read_text().split("struct WakeBrightnessPolicy {", 1)[1]
        policy = "struct WakeBrightnessPolicy {" + policy.split(
            "private let restoreBrightnessBit", 1
        )[0]
        scenarios = r"""
var policy = WakeBrightnessPolicy()
policy.displayDidWake() // Login/reconnect alone does not reset brightness.
assert(!policy.shouldRestore(deviceID: 1))
policy.displayDidSleep()
policy.displayDidWake()
assert(policy.shouldRestore(deviceID: 1)) // Even a short sleep restores brightness.
policy.didRestore(deviceID: 1)
policy.displayDidSleep()
policy.displayDidSleep() // Duplicate sleep during a dark wake.
policy.displayDidWake()
assert(policy.shouldRestore(deviceID: 1))
assert(policy.shouldRestore(deviceID: 1)) // Failed HID sends remain eligible.
policy.didRestore(deviceID: 1)
policy.displayDidWake() // Duplicate wake.
assert(!policy.shouldRestore(deviceID: 1)) // A later brightness change survives retries.
assert(policy.shouldRestore(deviceID: 2)) // Another device still needs its report.
policy.didRestore(deviceID: 2)
policy.displayDidSleep()
policy.displayDidWake()
assert(policy.shouldRestore(deviceID: 1))
policy.didRestore(deviceID: 1)
policy.displayDidSleep()
policy.displayDidWake()
assert(policy.shouldRestore(deviceID: 1)) // Each subsequent sleep restores again.
"""
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            harness = root / "main.swift"
            harness.write_text("import Foundation\n" + policy + scenarios)
            binary = root / "policy"
            subprocess.run(["xcrun", "swiftc", str(harness), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
