import KBDanceCore
import SwiftUI

@main
struct KeyboardDanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var dancer = Dancer.shared

    var body: some Scene {
        MenuBarExtra {
            Panel(dancer: dancer)
        } label: {
            MenuBarIcon(dancer: dancer)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Hands the backlight back however the app ends: Quit, logout, or `kill` (build-app.sh uses `pkill`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminateSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let mode = arguments.dropFirst(index + 2).first.flatMap(DanceMode.init) ?? .music
            Snapshot.write(to: arguments[index + 1], mode: mode)
            exit(0)
        }

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        terminateSignal = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        Dancer.shared.stop()
    }
}

/// `KeyboardDance --snapshot out.png [music|mic|wave]` renders the panel to a PNG and exits.
/// Used for the README screenshot.
enum Snapshot {
    @MainActor static func write(to path: String, mode: DanceMode) {
        let dancer = Dancer(live: false)
        dancer.showPreview(mode, level: 0.72)
        let root = Panel(dancer: dancer)
            .background(Color(white: 0.17))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .environment(\.colorScheme, .dark)

        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
