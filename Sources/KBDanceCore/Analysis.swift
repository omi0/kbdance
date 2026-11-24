import CoreAudio
import Foundation
import os

/// Measures loudness on the audio queue.
///
/// Mixes to mono, optionally keeps only the bass (where the kick drum lives), and measures
/// loudness in ~5 ms chunks. The render loop collects the loudest chunk since its previous
/// frame, so short hits are never lost between frames.
final class LevelMeter {
    private struct Shared {
        var bassOnly: Bool
        var peak: Float = 0
        var fresh = false
        var heardSignal = false
        var callbacks = 0
    }

    private let shared: OSAllocatedUnfairLock<Shared>
    private let alpha: Float
    private let chunk: Int
    // Only touched on the audio queue.
    private var lowpass1: Float = 0, lowpass2: Float = 0
    private var sum: Float = 0, count = 0

    init(sampleRate: Double, bassOnly: Bool, bassCutoff: Double = 150) {
        shared = OSAllocatedUnfairLock(initialState: Shared(bassOnly: bassOnly))
        alpha = Float(1 - exp(-2 * Double.pi * bassCutoff / sampleRate))
        chunk = max(32, Int(sampleRate * 0.005))
    }

    /// Can be flipped while audio is flowing.
    var bassOnly: Bool {
        get { shared.withLock { $0.bassOnly } }
        set { shared.withLock { $0.bassOnly = newValue } }
    }

    /// Call from the audio queue with each buffer of 32-bit float samples.
    func process(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var frames = Int.max
        for buffer in buffers where buffer.mNumberChannels > 0 && buffer.mData != nil {
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels)))
        }
        guard frames != Int.max else { return }

        let bassOnly = shared.withLock { $0.bassOnly }
        var peak: Float = 0
        var completedChunk = false
        var heardSignal = false
        for frame in 0..<frames {
            var mix: Float = 0
            var channels = 0
            for buffer in buffers {
                guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let width = Int(buffer.mNumberChannels)
                for channel in 0..<width { mix += samples[frame * width + channel] }
                channels += width
            }
            guard channels > 0 else { continue }

            var x = mix / Float(channels)
            if x != 0 { heardSignal = true }
            // Two one-pole low-passes: a gentle 12 dB/octave filter. Always run, so switching is seamless.
            lowpass1 += alpha * (x - lowpass1)
            lowpass2 += alpha * (lowpass1 - lowpass2)
            if bassOnly { x = lowpass2 }

            sum += x * x
            count += 1
            if count >= chunk {
                peak = max(peak, sum / Float(count))
                sum = 0
                count = 0
                completedChunk = true
            }
        }

        let (chunkPeak, gotChunk, gotSignal) = (peak, completedChunk, heardSignal)
        shared.withLock { state in
            state.callbacks += 1
            if gotSignal { state.heardSignal = true }
            if gotChunk {
                state.peak = max(state.peak, chunkPeak)
                state.fresh = true
            }
        }
    }

    /// The loudest chunk (mean square) since the last call, or nil if no new audio arrived.
    func take() -> Float? {
        shared.withLock { state in
            guard state.fresh else { return nil }
            defer {
                state.peak = 0
                state.fresh = false
            }
            return state.peak
        }
    }

    /// Whether any non-zero sample has arrived. All-zero input means nothing is playing,
    /// or macOS is withholding the audio.
    var heardSignal: Bool { shared.withLock { $0.heardSignal } }
    var callbacks: Int { shared.withLock { $0.callbacks } }
}

/// Turns loudness into a 0...1 level that jumps up on hits and falls back smoothly.
///
/// It adapts to the volume, so quiet and loud tracks both use the full range: the top of a
/// `range`-dB window follows the recent peaks, and anything below `gate` counts as silence.
final class AudioFollower {
    var range: Float
    var release: Float
    var gate: Float
    private var ceiling: Float
    private var target: Float = 0
    private var level: Float = 0

    init(range: Float, release: Float, gate: Float) {
        self.range = range
        self.release = release
        self.gate = gate
        ceiling = gate + range
    }

    func reset() {
        ceiling = gate + range
        target = 0
        level = 0
    }

    /// Advances one frame. `meanSquare` is nil when no new audio arrived since the last frame.
    func step(dt: Float, meanSquare: Float?) -> Float {
        if let meanSquare {
            let db = 10 * log10f(max(meanSquare, 1e-12))
            // The ceiling jumps up to new peaks, then drifts down 4 dB/s to follow quieter passages,
            // but never so far down that background noise would light the keyboard.
            ceiling = max(db > ceiling ? db : ceiling - 4 * dt, gate + range)
            target = db < gate ? 0 : min(max((db - (ceiling - range)) / range, 0), 1)
        }
        let timeConstant: Float = target > level ? 0.008 : release
        level += (target - level) * (1 - expf(-dt / timeConstant))
        return level
    }
}
