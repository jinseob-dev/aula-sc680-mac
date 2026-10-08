import Foundation
import IOKit

final class MockSession: DeviceSession {
    var onDeviceRemoved: (() -> Void)?
    var responses = [UInt8: Data]()
    var writes = [Data]()
    var echoWrites = true
    var featureUnlock = true
    var failLight = false
    var openDelay: UInt64 = 0
    var diagnosticText = ""
    var powerState: ReceiverPowerState?
    func receiverPower() async -> ReceiverPowerState? { powerState }
    func diagnostics() async -> String { diagnosticText }

    func open(forceReopen: Bool) async throws -> HIDConnectionInfo {
        if openDelay > 0 { try await Task.sleep(nanoseconds: openDelay) }
        return HIDConnectionInfo(identity: SC680DeviceIDs.dongle8K, productName: "Test receiver",
                                 transportMode: .dual8K, hasFeaturePath: true, hasOutputPath: true)
    }
    func unlock() async throws -> Bool { featureUnlock }
    func send(_ packet: Data, outputOnly: Bool) async throws {
        if failLight, packet[0] == 0x07 || (packet[0] == 0x04 && packet[1] != 0x38) {
            throw HIDTransportError.reportFailed("light rejected")
        }
        writes.append(packet)
        if echoWrites, let id = packet.first, BekenCodec.response(from: packet, reportID: id) != nil {
            responses[id] = packet
        }
    }
    func read(reportID: UInt8, length: Int) async throws -> Data {
        guard let packet = responses[reportID] else { throw HIDTransportError.reportFailed("read unavailable") }
        return packet
    }
}

enum TestError: Error { case failed(String) }

