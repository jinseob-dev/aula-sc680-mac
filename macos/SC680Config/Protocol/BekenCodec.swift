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

    static func decodeDPI(_ data: Data) -> (slots: [Int], activeIndex: Int)? {
        guard data.count >= 52, data[0] == dpiReportID else { return nil }
        var slots = [Int]()
        for i in 0..<8 {
            let dpi = bytesToDPI(data[8 + i], data[16 + i])
            slots.append(dpi)
        }
        let active = max(0, Int(data[24]) - 1)
        return (slots, active)
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
        guard data.count >= 4, data[0] == rateReportID else { return nil }
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

    static func hz(for interval: UInt8) -> Int {
        switch interval {
        case 0x10: return 8000
        case 0x20: return 4000
        case 0x40: return 2000
        case 0x01: return 1000
        case 0x02: return 500
        case 0x04: return 250
        case 0x08: return 125
        default: return 1000
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

    static func decodeParams(_ data: Data) -> (debounceMs: Int, angleSnap: Bool, ripple: Bool)? {
        guard data.count >= 13, data[0] == paramReportID else { return nil }
        return (Int(data[5]) * 2, (data[10] & 0x02) != 0, (data[10] & 0x04) != 0)
    }

    // MARK: - Buttons

    static func encodeButtons(_ actions: [UInt8], profile: UInt8 = 0x01) -> Data {
        var buf = [UInt8](repeating: 0, count: 64)
        buf[0] = buttonReportID
        buf[1] = buttonCommand
        buf[2] = profile
        for i in 0..<min(18, actions.count) {
            buf[3 + i * 3] = actions[i]
        }
        var sum: UInt16 = 0
        for i in 3...56 { sum &+= UInt16(buf[i]) }
        buf[57] = UInt8((sum >> 8) & 0xFF)
        buf[58] = UInt8(sum & 0xFF)
        return Data(buf)
    }

    static func decodeButtons(_ data: Data) -> [UInt8]? {
        guard data.count >= 59, data[0] == buttonReportID else { return nil }
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
        case 10: return .scrollUp
        case 9: return .scrollDown
        case 0x01: return .off
        default: return .off
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

    /// Pack a Beken feature-style packet for the 8K dongle Output report path.
    static func wrapFor8KOutput(_ packet: Data) -> Data {
        var out = [UInt8](repeating: 0, count: outputLength8K)
        if packet.first == outputReportID8K {
            // DPI (and any packet already using report id 0x04)
            let n = min(packet.count, outputLength8K)
            for i in 0..<n { out[i] = packet[i] }
        } else {
            // HID output report id must be 0x04; embed full Beken packet after it.
            out[0] = outputReportID8K
            let n = min(packet.count, outputLength8K - 1)
            for i in 0..<n { out[1 + i] = packet[i] }
        }
        return Data(out)
    }

    // MARK: - Helpers

    static func dpiToBytes(_ dpi: Int) -> (UInt8, UInt8) {
        guard dpi > 0 else { return (0, 0) }
        let v = (dpi - 50) / 50
        return (UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF))
    }

    static func bytesToDPI(_ lo: UInt8, _ hi: UInt8) -> Int {
        let v = (Int(hi) << 8) | Int(lo)
        return v == 0 ? 0 : v * 50 + 50
    }
}
