# AULA SC680 8K — HID protocol evidence and remaining gaps

Interoperability notes for rebuilding the Windows OEM configurator on macOS.

## Devices

| Role | VID | PID | Product | Config interface |
|------|-----|-----|---------|------------------|
| 8K HS dongle | `0x1D57` | `0xFA65` | 2.4G 8K HS Receiver | UsagePage `0xFF00`, **Out/In 64**, report ID **`0x04` only** for Output |
| Standard dongle | `0x3554` | `0xFA09` | 2.4G Wireless Receiver | `0xFF02` In/Out 20; `0xFF04` Feature 8 |

Chipset: Beken **BK3633**. OEM stack: SOAI `hiddriver_8k.dll` (stdcall).

## Boot sequence (captured)

```
Set_VIDPID(1D57, FA65)
Open_DevMonitor
Open_FeatureDevice => 1
Open_ReportDevice => 1
```

## Command format (confirmed in `Mouse.exe`)

These packet layouts match the proposed Beken BK3633 driver in [libratbag PR #1849](https://github.com/libratbag/libratbag/pull/1849). This is a reference for packet layout, not proof that SC680 firmware supports that driver’s Feature reads. OEM machine code builds:

| Report ID | Command byte | Purpose | Struct size |
|-----------|--------------|---------|-------------|
| `0x01` | — | Battery | 7 |
| `0x04` | `0x38` | DPI + DPI colors | 52 |
| `0x05` | `0x0F` | Params (debounce, angle snap, ripple) | 13 |
| `0x06` | `0x09` | Polling rate | 9 |
| `0x08` | `0x3B` | Buttons | 59–64 |
| `0x0C` | — | Apply | — |
| `0x80` | — | Unlock / WebHID init | 7 |

Profile field is typically `0x01`.

### DPI (`0x04 0x38`)

```
[0]  report_id = 0x04
[1]  command   = 0x38
[2]  profile   = 0x01
[3]  sens_x
[4]  sens_y
[5]  slot enable bitmask
[6]  dpi_x double flag (>12000)
[7]  dpi_y double flag
[8..15]   dpi low bytes  (value = (DPI-50)/50)
[16..23]  dpi high bytes
[24]      active slot (1-based)
[25..48]  8 × RGB
[49]      indication type (2)
[50..51]  checksum = sum(bytes[3..49]) as u16 BE
```

### Rate (`0x06 0x09`)

```
[0]=0x06 [1]=0x09 [2]=profile
[3]=interval  0x01=1000 0x02=500 0x04=250 0x08=125
    SC680 UI also offers 2000/4000/8000 — extended codes used by OEM (capture when available)
[4]=checksum = ~interval
```

### Params (`0x05 0x0F`)

```
[0]=0x05 [1]=0x0F [2]=profile
[5]=debounce_time  (ms/2)
[10]=flags  bit1=angle snap, bit2=ripple
[12]=checksum = buf[4]+buf[5]+buf[10]
```

### Buttons (`0x08 0x3B`)

18 slots × 3 bytes. Common action codes:  
`0x02` left, `0x03` right, `0x04` middle, `0x05` back, `0x06` forward, `0x0D` DPI cycle, `0x01` off.

Checksum: sum of bytes `[3..56]` as u16 BE at `[57..58]`.

### Unlock (before commit)

```
80 01 03 20 50 00 04
80 01 03 20 41 02 64
```

## 8K transport rules (probed)

- `WriteUSB(buf, 64)` succeeds only when **`buf[0] == 0x04`** and **len == 64**.
- Native DPI packet already starts with `0x04` → send padded to 64 bytes.
- Packets whose Beken report id ≠ `0x04` (rate/param/button): send as  
  **`[0x04] + full_beken_packet...` padded to 64**, **or** `SetFeature(beken_packet)` when the Feature collection accepts it (wired / some dongles).
- A user hardware log from macOS 27.0.1 / SC680Config 1.0.7 confirms shared open succeeds on a compound Generic Desktop primary interface with vendor usages and Output `0x04`/64. No Feature elements were exposed (`Feature=[]`, maximum size 1). All configuration reads failed. Opening `Open_FeatureDevice` in the Windows DLL is not proof that Feature `0x80` exists in this receiver’s descriptor.
- On receivers that expose Feature `0x80`, macOS can use that unlock path. Otherwise the existing Output-wrapped unlock is unconfirmed; successful USB transfer does not prove firmware acceptance.
- Version 1.0.8 adds interrupt Input `0x04` reception as an alternative to control `GET_REPORT`, but only when Input `0x04` is present in the descriptor. It accepts only validated requested responses and rejects responses older than the latest Output write/open. Scan sends no guessed read commands or settings writes.
- Windows verification establishes accepted write framing, not the read-request sequence or firmware persistence. The actual 8K read-request/response protocol remains unverified. If no valid Input response arrives, obtain an OEM capture including requests and replies before implementing a new request envelope. Do not send an all-zero DPI structure as a read request: it can be a destructive settings write.
- Copied connection details include Input/Output/Feature IDs and sizes, the configuration interface’s raw report descriptor, actual read errors, and a bounded vendor Input `0x04` prefix/count. Mouse/keyboard input reports are ignored.

## Capture tooling

- Proxy: `tools/hid_proxy/hiddriver_8k.dll` (+ `.def` undecorated exports)
- Runner: `tools/run_capture.ps1`
- Log: `%TEMP%\sc680_hid_capture.log`
