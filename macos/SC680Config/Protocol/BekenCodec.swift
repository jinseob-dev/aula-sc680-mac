import Foundation

/// Beken BK3633 report codec (same framing as AULA SC680 OEM / libratbag driver-beken).
enum BekenCodec {
    static let dpiReportID: UInt8 = 0x04
    static let paramReportID: UInt8 = 0x05
    static let rateReportID: UInt8 = 0x06
    static let buttonReportID: UInt8 = 0x08
    static let batteryReportID: UInt8 = 0x01
    static let applyReportID: UInt8 = 0x0C
    static let unlockReportID: UInt8 = 0x80
    /// OEM light frames on some BK3633 mice (not always present on 8K dongle Feature list).
    static let lightReportIDLegacy: UInt8 = 0x07

    static let dpiCommand: UInt8 = 0x38
    static let paramCommand: UInt8 = 0x0F
    static let rateCommand: UInt8 = 0x09
    static let buttonCommand: UInt8 = 0x3B
    /// LED/effect command byte used inside report 0x04 on several SOAI/Beken tools.
    static let lightCommand: UInt8 = 0x07

    static let outputReportID8K: UInt8 = 0x04
    static let outputLength8K = 64

    // MARK: - Unlock

    static func unlockPackets() -> [Data] {
        [
            Data([0x80, 0x01, 0x03, 0x20, 0x50, 0x00, 0x04]),
            Data([0x80, 0x01, 0x03, 0x20, 0x41, 0x02, 0x64]),
        ]
    }

    /// OEM 8K configuration envelope, sized for the macOS HID descriptor.
    static func encodeDPIOutput64(
        slots: [Int],
        activeIndex: Int,
        colors: [(UInt8, UInt8, UInt8)],
        enabledMask: UInt8 = 0xFF
    ) throws -> Data {
        try encode8KConfiguration(encodeDPI(slots: slots, activeIndex: activeIndex, colors: colors, enabledMask: enabledMask))
    }

    /// Commit/apply poke used by OEM after config writes (report 0x0C, or wrapped on 8K).
    static func encodeApplyCommit() -> Data {
        Data([applyReportID, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00])
    }

    // MARK: - DPI

    static func encodeDPI(slots: [Int], activeIndex: Int, colors: [(UInt8, UInt8, UInt8)], enabledMask: UInt8 = 0xFF) -> Data {
        var buf = [UInt8](repeating: 0, count: 52)
        buf[0] = dpiReportID
        buf[1] = dpiCommand
        buf[2] = 0x01
        buf[5] = enabledMask
        var xDouble: UInt8 = 0
        var yDouble: UInt8 = 0
        let count = min(8, slots.count)
        for i in 0..<count {
            let (lo, hi) = dpiToBytes(slots[i])
            buf[8 + i] = lo
            buf[16 + i] = hi
            if slots[i] > 12_000 {
                xDouble |= 1 << i
                yDouble |= 1 << i
            }
        }
        buf[6] = xDouble
        buf[7] = yDouble
        buf[24] = UInt8(max(1, min(8, activeIndex + 1)))
        for i in 0..<min(8, colors.count) {
            buf[25 + i * 3] = colors[i].0
            buf[26 + i * 3] = colors[i].1
            buf[27 + i * 3] = colors[i].2
        }
        buf[49] = 2
        var sum: UInt16 = 0
        for i in 3...49 { sum &+= UInt16(buf[i]) }
        buf[50] = UInt8((sum >> 8) & 0xFF)
        buf[51] = UInt8(sum & 0xFF)
        return Data(buf)
    }

    static func decodeDPI(_ data: Data) -> (slots: [Int], activeIndex: Int, enabledMask: UInt8, colors: [(UInt8, UInt8, UInt8)])? {
        guard data.count >= 52, data[0] == dpiReportID, data[1] == dpiCommand,
              (1...8).contains(Int(data[24])), checksum(data, from: 3, through: 49, at: 50) else { return nil }
        var slots = [Int]()
        var colors = [(UInt8, UInt8, UInt8)]()
        for i in 0..<8 {
            let dpi = bytesToDPI(data[8 + i], data[16 + i])
            slots.append(dpi)
            colors.append((data[25 + i * 3], data[26 + i * 3], data[27 + i * 3]))
        }
        return (slots, Int(data[24]) - 1, data[5], colors)
    }

