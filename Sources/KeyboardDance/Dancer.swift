import AppKit
import KBDanceCore
import Observation

enum Problem: Equatable {
    /// The user, or macOS, refused a permission.
    case blocked(Permission)
    /// The mic runs but sends pure zeros, which is what macOS does when it's blocking it.
    case silentMic
    case noAudio
    case failed(String)

    var message: String {
        switch self {
        case .blocked(.systemAudio):
            return "macOS is blocking system audio. Turn on Keyboard Dance under System Audio Recording Only, then try again."
        case .blocked(.microphone):
            return "macOS is blocking the microphone. Turn on Keyboard Dance under Microphone, then try again."
        case .silentMic:
            return "The microphone is completely silent, so macOS may be blocking it."
        case .noAudio:
            return "No audio is arriving. Try stopping and starting again."
        case .failed(let message):
            return message
        }
    }

    var settingsURL: URL? {
        switch self {
        case .blocked(let permission): return permission.settingsURL
        case .silentMic: return Permission.microphone.settingsURL
        case .noAudio, .failed: return nil
        }
    }
}

/// The app's model: preferences, permissions, and what the panel shows. Wraps a `DanceEngine`.
@MainActor @Observable
final class Dancer {
    static let shared = Dancer()

    // MARK: Preferences
    // Saved between launches. Changes apply to a running dance straight away.

    /// The mode whose options the panel shows: the running one, or the last one used.
    var selectedMode = DanceMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .music {
        didSet { defaults.set(selectedMode.rawValue, forKey: "mode") }
    }
    /// Music and mic each keep their own band: bass suits music, everything suits voices.
    var musicBand = Band(rawValue: defaults.string(forKey: "musicBand") ?? "") ?? .bass {
        didSet { defaults.set(musicBand.rawValue, forKey: "musicBand"); pushSettings() }
    }
    var micBand = Band(rawValue: defaults.string(forKey: "micBand") ?? "") ?? .full {
        didSet { defaults.set(micBand.rawValue, forKey: "micBand"); pushSettings() }
    }
    var shape = WaveShape(rawValue: defaults.string(forKey: "shape") ?? "") ?? .sine {
        didSet { defaults.set(shape.rawValue, forKey: "shape"); pushSettings() }
    }
    // The sliders all run from 0 to 1. The mappings below turn them into engine settings.
    var punch = defaults.double(forKey: "punch", default: 0.643) {
        didSet { defaults.set(punch, forKey: "punch"); pushSettings() }
    }
    var fade = defaults.double(forKey: "fade", default: 0.367) {
        didSet { defaults.set(fade, forKey: "fade"); pushSettings() }
    }
    var speed = defaults.double(forKey: "speed", default: 0.402) {
        didSet { defaults.set(speed, forKey: "speed"); pushSettings() }
    }
    var dimmest = defaults.double(forKey: "dimmest", default: 0) {
        didSet {
            if dimmest > brightest { brightest = dimmest }
            defaults.set(dimmest, forKey: "dimmest")
            pushSettings()
        }
    }
    var brightest = defaults.double(forKey: "brightest", default: 1) {
        didSet {
            if brightest < dimmest { dimmest = brightest }
            defaults.set(brightest, forKey: "brightest")
            pushSettings()
        }
    }

    /// Loudness window: 36 dB (subtle) to 8 dB (hard on/off flashes). The default is 18 dB.
    static func range(punch: Double) -> Float { Float(36 - 28 * punch) }
    /// Fall time: 50 ms to 1 s on a log scale. The default is 150 ms.
    static func release(fade: Double) -> Float { Float(0.05 * pow(20, fade)) }
    /// Seconds per cycle: 10 s to 0.5 s on a log scale. The default is 3 s.
    static func period(speed: Double) -> Double { 10 * pow(0.05, speed) }

    // MARK: State

    private(set) var mode: DanceMode?
    /// 0...1, updated 30 times a second for the panel's meter and glowing icon.
    private(set) var level: Float = 0
    /// Flips on beats (with hysteresis), so the menu bar icon can pulse without redrawing every frame.
    private(set) var iconLit = false
    private(set) var problem: Problem?
    private(set) var waitingForSound = false
    var isRunning: Bool { mode != nil }

