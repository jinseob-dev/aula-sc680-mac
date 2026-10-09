import AppKit
import SwiftUI
import Foundation

final class UIOnlySession: DeviceSession {
    var onDeviceRemoved: (() -> Void)?
    var writes: [Data] = []
    func open(forceReopen: Bool) async throws -> HIDConnectionInfo {
        HIDConnectionInfo(identity: SC680DeviceIDs.dongle8K, productName: "UI test receiver",
                          transportMode: .output8K, hasFeaturePath: false, hasOutputPath: true)
    }
    func unlock() async throws -> Bool { false }
    func send(_ packet: Data, outputOnly: Bool) async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
        writes.append(packet)
    }
    func read(reportID: UInt8, length: Int) async throws -> Data {
        try await Task.sleep(nanoseconds: 50_000_000)
        throw HIDTransportError.reportFailed("readback unavailable")
    }
}

@MainActor final class LayoutMeasurements {
    var frames: [ContentLayoutRegion: CGRect] = [:]
}

enum UICheckError: Error { case failed(String) }

@main
struct UIRegressionTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await run()
                print("PASS: Apply preserves content; sidebar and Apply button fit minimum, wide, and tall windows")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("UI regression failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func run() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let session = UIOnlySession()
        let store = DeviceStore(session: session, storageDirectory: temp)
        await store.refreshConnection()
        let layout = LayoutMeasurements()
        let host = NSHostingView(rootView: ContentView(initialTab: .dpi, onLayout: { layout.frames = $0 }).environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await checkRendered(host, layout: layout, name: "before")
        await store.applyOnly(.dpi)
        guard session.writes.map({ $0[0] }) == [4] else { throw UICheckError.failed("DPI Apply wrote another section") }
        try await checkRendered(host, layout: layout, name: "after-dpi")
        await store.applyAll()
        try await checkRendered(host, layout: layout, name: "after-all")
        store.statusText = String(repeating: "Long readback and unsupported-settings warning. ", count: 100)
        try await checkRendered(host, layout: layout, name: "long-status")
        for size in [NSSize(width: 1440, height: 900), NSSize(width: 1500, height: 1660)] {
            window.setContentSize(size)
            try await checkRendered(host, layout: layout, name: "resized-\(Int(size.width))-\(Int(size.height))")
        }
        window.setContentSize(NSSize(width: 980, height: 680))
        let apply = Task { await store.applyOnly(.dpi) }
        try await checkRendered(host, layout: layout, name: "during-apply")
        await apply.value
        try await checkRendered(host, layout: layout, name: "after-resize-apply")
        guard SidebarTab.dpi.settingsSection == .dpi,
              SidebarTab.polling.settingsSection == .polling,
              SidebarTab.profiles.settingsSection == nil else { throw UICheckError.failed("Page routing") }
    }

    @MainActor static func checkRendered<V: View>(_ host: NSHostingView<V>, layout: LayoutMeasurements, name: String) async throws {
        try await Task.sleep(nanoseconds: 250_000_000)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw UICheckError.failed("No rendered bitmap for \(name)")
        }
        host.cacheDisplay(in: host.bounds, to: image)
        let directory = URL(fileURLWithPath: "macos/build/ui-regressions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let png = image.representation(using: .png, properties: [:]) {
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
        guard let sidebar = layout.frames[.sidebar], let detail = layout.frames[.detail],
              let button = layout.frames[.applyButton] else {
            throw UICheckError.failed("Missing measured regions for \(name)")
        }
        guard abs(sidebar.minX) < 2, abs(sidebar.width - 220) < 2,
              abs(detail.minX - sidebar.maxX) < 3,
              abs(detail.maxX - host.bounds.width) < 3 else {
            throw UICheckError.failed("Misaligned sidebar/detail for \(name): \(layout.frames)")
        }
        guard button.width >= 80, button.height >= 24,
              button.minX > detail.minX, button.maxX <= detail.maxX,
              button.minY >= 0, button.maxY <= 120 else {
            throw UICheckError.failed("Apply button clipped or compressed for \(name): \(button)")
        }
        // Sample the middle of the detail pane, excluding the sidebar and header.
        // A blank background cannot satisfy this check through title/sidebar pixels.
        var palette = Set<String>()
        for y in stride(from: image.pixelsHigh / 4, to: image.pixelsHigh * 3 / 4, by: 3) {
            for x in stride(from: image.pixelsWide / 3, to: image.pixelsWide * 9 / 10, by: 3) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                palette.insert("\(Int(color.redComponent * 16)),\(Int(color.greenComponent * 16)),\(Int(color.blueComponent * 16))")
            }
        }
        guard palette.count > 5 else { throw UICheckError.failed("Blank detail pane after \(name): \(palette.count) colors") }
    }
}
