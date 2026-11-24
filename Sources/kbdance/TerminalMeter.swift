import Foundation

/// A live level bar on one terminal line, redrawn in place. Silent when output isn't a terminal.
final class TerminalMeter {
    let enabled: Bool
    private var lastDraw: Double = 0
    private static let width = 40
    private static let partialBlocks = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

    init(quiet: Bool) {
        enabled = !quiet && isatty(STDOUT_FILENO) != 0
    }

    func begin(_ header: String) {
        print(header)
        if enabled { print("\u{1B}[?25l", terminator: "") }  // hide the cursor
        fflush(stdout)
    }

    /// Draws at most 30 times a second.
    func draw(_ level: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        guard enabled, now - lastDraw >= 1.0 / 30 else { return }
        lastDraw = now
        let eighths = Int((min(max(level, 0), 1) * Float(Self.width * 8)).rounded())
        var bar = String(repeating: "█", count: eighths / 8) + Self.partialBlocks[eighths % 8]
        bar += String(repeating: " ", count: Self.width - bar.count)
        print("\r\u{1B}[2K  ▕\(bar)▏ \(String(format: "%3d", Int(level * 100)))%", terminator: "")
        fflush(stdout)
    }

    /// Prints a message on its own line above the bar.
    func note(_ message: String) {
        print(enabled ? "\r\u{1B}[2K\(message)" : message)
        fflush(stdout)
    }

    func end() {
        if enabled { print("\r\u{1B}[2K\u{1B}[?25h", terminator: "") }  // clear the line, show the cursor
        fflush(stdout)
    }
}
