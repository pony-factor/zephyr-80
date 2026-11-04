#!/usr/bin/env python3
"""Inspect or, with consent, install build prerequisites for a saved Glove80 import."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

SDK_VERSION = "0.16.8"
SDK_BASE = f"https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v{SDK_VERSION}"
SUPPORTED_REVISIONS = (
    "ce69e85f585c724142aae37ddf8a7e019ff19e93",
    "8aeaaa66fbb4b94948c8763e06f1920ab0b69480",
)


def tools_home():
    return Path.home() / "Library/Application Support/Glove80 Mac/Tools"


def managed_west():
    return tools_home() / "venv/bin/west"


def command_available(name):
    path = shutil.which(name)
    if not path:
        return False
    try:
        return subprocess.run([path, "--version"], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=5).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def zephyr_version(workspace):
    version_file = workspace / "zephyr/VERSION"
    if version_file.is_file():
        content = version_file.read_text(encoding="utf-8")
        major = re.search(r"(?m)^VERSION_MAJOR\s*=\s*(\d+)", content)
        minor = re.search(r"(?m)^VERSION_MINOR\s*=\s*(\d+)", content)
        if major and minor:
            return (int(major.group(1)), int(minor.group(1)))
    manifest = workspace / "config/west.yml"
    if manifest.is_file():
        content = manifest.read_text(encoding="utf-8")
        if any(re.search(r"(?m)^\s*revision:\s*" + revision + r"\s*$", content)
               for revision in SUPPORTED_REVISIONS):
            return (3, 5)
    return None


def sdk_candidate_paths():
    configured = os.environ.get("ZEPHYR_SDK_INSTALL_DIR")
    if configured:
        yield Path(configured).expanduser()
    yield tools_home() / f"zephyr-sdk-{SDK_VERSION}"
    home = Path.home()
    for parent in [home, home / ".local", home / ".local/opt",
                   Path("/opt"), Path("/usr/local")]:
        yield from sorted(parent.glob("zephyr-sdk-*"), reverse=True)


def compatible_sdk(candidate, version):
    # Do not substitute an arbitrary new SDK for Zephyr 3.5.
    if version != (3, 5) or not re.fullmatch(r"zephyr-sdk-0\.16\.\d+", candidate.name):
        return False
    gcc = candidate / "arm-zephyr-eabi/bin/arm-zephyr-eabi-gcc"
    return gcc.is_file() and os.access(gcc, os.X_OK) and (candidate / "cmake").is_dir()


def find_sdk(version):
    for candidate in sdk_candidate_paths():
        if compatible_sdk(candidate, version):
            return candidate.resolve()
    return None


def status(workspace):
    version = zephyr_version(workspace)
    sdk = find_sdk(version)
    west_ok = command_available("west") or managed_west().is_file()
    missing = []
    if not west_ok:
        missing.append("west")
    for name in ("cmake", "ninja"):
        if not command_available(name) and not (tools_home() / "venv/bin" / name).is_file():
            missing.append(name)
    if not sdk:
        missing.append("Zephyr 3.5-compatible ARM SDK" if version == (3, 5)
                       else "SDK for the selected Zephyr revision")
    return {"ready": not missing, "west": west_ok, "sdk": str(sdk) if sdk else None,
            "zephyr": ".".join(map(str, version)) if version else "not initialized",
            "missing": missing}


def install_python_tools():
    venv = tools_home() / "venv"
    if not (venv / "bin/python3").is_file():
        venv.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
    python = venv / "bin/python3"
    print("Installing west, CMake, and Ninja into the private Glove80 tools environment.", flush=True)
    subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check",
                    "west>=1,<2", "cmake>=3.20,<4", "ninja>=1.10"], check=True)


def verified_download(filename, destination, sums):
    url = f"{SDK_BASE}/{filename}"
    with urllib.request.urlopen(url, timeout=60) as response, destination.open("wb") as output:
        shutil.copyfileobj(response, output)
    entries = re.findall(r"(?m)^([0-9a-fA-F]{64})\s+\*?([^\r\n]+)$", sums)
    expected = next((digest for digest, name in entries if name == filename), None)
    if not expected:
        raise RuntimeError(f"Official checksum missing for {filename}.")
    digest = hashlib.sha256()
    with destination.open("rb") as downloaded:
        for block in iter(lambda: downloaded.read(1024 * 1024), b""):
            digest.update(block)
    actual = digest.hexdigest()
    if actual.lower() != expected.lower():
        raise RuntimeError(f"Official checksum mismatch for {filename}. Download discarded.")


def safe_extract(archive, destination):
    with tarfile.open(archive, "r:xz") as handle:
        for member in handle.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts:
                raise RuntimeError(f"Unsafe SDK archive entry: {member.name}")
            if member.issym() or member.islnk():
                link = PurePosixPath(member.linkname)
                if link.is_absolute():
                    raise RuntimeError(f"Unsafe SDK archive link: {member.name}")
                relative = (path.parent / link) if member.issym() else link
                destination_path = (destination / str(relative)).resolve()
                if not destination_path.is_relative_to(destination.resolve()):
                    raise RuntimeError(f"SDK archive link escapes its directory: {member.name}")
            elif not (member.isfile() or member.isdir()):
                raise RuntimeError(f"Unsupported SDK archive entry: {member.name}")
        handle.extractall(destination)


def install_sdk(workspace):
    version = zephyr_version(workspace)
    if version != (3, 5):
        raise RuntimeError(
            "Automatic SDK setup supports the bundled Zephyr 3.5 firmware. "
            "For another firmware revision, install its compatible SDK manually "
            "and set ZEPHYR_SDK_INSTALL_DIR. Your imported files are unchanged.")
    found = find_sdk(version)
    if found:
        print(f"Reusing compatible Zephyr SDK: {found}", flush=True)
        return found
    if sys.platform != "darwin":
        raise RuntimeError("Automatic Zephyr SDK installation is available on macOS only.")
    architecture = {"arm64": "aarch64", "aarch64": "aarch64",
                    "x86_64": "x86_64"}.get(platform.machine())
    if architecture is None:
        raise RuntimeError("Unsupported Mac architecture; install the SDK manually.")
    base = tools_home()
    target = base / f"zephyr-sdk-{SDK_VERSION}"
    if target.exists():
        raise RuntimeError(f"Incomplete or incompatible SDK at {target}; inspect it before retrying.")
    base.mkdir(parents=True, exist_ok=True)
    minimal = f"zephyr-sdk-{SDK_VERSION}_macos-{architecture}_minimal.tar.xz"
    arm = f"toolchain_macos-{architecture}_arm-zephyr-eabi.tar.xz"
    print(f"Downloading verified Zephyr SDK {SDK_VERSION} and ARM toolchain.", flush=True)
    with tempfile.TemporaryDirectory(prefix="sdk-install-", dir=base) as directory:
        temporary = Path(directory)
        with urllib.request.urlopen(f"{SDK_BASE}/sha256.sum", timeout=60) as response:
            sums = response.read().decode("utf-8")
        for name in (minimal, arm):
            verified_download(name, temporary / name, sums)
        safe_extract(temporary / minimal, temporary)
        staged = temporary / f"zephyr-sdk-{SDK_VERSION}"
        if not staged.is_dir():
            raise RuntimeError("Official SDK archive does not contain the expected directory.")
        safe_extract(temporary / arm, staged)
        if not compatible_sdk(staged, version):
            raise RuntimeError("Downloaded SDK does not contain a usable ARM compiler and CMake metadata.")
        staged.rename(target)
    print(f"Installed compatible ARM toolchain: {target}", flush=True)
    return target


def main(argv):
    if len(argv) != 3 or argv[1] not in ("status", "sdk-path", "install-python", "install-sdk"):
        print("Usage: zephyr_tools.py status|sdk-path|install-python|install-sdk <saved-import-directory>",
              file=sys.stderr)
        return 2
    workspace = Path(argv[2]).resolve()
    if not (workspace / "config/west.yml").is_file():
        print("Saved configuration is missing west.yml; reselect a valid saved import.",
              file=sys.stderr)
        return 2
    if argv[1] == "status":
        print(json.dumps(status(workspace), sort_keys=True))
        return 0
    if argv[1] == "sdk-path":
        selected = find_sdk(zephyr_version(workspace))
        if not selected:
            print("No compatible Zephyr SDK ARM compiler found.", file=sys.stderr)
            return 1
        print(selected)
        return 0
    try:
        if argv[1] == "install-python":
            install_python_tools()
        else:
            install_sdk(workspace)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"Build tools setup failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
