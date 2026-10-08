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
                Button("Rescan") { Task { await store.refreshConnection() } }
                    .disabled(store.isBusy)
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Copy Connection Details") { Task { await store.copyConnectionDetails() } }
                    .disabled(store.isBusy)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Apply All") { Task { await store.applyAll() } }
                    .disabled(store.isBusy)
                    .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }
}
