import Foundation
import IOKit.hid

enum HIDTransportError: Error, LocalizedError {
    case deviceNotFound
    case openFailed(String)
    case reportFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "SC680 receiver not found (plug 2.4G dongle, not Bluetooth)"
        case .openFailed(let detail):
            return "Failed to open HID device — \(detail)"
        case .reportFailed(let s):
            return "HID report failed: \(s)"
        }
    }
}

enum TransportMode: String {
    case feature
    case output8K
}

/// IOHIDDevice wrapper with Feature-first + 8K Output fallback.
final class HIDTransport {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private(set) var identity: USBIdentity?
    private(set) var productName: String = ""
    private(set) var transportMode: TransportMode = .feature
    private(set) var usagePage: Int = 0

    /// Called on the main queue when the open device is removed.
    var onDeviceRemoved: (() -> Void)?

    var isOpen: Bool { device != nil }

    func close() {
        if let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager {
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        manager = nil
        identity = nil
        productName = ""
        usagePage = 0
    }

    deinit { close() }

    @discardableResult
    func openFirstMatching() throws -> USBIdentity {
        close()

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Narrow match to known SC680 receivers (more reliable than matching-all).
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matchingDictionaries() as CFArray)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openKr = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openKr == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            throw HIDTransportError.openFailed(String(format: "IOHIDManagerOpen 0x%08X (USB permission or restart Mac)", openKr))
        }

