# SC680Config (macOS Apple Silicon)

Native SwiftUI configurator for **AULA SC680 8K** with Windows-app feature parity.

## Open & build

```bash
open SC680Config.xcodeproj
```

1. Target **My Mac (Apple Silicon)**
2. Signing → your Personal Team
3. Run ⌘R with the 8K dongle plugged in

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
| Angle snap / ripple / debounce | Yes (`0x05/0x0F`) |
| Light | Best-effort OEM frame |
| Profiles import/export | Local JSON + Apply to device |
| Macros | Local library |

Protocol details: [`../docs/protocol.md`](../docs/protocol.md)  
Verification: [`../docs/VERIFY.md`](../docs/VERIFY.md)
