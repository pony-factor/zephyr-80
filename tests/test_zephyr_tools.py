"""Offline regression tests for Glove80's opt-in Zephyr tool setup."""
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "zephyr_tools", Path(__file__).resolve().parents[1] / "scripts/zephyr_tools.py")
tools = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tools)


class ToolSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.workspace = self.root / "user-config/a"
        (self.workspace / "config").mkdir(parents=True)
        (self.workspace / "config/west.yml").write_text(
            "manifest:\n  projects:\n    - name: zmk\n      revision: " +
            tools.SUPPORTED_REVISIONS[0] + "\n")

    def sdk(self, version="0.16.8"):
        sdk = self.root / ("zephyr-sdk-" + version)
        gcc = sdk / "arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc"
        gcc.parent.mkdir(parents=True)
        gcc.write_text("#!/bin/sh\nexit 0\n")
        gcc.chmod(0o755)
        (sdk / "cmake").mkdir()
        return sdk

    def test_pinned_firmware_determines_compatible_sdk(self):
        self.assertEqual(tools.zephyr_version(self.workspace), (3, 5))
        sdk = self.sdk()
        self.assertTrue(tools.compatible_sdk(sdk, (3, 5)))
        self.assertFalse(tools.compatible_sdk(sdk, (4, 0)))
        self.assertFalse(tools.compatible_sdk(self.sdk("0.17.0"), (3, 5)))
        (self.workspace / "zephyr").mkdir()
        (self.workspace / "zephyr/VERSION").write_text("VERSION_MAJOR = 4\nVERSION_MINOR = 1\n")
        self.assertEqual(tools.zephyr_version(self.workspace), (4, 1))

    def test_status_reuses_installed_tools_without_changes(self):
        sdk = self.sdk()
        with patch.object(tools, "sdk_candidate_paths", return_value=iter([sdk])), \
             patch.object(tools, "command_available", return_value=True):
            state = tools.status(self.workspace)
        self.assertTrue(state["ready"])
        self.assertEqual(state["sdk"], str(sdk.resolve()))
        self.assertEqual(state["missing"], [])

    def test_no_sdk_install_for_unsupported_zephyr(self):
        (self.workspace / "zephyr").mkdir()
        (self.workspace / "zephyr/VERSION").write_text("VERSION_MAJOR = 4\nVERSION_MINOR = 2\n")
        with patch.object(tools, "find_sdk", return_value=None), \
             patch.object(tools, "verified_download") as download:
            with self.assertRaisesRegex(RuntimeError, "another firmware revision"):
                tools.install_sdk(self.workspace)
            download.assert_not_called()

    def test_tar_rejects_traversal_and_escaping_links(self):
        for name, link in (("../escape", None), ("inside/outside", "../../escape")):
            archive = self.root / "fixture.tar.xz"
            with tarfile.open(archive, "w:xz") as handle:
                if link:
                    item = tarfile.TarInfo(name)
                    item.type = tarfile.SYMTYPE
                    item.linkname = link
                    handle.addfile(item)
                else:
                    data = b"bad"
                    item = tarfile.TarInfo(name)
                    item.size = len(data)
                    handle.addfile(item, io.BytesIO(data))
            with self.assertRaisesRegex(RuntimeError, "Unsafe|escapes"):
                tools.safe_extract(archive, self.root / "unpack")

    def test_older_compatible_sdk_is_not_replaced_by_newest(self):
        sdk = self.sdk("0.16.3")
        with patch.object(tools, "sdk_candidate_paths", return_value=iter([sdk])):
            self.assertEqual(tools.find_sdk((3, 5)), sdk.resolve())


if __name__ == "__main__":
    unittest.main()
