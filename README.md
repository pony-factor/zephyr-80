# Glove80 Mac

macOS tools for flashing Glove80 firmware, reading battery levels, and optionally controlling charging through a compatible USB hub. Requires macOS 13 or later.

Build the app with `./macOS/build-app.sh`, then open `macOS/Glove80 Flasher.app` from this checkout. The build needs Xcode command line tools. The app uses a neutral keyboard icon and generic bootloader instructions; follow the bindings in your own firmware.

Place a matching firmware pair in `firmware/` as `glove80_lh-zmk.uf2` and `glove80_rh-zmk.uf2`. Connect each half by USB and enter its bootloader. The app detects `GLV80LHBOOT` or `GLV80RHBOOT` and copies the matching file. The Pull Repo button runs `git pull --ff-only`. Locally supplied UF2 files are ignored by Git. No firmware is bundled with this initial host-tools migration.

Restore Previous Build requires firmware and build metadata in repository history. Restore Factory Firmware requires an independently obtained factory pair in `firmware/factory/`. These actions report unavailable when those files are absent.

Charge Guard is optional and disabled until enabled in its settings or installed with `bash macOS/install-charge-guard.sh`. It defaults to an 80% cutoff and 70% resume threshold, both configurable. It needs `uhubctl` and a hub that actually switches USB charging power; cutting power also disconnects USB data. Pair Bluetooth before enabling it. Setup requires a safe two-port mapping and checks whether the reported cutoff survives removing charging power. Battery visibility depends on macOS and firmware support; stock firmware may not expose both halves independently.

The optional screen sleep/wake helper is installed with `bash macOS/install-screen-rgb-sync.sh`. It needs compatible firmware that implements the marked HID LED protocol; enabling community per-key RGB alone does not provide that protocol. It is disabled until installed. Installation requests administrator authentication for a root-owned LaunchDaemon, plus a user LaunchAgent for display events. Allow the system binary under Input Monitoring if required.

The helper sends Compose as the protocol marker, Kana for display awake, Num Lock to request brightness restoration on wake, and Scroll Lock for shutdown/restart. It preserves the ordinary Caps Lock bit. Firmware must implement these semantics on both halves. Stock firmware does not implement this integration.

The installer uses separate `Glove80 Mac` support/log directories and `io.github.JFWooten4.glove80-mac` service labels. It does not replace an older installation; disable any previous screen-sync service before installing this one so two helpers do not send conflicting reports.

Community RGB firmware is being migrated separately.
