import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var tab: SidebarTab = .buttons

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, selection: $tab) { item in
                Label(item.title, systemImage: item.icon)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(200)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.connection.rawValue)
                        .font(.headline)
                    if let battery = store.batteryPercent {
                        ProgressView(value: Double(battery), total: 100) {
                            Text(store.isCharging ? "Charging \(battery)%" : "Battery \(battery)%")
                        }
                    }
                    Text(store.lastTransport.isEmpty ? "—" : "Transport: \(store.lastTransport)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Rescan") { Task { await store.refreshConnection() } }
                        .disabled(store.isBusy)
                        .buttonStyle(.borderedProminent)
                    Button("Copy Connection Details") {
                        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                        let details = "SC680Config \(version)\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nStatus: \(store.statusText)\n\(store.connectionDetails)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(details, forType: .string)
                    }
                    .disabled(store.isBusy)
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                Group {
                    switch tab {
                    case .buttons: ButtonSettingsView()
                    case .dpi: DPISettingsView()
                    case .light: LightSettingsView()
                    case .polling: PollingSettingsView()
                    case .performance: PerformanceSettingsView()
                    case .power: PowerSettingsView()
                    case .macros: MacroSettingsView()
                    case .profiles: ProfileSettingsView()
                    }
                }
                .disabled(store.isBusy)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
            }
        }
        .task {
            // One-shot connect on first appear; avoid re-opening on every view refresh.
            if store.connection == .none {
                await store.refreshConnection()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("AULA SC680 8K")
                    .font(.title2.weight(.semibold))
                Text(store.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(store.isBusy ? "Working…" : "Apply") { Task { await store.applyAll() } }
                .disabled(store.isBusy)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding()
    }
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case buttons, dpi, light, polling, performance, power, macros, profiles
    var id: String { rawValue }

    var title: String {
        switch self {
        case .buttons: return "Buttons"
        case .dpi: return "DPI"
        case .light: return "Light"
        case .polling: return "Polling Rate"
        case .performance: return "Mouse Attribute"
        case .power: return "Power"
        case .macros: return "Macros"
        case .profiles: return "Profiles"
        }
    }

    var icon: String {
        switch self {
        case .buttons: return "computermouse"
        case .dpi: return "dot.radiowaves.left.and.right"
        case .light: return "light.max"
        case .polling: return "gauge.with.dots.needle.67percent"
        case .performance: return "slider.horizontal.3"
        case .power: return "battery.75"
        case .macros: return "recordingtape"
        case .profiles: return "square.stack.3d.up"
        }
    }
}
