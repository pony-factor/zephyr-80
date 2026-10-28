# Glove80 Mac

macOS tools for flashing Glove80 firmware, reading battery levels, and optionally controlling charging through a compatible USB hub. Requires macOS 13 or later.

Build the app with `./macOS/build-app.sh`, then open `macOS/Glove80 Flasher.app` from this checkout. The build needs Xcode command line tools. The app uses a neutral keyboard icon and generic bootloader instructions; follow the bindings in your own firmware.

Place a matching firmware pair in `firmware/` as `glove80_lh-zmk.uf2` and `glove80_rh-zmk.uf2`. Connect each half by USB and enter its bootloader. The app detects `GLV80LHBOOT` or `GLV80RHBOOT` and copies the matching file. The Pull Repo button runs `git pull --ff-only`. Locally supplied UF2 files are ignored by Git. The app bundles a separate fixed factory recovery pair.

Choose **Import ZMK…** to import a local `.keymap` file, a configuration folder, or a repository folder containing `config/`. Each import gets a separate `user-config/<import-ID>/config/` directory ignored by Git. Original files remain untouched. A single keymap is named `glove80.keymap`; configuration folders keep their supporting files, modules, manifest, and settings. Hidden files, credential filenames, symbolic links, build outputs, and unrelated file types are skipped. No imported files are committed or uploaded.

The firmware selector in the import dialog supplies `west.yml` and `glove80.conf` only if they are absent. An existing manifest continues to select the user's firmware fork. Selecting Community RGB does not rewrite an existing manifest, keymap, or configuration to add RGB mappings.

After import, build explicitly with `./scripts/build-user-config.sh <import-ID>`. This requires an installed `west` command and a compatible Zephyr SDK/toolchain. The build fetches the imported manifest's dependencies and compiles both halves; importing alone does not build or flash anything. The app shows the command and offers to reveal the saved configuration. Choose **Use Firmware…** to select the resulting `user-config/<import-ID>/firmware/` folder, then connect each half in bootloader mode. This selection also accepts any local folder containing a matching UF2 pair, without overwriting the repository's firmware files.

Restore Previous Build requires firmware and build metadata in repository history. **Restore Factory Firmware** uses the fixed MoErgo factory pair bundled in the app, with a checkout fallback under `firmware/factory/`. The original factory keymap is included alongside the UF2 files for reference. The build checks the recorded SHA-256 hashes before packaging the recovery files. Selecting factory recovery uses the existing flashing flow; flash both halves, then factory-reset and re-pair if needed. It does not overwrite an imported configuration. Factory recovery does not include community RGB or the screen-sync protocol.

Charge Guard is optional and disabled until enabled in its settings or installed with `bash macOS/install-charge-guard.sh`. It defaults to an 80% cutoff and 70% resume threshold, both configurable. It needs `uhubctl` and a hub that actually switches USB charging power; cutting power also disconnects USB data. Pair Bluetooth before enabling it. Setup requires a safe two-port mapping and checks whether the reported cutoff survives removing charging power. Battery visibility depends on macOS and firmware support; stock firmware may not expose both halves independently.

The optional screen sleep/wake helper is installed with `bash macOS/install-screen-rgb-sync.sh`. It needs compatible firmware that implements the marked HID LED protocol; enabling community per-key RGB alone does not provide that protocol. It is disabled until installed. Installation requests administrator authentication for a root-owned LaunchDaemon, plus a user LaunchAgent for display events. Allow the system binary under Input Monitoring if required.

The helper sends Compose as the protocol marker, Kana for display awake, Num Lock to request brightness restoration on wake, and Scroll Lock for shutdown/restart. It preserves the ordinary Caps Lock bit. Firmware must implement these semantics on both halves. Stock firmware does not implement this integration.

The installer uses separate `Glove80 Mac` support/log directories and `io.github.JFWooten4.glove80-mac` service labels. It does not replace an older installation; disable any previous screen-sync service before installing this one so two helpers do not send conflicting reports.

Two independent firmware profiles live under `config/`. The `stock` profile uses pinned MoErgo firmware and its built-in keymap. The `community-rgb` profile uses the pinned community RGB fork, an unchanged upstream keymap, and a neutral per-key map with all cells unlit. Lighting starts off in both profiles. Both profiles apply the shared color-independent RGB patches described below. No custom color effects are included.

The `community-rgb` branch provides the same clean starting point without importing history from another configuration. The firmware workflow builds both profiles for both halves. Download the two artifacts for the same profile and run, then copy their UF2 files and matching `build-status.json` into `firmware/`. The app checks build metadata against the checkout when it is present. These profiles do not include the optional screen-sync firmware protocol.

For local builds, copy the selected profile to a separate workspace as `config/`, then run `west init -l config`, `west update`, `python3 <glove80-mac-checkout>/scripts/apply-rgb-patches.py <workspace>/zmk`, `west zephyr-export`, and `west build -s zmk/app -b glove80_lh -- -DZMK_CONFIG=<absolute-config-directory>`. Build the right half in another build directory using `-d build-rh -b glove80_rh`.

For per-key colors, edit the `&ug 0x000000` cells in the community profile. Each cell corresponds to the same position in the stock keymap. Add maps with other `layer-id` values as needed; cycle to the fork's layer indicator effect and enable RGB using the existing stock RGB controls. Runtime RGB settings persist across flashes. Firmware compilation and actual LED behavior must be verified before relying on a modified map.

Upstream firmware and keymap sources:

- https://github.com/moergo-sc/zmk/tree/ce69e85f585c724142aae37ddf8a7e019ff19e93
- https://github.com/darknao/zmk/tree/8aeaaa66fbb4b94948c8763e06f1920ab0b69480

The community keymap retains its upstream copyright and MIT license notice.

The shared RGB patches preserve the selected color values and effect. Fade-off dims the current pixel buffer to black over 1.5 seconds, then releases LED power. It is enabled in both bundled build profiles; set `CONFIG_ZMK_RGB_UNDERGLOW_FADE_OFF=n` to disable it or change `CONFIG_ZMK_RGB_UNDERGLOW_FADE_OFF_MS` to adjust its duration.

USB suspend auto-off is available but disabled by default. Set `CONFIG_ZMK_RGB_UNDERGLOW_AUTO_OFF_USB_SUSPEND=y` to opt in. It remembers the pre-suspend RGB state and restores it on resume, while respecting any enabled idle and USB-power gates. The community version retains per-layer RGB handling. USB suspend can happen during a screensaver, so leave this disabled when using the optional helper to follow actual display sleep. These patches do not add the helper's HID firmware protocol.

The user-configuration builder applies these patches automatically for the two bundled pinned ZMK revisions. For another compatible upstream revision, opt in with `./scripts/build-user-config.sh <import-ID> --rgb-patches`. Patch compatibility is checked before changing upstream files, and repeated application is supported. The original custom color patch remains outside this repository.
