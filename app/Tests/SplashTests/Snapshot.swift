import AppKit
import SwiftUI

/// Renders the app's windows to PNG files in `SPLASH_APP_SNAPSHOTS`, light and dark, title bar and
/// toolbar included, for people to review the app's look without running it. The window is drawn
/// off screen.
@MainActor
enum Snapshot {
    static let directory = ProcessInfo.processInfo.environment["SPLASH_APP_SNAPSHOTS"].map { URL(filePath: $0) }

    static func save(_ name: String, size: CGSize = CGSize(width: 1120, height: 780), _ view: some View) async {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let controller = NSHostingController(rootView: view)
            controller.sceneBridgingOptions = .all
            let window = NSWindow(contentViewController: controller)
            window.title = "Splash"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(size)
            window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1.5))
            guard let frame = window.contentView?.superview,
                  let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
            else { continue }
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: directory.appending(path: "\(name)-\(suffix).png"))
            window.orderOut(nil)
        }
    }
}
