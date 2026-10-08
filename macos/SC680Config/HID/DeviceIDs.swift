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
            "Output=[\(hexList(outputReportIDs))]/\(maxOutputSize), Feature=[\(hexList(featureReportIDs))]/\(maxFeatureSize)"
    }
}
