# Glove80 factory recovery firmware

These static UF2 files provide a recovery path that does not use this repository's custom keymap or behavior code. They were built for the left and right Glove80 halves from MoErgo's official factory keymap configuration.

- Factory configuration: https://github.com/moergo-sc/glove80-zmk-config-west/tree/c36e4d78b6c6688190850743050b3e39a156c239
- MoErgo ZMK source: https://github.com/moergo-sc/zmk/tree/4b2f3b9b718a4508e87111cdec24cda16f3c2726
- Left SHA-256: `eed0d8ade69cef45c1220e6b5fe49784f0a895137769bb01a54e97ec50b9f09c`
- Right SHA-256: `0aa6682981a015bea0c84e30945c47379c1f36391f26062273981443a8170076`

Flash both halves with their matching files. Restoring factory firmware does not erase saved Bluetooth or split-pairing settings; perform MoErgo's configuration factory-reset and re-pairing procedure afterward when recovery requires a completely clean state.
