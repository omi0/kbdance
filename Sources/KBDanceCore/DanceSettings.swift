import Foundation

public enum DanceMode: String, CaseIterable, Sendable {
    /// Pulse to whatever the Mac is playing.
    case music
    /// Pulse to the microphone.
    case mic
    /// A smooth continuous wave, no audio needed.
    case wave

    /// The privacy permission this mode needs, if any.
    public var permission: Permission? {
        switch self {
        case .music: return .systemAudio
        case .mic: return .microphone
        case .wave: return nil
        }
    }
}

public enum Band: String, CaseIterable, Sendable {
    /// Just the low end, where the kick drum is. Gives clean pulses on the beat.
    case bass
    /// Overall loudness. Suits voices.
    case full
}

public enum WaveShape: String, CaseIterable, Sendable {
    case sine, triangle, breathe

    /// The level at `phase`, measured in cycles: 0 at the start of a cycle, 1 halfway through.
    func value(at phase: Double) -> Float {
        let fraction = phase - floor(phase)
        switch self {
        case .sine:
            return Float(0.5 - 0.5 * cos(2 * .pi * phase))
        case .triangle:
            return Float(fraction < 0.5 ? 2 * fraction : 2 - 2 * fraction)
        case .breathe:
            // The classic "sleeping Mac" LED curve: lingers dark, swells, then eases back.
            let e = M_E
            return Float((exp(sin(2 * .pi * phase - .pi / 2)) - 1 / e) / (e - 1 / e))
        }
    }
}

public struct DanceSettings: Equatable, Sendable {
    /// Dimmest hardware brightness, 0...1.
    public var minBrightness: Float = 0
    /// Brightest hardware brightness, 0...1.
    public var maxBrightness: Float = 1
    public var band: Band = .bass
    /// Width of the loudness window in dB. Lower gives harder on/off flashes.
    public var range: Float = 18
    /// Seconds the light takes to fall after a hit.
    public var release: Float = 0.15
    /// Anything quieter than this (dBFS) counts as silence.
    public var gate: Float = -60
    /// Seconds per wave cycle.
    public var period: Double = 3
    public var shape: WaveShape = .sine

    public init() {}
}
