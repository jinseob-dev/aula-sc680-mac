import Foundation
import IOKit.hid

struct HIDConnectionInfo {
    let identity: USBIdentity
    let productName: String
    let transportMode: TransportMode
    let hasFeaturePath: Bool
    let hasOutputPath: Bool
    var diagnostics: String = ""
}

protocol DeviceSession: AnyObject {
    var onDeviceRemoved: (() -> Void)? { get set }
    func open(forceReopen: Bool) async throws -> HIDConnectionInfo
    func unlock() async throws -> Bool
    func send(_ packet: Data, outputOnly: Bool) async throws
    func read(reportID: UInt8, length: Int) async throws -> Data
}

/// All HID calls and retry delays run on one worker queue, including removal handling.
final class HIDClient: DeviceSession {
    private let queue: DispatchQueue
    private let transport: HIDTransport
    var onDeviceRemoved: (() -> Void)?

    init() {
        let queue = DispatchQueue(label: "com.aula.sc680config.hid")
        self.queue = queue
        transport = HIDTransport(callbackQueue: queue)
        transport.onDeviceRemoved = { [weak self] in self?.onDeviceRemoved?() }
    }

    private func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    @discardableResult
    private func ensureOpen(forceReopen: Bool = false) throws -> HIDConnectionInfo {
        if !transport.isOpen || forceReopen {
            var lastError: Error = HIDTransportError.deviceNotFound
            var opened = false
            for attempt in 0..<4 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.25 * Double(attempt)) }
                do {
                    try transport.openFirstMatching()
                    opened = true
                    break
                } catch {
                    if case HIDTransportError.permissionDenied = error { throw error }
                    lastError = error
                }
            }
            if !opened { throw lastError }
        }
        guard let identity = transport.identity else { throw HIDTransportError.deviceNotFound }
        return HIDConnectionInfo(identity: identity, productName: transport.productName,
                                 transportMode: transport.transportMode,
                                 hasFeaturePath: transport.hasFeaturePath, hasOutputPath: transport.hasOutputPath, diagnostics: transport.connectionDiagnostics)
    }

    func open(forceReopen: Bool) async throws -> HIDConnectionInfo {
        try await perform { try self.ensureOpen(forceReopen: forceReopen) }
    }

    private func unlockOnQueue() throws -> Bool {
        try ensureOpen()
        if transport.hasFeaturePath {
            try transport.sendFeatureUnlock()
            Thread.sleep(forTimeInterval: 0.2)
            return true
        }
        for packet in BekenCodec.unlockPackets() {
            try transport.send8KOutput(BekenCodec.wrapFor8KOutput(packet))
            Thread.sleep(forTimeInterval: 0.08)
        }
        return false
    }

    func unlock() async throws -> Bool {
        try await perform { try self.unlockOnQueue() }
    }

    func send(_ packet: Data, outputOnly: Bool) async throws {
        try await perform {
            let wasOpen = self.transport.isOpen
            try self.ensureOpen()
            if !wasOpen { _ = try self.unlockOnQueue() }
            let write = {
                if outputOnly { try self.transport.send8KOutput(packet) }
                else { try self.transport.sendBekenPacket(packet) }
            }
            do { try write() }
            catch {
                Thread.sleep(forTimeInterval: 0.35)
                try self.ensureOpen(forceReopen: true)
                // A newly opened receiver must be unlocked before retrying the write.
                _ = try self.unlockOnQueue()
                try write()
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
    }

    func read(reportID: UInt8, length: Int) async throws -> Data {
        try await perform {
            try self.ensureOpen()
            return try self.transport.readBekenPacket(reportID: reportID, length: length)
        }
    }
}

enum HIDTransportError: Error, LocalizedError {
    case deviceNotFound
    case openFailed(String)
    case permissionDenied(String)
    case reportFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "SC680 receiver not found (plug 2.4G dongle, not Bluetooth)"
        case .permissionDenied(let detail):
            return "macOS denied HID access. Enable SC680Config in System Settings → Privacy & Security → Input Monitoring, quit and reopen the app, then Rescan. \(detail)"
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
    private let callbackQueue: DispatchQueue

    init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
    }
    private var manager: IOHIDManager?
    private var outputDevice: IOHIDDevice?
    private var featureDevice: IOHIDDevice?
    private(set) var identity: USBIdentity?
    private(set) var productName: String = ""
    private(set) var transportMode: TransportMode = .feature
    private(set) var usagePage: Int = 0
    private(set) var hasFeaturePath: Bool = false
    private(set) var hasOutputPath: Bool = false
    private(set) var connectionDiagnostics: String = ""

    /// Called on callbackQueue when one of the selected interfaces is removed.
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
        connectionDiagnostics = ""
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matchingDictionaries() as CFArray)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openKr = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openKr == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            throw Self.discoveryFailure(openErrors: [openKr], observations: ["IOHIDManagerOpen"])
        }
        guard let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !set.isEmpty else {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            throw HIDTransportError.deviceNotFound
        }

        let ranked = set.sorted { score($0) > score($1) }
        var openedOutput: (IOHIDDevice, USBIdentity, HIDInterfaceInfo)?
        var openedFeature: (IOHIDDevice, USBIdentity, HIDInterfaceInfo)?
        var observations = [String]()
        var openErrors = [kern_return_t]()
        var sawKnownReceiver = false

        for candidate in ranked {
            let vid = intProperty(candidate, kIOHIDVendorIDKey)
            let pid = intProperty(candidate, kIOHIDProductIDKey)
            guard let match = SC680DeviceIDs.known.first(where: { $0.vendorID == vid && $0.productID == pid }) else { continue }
            sawKnownReceiver = true
            if let selected = openedOutput ?? openedFeature {
                guard match == selected.1,
                      intProperty(candidate, kIOHIDLocationIDKey) == intProperty(selected.0, kIOHIDLocationIDKey) else { continue }
            }

            // A compound mouse interface can have PrimaryUsagePage=0x01 while also
            // exposing Output 0x04 and Feature 0x80. Try shared open before filtering.
            let shared = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
            let info = interfaceInfo(candidate)
            observations.append("\(match.label) \(info.summary); sharedOpen=\(String(format: "0x%08X", shared))")
            guard shared == kIOReturnSuccess else {
                openErrors.append(shared)
                continue
            }
            guard info.isConfigurationInterface else {
                IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
                continue
            }

            var kept = false
            if info.supports8KOutput, openedOutput == nil {
                openedOutput = (candidate, match, info)
                kept = true
            }
            if info.supportsFeatureConfiguration,
               openedFeature == nil || (info.supportsFeatureUnlock && openedFeature?.2.supportsFeatureUnlock == false) {
                if let previous = openedFeature, previous.0 !== openedOutput?.0 {
                    IOHIDDeviceClose(previous.0, IOOptionBits(kIOHIDOptionsTypeNone))
                }
                openedFeature = (candidate, match, info)
                kept = true
            }
            if !kept { IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone)) }
            if openedOutput != nil && openedFeature?.2.supportsFeatureUnlock == true { break }
        }

        connectionDiagnostics = observations.joined(separator: "\n")
        guard let selected = openedOutput ?? openedFeature else {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            if !sawKnownReceiver { throw HIDTransportError.deviceNotFound }
            throw Self.discoveryFailure(openErrors: openErrors, observations: observations)
        }
        manager = mgr
        outputDevice = openedOutput?.0
        featureDevice = openedFeature?.0
        identity = selected.1
        usagePage = selected.2.primaryUsagePage
        productName = stringProperty(selected.0, kIOHIDProductKey) ?? selected.1.label
        hasOutputPath = openedOutput != nil
        hasFeaturePath = openedFeature?.2.supportsFeatureUnlock == true
        transportMode = hasOutputPath ? (hasFeaturePath ? .dual8K : .output8K) : .feature

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { context, _, _, removedDevice in
            guard let context else { return }
            let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
            transport.callbackQueue.async { transport.handleRemoval(removedDevice) }
        }, Unmanaged.passUnretained(self).toOpaque())
        return selected.1
    }

    static func discoveryFailure(openErrors: [kern_return_t], observations: [String]) -> HIDTransportError {
        let details = observations.joined(separator: "\n")
        if let denied = openErrors.first(where: { $0 == kIOReturnNotPermitted || $0 == kIOReturnNotPrivileged }) {
            return .permissionDenied(String(format: "0x%08X", denied) + "\n" + details)
        }
        if let busy = openErrors.first(where: { $0 == kIOReturnExclusiveAccess }) {
            return .openFailed("Receiver is in exclusive use (\(String(format: "0x%08X", busy))). Quit other mouse configuration apps, then Rescan.\n\(details)")
        }
        if let error = openErrors.last {
            return .openFailed("Receiver detected; shared open failed (\(String(format: "0x%08X", error))).\n\(details)")
        }
        return .openFailed("Receiver detected and opened, but no supported configuration reports were found. Copy Connection Details for diagnosis.\n\(details)")
    }

    private func interfaceInfo(_ device: IOHIDDevice) -> HIDInterfaceInfo {
        var pages = Set<Int>()
        if let pairs = IOHIDDeviceGetProperty(device, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]] {
            for pair in pairs {
                if let page = pair[kIOHIDDeviceUsagePageKey] as? NSNumber { pages.insert(page.intValue) }
            }
        }
        var outputIDs = Set<Int>()
        var featureIDs = Set<Int>()
        if let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            for element in elements {
                pages.insert(Int(IOHIDElementGetUsagePage(element)))
                let reportID = Int(IOHIDElementGetReportID(element))
                switch IOHIDElementGetType(element) {
                case kIOHIDElementTypeOutput: outputIDs.insert(reportID)
                case kIOHIDElementTypeFeature: featureIDs.insert(reportID)
                default: break
                }
            }
        }
        return HIDInterfaceInfo(primaryUsagePage: intProperty(device, kIOHIDPrimaryUsagePageKey),
            usagePages: pages, outputReportIDs: outputIDs, featureReportIDs: featureIDs,
            maxOutputSize: intProperty(device, kIOHIDMaxOutputReportSizeKey),
            maxFeatureSize: intProperty(device, kIOHIDMaxFeatureReportSizeKey))
    }

    private func matchingDictionaries() -> [[String: Any]] {
        SC680DeviceIDs.known.map { id in
            [
                kIOHIDVendorIDKey as String: id.vendorID,
                kIOHIDProductIDKey as String: id.productID,
            ]
        }
    }

    private func handleRemoval(_ removedDevice: IOHIDDevice) {
        guard removedDevice === outputDevice || removedDevice === featureDevice else { return }
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
            if let response = BekenCodec.response(from: data, reportID: reportID) { return response }
        } catch {
            // fall through
        }
        let data = try getInputReport(reportID: BekenCodec.outputReportID8K, length: BekenCodec.outputLength8K)
        guard let response = BekenCodec.response(from: data, reportID: reportID) else {
            throw HIDTransportError.reportFailed("no valid response for report 0x\(String(reportID, radix: 16))")
        }
        return response
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
        let info = interfaceInfo(device)
        let page = info.primaryUsagePage
        var s = 0
        if vid == SC680DeviceIDs.dongle8K.vendorID && pid == SC680DeviceIDs.dongle8K.productID { s += 100 }
        if vid == SC680DeviceIDs.dongleStandard.vendorID && pid == SC680DeviceIDs.dongleStandard.productID { s += 50 }
        if info.supports8KOutput { s += 40 }
        if info.supportsFeatureUnlock { s += 30 }
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