        // Give the run loop a tick so already-attached devices appear.
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            throw HIDTransportError.deviceNotFound
        }

        let ranked = set.sorted { score($0) > score($1) }
        var lastOpenError: kern_return_t = kIOReturnError
        var sawKnownVIDPID = false
        var fallback: (IOHIDDevice, USBIdentity, Int)?

        // Prefer an interface that accepts Output report 0x04 (Windows WriteUSB path).
        for requireVendorPage in [true, false] {
            for candidate in ranked {
                let vid = intProperty(candidate, kIOHIDVendorIDKey)
                let pid = intProperty(candidate, kIOHIDProductIDKey)
                guard let match = SC680DeviceIDs.known.first(where: { $0.vendorID == vid && $0.productID == pid }) else {
                    continue
                }
                sawKnownVIDPID = true
                let page = intProperty(candidate, kIOHIDPrimaryUsagePageKey)
                let isVendor = (page & 0xFF00) == 0xFF00
                if requireVendorPage && !isVendor { continue }
                if !requireVendorPage && isVendor { continue }

                let shared = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
                var opened = shared == kIOReturnSuccess
                if !opened {
                    lastOpenError = shared
                    let seized = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
                    opened = seized == kIOReturnSuccess
                    if !opened {
                        lastOpenError = seized
                        continue
                    }
                }

                // Probe Output 0x04 / 64 — required for 8K DPI writes.
                if match == SC680DeviceIDs.dongle8K {
                    if probeOutput8K(candidate) {
                        if let (extra, _, _) = fallback {
                            IOHIDDeviceClose(extra, IOOptionBits(kIOHIDOptionsTypeNone))
                            fallback = nil
                        }
                        return finishOpen(mgr: mgr, candidate: candidate, match: match, page: page, mode: .output8K)
                    }
                    // Keep first openable interface as fallback; try other collections.
                    if fallback == nil { fallback = (candidate, match, page) }
                    else { IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) }
                    continue
                }

                return finishOpen(mgr: mgr, candidate: candidate, match: match, page: page, mode: .feature)
            }
        }

        if let (candidate, match, page) = fallback {
            return finishOpen(mgr: mgr, candidate: candidate, match: match, page: page, mode: .output8K)
        }

        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        if sawKnownVIDPID {
            throw HIDTransportError.openFailed(
                String(
                    format: "dongle seen but open blocked (0x%08X). Quit other mouse apps, unplug/replug dongle, then Rescan",
                    lastOpenError
                )
            )
        }
        throw HIDTransportError.deviceNotFound
    }

    private func probeOutput8K(_ candidate: IOHIDDevice) -> Bool {
        var probe = [UInt8](repeating: 0, count: BekenCodec.outputLength8K)
        probe[0] = BekenCodec.outputReportID8K
        let kr = probe.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceSetReport(
                candidate,
                kIOHIDReportTypeOutput,
                CFIndex(BekenCodec.outputReportID8K),
                buf.baseAddress!,
                buf.count
            )
        }
        return kr == kIOReturnSuccess
    }

    private func finishOpen(
        mgr: IOHIDManager,
        candidate: IOHIDDevice,
        match: USBIdentity,
        page: Int,
        mode: TransportMode
    ) -> USBIdentity {
        manager = mgr
        device = candidate
        identity = match
        usagePage = page
        productName = stringProperty(candidate, kIOHIDProductKey) ?? match.label
        transportMode = mode

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, _ in
            guard let context else { return }
            let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                transport.handleRemoval()
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        return match
    }

    private func matchingDictionaries() -> [[String: Any]] {
        SC680DeviceIDs.known.map { id in
            [
                kIOHIDVendorIDKey as String: id.vendorID,
                kIOHIDProductIDKey as String: id.productID,
            ]
        }
    }

    private func handleRemoval() {
        // Soft-clear the device handle. Keep manager scheduled so a quick
        // re-plug / USB reset can be recovered via openFirstMatching().
        if let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device = nil
        identity = nil
        productName = ""
        usagePage = 0
        onDeviceRemoved?()
    }

    /// Report IDs known to exist as Feature on BK3633 / SC680 paths.
    private static let featureReportIDs: Set<UInt8> = [0x01, 0x04, 0x05, 0x06, 0x08, 0x0C, 0x80]

    /// Send a Beken packet using the best transport for the connected dongle.
    func sendBekenPacket(_ packet: Data) throws {
        guard device != nil else { throw HIDTransportError.openFailed("session closed — tap Rescan") }
        guard let reportID = packet.first else {
            throw HIDTransportError.reportFailed("empty packet")
        }

        let is8K = transportMode == .output8K || identity == SC680DeviceIDs.dongle8K

        // 8K: WriteUSB only accepts Output report ID 0x04 (64 bytes). Always try that.
        // Only fall back to Feature for report IDs the descriptor actually lists —
        // legacy light report 0x07 yields setFeature 0xE0005000 on this dongle.
        if is8K {
            var outputError: Error?
            do {
                try setOutputReport(BekenCodec.wrapFor8KOutput(packet))
                transportMode = .output8K
                return
            } catch {
                outputError = error
            }

            if Self.featureReportIDs.contains(reportID) {
                do {
                    try setFeatureReport(packet)
                    transportMode = .feature
                    return
                } catch {
                    throw outputError ?? error
                }
            }
            throw outputError ?? HIDTransportError.reportFailed("unsupported report 0x\(String(reportID, radix: 16)) on 8K")
        }

        // Standard / wired: Feature first, Output wrap fallback.
        do {
            try setFeatureReport(packet)
            transportMode = .feature
            return
        } catch {
            try setOutputReport(BekenCodec.wrapFor8KOutput(packet))
            transportMode = .output8K
        }
    }

    /// Send a pre-sized 64-byte Output report (report ID must be 0x04).
    func send8KOutput(_ packet: Data) throws {
        guard device != nil else { throw HIDTransportError.openFailed("session closed — tap Rescan") }
        var bytes = [UInt8](repeating: 0, count: BekenCodec.outputLength8K)
        let n = min(packet.count, bytes.count)
        for i in 0..<n { bytes[i] = packet[i] }
        bytes[0] = BekenCodec.outputReportID8K
        try setOutputReport(Data(bytes))
        transportMode = .output8K
    }

    func readBekenPacket(reportID: UInt8, length: Int) throws -> Data {
        guard device != nil else { throw HIDTransportError.openFailed("session closed — tap Rescan") }

        do {
            let data = try getFeatureReport(reportID: reportID, length: length)
            if data.count > 1, data.dropFirst().contains(where: { $0 != 0 }) {
                return data
            }
            if data.first == reportID { return data }
        } catch {
            // fall through
        }
        return try getInputReport(reportID: BekenCodec.outputReportID8K, length: BekenCodec.outputLength8K)
    }

    func setOutputReport(_ data: Data) throws {
        guard let device else { throw HIDTransportError.openFailed("session closed — tap Rescan") }
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
        guard let device else { throw HIDTransportError.openFailed("session closed — tap Rescan") }
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
        guard let device else { throw HIDTransportError.openFailed("session closed — tap Rescan") }
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
        guard let device else { throw HIDTransportError.openFailed("session closed — tap Rescan") }
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
        // Prefer vendor collections over generic mouse/keyboard pages.
        if (page & 0xFF00) == 0xFF00 { s += 5 }
        return s
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1
    }

    private func stringProperty(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
