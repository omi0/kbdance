import Foundation

public enum AudioHealth: Sendable {
    /// Real samples are arriving.
    case flowing
    /// The device runs but every sample is exactly zero: nothing is playing, or macOS is withholding audio.
    case silent
    /// No audio is arriving at all.
    case noData
}

/// Drives the keyboard backlight from music, the microphone or a wave, 60 frames a second.
///
/// Use it from the main thread only.
public final class DanceEngine {
    public private(set) var mode: DanceMode?
    /// Can change while running. Takes effect on the next frame.
    public var settings: DanceSettings { didSet { apply() } }
    /// The current 0...1 level, before it's mapped to a brightness.
    public private(set) var level: Float = 0
    /// Called on the main thread after every frame with the current level.
    public var onFrame: ((Float) -> Void)?
    /// "System audio", or the microphone's name, while an audio mode runs.
    public private(set) var sourceName: String?

    private let light: Backlight
    private var curve: OutputCurve
    private let follower: AudioFollower
    private var session: BacklightSession?
    private var capture: DeviceCapture?
    private var meter: LevelMeter?
    private var timer: DispatchSourceTimer?
    private var phase: Double = 0
    private var lastTick: Double = 0

    public init(settings: DanceSettings = DanceSettings()) throws {
        light = try Backlight()
        self.settings = settings
        curve = OutputCurve(min: settings.minBrightness, max: settings.maxBrightness)
        follower = AudioFollower(range: settings.range, release: settings.release, gate: settings.gate)
    }

    /// Starts a mode, or switches to it without handing the backlight back in between.
    /// If audio capture can't start, this throws and leaves the backlight as it was.
    public func start(_ newMode: DanceMode) throws {
        stopCapture()
        sourceName = nil
        if newMode != .wave {
            do {
                try startCapture(mic: newMode == .mic)
            } catch {
                stop()
                throw error
            }
        }
        if session == nil { session = BacklightSession(light) }
        follower.reset()
        phase = 0
        mode = newMode
        startTimer()
    }

    /// Stops and hands the backlight back: brightness, auto-brightness and idle dimming.
    public func stop() {
        stopCapture()
        timer?.cancel()
        timer = nil
        session?.restore()
        session = nil
        mode = nil
        sourceName = nil
        level = 0
    }

    public var audioHealth: AudioHealth? {
        guard let meter else { return nil }
        if meter.callbacks == 0 { return .noData }
        return meter.heardSignal ? .flowing : .silent
    }

    private func startCapture(mic: Bool) throws {
        let device: DeviceCapture = mic ? try MicCapture() : try SystemAudioCapture()
        let levels = LevelMeter(sampleRate: device.sampleRate, bassOnly: settings.band == .bass)
        do {
            try device.start { levels.process($0) }
        } catch {
            device.stop()
            throw error
        }
        capture = device
        meter = levels
        sourceName = mic ? (device.name ?? "Microphone") : "System audio"
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
        meter = nil
    }

    private func apply() {
        curve = OutputCurve(min: settings.minBrightness, max: settings.maxBrightness)
        follower.range = settings.range
        follower.release = settings.release
        follower.gate = settings.gate
        meter?.bassOnly = settings.band == .bass
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard let mode else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(now - lastTick, 0.1)
        lastTick = now

        switch mode {
        case .wave:
            // Accumulating the phase (rather than using elapsed time) keeps the wave smooth when the speed changes.
            phase = (phase + dt / settings.period).truncatingRemainder(dividingBy: 1)
            level = settings.shape.value(at: phase)
        case .music, .mic:
            level = follower.step(dt: Float(dt), meanSquare: meter?.take())
        }
        light.drive(curve.brightness(level))
        onFrame?(level)
    }
}

/// Maps a perceptual 0...1 level to hardware brightness.
///
/// The backlight's light output is roughly linear in its brightness value, so a gamma curve
/// makes waves and fades look even to the eye. The endpoints stay in hardware units, so a
/// maximum of 0.5 really means half brightness.
struct OutputCurve {
    static let gamma: Float = 2.2
    private let low: Float
    private let high: Float

    init(min: Float, max: Float) {
        low = powf(min, 1 / Self.gamma)
        high = powf(max, 1 / Self.gamma)
    }

    func brightness(_ level: Float) -> Float {
        powf(low + (high - low) * Swift.min(Swift.max(level, 0), 1), Self.gamma)
    }
}