    // MARK: - Rate

    static func encodeRate(hz: Int, profile: UInt8 = 0x01) -> Data {
        var buf = [UInt8](repeating: 0, count: 9)
        buf[0] = rateReportID
        buf[1] = rateCommand
        buf[2] = profile
        buf[3] = interval(for: hz)
        buf[4] = ~buf[3]
        return Data(buf)
    }

    static func decodeRate(_ data: Data) -> Int? {
        guard data.count >= 5, data[0] == rateReportID, data[1] == rateCommand,
              data[4] == ~data[3] else { return nil }
        return hz(for: data[3])
    }

    static func interval(for hz: Int) -> UInt8 {
        switch hz {
        case 8000: return 0x10
        case 4000: return 0x20
        case 2000: return 0x40
        case 1000: return 0x01
        case 500: return 0x02
        case 250: return 0x04
        case 125: return 0x08
        default: return 0x01
        }
    }

    static func hz(for interval: UInt8) -> Int? {
        switch interval {
        case 0x10: return 8000
        case 0x20: return 4000
        case 0x40: return 2000
        case 0x01: return 1000
        case 0x02: return 500
        case 0x04: return 250
        case 0x08: return 125
        default: return nil
        }
    }

    // MARK: - Params

    static func encodeParams(
        debounceMs: Int,
        angleSnap: Bool,
        ripple: Bool,
        motionSync: Bool = false,
        profile: UInt8 = 0x01
    ) -> Data {
        var buf: [UInt8] = [
            paramReportID, paramCommand, profile,
            0x00, 0x03,
            UInt8(max(1, min(20, debounceMs / 2))),
            0x00, 0x00, 0xFF, 0x00,
            0x00,
            0x00,
            0x00,
        ]
        if angleSnap { buf[10] |= 0x02 }
        if ripple { buf[10] |= 0x04 }
        if motionSync { buf[10] |= 0x08 }
        buf[12] = buf[4] &+ buf[5] &+ buf[10]
        return Data(buf)
    }

    static func decodeParams(_ data: Data) -> (debounceMs: Int, angleSnap: Bool, ripple: Bool, motionSync: Bool)? {
        guard data.count >= 13, data[0] == paramReportID, data[1] == paramCommand,
              data[12] == data[4] &+ data[5] &+ data[10] else { return nil }
        return (Int(data[5]) * 2, (data[10] & 0x02) != 0, (data[10] & 0x04) != 0, (data[10] & 0x08) != 0)
    }

    /// OEM Mouse.exe 0x4158B3..0x4159AD, verified against Windows Apply capture.
    /// Preserve the shared packet's other mouse attributes when editing lighting.
    static func validOEMParameters(_ packet: Data) -> Bool {
        packet.count == 15 && packet[0] == paramReportID && packet[1] == paramCommand &&
        packet[2] == 1 && checksum(packet, from: 3, through: 10, at: 11) &&
        packet[13] == 0 && packet[14] == 0
    }

    static func encodeOEMLight(preserving original: Data, mode: UInt8, brightness: Int, speed: Int,
                               red: UInt8, green: UInt8, blue: UInt8) throws -> Data {
        guard validOEMParameters(original), mode <= 6, (1...8).contains(brightness), (1...8).contains(speed) else {
            throw HIDTransportError.reportFailed("Import a valid Windows capture before changing 8K lighting")
        }
        var packet = [UInt8](original)
        packet[3] = mode << 4
        packet[4] = (packet[4] & 0xF0) | UInt8(9 - speed)
        packet[5] = (packet[5] & 0xF0) | UInt8(mode == 1 || mode == 5 ? brightness : 8)
        packet[6] = red; packet[7] = green; packet[8] = blue
        let sum = packet[3...10].reduce(UInt16(0)) { $0 &+ UInt16($1) }
        packet[11] = UInt8(sum >> 8); packet[12] = UInt8(sum & 0xFF)
        return Data(packet)
    }

