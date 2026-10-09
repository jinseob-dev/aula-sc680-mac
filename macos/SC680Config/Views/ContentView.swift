import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var tab: SidebarTab = .buttons

    private let onLayout: (([ContentLayoutRegion: CGRect]) -> Void)?

    init(initialTab: SidebarTab = .buttons, onLayout: (([ContentLayoutRegion: CGRect]) -> Void)? = nil) {
        _tab = State(initialValue: initialTab)
        self.onLayout = onLayout
    }

    private var selection: Binding<SidebarTab?> {
        Binding(get: { tab }, set: { if let value = $0 { tab = value } })
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(SidebarTab.allCases, selection: selection) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
                .listStyle(.sidebar)
                Divider()
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
            .frame(width: 220)
            .frame(maxHeight: .infinity)
            .recordLayout(.sidebar)
            Divider()
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
            .recordLayout(.detail)
        }
        .coordinateSpace(name: "content-layout")
        .onPreferenceChange(ContentLayoutKey.self) { onLayout?($0) }
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
            if let section = tab.settingsSection {
                Button {
                    Task { await store.applyOnly(section) }
                } label: {
                    Text(store.isBusy ? "Working…" : "Apply \(section.rawValue)")
                        .frame(minWidth: 104)
                }
                .disabled(store.isBusy)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fixedSize()
                .layoutPriority(2)
                .recordLayout(.applyButton)
            }
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

// Measure rendered regions for layout regression checks at different window sizes.
enum ContentLayoutRegion: Hashable { case sidebar, detail, applyButton }

private struct ContentLayoutKey: PreferenceKey {
    static var defaultValue: [ContentLayoutRegion: CGRect] = [:]
    static func reduce(value: inout [ContentLayoutRegion: CGRect], nextValue: () -> [ContentLayoutRegion: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func recordLayout(_ region: ContentLayoutRegion) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: ContentLayoutKey.self,
                                   value: [region: geometry.frame(in: .named("content-layout"))])
        })
    }
}
