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
