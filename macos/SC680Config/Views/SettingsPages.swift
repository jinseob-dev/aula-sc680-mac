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
                        Text("Easy Aim").tag(ButtonAction.easyAim)
                        Text("DPI Cycle").tag(ButtonAction.dpiCycle)
                        Text("DPI +").tag(ButtonAction.dpiUp)
                        Text("DPI -").tag(ButtonAction.dpiDown)
                        Text("Scroll Up").tag(ButtonAction.scrollUp)
                        Text("Scroll Down").tag(ButtonAction.scrollDown)
                        Text("Off").tag(ButtonAction.off)
                    }
                }
            }
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
                            Text("Active").foregroundStyle(.secondary)
                        } else {
                            Button("Use") { store.activeDPIIndex = slot.id }
                        }
                    }
                }
            }
            Section {
                Button("Apply DPI") {
                    do {
                        try store.sendUnlock()
                        Thread.sleep(forTimeInterval: 0.2)
                        try store.ensureOpen(forceReopen: false)
                        try store.applyDPI()
                        store.statusText = "DPI applied (stage \(store.activeDPIIndex + 1), \(store.dpiSlots[store.activeDPIIndex].dpi))"
                    } catch {
                        store.statusText = error.localizedDescription
                    }
                }
                Text("No Mac reboot needed. After Apply: press the mouse DPI button to cycle stages, or power-cycle the mouse. Transport should show output8K+feature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct LightSettingsView: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Form {
            Picker("Mode", selection: $store.lightMode) {
                ForEach(LightMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            LabeledContent("Brightness") { Slider(value: $store.lightBrightness, in: 0...100) }
            LabeledContent("Speed") { Slider(value: $store.lightSpeed, in: 0...100) }
            ColorPicker("Color", selection: $store.lightColor)
            Button("Apply Light") {
                do {
                    try store.sendUnlock()
                    try store.applyLight()
                } catch {
                    store.statusText = error.localizedDescription
                }
            }
            Text("Wheel LED effects are OEM-extended. If Apply does not change the mouse, use DPI tab colors (those are confirmed on SC680).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
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
            Button("Apply Polling Rate") {
                do { try store.sendUnlock(); try store.applyPolling(); store.statusText = "Polling applied" }
                catch { store.statusText = error.localizedDescription }
            }
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
            LabeledContent("Key Response Time") {
                Slider(value: $store.debounceMs, in: 2...25, step: 1)
                Text("\(Int(store.debounceMs)) ms").frame(width: 50)
            }
            Toggle("Ripple Control", isOn: $store.rippleControl)
            Toggle("Angle Snapping", isOn: $store.angleSnap)
            Toggle("Motion Sync", isOn: $store.motionSync)
            Button("Apply Attributes") {
                do { try store.sendUnlock(); try store.applyParams(); store.statusText = "Attributes applied" }
                catch { store.statusText = error.localizedDescription }
            }
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
            Text("Sleep timer is stored in the active profile and sent with Apply.")
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct MacroSettingsView: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Form {
            Section("Macros (local library; assign via Buttons when device supports onboard slots)") {
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
