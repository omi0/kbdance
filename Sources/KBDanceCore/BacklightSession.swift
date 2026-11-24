import Foundation

/// The backlight's state before an animation took over.
public struct SavedState: Codable, Equatable {
    public var brightness: Float
    public var autoBrightness: Bool
}

/// Keeps the pre-animation state on disk, so it can be put back even when a run is killed
/// without cleaning up (`kill -9`, a crash). Shared by the command-line tool and the app.
public enum StateFile {
    static let url = URL.applicationSupportDirectory.appending(path: "kbdance/state.json")

    public static func load() -> SavedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    static func save(_ state: SavedState) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Takes over the backlight for an animation and gives it back afterwards.
public final class BacklightSession {
    private let light: Backlight
    private let original: SavedState
    private var restored = false

    public init(_ light: Backlight) {
        self.light = light
        // A leftover file means an earlier run died mid-animation, so it holds the real original.
        original = StateFile.load() ?? SavedState(brightness: light.brightness, autoBrightness: light.autoBrightness)
        StateFile.save(original)
        // Keep the ambient light sensor and the idle timer from fighting the animation.
        light.autoBrightness = false
        light.idleDimmingSuspended = true
    }

    /// Puts back brightness, auto-brightness and idle dimming. Safe to call more than once.
    public func restore() {
        guard !restored else { return }
        restored = true
        Self.apply(original, to: light)
        StateFile.remove()
    }

    /// Puts back the state left behind by a run that never cleaned up, if there is one.
    @discardableResult
    public static func recoverLeftover(using light: Backlight) -> SavedState? {
        guard let saved = StateFile.load() else { return nil }
        apply(saved, to: light)
        StateFile.remove()
        return saved
    }

    private static func apply(_ state: SavedState, to light: Backlight) {
        light.set(state.brightness, commit: true)
        light.idleDimmingSuspended = false
        light.autoBrightness = state.autoBrightness
    }
}
