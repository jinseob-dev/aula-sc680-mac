# SC680Config (macOS Apple Silicon)

Native SwiftUI configurator for **AULA SC680 8K**. Implemented device settings are verified by readback when the receiver provides a valid response.

## Open & build

```bash
open SC680Config.xcodeproj
```

1. Target **My Mac (Apple Silicon)**
2. Signing → your Personal Team
3. Run ⌘R with the 8K dongle plugged in

## Install file (DMG) for MacBook

On a Mac with Xcode installed:

```bash
cd macos
chmod +x scripts/make-installer.sh
./scripts/make-installer.sh
```

Outputs under `macos/build/`:

- `SC680Config-<version>-build<n>-macOS-arm64.dmg` — open it, drag **SC680Config** into **Applications**
- `SC680Config-<version>-build<n>-macOS-arm64.zip` — same app bundle, for manual copy

The script ad-hoc signs the app (`CODE_SIGN_IDENTITY=-`). On first launch, macOS may block it: **Control-click → Open**, or run `xattr -cr /Applications/SC680Config.app`.

**GitHub Actions:** push a tag like `v1.0.0`, or run the **macOS installer** workflow manually; download the DMG/ZIP from the workflow artifacts (releases attach files for version tags).

Requires **macOS 13+** and **Apple Silicon** (M1/M2/M3/M4).

## Layout

```
SC680Config/
  SC680ConfigApp.swift
  HID/           # IOHIDManager transport
  Protocol/      # Beken BK3633 codec + 8K wrap
  Models/        # DeviceStore, profiles, macros
  Views/         # Buttons DPI Light Polling Attrs Power Macros Profiles
  *.entitlements # USB, no sandbox
```

## Features

| Area | Status |
|------|--------|
| Device detect `1D57:FA65` / `3554:FA09` | Yes |
| DPI read/write | Yes (Beken `0x04/0x38`) |
| Polling 125–8000 | Yes (`0x06/0x09` + 8K wrap) |
| Buttons | Yes (`0x08/0x3B`) |
| Battery | Yes (`0x01`) |
| Angle snap / ripple / debounce | Device write + readback (`0x05/0x0F`); debounce uses 2 ms steps |
| LOD / sleep timer / Move Wake | Local profile storage only; device commands are not implemented |
| Light | Best-effort OEM frame |
| Profiles import/export | Local JSON + Apply to device |
| Macros | Local library only; assignment and playback are not implemented |
| Easy Aim / shortcuts | Not implemented; unavailable for assignment |

Protocol details: [`../docs/protocol.md`](../docs/protocol.md)  
Verification: [`../docs/VERIFY.md`](../docs/VERIFY.md)

## Apply and recovery behavior

HID operations run on a serial worker queue. Apply and Rescan disable concurrent
operations while they are running. Writes are followed by readback; a mismatch or
unavailable response remains visible in the status instead of being reported as
verified success. Light writes are experimental and always reported as unverified.

Button read and write use the same six-button mapping. Middle is the wheel click.
Before applying buttons, the app reads the original packet and preserves unmapped
slots and unchanged action parameters. If that read fails and no valid packet is
cached for the current receiver, button Apply stops rather than erasing unknown
settings. Rescan preserves DPI stage enable bits, colors, and Motion Sync.

Profile import validates array lengths, IDs, active stage, ranges, and finite
numbers before changing the selected profile. Older seven-button exports migrate
by dropping the duplicate Scroll row. Invalid saved profiles are skipped on load.

## Regression checks

On macOS with Xcode command-line tools:

```bash
bash macos/scripts/run-regression-tests.sh # run from repository root
```

The checks use the captured Windows DPI fixture and a mock device session. They
cover packet validation, requested response routing, button/DPI preservation,
readback notices, profile validation, and overlapping operations. GitHub Actions
also builds the full SwiftUI app on pull requests. Hardware behavior still needs
the functional checks in `docs/VERIFY.md`.
