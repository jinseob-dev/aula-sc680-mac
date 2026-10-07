import Foundation

/// Compatibility façade — prefer `BekenCodec` + `HIDTransport.sendBekenPacket`.
enum MouseProtocol {
    static func unlockFrames() -> [Data] { BekenCodec.unlockPackets() }

    static func dpiWrite(activeIndex: Int, dpiValues: [Int], colors: [(UInt8, UInt8, UInt8)], enabledMask: UInt8) -> Data {
        BekenCodec.encodeDPI(slots: dpiValues, activeIndex: activeIndex, colors: colors, enabledMask: enabledMask)
    }

    static func rateWrite(hz: Int) -> Data {
        BekenCodec.encodeRate(hz: hz)
    }
}
