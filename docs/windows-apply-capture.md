# Windows Apply comparison

The supplied capture uses the same Mouse.exe and hiddriver_8k.dll hashes as the earlier static analysis. All ten WriteUSB calls returned 1, and all outer checksums are valid. Windows passes 65 bytes; the final byte is padding. The macOS descriptor allows 64 bytes including report ID, so no command payload is truncated.

The first Apply sends conditional 0x0C initialization, DPI, shared lighting/attributes, polling and buttons, with approximately one second between calls. Later individual edits send only the changed command; no unconditional commit follows them. The capture does not justify blindly sending the conditional initialization command.

The user reports changing Breathe first, then a color associated with DPI, then sensitivity, with immediate LED updates. At the byte level, the color changes are RGB in 0x05: mode 2 becomes 1; RGB 00 00 FF becomes 48 B1 FF and then returns. Subsequent 0x04 packets change stage 2 from 1600 to 4000 and back. All three DPI packets have identical stage color tables. Thus this capture verifies independent live lighting writes, not a stage-color-table refresh command.

## DPI correction

Mouse.exe 0x415B40 reads offsets 0x8B4, 0x93C, 0x940, 0x944 into inner bytes 3, 4, 6, 7. Its UI initialization maps these to LOD, Ripple Control, Angle Snapping and Motion Sync, respectively. Default values are 0, 0, 0, 1. The capture includes a 26000-DPI slot yet bytes 6/7 remain 0/1. These are not high-range DPI masks. Importing a capture preserves its control values; without a capture the 8K codec uses the OEM defaults. Generic transport encoding remains unchanged.

## Shared lighting packet

Mouse.exe 0x4158B3..0x4159AD sends 15 bytes:

| Inner offset | Meaning |
| --- | --- |
| 0..2 | 05 0F 01 |
| 3 high nibble | Mode 0..6 (Off, Static, Breathing, Neon, Color Breathing, Static DPI, Breathing DPI) |
| 4 low nibble | 9 minus UI speed (1..8) |
| 5 low nibble | UI brightness for Static/Static DPI; 8 for other modes |
| 6..8 | RGB |
| 11..12 | Big-endian sum of bytes 3..10 |
| 13..14 | Zero padding |

Other bits/fields share mouse settings and are preserved. The Mac app requires a valid successful Windows baseline before editing lighting, rather than guessing these attributes. Capture import does not transmit anything, does not replay initialization/buttons, and persists the baseline with the local profile. Fixtures contain only protocol frames; proprietary OEM binaries and the user's raw log are not published.