    /// Successful TX calls from our proxy; malformed, incomplete and failed writes are excluded.
    static func packets(fromCapture text: String) throws -> [Data] {
        guard text.contains("Set_VIDPID(1D57, FA65)") else {
            throw HIDTransportError.reportFailed("The log is not an SC680 8K receiver capture")
        }
        var pending: Data?
        var result: [Data] = []
        for line in text.components(separatedBy: .newlines) {
            if let range = line.range(of: "TX[65]: ") {
                let tokens = line[range.upperBound...].split(separator: " ")
                let bytes = tokens.compactMap { UInt8($0, radix: 16) }
                guard tokens.count == 65, bytes.count == 65, bytes[64] == 0,
                      is8KOutputEnvelope(Data(bytes.prefix(64))) else {
                    throw HIDTransportError.reportFailed("Invalid output frame in capture")
                }
                pending = Data(bytes[3..<(Int(bytes[1]) - 2)])
            } else if line.contains("WriteUSB =>") {
                if line.hasSuffix("WriteUSB => 1"), let packet = pending { result.append(packet) }
                pending = nil
            }
        }
        return result
    }

    static func oemParameters(fromCapture text: String) throws -> Data {
        guard let packet = try packets(fromCapture: text).last(where: validOEMParameters),
              packet[3] & 0x0F == 0, packet[3] >> 4 <= 6,
              (1...8).contains(Int(packet[4] & 0x0F)), (1...8).contains(Int(packet[5] & 0x0F)) else {
            throw HIDTransportError.reportFailed("No supported successful lighting configuration in capture")
        }
        return packet
    }

    static func validOEMDPI(_ packet: Data) -> Bool {
        packet.count == 56 && decodeDPI(packet) != nil && packet[49] == 1 &&
        [3, 4, 6, 7].allSatisfy { packet[$0] <= 1 } && packet.suffix(4).allSatisfy { $0 == 0 }
    }

    static func encodeOEMDPI(_ generic: Data, preserving original: Data? = nil) throws -> Data {
        guard generic.count == 52, decodeDPI(generic) != nil,
              original == nil || validOEMDPI(original!) else {
            throw HIDTransportError.reportFailed("Invalid OEM DPI configuration")
        }
        var inner = [UInt8](generic)
        // OEM fields are LOD, ripple control, angle snap, and motion sync, not DPI high-range masks.
        // Defaults from Mouse.exe 0x417370; imported capture preserves existing firmware settings.
        let defaults: [Int: UInt8] = [3: 0, 4: 0, 6: 0, 7: 1]
        for index in [3, 4, 6, 7] { inner[index] = original?[index] ?? defaults[index]! }
        inner[49] = 1
        let sum = inner[3...49].reduce(UInt16(0)) { $0 &+ UInt16($1) }
        inner[50] = UInt8(sum >> 8); inner[51] = UInt8(sum & 0xFF)
        inner += [0, 0, 0, 0]
        return Data(inner)
    }

    // MARK: - Buttons

    /// Shared mapping for the six physical buttons. Wheel click is Middle, not a seventh button.
    static let uiButtonSlots = [0, 1, 2, 5, 4, 3]

    static func encodeButtons(_ actions: [UInt8], profile: UInt8 = 0x01, preserving original: Data? = nil) -> Data {
        var buf = [UInt8](repeating: 0, count: 64)
        if let original, decodeButtons(original) != nil {
            for i in 0..<min(original.count, buf.count) { buf[i] = original[i] }
        }
        buf[0] = buttonReportID
        buf[1] = buttonCommand
        buf[2] = profile
        for i in 0..<min(18, actions.count) {
            if buf[3 + i * 3] != actions[i] {
                buf[4 + i * 3] = 0
                buf[5 + i * 3] = 0
            }
            buf[3 + i * 3] = actions[i]
        }
        var sum: UInt16 = 0
        for i in 3...56 { sum &+= UInt16(buf[i]) }
        buf[57] = UInt8((sum >> 8) & 0xFF)
        buf[58] = UInt8(sum & 0xFF)
        return Data(buf)
    }

