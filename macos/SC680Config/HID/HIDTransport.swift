import Foundation
import IOKit.hid

enum HIDTransportError: Error, LocalizedError {
    case deviceNotFound
    case openFailed
    case reportFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound: return "SC680 receiver not found (plug 2.4G dongle or USB-C)"
        case .openFailed: return "Failed to open HID device"
        case .reportFailed(let s): return "HID report failed: \(s)"
        }
    }
}

enum TransportMode: String {
    case feature
    case output8K
}

/// IOHIDDevice wrapper with Feature-first + 8K Output fallback.
final class HIDTransport {
    private var device: IOHIDDevice?
    private(set) var identity: USBIdentity?
    private(set) var productName: String = ""
    private(set) var transportMode: TransportMode = .feature
    private(set) var usagePage: Int = 0

    var isOpen: Bool { device != nil }

    func close() {
        if let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        identity = nil
        productName = ""
        usagePage = 0
    }

    deinit { close() }

    @discardableResult
    func openFirstMatching() throws -> USBIdentity {
        close()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            throw HIDTransportError.deviceNotFound
        }

        // Prefer 8K dongle vendor page, then standard dongle vendor pages.
        let ranked = set.sorted { a, b in
            score(a) > score(b)
        }

        for candidate in ranked {
            let vid = intProperty(candidate, kIOHIDVendorIDKey)
            let pid = intProperty(candidate, kIOHIDProductIDKey)
            guard let match = SC680DeviceIDs.known.first(where: { $0.vendorID == vid && $0.productID == pid }) else {
                continue
            }
            let page = intProperty(candidate, kIOHIDPrimaryUsagePageKey)
            guard (page & 0xFF00) == 0xFF00 else { continue }

            let opened =
                IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess
                || IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
            guard opened else { continue }

            device = candidate
            identity = match
            usagePage = page
            productName = stringProperty(candidate, kIOHIDProductKey) ?? match.label
            transportMode = (match == SC680DeviceIDs.dongle8K) ? .output8K : .feature
            return match
        }
        throw HIDTransportError.deviceNotFound
    }

    /// Send a Beken packet using the best transport for the connected dongle.
    func sendBekenPacket(_ packet: Data) throws {
        guard device != nil else { throw HIDTransportError.openFailed }

        // 1) Try Feature report (works on many BK3633 wired / standard paths)
        do {
            try setFeatureReport(packet)
            return
        } catch {
            // continue to fallback
        }

        // 2) 8K Output report fallback
        let wrapped = BekenCodec.wrapFor8KOutput(packet)
        try setOutputReport(wrapped)
        transportMode = .output8K
    }

    func readBekenPacket(reportID: UInt8, length: Int) throws -> Data {
        // Prefer Feature get
        do {
            let data = try getFeatureReport(reportID: reportID, length: length)
            if data.count > 1, data.dropFirst().contains(where: { $0 != 0 }) {
                return data
            }
            if data.first == reportID { return data }
        } catch {
            // fall through
        }
        // Some firmwares echo via input report after a poke
        return try getInputReport(reportID: BekenCodec.outputReportID8K, length: BekenCodec.outputLength8K)
    }

    func setOutputReport(_ data: Data) throws {
        guard let device else { throw HIDTransportError.openFailed }
        var bytes = [UInt8](data)
        let kr = bytes.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeOutput,
                CFIndex(buf[0]),
                buf.baseAddress!,
                buf.count
            )
        }
        guard kr == kIOReturnSuccess else {
            throw HIDTransportError.reportFailed(String(format: "setOutput 0x%08X", kr))
        }
    }

    func getInputReport(reportID: UInt8, length: Int) throws -> Data {
        guard let device else { throw HIDTransportError.openFailed }
        var buffer = [UInt8](repeating: 0, count: length)
        buffer[0] = reportID
        var len = buffer.count
        let kr = buffer.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeInput,
                CFIndex(reportID),
                buf.baseAddress!,
                &len
            )
        }
        guard kr == kIOReturnSuccess else {
            throw HIDTransportError.reportFailed(String(format: "getInput 0x%08X", kr))
        }
        return Data(buffer.prefix(len))
    }

    func getFeatureReport(reportID: UInt8, length: Int) throws -> Data {
        guard let device else { throw HIDTransportError.openFailed }
        var buffer = [UInt8](repeating: 0, count: length)
        buffer[0] = reportID
        var len = buffer.count
        let kr = buffer.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                CFIndex(reportID),
                buf.baseAddress!,
                &len
            )
        }
        guard kr == kIOReturnSuccess else {
            throw HIDTransportError.reportFailed(String(format: "getFeature 0x%08X", kr))
        }
        return Data(buffer.prefix(len))
    }

    func setFeatureReport(_ data: Data) throws {
        guard let device else { throw HIDTransportError.openFailed }
        var bytes = [UInt8](data)
        let kr = bytes.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeFeature,
                CFIndex(buf[0]),
                buf.baseAddress!,
                buf.count
            )
        }
        guard kr == kIOReturnSuccess else {
            throw HIDTransportError.reportFailed(String(format: "setFeature 0x%08X", kr))
        }
    }

    private func score(_ device: IOHIDDevice) -> Int {
        let vid = intProperty(device, kIOHIDVendorIDKey)
        let pid = intProperty(device, kIOHIDProductIDKey)
        let page = intProperty(device, kIOHIDPrimaryUsagePageKey)
        var s = 0
        if vid == SC680DeviceIDs.dongle8K.vendorID && pid == SC680DeviceIDs.dongle8K.productID { s += 100 }
        if vid == SC680DeviceIDs.dongleStandard.vendorID && pid == SC680DeviceIDs.dongleStandard.productID { s += 50 }
        if page == Int(SC680DeviceIDs.usagePageVendorFF00) { s += 20 }
        if page == Int(SC680DeviceIDs.usagePageVendorFF04) { s += 15 }
        if page == Int(SC680DeviceIDs.usagePageVendorFF02) { s += 10 }
        return s
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
