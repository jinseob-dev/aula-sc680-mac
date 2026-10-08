import Foundation
import SwiftUI
import AppKit

enum ConnectionMode: String, CaseIterable, Identifiable {
    case none = "No Device"
    case wireless8K = "2.4G 8K"
    case wireless = "2.4G"
    case wired = "Wired"
    var id: String { rawValue }
}

enum LightMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case steady = "Steady"
    case breathe = "Breathe"
    case neon = "Neon"
    case cycleBreathe = "Cycle Breathe"
    case dpiSteady = "DPI Steady"
    case dpiBreathe = "DPI Breathe"
    var id: String { rawValue }

    var oemCode: UInt8 {
        switch self {
        case .off: return 0
        case .steady: return 1
        case .breathe: return 2
        case .neon: return 3
        case .cycleBreathe: return 4
        case .dpiSteady: return 5
        case .dpiBreathe: return 6
        }
    }

    static func from(oemCode: UInt8) -> LightMode {
        LightMode.allCases.first { $0.oemCode == oemCode } ?? .off
    }
}

struct DPISlot: Identifiable, Equatable, Codable {
    var id: Int
    var dpi: Int
    var red: Double
    var green: Double
    var blue: Double
    var enabled: Bool

    var color: Color {
        get { Color(red: red, green: green, blue: blue) }
        set {
            #if canImport(AppKit)
            let ns = NSColor(newValue)
            if let rgb = ns.usingColorSpace(.deviceRGB) {
                red = Double(rgb.redComponent)
                green = Double(rgb.greenComponent)
                blue = Double(rgb.blueComponent)
            }
            #endif
        }
    }
}

struct ButtonBinding: Identifiable, Equatable, Codable {
    var id: Int
    var name: String
    var action: ButtonAction
}

enum ButtonAction: Equatable, Hashable {
    case leftClick, rightClick, middleClick, forward, backward
    case doubleClick, fireButton, easyAim
    case scrollUp, scrollDown
    case dpiCycle, dpiUp, dpiDown
    case profileCycle
    case shortcut(String)
    case macro(String)
    case off
    case unknown(UInt8)
}

struct MacroDefinition: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var name: String
    var events: [MacroEvent]
}

struct MacroEvent: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var key: String
    var isDown: Bool
    var delayMs: Int
}

struct MouseProfile: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var name: String
    var dpiSlots: [DPISlot]
    var activeDPIIndex: Int
    var pollingRate: Int
    var buttons: [ButtonBinding]
    var lightMode: String
    var lightBrightness: Double
    var lightSpeed: Double
    var lightRed: Double
    var lightGreen: Double
    var lightBlue: Double
    var sleepMinutes: Double
    var moveWake: Bool
    var lodMM: Int
    var debounceMs: Double
    var rippleControl: Bool
    var angleSnap: Bool
    var motionSync: Bool

    /// Reject malformed profiles before they reach UI bindings or HID encoders.
    func validated() throws -> MouseProfile {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw ProfileValidationError.invalid(message) }
        }
        try require(dpiSlots.count == 8, "A profile must contain eight DPI stages")
        try require(dpiSlots.indices.contains(activeDPIIndex), "Active DPI stage is out of range")
        try require(dpiSlots.contains(where: \.enabled), "Enable at least one DPI stage")
        try require(dpiSlots[activeDPIIndex].enabled, "The active DPI stage must be enabled")
        for (index, slot) in dpiSlots.enumerated() {
            try require(slot.id == index, "DPI stage IDs must be consecutive")
            try require((50...26000).contains(slot.dpi) && slot.dpi % 50 == 0, "DPI must be 50–26000 in steps of 50")
            try require([slot.red, slot.green, slot.blue].allSatisfy { $0.isFinite && (0...1).contains($0) }, "DPI colors must be between 0 and 1")
        }
        try require([125, 250, 500, 1000, 2000, 4000, 8000].contains(pollingRate), "Unsupported polling rate")
        try require(buttons.count == 6 || buttons.count == 7, "A profile must contain six physical button bindings")
        for (index, button) in buttons.enumerated() {
            try require(button.id == index, "Button IDs must be consecutive")
            if index < 6 {
                switch button.action {
                case .easyAim, .shortcut, .macro:
                    throw ProfileValidationError.invalid("Easy Aim, shortcuts and macro assignments are not implemented")
                default: break
                }
            }
        }
        try require(LightMode(rawValue: lightMode) != nil, "Unknown light mode")
        try require([lightBrightness, lightSpeed].allSatisfy { $0.isFinite && (0...100).contains($0) }, "Light brightness and speed must be 0–100")
        try require([lightRed, lightGreen, lightBlue].allSatisfy { $0.isFinite && (0...1).contains($0) }, "Light color must be between 0 and 1")
        try require(sleepMinutes.isFinite && (1...20).contains(sleepMinutes), "Sleep timer must be 1–20 minutes")
        try require(lodMM == 1 || lodMM == 2, "LOD must be 1 or 2 mm")
        try require(debounceMs.isFinite && (2...40).contains(debounceMs) && debounceMs.truncatingRemainder(dividingBy: 2) == 0,
                    "Debounce must be 2–40 ms in steps of 2")
        var result = self
        // Older exports included a duplicate Scroll binding for the Middle hardware slot.
        result.buttons = Array(buttons.prefix(6))
        return result
    }
}