    static func decodeButtons(_ data: Data) -> [UInt8]? {
        guard data.count >= 59, data[0] == buttonReportID, data[1] == buttonCommand,
              checksum(data, from: 3, through: 56, at: 57) else { return nil }
        var actions = [UInt8]()
        for i in 0..<18 {
            actions.append(data[3 + i * 3])
        }
        return actions
    }

    static func actionCode(for action: ButtonAction) -> UInt8 {
        switch action {
        case .leftClick: return 0x02
        case .rightClick: return 0x03
        case .middleClick: return 0x04
        case .backward: return 0x05
        case .forward: return 0x06
        case .dpiCycle: return 0x0D
        case .scrollUp: return 10
        case .scrollDown: return 9
        case .off: return 0x01
        case .doubleClick: return 0x07
        case .fireButton: return 0x08
        case .easyAim: return 0x09
        case .dpiUp: return 0x0E
        case .dpiDown: return 0x0F
        case .profileCycle: return 0x10
        case .shortcut, .macro: return 0x01
        case .unknown(let code): return code
        }
    }

    static func buttonAction(from code: UInt8) -> ButtonAction {
        switch code {
        case 0x02: return .leftClick
        case 0x03: return .rightClick
        case 0x04: return .middleClick
        case 0x05: return .backward
        case 0x06: return .forward
        case 0x0D: return .dpiCycle
        case 0x07: return .doubleClick
        case 0x08: return .fireButton
        case 0x0E: return .dpiUp
        case 0x0F: return .dpiDown
        case 0x10: return .profileCycle
        case 10: return .scrollUp
        case 9: return .scrollDown
        case 0x01: return .off
        default: return .unknown(code)
        }
    }

    // MARK: - Battery

    static func decodeBattery(_ data: Data) -> Int? {
        guard data.count >= 7, data[0] == batteryReportID else { return nil }
        let pct = Int(data[6])
        return (0...100).contains(pct) ? pct : nil
    }

    // MARK: - Light / LED

    /// Build light frames to try on device. Prefer report `0x04` (confirmed on 8K);
    /// legacy `0x07` Feature is unsupported on the 8K receiver (setFeature 0xE0005000).
    static func encodeLightFrames(
        mode: UInt8,
        brightness: UInt8,
        speed: UInt8,
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) -> [Data] {
        // A) Native 8K path: report 0x04 + LED command 0x07 (64 bytes)
        var a = [UInt8](repeating: 0, count: outputLength8K)
        a[0] = dpiReportID
        a[1] = lightCommand
        a[2] = 0x01
        a[3] = mode
        a[4] = brightness
        a[5] = speed
        a[6] = red
        a[7] = green
        a[8] = blue
        a[9] = mode &+ brightness &+ speed &+ red &+ green &+ blue

        // B) Same payload with command 0x0A (seen in some OEM light frames)
        var b = a
        b[1] = 0x0A
        b[9] = mode &+ brightness &+ speed &+ red &+ green &+ blue

        // C) Legacy short feature-style (wired / non-8K only; wrap for 8K Output)
        var c = [UInt8](repeating: 0, count: 16)
        c[0] = lightReportIDLegacy
        c[1] = 0x0A
        c[2] = 0x01
        c[3] = mode
        c[4] = brightness
        c[5] = speed
        c[6] = red
        c[7] = green
        c[8] = blue
        c[9] = mode &+ brightness &+ speed &+ red &+ green &+ blue

        return [Data(a), Data(b), Data(c)]
    }

    // MARK: - 8K output wrapping

