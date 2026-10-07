# AULA SC680 → Mac Silicon config app

Native **Apple Silicon** replacement for the Windows-only SC680 8K mouse software.

## Quick start (Mac)

```bash
cd macos
open SC680Config.xcodeproj
```

See [`macos/README.md`](macos/README.md) and [`docs/VERIFY.md`](docs/VERIFY.md).

## Repo map

| Path | Purpose |
|------|---------|
| [`macos/SC680Config/`](macos/SC680Config/) | SwiftUI app sources + Xcode project |
| [`docs/protocol.md`](docs/protocol.md) | Confirmed Beken/8K HID protocol |
| [`docs/VERIFY.md`](docs/VERIFY.md) | Mac + Windows cross-check checklist |
| [`sc680-windows/`](sc680-windows/) | OEM app copy (reference) |
| [`tools/hid_proxy/`](tools/hid_proxy/) | Logging DLL for OEM capture |
| [`tools/verify_windows_protocol.ps1`](tools/verify_windows_protocol.ps1) | Windows transport self-test |

## Protocol summary

- Dongle: **`1D57:FA65`** (8K), **`3554:FA09`** (standard)
- Commands: Beken BK3633 feature reports (`DPI 0x04/0x38`, `Rate 0x06/0x09`, `Param 0x05/0x0F`, `Button 0x08/0x3B`)
- 8K transport: Output report **ID `0x04`**, 64 bytes (`WriteUSB`); non-`0x04` Beken packets are wrapped
