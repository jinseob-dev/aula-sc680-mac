# SC680Config verification checklist

## Windows protocol checks (done on this machine)

- [x] Enumerate dongle `1D57:FA65` (8K) and `3554:FA09` (standard)
- [x] Confirm Output report ID `0x04`, length 64 for 8K `WriteUSB`
- [x] Confirm `Mouse.exe` builds Beken frames `04 38` / `05 0F` / `06 09` / `08 3B`
- [x] Proxy capture of boot: `Set_VIDPID` → Feature/Report open
- [x] Successful `WriteUSB` of full DPI 52-byte packet padded to 64
- [x] Automated transport self-test `tools/verify32.ps1` → `VERIFY_EXIT=0` (see `fixtures/windows_verify_result.txt`)

## Apple Silicon Mac — build

1. Copy `aula/macos` to the Mac.
2. Open `SC680Config.xcodeproj` in Xcode 15+.
3. Select **My Mac (Apple Silicon)**.
4. Signing: Personal Team / Sign to Run Locally.
5. Entitlements: USB enabled, App Sandbox off (see `SC680Config.entitlements`).
6. Run (⌘R).

## Apple Silicon Mac — functional tests

### Connection

- [ ] Plug **8K 2.4G receiver** → app shows **2.4G 8K** and product string
- [ ] Unplug → Rescan shows No Device
- [ ] Plug **USB-C wired** (if exposed as same VID/PID family) → connects
- [ ] BT mode: pointer works, advanced config may be unavailable (expected)

### MVP

- [ ] Change DPI stage / active stage → **Apply** → wheel LED / feel matches
- [ ] Set polling 125 → 1000 → 8000 → Apply → verify in Windows OEM app if dual-boot, or by feel
- [ ] Remap Forward/Back → Apply → test in browser
- [ ] Battery percentage appears when wireless

### Parity

- [ ] Light mode / color / brightness Apply
- [ ] Angle snap / ripple / debounce Apply
- [ ] Profile add / export / import / reset
- [ ] Macro create (local library)

### Cross-check with Windows OEM

1. Apply a distinctive DPI set on Mac (e.g. 1200 / 2400 / 4800).
2. Boot Windows, open OEM `Mouse.exe`.
3. Confirm the same DPI values are shown (or sensor feel matches if UI caches).

### Recovery

If the mouse misbehaves after a bad write:

1. Connect USB-C wired.
2. Open Windows OEM app → Reset profile.
3. Power-cycle mouse.

## Automated regressions (macOS)

Run `bash macos/scripts/run-regression-tests.sh` from the repository root. The
`macOS checks` workflow runs the same tests and builds the app on pull requests.
Mock tests verify app behavior; they do not establish firmware support.

## Settings preservation and failure reporting

- [ ] Set a custom Middle action and distinct Forward/Back actions; Apply, Rescan,
      and verify the same assignments remain.
- [ ] Disable DPI stages 6–8 and set distinctive stage colors; Rescan then Apply
      must preserve both the disabled mask and colors.
- [ ] Disconnect or prevent readback during Apply; status must remain unverified
      or failed, never claim all settings were verified.
- [ ] Change LOD, Sleep Timer, and Move Wake; UI must identify local storage only.
- [ ] Apply during receiver reset; UI stays responsive and duplicate operations
      are disabled.
- [ ] Power-cycle the mouse after a verified write to check persistence separately.