enum ProfileValidationError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum SettingsSection: String {
    case dpi = "DPI", polling = "Polling", parameters = "Attributes", buttons = "Buttons", light = "Light"
}

@MainActor
final class DeviceStore: ObservableObject {
    @Published var connection: ConnectionMode = .none
    @Published var productName: String = ""
    @Published var batteryPercent: Int?
    @Published var isCharging: Bool = false
    @Published var statusText: String = "Connect the SC680 via 2.4G dongle or USB-C."
    @Published var lastTransport: String = ""
    @Published private(set) var connectionDetails: String = "No scan performed."

    @Published var profileDocs: [MouseProfile] = []
    @Published var activeProfileIndex: Int = 0

    @Published var dpiSlots: [DPISlot] = DeviceStore.defaultDPISlots()
    @Published var activeDPIIndex: Int = 1

    @Published var pollingRate: Int = 1000
    let pollingRates = [125, 250, 500, 1000, 2000, 4000, 8000]

    @Published var lightMode: LightMode = .off
    @Published var lightBrightness: Double = 50
    @Published var lightSpeed: Double = 50
    @Published var lightColor: Color = .red

    @Published var sleepMinutes: Double = 3
    @Published var moveWake: Bool = true
    @Published var lodMM: Int = 1
    @Published var debounceMs: Double = 8
    @Published var rippleControl: Bool = false
    @Published var angleSnap: Bool = false
    @Published var motionSync: Bool = false

    @Published var buttons: [ButtonBinding] = DeviceStore.defaultButtons()
    @Published var macros: [MacroDefinition] = []

    @Published private(set) var isBusy = false
    private let session: DeviceSession
    private var rawButtons: Data?
    private var syncMissing: [String]?
    private let profilesURL: URL
    private let macrosURL: URL

