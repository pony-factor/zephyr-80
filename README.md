# Glove80 Mac

macOS tools for flashing Glove80 firmware, reading battery levels, and optionally controlling charging through a compatible USB hub. Requires macOS 13 or later.

Build the app with `./macOS/build-app.sh`, then open `macOS/Glove80 Flasher.app` from this checkout. The build needs Xcode command line tools. The app uses a neutral keyboard icon and generic bootloader instructions; follow the bindings in your own firmware.

Place a matching firmware pair in `firmware/` as `glove80_lh-zmk.uf2` and `glove80_rh-zmk.uf2`. Connect each half by USB and enter its bootloader. The app detects `GLV80LHBOOT` or `GLV80RHBOOT` and copies the matching file. The Pull Repo button runs `git pull --ff-only`. Locally supplied UF2 files are ignored by Git. The app bundles a separate fixed factory recovery pair.

## Bring your own configuration

Choose **Import ZMK…** and select one of these local inputs:

- A `.keymap` source file. The importer saves it as `glove80.keymap` and supplies the selected profile's settings and firmware manifest.
- A configuration folder laid out like the example below.
- A repository folder with a `config/` folder inside it. Only that `config/` folder is imported, so keep any required supporting source files inside it.

```text
my-config/
├── glove80.keymap       # Your key bindings and layers
├── glove80.conf         # Optional: your firmware settings
├── west.yml             # Optional: your firmware fork and revision
├── support/             # Optional: local module source and supporting files
│   ├── CMakeLists.txt
│   ├── Kconfig
│   └── my_feature.c
└── zephyr/              # Optional: registers the local module
    └── module.yml
```

Only the keymap is required for import. `support/` is a suggested name, not a required folder. Keep relative include paths and module paths consistent with your own layout. If your setup needs external modules, declare them in `west.yml`; files outside the selected configuration folder are not copied.

### File names and formatting

| File | Format and expectations |
| --- | --- |
| `glove80.keymap` | Plain-text ZMK devicetree source, including its required `#include` directives. Keep the Glove80 binding order and 80 key positions per layer. A JSON layout export, image, or compiled `.uf2` is not a keymap source file. |
| `glove80.conf` | Plain-text Kconfig settings, one assignment per line, such as `CONFIG_ZMK_RGB_UNDERGLOW=y`. Use `y` or `n` for Boolean settings and `#` for comments. Setting names must be supported by your selected firmware. |
| `west.yml` | YAML manifest selecting the firmware and dependencies. Use spaces for indentation, preserve its nesting, and set `manifest.self.path` to `config` for the supplied build script. |
| `zephyr/module.yml` | YAML metadata for an optional local module. Its build paths are relative to the configuration folder; the example below matches the tree above. |

```yaml
name: my-config
build:
  cmake: support
  kconfig: support/Kconfig
```

For a folder import, place the keymap directly at the configuration root. Use `glove80.keymap`, or a matching pair named `glove80_lh.keymap` and `glove80_rh.keymap`. A lone differently named `.keymap` file is renamed to `glove80.keymap`; multiple differently named keymaps are rejected unless one of the supported names or the complete pair is present. Include the settings, headers, overlays, and modules referenced by your keymap rather than importing only the keymap when it depends on those files.

The firmware selector supplies `west.yml` and `glove80.conf` only when each file is absent. Existing files are preserved; defaults are not merged into them. Selecting Community RGB does not rewrite an existing manifest, keymap, or configuration to add RGB support. To start with per-key RGB, copy `config/community-rgb/`, edit its keymap and settings, then import that folder. Its `&ug 0xRRGGBB` color cells use six hexadecimal digits and follow the key positions in the example; preserve the map's structure and set `layer-id` to the corresponding keymap layer index, starting at zero. These color maps require the community firmware fork.

Each import creates a separate `user-config/<import-ID>/config/` directory ignored by Git; the source files remain untouched. The importer copies `.keymap`, `.conf`, `.dtsi`, `.dts`, `.overlay`, `.c`, `.h`, `.yaml`, `.yml`, and `.patch` files, plus `CMakeLists.txt`, `Kconfig`, and `Kconfig.*`. It preserves the top-level `zephyr/` module metadata folder. Hidden files, credential filenames, symbolic links, dependency/build folders, and other file types are skipped. Python tests and shell scripts are not copied. Keep the original repository for files outside this list. No imported files are committed or uploaded.

### Build and flash

Import checks file selection and keymap names; it does not validate ZMK syntax or firmware compatibility. After import, run the command shown by the app from this repository's root:

```sh
./scripts/build-user-config.sh <import-ID>
```

Replace `<import-ID>` with the generated ID shown by the app. The build requires an installed `west` command and a compatible Zephyr SDK/toolchain, fetches the imported manifest's dependencies, and compiles both halves. Importing alone does not build or flash anything. Resolve compiler errors before flashing.

The builder applies the shared RGB patches automatically for the bundled pinned firmware revisions, as described below. Your imported `.patch` files are retained as source only and are not applied automatically. If your configuration needs them, prepare a manual build workspace, apply the shared RGB patches first and your patches afterward, then compile. The local build commands below show the manual workflow.

Choose **Use Firmware…** to select the resulting `user-config/<import-ID>/firmware/` folder, then connect each half in bootloader mode. The selector also accepts any local folder containing `glove80_lh-zmk.uf2` and `glove80_rh-zmk.uf2`, without overwriting the repository's firmware files.

## Recovery and optional helpers

Restore Previous Build requires firmware and build metadata in repository history. **Restore Factory Firmware** uses the fixed MoErgo factory pair bundled in the app, with a checkout fallback under `firmware/factory/`. The original factory keymap is included alongside the UF2 files for reference. The build checks the recorded SHA-256 hashes before packaging the recovery files. Selecting factory recovery uses the existing flashing flow; flash both halves, then factory-reset and re-pair if needed. It does not overwrite an imported configuration. Factory recovery does not include community RGB or the screen-sync protocol.

Charge Guard is optional and disabled until enabled in its settings or installed with `bash macOS/install-charge-guard.sh`. It defaults to an 80% cutoff and 70% resume threshold, both configurable. It needs `uhubctl` and a hub that actually switches USB charging power; cutting power also disconnects USB data. Pair Bluetooth before enabling it. Setup requires a safe two-port mapping and checks whether the reported cutoff survives removing charging power. Battery visibility depends on macOS and firmware support; stock firmware may not expose both halves independently.

The optional screen sleep/wake helper is installed with `bash macOS/install-screen-rgb-sync.sh`. It needs compatible firmware that implements the marked HID LED protocol; enabling community per-key RGB alone does not provide that protocol. It is disabled until installed. Installation requests administrator authentication for a root-owned LaunchDaemon, plus a user LaunchAgent for display events. Allow the system binary under Input Monitoring if required.

The helper sends Compose as the protocol marker, Kana for display awake, Num Lock to request brightness restoration on wake, and Scroll Lock for shutdown/restart. It preserves the ordinary Caps Lock bit. Firmware must implement these semantics on both halves. Stock firmware does not implement this integration.

The installer uses separate `Glove80 Mac` support/log directories and `io.github.JFWooten4.glove80-mac` service labels. It does not replace an older installation; disable any previous screen-sync service before installing this one so two helpers do not send conflicting reports.

## Bundled firmware and RGB

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
