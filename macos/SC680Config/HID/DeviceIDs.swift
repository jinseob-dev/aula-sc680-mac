import Foundation

enum SC680DeviceIDs {
    /// 8K HS wireless receiver (primary config path on this hardware)
    static let dongle8K = USBIdentity(vendorID: 0x1D57, productID: 0xFA65)
    /// Standard 2.4G receiver
    static let dongleStandard = USBIdentity(vendorID: 0x3554, productID: 0xFA09)

    static let known: [USBIdentity] = [dongle8K, dongleStandard]

    /// Vendor usage pages observed on SC680 receivers
    static let usagePageVendorFF00: UInt32 = 0xFF00
    static let usagePageVendorFF02: UInt32 = 0xFF02
    static let usagePageVendorFF04: UInt32 = 0xFF04

    /// Only valid Output report ID on 8K dongle (64-byte reports)
    static let reportIDConfig8K: UInt8 = 0x04
}

struct USBIdentity: Hashable, Sendable {
    let vendorID: Int
    let productID: Int

    var label: String {
        String(format: "%04X:%04X", vendorID, productID)
    }
}

/// A receiver may expose mouse and configuration collections on the same HID interface.
/// PrimaryUsagePage alone does not describe all of its report capabilities.
struct HIDInterfaceInfo {
    let primaryUsagePage: Int
    let usagePages: Set<Int>
    let outputReportIDs: Set<Int>
    let featureReportIDs: Set<Int>
    let maxOutputSize: Int
    let maxFeatureSize: Int
    var inputReportIDs: Set<Int> = []
    var maxInputSize: Int = 0

    var hasVendorCollection: Bool {
        usagePages.union([primaryUsagePage]).contains { ($0 & 0xFF00) == 0xFF00 }
    }
    var supports8KOutput: Bool {
        outputReportIDs.contains(0x04) && (maxOutputSize <= 0 || maxOutputSize >= 63)
    }
    var supportsFeatureUnlock: Bool { featureReportIDs.contains(0x80) }
    var supportsFeatureConfiguration: Bool {
        !featureReportIDs.isDisjoint(with: [0x04, 0x05, 0x06, 0x08, 0x80])
    }
    var isConfigurationInterface: Bool {
        supports8KOutput || supportsFeatureConfiguration
    }

    var summary: String {
        func hexList(_ values: Set<Int>) -> String {
            values.sorted().map { String(format: "0x%X", $0) }.joined(separator: ",")
        }
        return "primary=\(String(format: "0x%X", primaryUsagePage)), usages=[\(hexList(usagePages))], " +
            "Input=[\(hexList(inputReportIDs))]/\(maxInputSize), Output=[\(hexList(outputReportIDs))]/\(maxOutputSize), Feature=[\(hexList(featureReportIDs))]/\(maxFeatureSize)"
    }
}


/// Bounded, thread-safe inbox for vendor Input 0x04 responses. Pointer/keyboard
/// reports are never retained. A write/open timestamp prevents stale verification.
final class HIDResponseInbox {
    private let condition = NSCondition()
    private var frames: [(time: TimeInterval, data: Data)] = []
    private var receivedCount = 0
    private var lastPreview = "none"
    private var telemetryCount = 0
    private var telemetryPreview = "none"

    func record(reportID: Int, data: Data, receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard [3, Int(BekenCodec.outputReportID8K)].contains(reportID), !data.isEmpty, data.count <= 64 else { return }
        condition.lock()
        defer { condition.unlock() }
        if reportID == 3 {
            // OEM monitor consumes this short event report, not a settings dump.
            telemetryCount += 1
            telemetryPreview = data.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
            return
        }
        receivedCount += 1
        lastPreview = data.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
        frames.append((receivedAt, data))
        if frames.count > 16 { frames.removeFirst(frames.count - 16) }
        condition.broadcast()
    }

    func response(reportID: UInt8, receivedAfter: TimeInterval, timeout: TimeInterval) -> Data? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        repeat {
            for frame in frames.reversed() where frame.time >= receivedAfter {
                // IOKit may provide the report ID separately from its payload.
                let candidates = [frame.data, Data([BekenCodec.outputReportID8K]) + frame.data]
                for candidate in candidates {
                    if let packet = BekenCodec.response(from: candidate, reportID: reportID) { return packet }
                }
            }
            if timeout <= 0 || !condition.wait(until: deadline) { return nil }
        } while Date() < deadline
        return nil
    }

    var summary: String {
        condition.lock()
        defer { condition.unlock() }
        return "Interrupt Input 0x04: \(receivedCount) reports; last prefix: \(lastPreview)\nOEM Input 0x03: \(telemetryCount) events; last prefix: \(telemetryPreview)"
    }
}