    init(session: DeviceSession = HIDClient(), storageDirectory: URL? = nil) {
        self.session = session
        let directory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SC680Config", isDirectory: true)
        profilesURL = directory.appendingPathComponent("profiles.json")
        macrosURL = directory.appendingPathComponent("macros.json")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { statusText = "Local storage unavailable: \(error.localizedDescription)" }
        loadLocalState()
        if profileDocs.isEmpty { profileDocs = [snapshotProfile(name: "Profile 1")] }
        session.onDeviceRemoved = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.rawButtons = nil
                guard !self.isBusy else { return }
                self.markDisconnected(reason: "Receiver disconnected — reconnect and tap Rescan")
            }
        }
    }

    func refreshConnection() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        syncMissing = nil
        statusText = "Connecting…"
        connectionDetails = ""
        do {
            let info = try await session.open(forceReopen: true)
            updateConnection(info)
            rawButtons = nil
            await syncFromDevice()
        } catch { markDisconnected(reason: error.localizedDescription) }
        await captureConnectionDetails()
    }

    func captureConnectionDetails() async {
        await updateReceiverPower()
        let details = await session.diagnostics()
        if !details.isEmpty {
            connectionDetails = "Transport: \(lastTransport)\n" + details
        }
    }

    private func updateReceiverPower() async {
        guard connection != .none, let power = await session.receiverPower(), connection != .none else { return }
        batteryPercent = power.batteryPercent
        isCharging = power.isCharging
        updateSyncStatus()
    }

    private func updateSyncStatus() {
        guard var missing = syncMissing else { return }
        if batteryPercent != nil || isCharging { missing.removeAll { $0 == "Battery" } }
        statusText = missing.isEmpty ? "Synced from device" : "Connected; could not read: \(missing.joined(separator: ", ")). Existing values kept."
    }

    private func updateConnection(_ info: HIDConnectionInfo) {
        connection = info.identity == SC680DeviceIDs.dongle8K ? .wireless8K : .wireless
        productName = info.productName
        lastTransport = info.transportMode.rawValue
        connectionDetails = "Receiver: \(info.identity.label), transport: \(info.transportMode.rawValue)\n" + info.diagnostics
    }

    private func markDisconnected(reason: String) {
        syncMissing = nil
        connection = .none
        productName = ""
        batteryPercent = nil
        isCharging = false
        lastTransport = ""
        rawButtons = nil
        connectionDetails = reason + "\n" + connectionDetails
        statusText = reason.components(separatedBy: "\n").first ?? reason
    }

    func syncFromDevice() async {
        syncMissing = nil
        var missing = [String]()
        batteryPercent = nil
        isCharging = false
        if let raw = try? await session.read(reportID: BekenCodec.batteryReportID, length: 7),
           let pct = BekenCodec.decodeBattery(raw) { batteryPercent = pct }
        else { missing.append("Battery") }

        if let raw = try? await session.read(reportID: BekenCodec.dpiReportID, length: 52),
           let decoded = BekenCodec.decodeDPI(raw) {
            for i in dpiSlots.indices {
                dpiSlots[i].dpi = decoded.slots[i]
                dpiSlots[i].enabled = decoded.enabledMask & (1 << i) != 0
                dpiSlots[i].red = Double(decoded.colors[i].0) / 255
                dpiSlots[i].green = Double(decoded.colors[i].1) / 255
                dpiSlots[i].blue = Double(decoded.colors[i].2) / 255
            }
            activeDPIIndex = decoded.activeIndex
        } else { missing.append("DPI") }

        if let raw = try? await session.read(reportID: BekenCodec.rateReportID, length: 9),
           let hz = BekenCodec.decodeRate(raw) { pollingRate = hz }
        else { missing.append("Polling") }

        if let raw = try? await session.read(reportID: BekenCodec.paramReportID, length: 13),
           let decoded = BekenCodec.decodeParams(raw) {
            debounceMs = Double(decoded.debounceMs)
            angleSnap = decoded.angleSnap
            rippleControl = decoded.ripple
            motionSync = decoded.motionSync
        } else { missing.append("Attributes") }

        if let raw = try? await session.read(reportID: BekenCodec.buttonReportID, length: 64),
           let actions = BekenCodec.decodeButtons(raw) {
            rawButtons = raw
            for (ui, hw) in BekenCodec.uiButtonSlots.enumerated() {
                buttons[ui].action = BekenCodec.buttonAction(from: actions[hw])
            }
        } else { missing.append("Buttons") }
        await updateReceiverPower()
        syncMissing = missing
        updateSyncStatus()
    }

    func applyAll() async { await apply([.dpi, .polling, .parameters, .buttons, .light]) }
    func applyOnly(_ section: SettingsSection) async { await apply([section]) }

    private func apply(_ sections: [SettingsSection]) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        syncMissing = nil
        statusText = "Applying…"
        var written = [String]()
        var notices = [String]()
        do {
            // Validate before any HID writes or numeric conversions.
            _ = try snapshotProfile(name: "Current").validated()
            let info = try await session.open(forceReopen: false)
            updateConnection(info)
            if !(try await session.unlock()) {
                notices.append("Receiver acceptance requires readback or a hardware check")
            }
            for section in sections {
                if info.identity == SC680DeviceIDs.dongle8K && (section == .parameters || section == .light) {
                    notices.append("\(section.rawValue) skipped: device application is not supported on this 8K receiver yet")
                    continue
                }
                if sections.count > 1, section == .buttons, rawButtons == nil {
                    // An unavailable button read must not undo or obscure other sections.
                    if let raw = try? await session.read(reportID: BekenCodec.buttonReportID, length: 64),
                       BekenCodec.decodeButtons(raw) != nil { rawButtons = raw }
                    if rawButtons == nil {
                        notices.append("Buttons skipped: existing mapping could not be read")
                        continue
                    }
                }
                let warning: String?
                switch section {
                case .dpi: warning = try await applyDPI()
                case .polling: warning = try await applyPolling()
                case .parameters: warning = try await applyParams()
                case .buttons: warning = try await applyButtons()
                case .light: warning = try await applyLight()
                }
                written.append(section.rawValue)
                if let warning { notices.append(warning) }
            }
            persistActiveProfile()
            statusText = written.isEmpty
                ? notices.joined(separator: "; ")
                : notices.isEmpty
                ? "Applied and verified: \(written.joined(separator: ", "))"
                : "\(written.joined(separator: ", ")) sent. \(notices.joined(separator: "; "))"
        } catch {
            let prefix = written.isEmpty ? "Apply failed" : "Partial apply (\(written.joined(separator: ", ")) already sent)"
            statusText = "\(prefix): \(error.localizedDescription)"
        }
        await captureConnectionDetails()
    }

    private func applyDPI() async throws -> String? {
        let values = dpiSlots.map(\.dpi)
        let colors = dpiSlots.map { (UInt8(($0.red * 255).rounded()), UInt8(($0.green * 255).rounded()), UInt8(($0.blue * 255).rounded())) }
        let mask = dpiSlots.enumerated().reduce(UInt8(0)) { $1.element.enabled ? $0 | (1 << $1.offset) : $0 }
        let packet = BekenCodec.encodeDPI(slots: values, activeIndex: activeDPIIndex, colors: colors, enabledMask: mask)
        try await session.send(packet, outputOnly: false)
        let commitNotice = await sendApplyCommit()
        guard let raw = try? await session.read(reportID: BekenCodec.dpiReportID, length: 52),
              let decoded = BekenCodec.decodeDPI(raw) else { return "DPI readback unavailable; application unverified" }
        let colorMatch = zip(colors, decoded.colors).allSatisfy { pair in
            let (expected, got) = pair
            return expected.0 == got.0 && expected.1 == got.1 && expected.2 == got.2
        }
        guard decoded.slots == values, decoded.activeIndex == activeDPIIndex,
              decoded.enabledMask == mask, colorMatch else { return "DPI readback differs from the requested stages, mask, active stage or colors" }
        return commitNotice
    }

    private func sendApplyCommit() async -> String? {
        if connection == .wireless8K {
            return "Persistence after power-cycle is unverified"
        }
        do {
            try await session.send(BekenCodec.encodeApplyCommit(), outputOnly: false)
            return nil
        } catch { return "Commit failed; persistence after power-cycle is unverified" }
    }

    private func applyPolling() async throws -> String? {
        let expected = pollingRate
        try await session.send(BekenCodec.encodeRate(hz: expected), outputOnly: false)
        guard let raw = try? await session.read(reportID: BekenCodec.rateReportID, length: 9),
              let got = BekenCodec.decodeRate(raw) else { return "Polling readback unavailable; application unverified" }
        return got == expected ? nil : "Polling readback is \(got) Hz (requested \(expected) Hz)"
    }

    private func applyParams() async throws -> String? {
        let packet = BekenCodec.encodeParams(debounceMs: Int(debounceMs), angleSnap: angleSnap,
                                             ripple: rippleControl, motionSync: motionSync)
        try await session.send(packet, outputOnly: false)
        guard let raw = try? await session.read(reportID: BekenCodec.paramReportID, length: 13),
              let got = BekenCodec.decodeParams(raw) else { return "Attributes readback unavailable; application unverified" }
        return got.debounceMs == Int(debounceMs) && got.angleSnap == angleSnap && got.ripple == rippleControl && got.motionSync == motionSync
            ? nil : "Attributes readback differs from the requested values"
    }

    private func applyButtons() async throws -> String? {
        // Read before editing so unknown actions, parameters and unmapped slots survive Apply.
        if let raw = try? await session.read(reportID: BekenCodec.buttonReportID, length: 64),
           BekenCodec.decodeButtons(raw) != nil { rawButtons = raw }
        guard let original = rawButtons, var actions = BekenCodec.decodeButtons(original) else {
            throw HIDTransportError.reportFailed("cannot read button configuration; refusing to overwrite unknown slots")
        }
        for (ui, hw) in BekenCodec.uiButtonSlots.enumerated() {
            actions[hw] = BekenCodec.actionCode(for: buttons[ui].action)
        }
        let packet = BekenCodec.encodeButtons(actions, preserving: original)
        try await session.send(packet, outputOnly: false)
        guard let raw = try? await session.read(reportID: BekenCodec.buttonReportID, length: 64),
              BekenCodec.decodeButtons(raw) != nil else { return "Buttons readback unavailable; application unverified" }
        rawButtons = raw
        return Data(raw[3...56]) == Data(packet[3...56]) ? nil : "Buttons readback differs from the requested mapping"
    }

    private func applyLight() async throws -> String? {
        let rgb = NSColor(lightColor).usingColorSpace(.deviceRGB)
        let frames = BekenCodec.encodeLightFrames(mode: lightMode.oemCode,
            brightness: UInt8(lightBrightness), speed: UInt8(lightSpeed),
            red: UInt8(clamping: Int(((rgb?.redComponent ?? 1) * 255).rounded())),
            green: UInt8(clamping: Int(((rgb?.greenComponent ?? 0) * 255).rounded())),
            blue: UInt8(clamping: Int(((rgb?.blueComponent ?? 0) * 255).rounded())))
        var lastError: Error = HIDTransportError.reportFailed("light unsupported")
        for frame in frames {
            do {
                try await session.send(frame, outputOnly: frame.first == BekenCodec.dpiReportID && frame.count == 64)
                return "Light command sent; firmware effect cannot be verified"
            } catch { lastError = error }
        }
        return "Light saved locally; device rejected the command (\(lastError.localizedDescription))"
    }

    // MARK: - Profiles / macros (local + device commit)

    func addProfile() {
        persistActiveProfile()
        let name = "Profile \(profileDocs.count + 1)"
        profileDocs.append(snapshotProfile(name: name))
        activeProfileIndex = profileDocs.count - 1
        saveLocalState()
    }

    func deleteProfile() {
        guard profileDocs.count > 1, profileDocs.indices.contains(activeProfileIndex) else {
            statusText = "Keep at least one profile"
            return
        }
        profileDocs.remove(at: activeProfileIndex)
        activeProfileIndex = max(0, activeProfileIndex - 1)
        loadProfile(at: activeProfileIndex)
        saveLocalState()
    }

    func selectProfile(_ index: Int) {
        persistActiveProfile()
        guard profileDocs.indices.contains(index) else { return }
        activeProfileIndex = index
        loadProfile(at: index)
    }

    func resetActiveProfile() {
        dpiSlots = Self.defaultDPISlots()
        activeDPIIndex = 1
        pollingRate = 1000
        buttons = Self.defaultButtons()
        lightMode = .off
        debounceMs = 8
        angleSnap = false
        rippleControl = false
        motionSync = false
        sleepMinutes = 3
        moveWake = true
        lodMM = 1
        lightBrightness = 50
        lightSpeed = 50
        lightColor = .red
        persistActiveProfile()
        statusText = "Profile reset to defaults"
    }

    func exportActiveProfile(to url: URL) throws {
        _ = try snapshotProfile(name: "Current").validated()
        persistActiveProfile()
        let data = try JSONEncoder().encode(profileDocs[activeProfileIndex])
        try data.write(to: url)
    }

    func importProfile(from url: URL) throws {
        let data = try Data(contentsOf: url)
        var profile = try JSONDecoder().decode(MouseProfile.self, from: data).validated()
        // Importing the same file twice must not create duplicate Identifiable IDs.
        profile.id = UUID()
        persistActiveProfile()
        profileDocs.append(profile)
        activeProfileIndex = profileDocs.count - 1
        loadProfile(at: activeProfileIndex)
        saveLocalState()
    }

    func addMacro() {
        macros.append(MacroDefinition(name: "Macro \(macros.count + 1)", events: []))
        saveLocalState()
    }

    func deleteMacro(_ id: UUID) {
        macros.removeAll { $0.id == id }
        saveLocalState()
    }

    // MARK: - Private

    private func snapshotProfile(name: String) -> MouseProfile {
        let ns = NSColor(lightColor)
        let rgb = ns.usingColorSpace(.deviceRGB)
        return MouseProfile(
            name: name,
            dpiSlots: dpiSlots,
            activeDPIIndex: activeDPIIndex,
            pollingRate: pollingRate,
            buttons: buttons,
            lightMode: lightMode.rawValue,
            lightBrightness: lightBrightness,
            lightSpeed: lightSpeed,
            lightRed: Double(rgb?.redComponent ?? 1),
            lightGreen: Double(rgb?.greenComponent ?? 0),
            lightBlue: Double(rgb?.blueComponent ?? 0),
            sleepMinutes: sleepMinutes,
            moveWake: moveWake,
            lodMM: lodMM,
            debounceMs: debounceMs,
            rippleControl: rippleControl,
            angleSnap: angleSnap,
            motionSync: motionSync
        )
    }

    private func persistActiveProfile() {
        guard profileDocs.indices.contains(activeProfileIndex) else { return }
        var p = snapshotProfile(name: profileDocs[activeProfileIndex].name)
        p.id = profileDocs[activeProfileIndex].id
        profileDocs[activeProfileIndex] = p
        saveLocalState()
    }

    private func loadProfile(at index: Int) {
        guard profileDocs.indices.contains(index) else { return }
        let p = profileDocs[index]
        dpiSlots = p.dpiSlots
        activeDPIIndex = p.activeDPIIndex
        pollingRate = p.pollingRate
        buttons = p.buttons
        lightMode = LightMode(rawValue: p.lightMode) ?? .off
        lightBrightness = p.lightBrightness
        lightSpeed = p.lightSpeed
        lightColor = Color(red: p.lightRed, green: p.lightGreen, blue: p.lightBlue)
        sleepMinutes = p.sleepMinutes
        moveWake = p.moveWake
        lodMM = p.lodMM
        debounceMs = p.debounceMs
        rippleControl = p.rippleControl
        angleSnap = p.angleSnap
        motionSync = p.motionSync
    }

    private func saveLocalState() {
        if let data = try? JSONEncoder().encode(profileDocs) {
            try? data.write(to: profilesURL, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(macros) {
            try? data.write(to: macrosURL, options: .atomic)
        }
    }

    private func loadLocalState() {
        if let data = try? Data(contentsOf: profilesURL),
           let docs = try? JSONDecoder().decode([MouseProfile].self, from: data) {
            profileDocs = docs.compactMap { try? $0.validated() }
            if !profileDocs.isEmpty {
                loadProfile(at: 0)
            }
            if profileDocs.count != docs.count { statusText = "Invalid saved profiles were skipped; original file kept until the next save" }
        }
        if let data = try? Data(contentsOf: macrosURL),
           let docs = try? JSONDecoder().decode([MacroDefinition].self, from: data) {
            macros = docs
        }
    }

    private static func defaultDPISlots() -> [DPISlot] {
        [
            .init(id: 0, dpi: 400, red: 1, green: 0, blue: 0, enabled: true),
            .init(id: 1, dpi: 800, red: 0, green: 1, blue: 0, enabled: true),
            .init(id: 2, dpi: 1600, red: 0, green: 0, blue: 1, enabled: true),
            .init(id: 3, dpi: 3200, red: 1, green: 0, blue: 1, enabled: true),
            .init(id: 4, dpi: 6400, red: 0, green: 1, blue: 1, enabled: true),
            .init(id: 5, dpi: 12000, red: 1, green: 1, blue: 0, enabled: false),
            .init(id: 6, dpi: 18000, red: 1, green: 0.5, blue: 0, enabled: false),
            .init(id: 7, dpi: 26000, red: 1, green: 1, blue: 1, enabled: false),
        ]
    }

    private static func defaultButtons() -> [ButtonBinding] {
        [
            .init(id: 0, name: "Left", action: .leftClick),
            .init(id: 1, name: "Right", action: .rightClick),
            .init(id: 2, name: "Middle", action: .middleClick),
            .init(id: 3, name: "Forward", action: .forward),
            .init(id: 4, name: "Back", action: .backward),
            .init(id: 5, name: "DPI", action: .dpiCycle),
        ]
    }
}