    /// Mouse.exe VA 0x4150BB: [04, inner length + 5, 00, inner, sum16 BE].
    /// Windows passes a 65-byte API buffer; this receiver's macOS descriptor
    /// permits 64 bytes including the report ID. No command bytes are truncated.
    static func wrapFor8KOutput(_ packet: Data) throws -> Data {
        guard !packet.isEmpty, packet.count <= outputLength8K - 5 else {
            throw HIDTransportError.reportFailed("8K packet does not fit the receiver output report")
        }
        var out = [UInt8](repeating: 0, count: outputLength8K)
        out[0] = outputReportID8K
        out[1] = UInt8(packet.count + 5)
        for (i, value) in packet.enumerated() { out[3 + i] = value }
        let sum = out.prefix(packet.count + 3).reduce(UInt16(0)) { $0 &+ UInt16($1) }
        out[packet.count + 3] = UInt8(sum >> 8)
        out[packet.count + 4] = UInt8(sum & 0xFF)
        return Data(out)
    }

    /// Translate the existing generic Beken model into the uploaded SC680 OEM
    /// program's wire format. Unconfirmed commands are rejected before USB I/O.
    static func encode8KConfiguration(_ packet: Data) throws -> Data {
        var inner = [UInt8](packet)
        switch packet.first {
        case dpiReportID:
            if validOEMDPI(packet) { inner = [UInt8](packet) }
            else { inner = [UInt8](try encodeOEMDPI(packet)) }
        case rateReportID:
            guard packet.count == 9, let hz = decodeRate(packet) else {
                throw HIDTransportError.reportFailed("invalid polling command")
            }
            // OEM 0x4159D5..0x415A3B and telemetry handler 0x413AB0.
            let codes: [Int: UInt8] = [125: 0x20, 250: 0x10, 500: 0x08,
                1000: 0x04, 2000: 0x02, 4000: 0x01, 8000: 0x40]
            guard let code = codes[hz] else { throw HIDTransportError.reportFailed("unsupported polling rate") }
            inner[3] = code; inner[4] = ~code
        case paramReportID:
            guard validOEMParameters(packet) else {
                throw HIDTransportError.reportFailed("invalid OEM shared lighting/attribute command")
            }
        case buttonReportID:
            guard decodeButtons(packet) != nil else { throw HIDTransportError.reportFailed("invalid button command") }
            // OEM sends exactly 59 bytes; remaining generic bytes are padding.
            inner = Array(packet.prefix(59))
        default:
            throw HIDTransportError.reportFailed("8K command not verified against the SC680 OEM program")
        }
        return try wrapFor8KOutput(Data(inner))
    }

    static func is8KOutputEnvelope(_ packet: Data) -> Bool {
        guard packet.count == outputLength8K, packet[0] == outputReportID8K,
              packet[2] == 0 else { return false }
        let count = Int(packet[1])
        guard (6...outputLength8K).contains(count) else { return false }
        return checksum(packet, from: 0, through: count - 3, at: count - 2)
    }

    // MARK: - Helpers

    static func dpiToBytes(_ dpi: Int) -> (UInt8, UInt8) {
        guard dpi > 0 else { return (0, 0) }
        let v = (dpi - 50) / 50
        return (UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF))
    }

    static func bytesToDPI(_ lo: UInt8, _ hi: UInt8) -> Int {
        let v = (Int(hi) << 8) | Int(lo)
        return v * 50 + 50
    }

    private static func checksum(_ data: Data, from start: Int, through end: Int, at offset: Int) -> Bool {
        let sum = data[start...end].reduce(UInt16(0)) { $0 &+ UInt16($1) }
        return data[offset] == UInt8(sum >> 8) && data[offset + 1] == UInt8(sum & 0xFF)
    }

    /// Accept only the requested response, including an optional 8K outer report ID.
    static func response(from data: Data, reportID: UInt8) -> Data? {
        let bytes = Data(data)
        let candidates = [bytes, Data(bytes.dropFirst())]
        for (index, packet) in candidates.enumerated() {
            if index == 1 && bytes.first != outputReportID8K { continue }
            let valid: Bool
            switch reportID {
            case dpiReportID: valid = decodeDPI(packet) != nil
            case rateReportID: valid = decodeRate(packet) != nil
            case paramReportID: valid = decodeParams(packet) != nil
            case buttonReportID: valid = decodeButtons(packet) != nil
            case batteryReportID: valid = decodeBattery(packet) != nil
            default: valid = false
            }
            if valid { return packet }
        }
        return nil
    }
}
