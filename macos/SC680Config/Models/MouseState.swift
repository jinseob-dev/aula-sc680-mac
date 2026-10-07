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
                red = rgb.redComponent
                green = rgb.greenComponent
                blue = rgb.blueComponent
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
}

@MainActor
final class DeviceStore: ObservableObject {
    @Published var connection: ConnectionMode = .none
    @Published var productName: String = ""
    @Published var batteryPercent: Int?
    @Published var isCharging: Bool = false
    @Published var statusText: String = "Connect the SC680 via 2.4G dongle or USB-C."
    @Published var lastTransport: String = ""

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

    private let transport = HIDTransport()
    private let profilesURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SC680Config", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }()
    private let macrosURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SC680Config", isDirectory: true)
        return dir.appendingPathComponent("macros.json")
    }()

    init() {
        loadLocalState()
        if profileDocs.isEmpty {
            profileDocs = [snapshotProfile(name: "Profile 1")]
        }
    }

    func refreshConnection() {
        do {
            let id = try transport.openFirstMatching()
            productName = transport.productName
            connection = (id == SC680DeviceIDs.dongle8K) ? .wireless8K : .wireless
            lastTransport = transport.transportMode.rawValue
            statusText = "Connected: \(productName) (\(id.label)) via \(lastTransport)"
            syncFromDevice()
        } catch {
            connection = .none
            productName = ""
            batteryPercent = nil
            statusText = error.localizedDescription
        }
    }

    func syncFromDevice() {
        guard transport.isOpen else { return }
        do {
            // Battery
            if let bat = try? transport.readBekenPacket(reportID: BekenCodec.batteryReportID, length: 7),
               let pct = BekenCodec.decodeBattery(bat) {
                batteryPercent = pct
            }
            // DPI
            if let raw = try? transport.readBekenPacket(reportID: BekenCodec.dpiReportID, length: 52),
               let decoded = BekenCodec.decodeDPI(raw) {
                for i in 0..<min(dpiSlots.count, decoded.slots.count) where decoded.slots[i] > 0 {
                    dpiSlots[i].dpi = decoded.slots[i]
                    dpiSlots[i].enabled = true
                }
                activeDPIIndex = min(max(0, decoded.activeIndex), dpiSlots.count - 1)
            }
            // Rate
            if let raw = try? transport.readBekenPacket(reportID: BekenCodec.rateReportID, length: 9),
               let hz = BekenCodec.decodeRate(raw) {
                pollingRate = hz
            }
            // Params
            if let raw = try? transport.readBekenPacket(reportID: BekenCodec.paramReportID, length: 13),
               let p = BekenCodec.decodeParams(raw) {
                debounceMs = Double(p.debounceMs)
                angleSnap = p.angleSnap
                rippleControl = p.ripple
            }
            // Buttons
            if let raw = try? transport.readBekenPacket(reportID: BekenCodec.buttonReportID, length: 64),
               let actions = BekenCodec.decodeButtons(raw) {
                let map = [0, 1, 2, 4, 5, 3] // hw indices for first 6 UI buttons
                for (ui, hw) in map.enumerated() where ui < buttons.count && hw < actions.count {
                    buttons[ui].action = BekenCodec.buttonAction(from: actions[hw])
                }
            }
            statusText = "Synced from device"
        }
    }

    func applyAll() {
        guard transport.isOpen else {
            statusText = "No device"
            return
        }
        do {
            try sendUnlock()
            try applyDPI()
            try applyPolling()
            try applyParams()
            try applyButtons()
            try applyLight()
            persistActiveProfile()
            statusText = "Applied configuration to device"
        } catch {
            statusText = error.localizedDescription
        }
    }

    func applyDPI() throws {
        let values = dpiSlots.map(\.dpi)
        var mask: UInt8 = 0
        for (i, slot) in dpiSlots.enumerated() where slot.enabled && i < 8 {
            mask |= 1 << i
        }
        let colors: [(UInt8, UInt8, UInt8)] = dpiSlots.map {
            (UInt8(clamping: Int($0.red * 255)), UInt8(clamping: Int($0.green * 255)), UInt8(clamping: Int($0.blue * 255)))
        }
        let packet = BekenCodec.encodeDPI(slots: values, activeIndex: activeDPIIndex, colors: colors, enabledMask: mask == 0 ? 0x1F : mask)
        try transport.sendBekenPacket(packet)
        Thread.sleep(forTimeInterval: 0.08)
    }

    func applyPolling() throws {
        let packet = BekenCodec.encodeRate(hz: pollingRate)
        try transport.sendBekenPacket(packet)
        Thread.sleep(forTimeInterval: 0.08)
    }

    func applyParams() throws {
        let packet = BekenCodec.encodeParams(
            debounceMs: Int(debounceMs),
            angleSnap: angleSnap,
            ripple: rippleControl,
            motionSync: motionSync
        )
        try transport.sendBekenPacket(packet)
        Thread.sleep(forTimeInterval: 0.08)
    }

    func applyButtons() throws {
        // Hardware order: Left, Right, Middle, DPI, Back, Forward, ...
        var actions = [UInt8](repeating: 0x01, count: 18)
        let uiToHw = [0, 1, 2, 5, 4, 3, 2] // map 7 UI buttons → hw slots
        for (ui, hw) in uiToHw.enumerated() where ui < buttons.count {
            actions[hw] = BekenCodec.actionCode(for: buttons[ui].action)
        }
        actions[16] = BekenCodec.actionCode(for: .scrollUp)
        actions[17] = BekenCodec.actionCode(for: .scrollDown)
        let packet = BekenCodec.encodeButtons(actions)
        try transport.sendBekenPacket(packet)
        Thread.sleep(forTimeInterval: 0.08)
    }

    func applyLight() throws {
        // Light is OEM-extended; send as param-adjacent vendor packet using report 0x05 spare / dedicated light write.
        // SC680 UI stores mode/brightness/speed/color — encode into a 64-byte vendor frame used by many BK3633 mice.
        var buf = [UInt8](repeating: 0, count: 16)
        buf[0] = 0x07 // light report id used by several BK3633 OEM tools
        buf[1] = 0x0A
        buf[2] = 0x01
        buf[3] = lightMode.oemCode
        buf[4] = UInt8(clamping: Int(lightBrightness))
        buf[5] = UInt8(clamping: Int(lightSpeed))
        let ns = NSColor(lightColor)
        if let rgb = ns.usingColorSpace(.deviceRGB) {
            buf[6] = UInt8(clamping: Int(rgb.redComponent * 255))
            buf[7] = UInt8(clamping: Int(rgb.greenComponent * 255))
            buf[8] = UInt8(clamping: Int(rgb.blueComponent * 255))
        }
        buf[9] = buf[3] &+ buf[4] &+ buf[5] &+ buf[6] &+ buf[7] &+ buf[8]
        try? transport.sendBekenPacket(Data(buf))
    }

    func sendUnlock() throws {
        for packet in BekenCodec.unlockPackets() {
            try transport.sendBekenPacket(packet)
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    // MARK: - Profiles / macros (local + device commit)

    func addProfile() {
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
        persistActiveProfile()
        statusText = "Profile reset to defaults"
    }

    func exportActiveProfile(to url: URL) throws {
        persistActiveProfile()
        let data = try JSONEncoder().encode(profileDocs[activeProfileIndex])
        try data.write(to: url)
    }

    func importProfile(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let profile = try JSONDecoder().decode(MouseProfile.self, from: data)
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
            lightRed: rgb?.redComponent ?? 1,
            lightGreen: rgb?.greenComponent ?? 0,
            lightBlue: rgb?.blueComponent ?? 0,
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
            try? data.write(to: profilesURL)
        }
        if let data = try? JSONEncoder().encode(macros) {
            try? data.write(to: macrosURL)
        }
    }

    private func loadLocalState() {
        if let data = try? Data(contentsOf: profilesURL),
           let docs = try? JSONDecoder().decode([MouseProfile].self, from: data) {
            profileDocs = docs
            if let first = docs.first {
                profileDocs = docs
                loadProfile(at: 0)
                _ = first
            }
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
            .init(id: 6, name: "Scroll", action: .middleClick),
        ]
    }
}
