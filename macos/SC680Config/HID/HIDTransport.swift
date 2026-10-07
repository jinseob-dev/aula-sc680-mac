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
    /// Windows OEM opens Feature + Report devices together.
    case dual8K = "output8K+feature"
}

/// Dual-handle transport mirroring Windows `Open_FeatureDevice` + `Open_ReportDevice`.
///
/// Without Feature unlock (`0x80`), Output DPI writes can return success at the HID
/// layer while the mouse firmware ignores them — which looks like “no error, not applied”.
final class HIDTransport {
    private var manager: IOHIDManager?
    private var outputDevice: IOHIDDevice?
    private var featureDevice: IOHIDDevice?
    private(set) var identity: USBIdentity?
    private(set) var productName: String = ""
    private(set) var transportMode: TransportMode = .feature
    private(set) var usagePage: Int = 0
    private(set) var hasFeaturePath: Bool = false
    private(set) var hasOutputPath: Bool = false

    /// Called on the main queue when the open device is removed.
    var onDeviceRemoved: (() -> Void)?

    var isOpen: Bool { outputDevice != nil || featureDevice != nil }

    func close() {
        if let outputDevice {
            IOHIDDeviceClose(outputDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let featureDevice, featureDevice !== outputDevice {
            IOHIDDeviceClose(featureDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager {
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        outputDevice = nil
        featureDevice = nil
        manager = nil
        identity = nil
        productName = ""
        usagePage = 0
        hasFeaturePath = false
        hasOutputPath = false
    }

    deinit { close() }

    @discardableResult
    func openFirstMatching() throws -> USBIdentity {
        close()

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matchingDictionaries() as CFArray)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openKr = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openKr == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            throw HIDTransportError.openFailed(String(format: "IOHIDManagerOpen 0x%08X (USB permission or restart Mac)", openKr))
        }

        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            throw HIDTransportError.deviceNotFound
        }

        let ranked = set.sorted { score($0) > score($1) }
        var lastOpenError: kern_return_t = kIOReturnError
        var sawKnownVIDPID = false
        var openedOutput: (IOHIDDevice, USBIdentity, Int)?
        var openedFeature: (IOHIDDevice, USBIdentity, Int)?
        var extrasToClose: [IOHIDDevice] = []

        for candidate in ranked {
            let vid = intProperty(candidate, kIOHIDVendorIDKey)
            let pid = intProperty(candidate, kIOHIDProductIDKey)
            guard let match = SC680DeviceIDs.known.first(where: { $0.vendorID == vid && $0.productID == pid }) else {
                continue
            }
            sawKnownVIDPID = true
            let page = intProperty(candidate, kIOHIDPrimaryUsagePageKey)
            guard (page & 0xFF00) == 0xFF00 else { continue }

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

            let canOut = probeOutput8K(candidate)
            let canFeat = probeFeatureUnlock(candidate)

            if canOut, openedOutput == nil {
                openedOutput = (candidate, match, page)
            } else if canFeat, openedFeature == nil {
                openedFeature = (candidate, match, page)
            } else if openedOutput == nil && openedFeature == nil {
                // Keep something openable even if probes are inconclusive.
                openedOutput = (candidate, match, page)
            } else {
                extrasToClose.append(candidate)
            }

            if openedOutput != nil, openedFeature != nil { break }
            // Same interface may support both.
            if canOut && canFeat {
                openedFeature = openedOutput
                break
            }
        }

        for extra in extrasToClose {
            IOHIDDeviceClose(extra, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        guard let out = openedOutput ?? openedFeature else {
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

        manager = mgr
        outputDevice = out.0
        featureDevice = openedFeature?.0 ?? out.0
        identity = out.1
        usagePage = out.2
        productName = stringProperty(out.0, kIOHIDProductKey) ?? out.1.label
        hasOutputPath = openedOutput != nil && probeOutput8K(out.0)
        hasFeaturePath = featureDevice != nil && probeFeatureUnlock(featureDevice!)
        if hasOutputPath && hasFeaturePath {
            transportMode = .dual8K
        } else if hasOutputPath || out.1 == SC680DeviceIDs.dongle8K {
            transportMode = .output8K
        } else {
            transportMode = .feature
        }

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, _ in
            guard let context else { return }
            let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                transport.handleRemoval()
            }
        }, Unmanaged.passUnretained(self).toOpaque())

        return out.1
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

    private func probeFeatureUnlock(_ candidate: IOHIDDevice) -> Bool {
        // Probe with GetFeature on unlock report id — cheaper than writing unlock.
        var buffer = [UInt8](repeating: 0, count: 7)
        buffer[0] = BekenCodec.unlockReportID
        var len = buffer.count
        let kr = buffer.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceGetReport(
                candidate,
                kIOHIDReportTypeFeature,
                CFIndex(BekenCodec.unlockReportID),
                buf.baseAddress!,
                &len
            )
        }
        if kr == kIOReturnSuccess { return true }
        // Some firmwares reject get but accept set — try a no-op-sized set of zeros is unsafe.
        // Accept Feature DPI get as evidence of a Feature collection.
        buffer = [UInt8](repeating: 0, count: 52)
        buffer[0] = BekenCodec.dpiReportID
        len = buffer.count
        let kr2 = buffer.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceGetReport(
                candidate,
                kIOHIDReportTypeFeature,
                CFIndex(BekenCodec.dpiReportID),
                buf.baseAddress!,
                &len
            )
        }
        return kr2 == kIOReturnSuccess
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
        if let outputDevice {
            IOHIDDeviceClose(outputDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let featureDevice, featureDevice !== outputDevice {
            IOHIDDeviceClose(featureDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        outputDevice = nil
        featureDevice = nil
        identity = nil
        productName = ""
        usagePage = 0
        hasFeaturePath = false
        hasOutputPath = false
        onDeviceRemoved?()
    }

    /// True Feature unlock (Windows SetFeature). Critical before config writes.
    func sendFeatureUnlock() throws {
        guard let featureDevice else {
            throw HIDTransportError.openFailed("no Feature path for unlock — Rescan / try another USB port")
        }
        for packet in BekenCodec.unlockPackets() {
            var bytes = [UInt8](packet)
            let kr = bytes.withUnsafeMutableBufferPointer { buf in
                IOHIDDeviceSetReport(
                    featureDevice,
                    kIOHIDReportTypeFeature,
                    CFIndex(buf[0]),
                    buf.baseAddress!,
                    buf.count
                )
            }
            guard kr == kIOReturnSuccess else {
                throw HIDTransportError.reportFailed(String(format: "unlock setFeature 0x%08X", kr))
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Send a Beken packet using the best transport for the connected dongle.
    func sendBekenPacket(_ packet: Data) throws {
        guard isOpen else { throw HIDTransportError.openFailed("session closed — tap Rescan") }
        guard let reportID = packet.first else {
            throw HIDTransportError.reportFailed("empty packet")
        }

        let is8K = identity == SC680DeviceIDs.dongle8K || transportMode == .output8K || transportMode == .dual8K

        if is8K {
            // Config writes: Output 0x04 / 64 (WriteUSB). Unlock uses sendFeatureUnlock separately.
            if reportID == BekenCodec.unlockReportID {
                try sendFeatureUnlock()
                return
            }
            do {
                try send8KOutput(BekenCodec.wrapFor8KOutput(packet))
                return
            } catch {
                if hasFeaturePath {
                    try setFeatureReport(packet)
                    return
                }
                throw error
            }
        }

        do {
            try setFeatureReport(packet)
        } catch {
            try send8KOutput(BekenCodec.wrapFor8KOutput(packet))
        }
    }

    func send8KOutput(_ packet: Data) throws {
        guard let outputDevice else { throw HIDTransportError.openFailed("no Output path — tap Rescan") }
        var bytes = [UInt8](repeating: 0, count: BekenCodec.outputLength8K)
        let n = min(packet.count, bytes.count)
        for i in 0..<n { bytes[i] = packet[i] }
        bytes[0] = BekenCodec.outputReportID8K
        let kr = bytes.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceSetReport(
                outputDevice,
                kIOHIDReportTypeOutput,
                CFIndex(BekenCodec.outputReportID8K),
                buf.baseAddress!,
                buf.count
            )
        }
        guard kr == kIOReturnSuccess else {
            throw HIDTransportError.reportFailed(String(format: "setOutput 0x%08X", kr))
        }
    }

    func readBekenPacket(reportID: UInt8, length: Int) throws -> Data {
        guard isOpen else { throw HIDTransportError.openFailed("session closed — tap Rescan") }

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

    func getInputReport(reportID: UInt8, length: Int) throws -> Data {
        guard let device = outputDevice ?? featureDevice else {
            throw HIDTransportError.openFailed("session closed — tap Rescan")
        }
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
        guard let featureDevice else { throw HIDTransportError.openFailed("no Feature path") }
        var buffer = [UInt8](repeating: 0, count: length)
        buffer[0] = reportID
        var len = buffer.count
        let kr = buffer.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceGetReport(
                featureDevice,
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
        guard let featureDevice else { throw HIDTransportError.openFailed("no Feature path") }
        var bytes = [UInt8](data)
        let kr = bytes.withUnsafeMutableBufferPointer { buf in
            IOHIDDeviceSetReport(
                featureDevice,
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
