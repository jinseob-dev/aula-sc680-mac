import SwiftUI

@main
struct SC680ConfigApp: App {
    @StateObject private var store = DeviceStore()

    var body: some Scene {
        WindowGroup("AULA SC680") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Device") {
                Button("Rescan") { store.refreshConnection() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Apply All") { store.applyAll() }
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }
}
