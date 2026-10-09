import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ButtonSettingsView: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Form {
            Section("Button Mapping") {
                ForEach($store.buttons) { $button in
                    Picker(button.name, selection: $button.action) {
                        Text("Left Click").tag(ButtonAction.leftClick)
                        Text("Right Click").tag(ButtonAction.rightClick)
                        Text("Middle Click").tag(ButtonAction.middleClick)
                        Text("Forward").tag(ButtonAction.forward)
                        Text("Back").tag(ButtonAction.backward)
                        Text("Double Click").tag(ButtonAction.doubleClick)
                        Text("Fire Button").tag(ButtonAction.fireButton)
                        Text("Easy Aim (unverified)").tag(ButtonAction.easyAim).disabled(true)
                        Text("DPI Cycle").tag(ButtonAction.dpiCycle)
                        Text("DPI +").tag(ButtonAction.dpiUp)
                        Text("DPI -").tag(ButtonAction.dpiDown)
                        Text("Scroll Up").tag(ButtonAction.scrollUp)
                        Text("Scroll Down").tag(ButtonAction.scrollDown)
                        Text("Profile Cycle").tag(ButtonAction.profileCycle)
                        if case .unknown(let code) = button.action {
                            Text("Device action 0x\(String(code, radix: 16)) (preserved)").tag(button.action)
                        }
                        Text("Off").tag(ButtonAction.off)
                    }
                }
            }
            Text("Middle is the wheel click. Unknown device actions are preserved unless you change them.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct DPISettingsView: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Form {
            Section("DPI Stages") {
                ForEach($store.dpiSlots) { $slot in
                    HStack {
                        Toggle("", isOn: $slot.enabled).labelsHidden()
                        Text("Stage \(slot.id + 1)").frame(width: 70, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(slot.dpi) },
                            set: { slot.dpi = Int($0) }
                        ), in: 50...26000, step: 50)
                        TextField("", value: $slot.dpi, format: .number).frame(width: 70)
                        ColorPicker("", selection: Binding(
                            get: { slot.color },
                            set: { slot.color = $0 }
                        )).labelsHidden()
                        if store.activeDPIIndex == slot.id {
                            Text("Selected").foregroundStyle(.secondary).frame(width: 60)
                        } else {
                            Button("Select") { store.activeDPIIndex = slot.id }.frame(width: 60)
                        }
                    }
                }
            }
            Section {
                Text("Use Apply DPI above to send these stages. Choose DPI Steady or DPI Breathe in Light to follow stage colors; Steady and Breathe use their own color.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct LightSettingsView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var showingCaptureImporter = false

    var body: some View {
        Form {
            Picker("Mode", selection: $store.lightMode) {
                ForEach(LightMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            LabeledContent("Brightness") {
                Slider(value: $store.lightBrightness, in: store.connection == .wireless8K ? 12.5...100 : 0...100,
                       step: store.connection == .wireless8K ? 12.5 : 1)
            }
            LabeledContent("Speed") {
                Slider(value: $store.lightSpeed, in: store.connection == .wireless8K ? 12.5...100 : 0...100,
                       step: store.connection == .wireless8K ? 12.5 : 1)
            }
            ColorPicker("Color", selection: $store.lightColor)
            if store.connection == .wireless8K {
                Button("Import Windows Lighting Capture…") { showingCaptureImporter = true }
                Text(store.oemParameters == nil
                    ? "Import sc680_hid_capture.log once before Apply. This preserves the mouse attributes shared with lighting."
                    : "Windows lighting baseline loaded. Steady and Breathe use this color; DPI modes use the stage colors.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showingCaptureImporter,
                      allowedContentTypes: [.plainText, UTType(filenameExtension: "log") ?? .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try store.importLightingCapture(from: url) }
            catch { store.statusText = error.localizedDescription }
        }
    }
}

struct PollingSettingsView: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Form {
            Picker("Polling Rate", selection: $store.pollingRate) {
                ForEach(store.pollingRates, id: \.self) { hz in
                    Text("\(hz) Hz").tag(hz)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.grouped)
    }
}

struct PerformanceSettingsView: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Form {
            Picker("Lift-Off Distance", selection: $store.lodMM) {
                Text("1 mm").tag(1)
                Text("2 mm").tag(2)
            }
            Text("LOD is saved locally; this firmware's LOD command is not implemented.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Key Response Time") {
                Slider(value: $store.debounceMs, in: 2...40, step: 2)
                Text("\(Int(store.debounceMs)) ms").frame(width: 50)
            }
            Toggle("Ripple Control", isOn: $store.rippleControl)
            Toggle("Angle Snapping", isOn: $store.angleSnap)
            Toggle("Motion Sync", isOn: $store.motionSync)
        }
        .formStyle(.grouped)
    }
}

struct PowerSettingsView: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Form {
            LabeledContent("Sleep Timer") {
                Slider(value: $store.sleepMinutes, in: 1...20, step: 1)
                Text("\(Int(store.sleepMinutes)) min").frame(width: 60)
            }
            Toggle("Move Wake", isOn: $store.moveWake)
            LabeledContent("Battery", value: store.batteryPercent.map { "\($0)%" } ?? "—")
            Text("Sleep Timer and Move Wake are saved locally. Device commands are not implemented.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct MacroSettingsView: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Form {
            Section("Macros (local library only; device assignment and playback are not implemented)") {
                if store.macros.isEmpty {
                    Text("No macros yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.macros) { macro in
                    HStack {
                        Text(macro.name)
                        Spacer()
                        Text("\(macro.events.count) events").foregroundStyle(.secondary)
                        Button("Delete", role: .destructive) { store.deleteMacro(macro.id) }
                    }
                }
                Button("Add Macro") { store.addMacro() }
            }
        }
        .formStyle(.grouped)
    }
}

struct ProfileSettingsView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var showingImporter = false

    var body: some View {
        Form {
            Picker("Active Profile", selection: Binding(
                get: { store.activeProfileIndex },
                set: { store.selectProfile($0) }
            )) {
                ForEach(store.profileDocs.indices, id: \.self) { idx in
                    Text(store.profileDocs[idx].name).tag(idx)
                }
            }
            HStack {
                Button("Add") { store.addProfile() }
                Button("Delete") { store.deleteProfile() }
                Button("Reset") { store.resetActiveProfile() }
                Button("Import…") { showingImporter = true }
                Button("Export…") { exportProfile() }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                do {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try store.importProfile(from: url)
                    store.statusText = "Profile imported"
                } catch {
                    store.statusText = error.localizedDescription
                }
            }
        }
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "sc680-profile.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try store.exportActiveProfile(to: url)
                store.statusText = "Profile exported"
            } catch {
                store.statusText = error.localizedDescription
            }
        }
    }
}
