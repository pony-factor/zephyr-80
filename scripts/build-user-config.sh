#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMPORT_ID="${1:?Usage: build-user-config.sh <import ID> [--rgb-patches]}"
RGB_PATCHES="${2:-}"
if [[ "$#" -gt 2 || ( -n "$RGB_PATCHES" && "$RGB_PATCHES" != --rgb-patches ) ]]; then
  echo 'Usage: build-user-config.sh <import ID> [--rgb-patches]' >&2
  exit 1
fi
# Import IDs are generated UUIDs, never paths or shell fragments.
if [[ ! "$IMPORT_ID" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
  echo 'Pass the import ID shown by the app.' >&2
  exit 1
fi
WORKSPACE="$REPO_ROOT/user-config/$IMPORT_ID"
[[ -f "$WORKSPACE/config/west.yml" ]] || { echo 'Imported configuration not found.' >&2; exit 1; }
command -v west >/dev/null || { echo 'Install west and a compatible Zephyr SDK before building.' >&2; exit 1; }
cd "$WORKSPACE"
if [[ ! -d .west ]]; then west init -l config; fi
west update --fetch-opt=--filter=tree:0
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
