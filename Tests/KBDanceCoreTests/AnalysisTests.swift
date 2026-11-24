import CoreAudio
@testable import KBDanceCore
import XCTest

final class BeatFollowingTests: XCTestCase {
    static let sampleRate = 48_000.0
    static let framesPerSecond = 60.0

    /// Four seconds at 120 BPM: a kick drum on every beat (each 0.5 s), a hi-hat on every
    /// off-beat, and a steady tone underneath. Deterministic, so the tests are too.
    static func track(gain: Float = 1) -> [Float] {
        var noise: UInt32 = 1
        return (0..<Int(sampleRate * 4)).map { i in
            let t = Double(i) / sampleRate
            let sinceKick = t.truncatingRemainder(dividingBy: 0.5)
            let kick = sin(2 * .pi * (45 + 60 * exp(-sinceKick / 0.03)) * sinceKick) * exp(-sinceKick / 0.09) * 0.8
            noise = noise &* 1_664_525 &+ 1_013_904_223
            let white = Double(noise >> 8) / Double(1 << 23) - 1
            let hat = white * exp(-(t + 0.25).truncatingRemainder(dividingBy: 0.5) / 0.02) * 0.35
            let tone = sin(2 * .pi * 440 * t) * 0.12
            return Float(kick + hat + tone) * gain
        }
    }

    /// Runs the analysis like `DanceEngine` does: 512-sample buffers in, one level per 60 fps frame out.
    static func levels(_ samples: [Float], band: Band) -> [Float] {
        let meter = LevelMeter(sampleRate: sampleRate, bassOnly: band == .bass)
        let follower = AudioFollower(range: 18, release: 0.15, gate: -60)
        var levels: [Float] = []
        var copy = samples
        var position = 0
        copy.withUnsafeMutableBufferPointer { buffer in
            while position < buffer.count {
                let length = min(512, buffer.count - position)
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(length * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(buffer.baseAddress! + position)
                ))
                meter.process(&list)
                position += length
                while Double(levels.count) * sampleRate / framesPerSecond <= Double(position) {
                    levels.append(follower.step(dt: Float(1 / framesPerSecond), meanSquare: meter.take()))
                }
            }
        }
        return levels
    }

    // Kicks land on frames 120, 150, 180…; hi-hats on 135, 165…
    // The checks skip the first two seconds, while the follower adapts to the volume.

    func testBassFlashesOnEveryKickAndFadesBeforeTheNext() {
        let levels = Self.levels(Self.track(), band: .bass)
        for kick in [120, 150, 180, 210] {
            XCTAssertGreaterThan(levels[kick + 1], 0.9, "right after the kick at frame \(kick)")
            XCTAssertLessThan(levels[kick + 29], 0.25, "just before the beat after frame \(kick)")
        }
    }

    func testBassIgnoresHiHats() {
        let levels = Self.levels(Self.track(), band: .bass)
        for hat in [135, 165, 195] {
            XCTAssertLessThanOrEqual(levels[hat + 1], levels[hat - 1] + 0.01, "hi-hat at frame \(hat) made it brighter")
        }
    }

    func testQuietTracksStillReachFullBrightness() {
        let levels = Self.levels(Self.track(gain: 0.05), band: .bass)  // 26 dB quieter
        XCTAssertGreaterThan(levels[151], 0.9)
    }

    func testFullBandFollowsTheKicksToo() {
        let levels = Self.levels(Self.track(), band: .full)
        XCTAssertGreaterThan(levels[151], 0.9)
        XCTAssertLessThan(levels[179], levels[151])
    }

    func testSilenceStaysDark() {
        let levels = Self.levels([Float](repeating: 0, count: Int(Self.sampleRate)), band: .bass)
        XCTAssertEqual(levels.max(), 0)
    }

    func testNoiseBelowTheGateStaysDark() {
        let hiss = Self.track(gain: 0.0001)  // roughly -90 dBFS
        XCTAssertLessThan(Self.levels(hiss, band: .full).max() ?? 1, 0.01)
    }
}

final class WaveShapeTests: XCTestCase {
    func testEveryShapeStartsDarkAndPeaksHalfway() {
        for shape in WaveShape.allCases {
            XCTAssertEqual(shape.value(at: 0), 0, accuracy: 1e-5, "\(shape)")
            XCTAssertEqual(shape.value(at: 0.5), 1, accuracy: 1e-5, "\(shape)")
            XCTAssertEqual(shape.value(at: 1), 0, accuracy: 1e-5, "\(shape)")
        }
    }

    func testEveryShapeStaysInRange() {
        for shape in WaveShape.allCases {
            for step in 0...200 {
                let value = shape.value(at: Double(step) / 73)
                XCTAssert((0...1).contains(value), "\(shape) gave \(value)")
            }
        }
    }
}

final class OutputCurveTests: XCTestCase {
    func testEndpointsAreTheConfiguredBrightness() {
        let curve = OutputCurve(min: 0.1, max: 0.8)
        XCTAssertEqual(curve.brightness(0), 0.1, accuracy: 1e-5)
        XCTAssertEqual(curve.brightness(1), 0.8, accuracy: 1e-5)
    }

    func testOutOfRangeLevelsAreClamped() {
        let curve = OutputCurve(min: 0.2, max: 0.9)
        XCTAssertEqual(curve.brightness(-1), curve.brightness(0))
        XCTAssertEqual(curve.brightness(2), curve.brightness(1))
    }

    func testHalfwayLooksHalfAsBright() {
        // Perceived brightness is roughly the 1/2.2 power of light output.
        XCTAssertEqual(OutputCurve(min: 0, max: 1).brightness(0.5), powf(0.5, 2.2), accuracy: 1e-5)
    }
}