@main
struct RegressionTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestError.failed(message) }
    }

    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SC680Tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        @MainActor func makeStore(_ session: MockSession) -> DeviceStore {
            DeviceStore(session: session, storageDirectory: root.appendingPathComponent(UUID().uuidString))
        }

        // Compound HID receivers need not have a vendor PrimaryUsagePage.
        let compound = HIDInterfaceInfo(primaryUsagePage: 1, usagePages: [1, 0xFF00],
            outputReportIDs: [4], featureReportIDs: [0x80], maxOutputSize: 64, maxFeatureSize: 8)
        try check(compound.isConfigurationInterface && compound.supports8KOutput && compound.supportsFeatureUnlock,
                  "Find configuration reports in a generic-desktop primary interface")
        let reportsOnly = HIDInterfaceInfo(primaryUsagePage: 1, usagePages: [1],
            outputReportIDs: [4], featureReportIDs: [], maxOutputSize: 64, maxFeatureSize: 0)
        try check(reportsOnly.supports8KOutput, "Known receiver report capabilities are sufficient")
        let mouse = HIDInterfaceInfo(primaryUsagePage: 1, usagePages: [1],
            outputReportIDs: [], featureReportIDs: [], maxOutputSize: 0, maxFeatureSize: 0)
        try check(!mouse.isConfigurationInterface, "Do not use a plain mouse input collection for configuration")
        let shortReport = HIDInterfaceInfo(primaryUsagePage: 0xFF00, usagePages: [0xFF00],
            outputReportIDs: [4], featureReportIDs: [], maxOutputSize: 20, maxFeatureSize: 0)
        try check(!shortReport.supports8KOutput, "Do not send 64-byte reports to a short output interface")
        let featureOnly = HIDInterfaceInfo(primaryUsagePage: 1, usagePages: [],
            outputReportIDs: [], featureReportIDs: [0x80], maxOutputSize: 0, maxFeatureSize: 8)
        try check(featureOnly.isConfigurationInterface && featureOnly.supportsFeatureUnlock,
                  "Keep a separate Feature unlock interface")
        let noReports = HIDTransport.discoveryFailure(openErrors: [], observations: ["primary=0x1; sharedOpen=0x00000000"]).localizedDescription
        try check(noReports.contains("no supported configuration reports") && !noReports.contains("0xE00002BC"),
                  "Never invent an open-blocked error when interfaces opened successfully")
        let denied = HIDTransport.discoveryFailure(openErrors: [kIOReturnNotPermitted], observations: [])
        if case .permissionDenied = denied {} else { throw TestError.failed("Classify actual permission denial") }
        try check(denied.localizedDescription.contains("Input Monitoring"), "Give permission-specific recovery guidance")
        let exclusive = HIDTransport.discoveryFailure(openErrors: [kIOReturnExclusiveAccess], observations: []).localizedDescription
        try check(exclusive.contains("exclusive use") && exclusive.contains("0xE00002C5"), "Preserve actual exclusive-access error")

        // Captured Windows DPI packet is the independent framing/checksum reference.
        let fixture = try String(contentsOfFile: "docs/fixtures/dpi_write_64.hex", encoding: .utf8)
        let hex = fixture.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: " ")
        let captured = Data(hex.split(whereSeparator: { $0.isWhitespace }).map { UInt8($0, radix: 16)! })
        let inbox = HIDResponseInbox()
        inbox.record(reportID: 4, data: captured, receivedAt: 100)
        try check(inbox.response(reportID: 4, receivedAfter: 99, timeout: 0) == captured,
                  "Read the requested valid interrupt response")
        try check(inbox.response(reportID: 6, receivedAfter: 99, timeout: 0) == nil,
                  "Do not route DPI interrupts to polling reads")
        try check(inbox.response(reportID: 4, receivedAfter: 101, timeout: 0) == nil,
                  "Never use a pre-write response to verify a new configuration")
        let interruptRate = BekenCodec.encodeRate(hz: 500)
        inbox.record(reportID: 4, data: interruptRate, receivedAt: 200)
        try check(BekenCodec.decodeRate(inbox.response(reportID: 6, receivedAfter: 199, timeout: 0)!) == 500,
                  "Handle callback payloads where IOKit supplies report ID separately")
        inbox.record(reportID: 1, data: Data([1, 0, 0, 0, 0, 0, 50]), receivedAt: 201)
        try check(inbox.response(reportID: 1, receivedAfter: 199, timeout: 0) == nil,
                  "Ignore pointer and keyboard reports even if bytes resemble a battery packet")
        var invalidInterrupt = captured; invalidInterrupt[50] ^= 1
        inbox.record(reportID: 4, data: invalidInterrupt, receivedAt: 300)
        try check(inbox.response(reportID: 4, receivedAfter: 299, timeout: 0) == nil,
                  "Reject invalid interrupt checksums")
        let bounded = HIDResponseInbox()
        bounded.record(reportID: 4, data: captured, receivedAt: 100)
        for i in 0..<17 { bounded.record(reportID: 4, data: Data([4, 0]), receivedAt: Double(101 + i)) }
        try check(bounded.response(reportID: 4, receivedAfter: 99, timeout: 0) == nil,
                  "Bound the interrupt queue and discard old reports")

        let decoded = BekenCodec.decodeDPI(captured)!
        try check(decoded.slots.prefix(5) == [400, 800, 1600, 3200, 6400], "Captured DPI values")
        try check(decoded.activeIndex == 1 && decoded.enabledMask == 0x1F, "Captured DPI stage/mask")
        let encoded = BekenCodec.encodeDPI(slots: [400, 800, 1600, 3200, 6400], activeIndex: 1,
            colors: [(255,0,0), (0,255,0), (0,0,255), (255,0,255), (0,255,255)], enabledMask: 0x1F)
        try check(encoded == Data(captured.prefix(52)), "Generic DPI encoder matches the historical API probe")
        var corrupt = captured; corrupt[50] ^= 1
        try check(BekenCodec.decodeDPI(corrupt) == nil, "Reject bad DPI checksum")
        try check(BekenCodec.response(from: captured, reportID: 0x06) == nil, "Do not decode DPI as polling")
        let rate = BekenCodec.encodeRate(hz: 500)
        try check(BekenCodec.decodeRate(BekenCodec.response(from: Data([4]) + rate, reportID: 0x06)!) == 500,
                  "Unwrap the requested polling response")
        try check(BekenCodec.response(from: Data([0x04] + [UInt8](repeating: 0, count: 63)), reportID: 0x04) == nil,
                  "Reject empty input report")
        // Independent OEM-derived vectors; these are not device read responses.
        let oemFixture = try String(contentsOfFile: "docs/fixtures/oem_8k_dpi_output.hex", encoding: .utf8)
        let oemHex = oemFixture.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: " ")
        let expectedOEM = Data(oemHex.split(whereSeparator: { $0.isWhitespace }).map { UInt8($0, radix: 16)! })
        let oemOutput = try BekenCodec.encode8KConfiguration(encoded)
        try check(oemOutput == expectedOEM, "Match the OEM length, payload, indication and both checksums")
        try check(BekenCodec.is8KOutputEnvelope(oemOutput), "Validate output envelope")
        var corruptOEM = oemOutput; corruptOEM[60] ^= 1
        try check(!BekenCodec.is8KOutputEnvelope(corruptOEM), "Reject corrupted outer checksum")
        try check(!BekenCodec.is8KOutputEnvelope(captured), "The old raw DPI API probe is not an OEM envelope")
        for (hz, code) in [(125, UInt8(0x20)), (250, 0x10), (500, 0x08),
                           (1000, 0x04), (2000, 0x02), (4000, 0x01), (8000, 0x40)] {
            let output = try BekenCodec.encode8KConfiguration(BekenCodec.encodeRate(hz: hz))
            try check(output[1] == 14 && output[6] == code && output[7] == ~code,
                      "OEM polling code for \(hz) Hz")
        }
        let fullButtons = try BekenCodec.encode8KConfiguration(BekenCodec.encodeButtons([2, 3, 4]))
        try check(fullButtons.count == 64 && fullButtons[1] == 64 && BekenCodec.is8KOutputEnvelope(fullButtons),
                  "59-byte buttons fit exactly without truncating their checksum")
        for unsupported in [Data(repeating: 0, count: 60), Data(), BekenCodec.unlockPackets()[0],
                            BekenCodec.encodeApplyCommit(), BekenCodec.encodeParams(debounceMs: 8, angleSnap: false, ripple: false)] {
            var rejected = false
            do { _ = try BekenCodec.encode8KConfiguration(unsupported) } catch { rejected = true }
            try check(rejected, "Reject unconfirmed commands before transport")
        }
        var oversizedRejected = false
        do { _ = try BekenCodec.wrapFor8KOutput(Data(repeating: 1, count: 60)) } catch { oversizedRejected = true }
        try check(oversizedRejected, "Never silently truncate an oversized command")
        inbox.record(reportID: 3, data: Data([3, 0x10, 0x10, 2, 0]), receivedAt: 400)
        try check(inbox.summary.contains("OEM Input 0x03: 1 events"), "Observe OEM telemetry reports")
        try check(inbox.response(reportID: 4, receivedAfter: 399, timeout: 0) == nil,
                  "Telemetry is not a complete DPI configuration or readback")

        // Real v1.0.9 receiver log: 03 10 40 01 63 => battery 99%.
        let powerInbox = HIDResponseInbox()
        powerInbox.record(reportID: 3, data: Data([3, 0x10, 0x40, 1, 0x63]))
        try check(powerInbox.receiverPower == ReceiverPowerState(batteryPercent: 99, isCharging: false),
                  "Decode the actual receiver power event")
        try check(ReceiverPowerState.decode(reportID: 3, data: Data([0x10, 0x40, 1, 0x63])) == powerInbox.receiverPower,
                  "Handle payloads with the physical ID supplied separately")
        for (id, invalid) in [(4, [UInt8(3), 0x10, 0x40, 1, 99]),
                              (3, [3, 0x10, 0x20, 1, 99]), (3, [3, 0x10, 0x40, 1, 101]),
                              (3, [3, 0x10, 0x40, 1]), (3, [3, 0x10, 0x40, 0, 99])] {
            try check(ReceiverPowerState.decode(reportID: id, data: Data(invalid)) == nil,
                      "Reject unrelated, malformed or invalid battery events")
        }
        powerInbox.record(reportID: 3, data: Data([3, 0x10, 0x10, 2, 0]))
        try check(powerInbox.receiverPower?.batteryPercent == 99, "Stage events must not replace power state")
        try check(powerInbox.response(reportID: 1, receivedAfter: 0, timeout: 0) == nil,
                  "Power telemetry is not a fabricated configuration response")
        powerInbox.record(reportID: 3, data: Data([3, 0x10, 0x40, 2, 99]))
        try check(powerInbox.receiverPower == ReceiverPowerState(batteryPercent: nil, isCharging: true),
                  "Charging must not imply a measured 100 percent")
        try check(HIDResponseInbox().receiverPower == nil, "New connection has no stale power state")
        let telemetrySession = MockSession()
        telemetrySession.powerState = ReceiverPowerState(batteryPercent: 99, isCharging: false)
        let telemetryStore = makeStore(telemetrySession)
        await telemetryStore.refreshConnection()
        try check(telemetryStore.batteryPercent == 99 && !telemetryStore.isCharging,
                  "Show the real power event even when Feature battery read fails")
        try check(!telemetryStore.statusText.contains("Battery") && telemetryStore.statusText.contains("DPI"),
                  "Only battery is resolved; full settings remain unread")
        await telemetryStore.applyAll()
        try check(telemetrySession.writes.map { $0[0] } == [4, 6],
                  "Apply All sends supported sections and preserves unread buttons")
        try check(telemetryStore.statusText.contains("Attributes skipped") && telemetryStore.statusText.contains("Light skipped") &&
                  telemetryStore.statusText.contains("Buttons skipped") && telemetryStore.statusText.contains("readback unavailable"),
                  "Preserve readback warnings and explicitly list skipped sections")
        telemetrySession.writes.removeAll()
        await telemetryStore.applyOnly(.parameters)
        try check(telemetrySession.writes.isEmpty && telemetryStore.statusText.contains("Attributes skipped"),
                  "Unsupported single-section apply must not claim a write")
        telemetrySession.powerState = nil
        await telemetryStore.refreshConnection()
        try check(telemetryStore.batteryPercent == nil && !telemetryStore.isCharging,
                  "Reconnecting without telemetry clears the previous battery")

        let minimum = BekenCodec.encodeDPI(slots: [50], activeIndex: 0, colors: [], enabledMask: 1)
        try check(BekenCodec.decodeDPI(minimum)?.slots[0] == 50, "50 DPI must survive readback")
        let actions: [ButtonAction] = [.leftClick, .rightClick, .middleClick, .forward, .backward,
            .doubleClick, .fireButton, .scrollUp, .scrollDown, .dpiCycle, .dpiUp, .dpiDown, .profileCycle, .off, .unknown(0xEE)]
        for action in actions {
            try check(BekenCodec.buttonAction(from: BekenCodec.actionCode(for: action)) == action, "Button roundtrip: \(action)")
        }
        let unknown = ButtonAction.unknown(0xEE)
        let restored = try JSONDecoder().decode(ButtonAction.self, from: JSONEncoder().encode(unknown))
        try check(restored == unknown, "Preserve unknown button code in exported JSON")

        let session = MockSession()
        session.responses[0x04] = captured
        session.responses[0x06] = BekenCodec.encodeRate(hz: 1000)
        session.responses[0x05] = BekenCodec.encodeParams(debounceMs: 8, angleSnap: true, ripple: false, motionSync: true)
        session.responses[0x01] = Data([1, 0, 0, 0, 0, 0, 76])
        var hardware = [UInt8](repeating: 1, count: 18)
        hardware[0] = 2; hardware[1] = 3; hardware[2] = 4; hardware[3] = 0x0D
        hardware[4] = 5; hardware[5] = 6; hardware[7] = 0xEE; hardware[16] = 10; hardware[17] = 9
        var original = BekenCodec.encodeButtons(hardware)
        original[25] = 0xA5 // opaque parameter on unmapped hardware slot 7
        original = BekenCodec.encodeButtons(hardware, preserving: checksumButtons(original))
        session.responses[0x08] = original
        let store = makeStore(session)
        session.diagnosticText = "GET_REPORT Input 0x04 failed: 0xE00002E2"
        await store.refreshConnection()
        try check(store.connectionDetails.contains("0xE00002E2"), "Expose actual read errors in copied diagnostics")
        try check(store.buttons.count == 6, "Wheel click must not become a duplicate seventh button")
        try check(store.buttons[3].action == .forward && store.buttons[4].action == .backward, "Forward/Back mapping")
        try check(!store.dpiSlots[5].enabled && !store.dpiSlots[7].enabled, "Disabled stages stay disabled")
        try check(store.dpiSlots[1].green == 1 && store.motionSync, "Read colors and Motion Sync")
        await store.applyOnly(.dpi)
        let writtenDPI = session.writes.first { $0[0] == 4 && $0[1] == 0x38 }!
        try check(writtenDPI[5] == 0x1F && writtenDPI[29] == 255, "Preserve DPI mask and color on Apply")
        try check(store.statusText.contains("Persistence after power-cycle is unverified"), "Readback must not imply confirmed persistence")
        try check(!session.writes.contains { $0.first == 0x0C }, "Do not send the guessed 8K commit")
        store.buttons[2].action = .doubleClick
        await store.applyOnly(.buttons)
        let writtenButtons = session.writes.last { $0[0] == 8 }!
        let buttonCodes = BekenCodec.decodeButtons(writtenButtons)!
        try check(buttonCodes[2] == 7 && buttonCodes[4] == 5 && buttonCodes[5] == 6, "Middle/Forward/Back write mapping")
        try check(writtenButtons[25] == 0xA5 && buttonCodes[7] == 0xEE, "Preserve opaque action parameters/unmapped slots")
        await store.refreshConnection()
        try check(store.buttons[2].action == .doubleClick, "Rescan must not turn Double Click off")

        session.echoWrites = false
        store.dpiSlots[store.activeDPIIndex].dpi = 1200
        await store.applyOnly(.dpi)
        try check(store.statusText.contains("readback differs"), "Keep DPI mismatch warning")
        await store.applyAll()
        try check(store.statusText.contains("readback differs"), "Apply All must not overwrite mismatch warning")
        session.responses[0x04] = nil
        await store.applyOnly(.dpi)
        try check(store.statusText.contains("readback unavailable"), "Missing readback is unverified")
        session.responses.removeAll()
        let previous = store.dpiSlots
        await store.refreshConnection()
        try check(store.statusText.contains("could not read") && store.dpiSlots == previous, "Read failures keep existing values and report partial sync")

        let invalidStore = makeStore(MockSession())
        let valid = invalidStore.profileDocs[0]
        var malformed = [MouseProfile]()
        var bad = valid; bad.dpiSlots = []; malformed.append(bad)
        bad = valid; bad.activeDPIIndex = Int.max; malformed.append(bad)
        bad = valid; bad.activeDPIIndex = -1; malformed.append(bad)
        bad = valid; bad.dpiSlots[0].red = 1e300; malformed.append(bad)
        bad = valid; bad.dpiSlots[0].dpi = -100; malformed.append(bad)
        bad = valid; bad.dpiSlots[0].id = 99; malformed.append(bad)
        bad = valid; bad.buttons[0].id = 99; malformed.append(bad)
        bad = valid; bad.pollingRate = 999; malformed.append(bad)
        bad = valid; bad.debounceMs = 3; malformed.append(bad)
        bad = valid; bad.dpiSlots[bad.activeDPIIndex].enabled = false; malformed.append(bad)
        for profile in malformed {
            let url = root.appendingPathComponent("invalid.json")
            try JSONEncoder().encode(profile).write(to: url)
            do {
                try invalidStore.importProfile(from: url)
                throw TestError.failed("Malformed profile unexpectedly accepted")
            } catch is ProfileValidationError { }
            try check(invalidStore.profileDocs.count == 1, "Failed import must not mutate profile collection")
        }
        var old = valid; old.buttons.append(ButtonBinding(id: 6, name: "Scroll", action: .off))
        let migrated = try old.validated()
        try check(migrated.buttons.count == 6, "Migrate old seven-binding profiles")
        invalidStore.dpiSlots = []
        await invalidStore.applyOnly(.dpi)
        try check(invalidStore.statusText.contains("eight DPI"), "Validate edited state before writing/indexing")
        let noButtons = makeStore(MockSession())
        await noButtons.applyOnly(.buttons)
        try check(noButtons.statusText.contains("refusing to overwrite"), "Do not erase unknown button slots when read fails")

        let delayed = MockSession(); delayed.openDelay = 100_000_000
        let busyStore = makeStore(delayed)
        let first = Task { await busyStore.applyOnly(.polling) }
        while !busyStore.isBusy { await Task.yield() }
        await busyStore.applyOnly(.polling)
        await first.value
        try check(delayed.writes.count == 1 && !busyStore.isBusy, "Prevent overlapping Apply operations and release busy state")
        print("PASS: interrupt routing/freshness, read diagnostics, captured framing, response validation, button/DPI preservation, verification notices, profile validation, and async operation serialization")
    }

    static func checksumButtons(_ data: Data) -> Data {
        var result = data
        let sum = data[3...56].reduce(UInt16(0)) { $0 &+ UInt16($1) }
        result[57] = UInt8(sum >> 8); result[58] = UInt8(sum & 255)
        return result
    }
}
