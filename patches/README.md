# Shared RGB power patches

The `stock/` variants target the pinned MoErgo ZMK revision. The `community-rgb/` variants target the pinned darknao fork and preserve its transient and per-layer RGB paths. The manifests under `config/` record the supported revisions.

Apply suspend support before fade-off. Run `python3 scripts/apply-rgb-patches.py <zmk-checkout>` to select the matching variants, check compatibility, and apply both together. The script preserves unrelated edits, recognizes repeated application, and leaves incompatible sources unchanged.

Fade-off scales each currently displayed pixel toward black over a configurable interval, retaining LED power until completion. It changes no palettes, hue, saturation, startup effect, or key bindings. The community implementation also handles transient on/off transitions.

Suspend support combines enabled idle, USB-power, and USB-suspend gates and restores the pre-sleep lighting state. It is opt-in through `CONFIG_ZMK_RGB_UNDERGLOW_AUTO_OFF_USB_SUSPEND=y`. It is independent of the optional display-state HID protocol.

Test patched upstream functions with `python3 tests/test_rgb_patches.py <zmk-checkout>`. The tests compile fade and suspend both enabled and disabled, including power-off fallback, wake cancellation, and community layer events. Full Zephyr builds and hardware tests are still required to validate device behavior.
