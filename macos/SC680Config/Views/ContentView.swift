import SwiftUI

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
                    Button("Rescan") { store.refreshConnection() }
                        .buttonStyle(.borderedProminent)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
            }
        }
        .task {
            // One-shot connect on first appear; avoid re-opening on every view refresh.
            if store.connection == .none {
                store.refreshConnection()
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
                    .lineLimit(2)
            }
            Spacer()
            Button("Apply") { store.applyAll() }
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
