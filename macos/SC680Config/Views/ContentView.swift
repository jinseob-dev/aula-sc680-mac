import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var tab: SidebarTab = .buttons

    init(initialTab: SidebarTab = .buttons) {
        _tab = State(initialValue: initialTab)
    }

    private var selection: Binding<SidebarTab?> {
        Binding(get: { tab }, set: { if let value = $0 { tab = value } })
    }

    var body: some View {
        HSplitView {
            List(SidebarTab.allCases, selection: selection) { item in
                Label(item.title, systemImage: item.icon)
                    .tag(item)
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.connection.rawValue)
                        .font(.headline)
                    if let battery = store.batteryPercent {
                        ProgressView(value: Double(battery), total: 100) {
                            Text(store.isCharging ? "Charging \(battery)%" : "Battery \(battery)%")
                        }
                    } else if store.isCharging {
                        Text("Charging — percentage unavailable")
                            .font(.caption)
                    }
                    Text(store.lastTransport.isEmpty ? "—" : "Transport: \(store.lastTransport)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Rescan") { Task { await store.refreshConnection() } }
                        .disabled(store.isBusy)
                        .buttonStyle(.borderedProminent)
                    Button("Copy Connection Details") {
                        Task { await store.copyConnectionDetails(context: "Page: \(tab.title)") }
                    }
                    .disabled(store.isBusy)
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
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
                .id(tab)
                .disabled(store.isBusy)
                .frame(minHeight: 360)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
                .padding()
            }
            .frame(minWidth: 680, maxWidth: .infinity, maxHeight: .infinity)
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
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .help(store.statusText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Button(store.isBusy ? "Working…" : tab.settingsSection.map { "Apply \($0.rawValue)" } ?? "Apply") {
                if let section = tab.settingsSection { Task { await store.applyOnly(section) } }
            }
                .disabled(store.isBusy || tab.settingsSection == nil)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding()
        .frame(maxHeight: 120)
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

    var settingsSection: SettingsSection? {
        switch self {
        case .buttons: return .buttons
        case .dpi: return .dpi
        case .light: return .light
        case .polling: return .polling
        case .performance: return .parameters
        case .power, .macros, .profiles: return nil
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