    @ObservationIgnored private var engine: DanceEngine?
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var resumeAfterWake: DanceMode?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// `live: false` makes an inert copy for snapshots.
    init(live: Bool = true) {
        guard live else { return }
        // If the app or the CLI was killed mid-dance last time, put the backlight back now.
        if let light = try? Backlight() { BacklightSession.recoverLeftover(using: light) }

        // Hand the backlight back for sleep, and carry on after waking.
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didWake() }
            },
        ]
    }

    // MARK: Actions

    /// Starts the mode, or stops it if it's the one running.
    func toggle(_ newMode: DanceMode) {
        mode == newMode ? stop() : start(newMode)
    }

    func start(_ newMode: DanceMode) {
        selectedMode = newMode
        guard !starting else { return }
        starting = true
        problem = nil
        Task {
            defer { starting = false }
            // If a permission is refused, whatever was already running keeps running.
            if let permission = newMode.permission, !(await Self.ensure(permission)) {
                problem = .blocked(permission)
                return
            }
            do {
                let engine = try makeEngine()
                engine.settings = settings(for: newMode)
                try engine.start(newMode)
                mode = newMode
                watchAudio(newMode)
            } catch {
                stop()
                problem = .failed(String(describing: error))
            }
        }
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        engine?.stop()
        mode = nil
        level = 0
        iconLit = false
        waitingForSound = false
        problem = nil
    }

    /// Puts the model in a fake running state, for `--snapshot`.
    func showPreview(_ previewMode: DanceMode, level previewLevel: Float) {
        selectedMode = previewMode
        mode = previewMode
        level = previewLevel
    }

    // MARK: Engine

    private func makeEngine() throws -> DanceEngine {
        if let engine { return engine }
        let created = try DanceEngine()
        created.onFrame = { [weak self] level in
            MainActor.assumeIsolated { self?.frame(level) }
        }
        engine = created
        return created
    }

    private func settings(for mode: DanceMode) -> DanceSettings {
        var settings = DanceSettings()
        settings.minBrightness = Float(dimmest)
        settings.maxBrightness = Float(brightest)
        settings.band = mode == .mic ? micBand : musicBand
        settings.gate = mode == .mic ? -55 : -60
        settings.range = Self.range(punch: punch)
        settings.release = Self.release(fade: fade)
        settings.period = Self.period(speed: speed)
        settings.shape = shape
        return settings
    }

    private func pushSettings() {
        guard let mode, let engine else { return }
        engine.settings = settings(for: mode)
    }

    private func frame(_ newLevel: Float) {
        frameCount &+= 1
        if frameCount % 2 == 0 { level = newLevel }
        if iconLit ? newLevel < 0.3 : newLevel > 0.6 { iconLit.toggle() }
    }

    /// Watches for silence: nothing playing yet (music), or a mic that macOS is blocking.
    /// Only clears the problems it raised itself.
    private func watchAudio(_ watched: DanceMode) {
        watchdog?.cancel()
        waitingForSound = false
        guard watched != .wave else { return }
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                guard let self, self.mode == watched else { return }
                switch self.engine?.audioHealth {
                case .silent?:
                    if watched == .mic { self.problem = .silentMic } else { self.waitingForSound = true }
                case .noData?:
                    self.problem = .noAudio
                case .flowing?, nil:
                    self.waitingForSound = false
                    if self.problem == .silentMic || self.problem == .noAudio { self.problem = nil }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Asks for the permission if macOS hasn't asked yet. True if audio can be used.
    private static func ensure(_ permission: Permission) async -> Bool {
        switch permission.status {
        case .denied?:
            return false
        case .notDetermined?:
            return await withCheckedContinuation { answer in
                let asked = permission.request { answer.resume(returning: $0) }
                if !asked { answer.resume(returning: true) }
            }
        case .granted?, nil:
            return true
        }
    }

    // MARK: Sleep

    private func willSleep() {
        resumeAfterWake = mode
        if mode != nil { stop() }
    }

    private func didWake() {
        guard let resume = resumeAfterWake else { return }
        resumeAfterWake = nil
        Task {
            try? await Task.sleep(for: .seconds(2))  // let audio devices come back first
            if mode == nil { start(resume) }
        }
    }
}

private let defaults = UserDefaults.standard

private extension UserDefaults {
    func double(forKey key: String, default fallback: Double) -> Double {
        object(forKey: key) as? Double ?? fallback
    }
}
