# SC680 protocol evidence

## Sources and confidence

The uploaded installer and ZIP contain byte-identical Mouse.exe and HID drivers.
Mouse.exe SHA-256: `7feaea7482705ddaacb41dc4d40ccce8102304a3623b8dc558e0af0484354a03`.
hiddriver_8k.dll SHA-256: `ef551819adebd979a52ac07f9a0a70e0d22c8e028f4e27f7bb1eacaea0b05f2f`.
Addresses below are PE virtual addresses (EXE image base 0x400000; DLL 0x10000000).
Only protocol facts and independently generated vectors are checked in, not OEM binaries.

The user's receiver is 1D57:FA65. Its compound interface exposes Input IDs 1/2/3/4,
Output ID 4 with 63 payload bytes, and no Feature reports. Shared open succeeds.
Version 1.0.8 received no Input 4 reports and all full configuration reads failed.
Successful OS writes in earlier probes did **not** establish firmware acceptance.

## Confirmed OEM output algorithm

Mouse.exe `0x4150BB..0x4151D6`, invoked through the 8K WriteUSB function pointer:

```
04 [inner_length + 5] 00 [full inner packet] [sum16 big endian] [zero padding]
```

The outer checksum sums every byte before it, including the outer header and the
inner checksum. DPI is nested even though its inner report ID is also 04.
The OEM passes a 65-byte Windows API buffer. macOS uses the descriptor's 64-byte
report, including ID, retaining every command and checksum byte. This platform
length adaptation still needs hardware validation. Inner payloads over 59 bytes
are rejected rather than truncated; macro chunking is not implemented.

### DPI

Mouse.exe `0x415B40..0x415E76` emits **56** bytes, not the historical 52-byte probe:

| Offset | Meaning |
| --- | --- |
| 0..2 | 04 38 01 |
| 3..4 | OEM sensitivity fields |
| 5 | Enabled-stage bit mask |
| 6..7 | OEM X/Y flags |
| 8..15, 16..23 | Eight DPI low/high bytes; 50-DPI units minus one |
| 24 | Active stage, one based |
| 25..48 | Eight RGB triplets |
| 49 | Indication type **1** |
| 50..51 | Sum of bytes 3..49, big endian |
| 52..55 | Zero padding included in the OEM inner length |

The adapter retains existing sensitivity and X/Y model fields. Their complete
meaning and non-default behavior need further capture. The generic Beken model
remains separate from the OEM wire representation. The OEM-derived fixture is
`docs/fixtures/oem_8k_dpi_output.hex`; it is **not** a captured receiver response.
The old `dpi_write_64.hex` is a historical raw API probe only.

### Polling

`0x4159D5..0x415A3B` and the independent receive handler `0x413AB0..0x413B1C`:
inner `06 09 01 code ~code 00 00 00 00`.

| Hz | OEM code |
| --- | --- |
| 125 | 20 |
| 250 | 10 |
| 500 | 08 |
| 1000 | 04 |
| 2000 | 02 |
| 4000 | 01 |
| 8000 | 40 |

These differ from the proposed generic libratbag Beken codes. Translation is
restricted to the SC680 8K output path.

### Buttons and unsupported commands

OEM buttons use 59 inner bytes: `08 3B 01`, 18 triplets, then sum of bytes 3..56
at 57..58. The adapter trims only the generic model's trailing padding. Buttons
still require a valid current read before editing so opaque slots survive.

OEM attributes are **15** bytes with checksum at 11..12 and two padding bytes;
the old 13-byte generic attributes layout does not match. Until its bit fields
are established, the 8K adapter rejects attributes and guessed lighting packets.
It also rejects the old guessed 0C commit and does not send Output-wrapped 80
unlock packets. The OEM sends `0C 0A 01 FE 01 FE 00 00 00 00` **before** changed
settings in a batch; its semantics and persistence are not established, so it is
not substituted as an after-write commit.

## Reads and telemetry

The DLL's Open_FeatureDevice (`0x10002E70`) simply returns 1. GetFeature and ReadUSB
are loaded by Mouse.exe but no 8K call sites were found in the analyzed code.
This does not prove firmware has no full read support.

The DLL monitor (`0x10002630`) passively reads the UsagePage 0A / Usage 0 interface.
It accepts report IDs 3 or 4, decodes two little-endian words from bytes 1..4,
and posts those words to the UI. The 8K UI handler (`0x413A40`) recognizes event
1010 (active stage), 2010 (polling code), 4010 (connection/charging and battery),
and others. These short events are **not** complete DPI/attributes/button dumps.
Input 3 prefixes/counts are now included in diagnostics but are not converted to
fabricated complete configuration or accepted as write verification.

Existing Feature/GET_REPORT/validated interrupt read paths remain diagnostic
fallbacks. No guessed output read commands are sent. Readback and persistence
remain unverified on the physical device. Capture OEM startup, one DPI change,
Apply, and its replies with USBPcap/Wireshark to resolve remaining sequence gaps.
