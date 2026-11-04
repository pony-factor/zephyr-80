#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMPORT_ID="${1:?Usage: build-user-config.sh <import ID> [--rgb-patches]}"
RGB_PATCHES=""
INSTALL_TOOLS=false
for argument in "$@"; do
  case "$argument" in
    "$IMPORT_ID") ;;
    --rgb-patches) RGB_PATCHES=--rgb-patches ;;
    --install-tools) INSTALL_TOOLS=true ;;
    *) echo 'Usage: build-user-config.sh <import ID> [--rgb-patches] [--install-tools]' >&2; exit 1 ;;
  esac
done
# Import IDs are generated UUIDs, never paths or shell fragments.
if [[ ! "$IMPORT_ID" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
  echo 'Pass the import ID shown by the app.' >&2
  exit 1
fi
WORKSPACE="$REPO_ROOT/user-config/$IMPORT_ID"
[[ -f "$WORKSPACE/config/west.yml" ]] || { echo 'Imported configuration not found.' >&2; exit 1; }
TOOLS_HOME="$HOME/Library/Application Support/Glove80 Mac/Tools"
export PATH="$TOOLS_HOME/venv/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
if "$INSTALL_TOOLS"; then
  # Installation only runs after explicit confirmation in the app.
  python3 "$REPO_ROOT/scripts/zephyr_tools.py" install-python "$WORKSPACE"
fi
for program in west cmake ninja; do
  command -v "$program" >/dev/null || {
    echo "Missing $program. Choose Install & Build in Glove80 Flasher, or install it manually." >&2
    exit 20
  }
done
cd "$WORKSPACE"
if [[ ! -d .west ]]; then west init -l config; fi
west update --fetch-opt=--filter=tree:0
# Choose the SDK against the actual checked-out Zephyr revision.
if ! python3 "$REPO_ROOT/scripts/zephyr_tools.py" sdk-path "$WORKSPACE" >/dev/null; then
  if "$INSTALL_TOOLS"; then
    python3 "$REPO_ROOT/scripts/zephyr_tools.py" install-sdk "$WORKSPACE"
  else
    echo "A compatible Zephyr SDK with the ARM toolchain was not found. Choose Install & Build, then retry the saved import." >&2
    exit 21
  fi
fi
export ZEPHYR_SDK_INSTALL_DIR="$(python3 "$REPO_ROOT/scripts/zephyr_tools.py" sdk-path "$WORKSPACE")"
export ZEPHYR_TOOLCHAIN_VARIANT=zephyr
if "$INSTALL_TOOLS"; then
  python3 -m pip install --disable-pip-version-check -r "$WORKSPACE/zephyr/scripts/requirements.txt"
fi
# The bundled profiles use these pinned, supported upstream versions.
ZMK_REVISION="$(git -C zmk rev-parse HEAD)"
case "$ZMK_REVISION" in
  ce69e85f585c724142aae37ddf8a7e019ff19e93|8aeaaa66fbb4b94948c8763e06f1920ab0b69480)
    python3 "$REPO_ROOT/scripts/apply-rgb-patches.py" "$WORKSPACE/zmk" ;;
  *)
    if [[ "$RGB_PATCHES" == --rgb-patches ]]; then
      python3 "$REPO_ROOT/scripts/apply-rgb-patches.py" "$WORKSPACE/zmk"
    fi ;;
esac
west zephyr-export
# Keep the last complete firmware pair intact if either new half fails.
OUTPUT="$(mktemp -d "$WORKSPACE/.firmware.XXXXXX")"
trap 'rm -rf "$OUTPUT"' EXIT
for side in lh rh; do
  west build -p always -s zmk/app -d "build-$side" -b "glove80_$side" -- -DZMK_CONFIG="$WORKSPACE/config"
  cp "build-$side/zephyr/zmk.uf2" "$OUTPUT/glove80_$side-zmk.uf2"
done
mkdir -p firmware
cp "$OUTPUT/"*.uf2 firmware/
echo "Firmware pair built in: $WORKSPACE/firmware"
echo 'Select that folder with Use Firmware… in Glove80 Flasher.'
