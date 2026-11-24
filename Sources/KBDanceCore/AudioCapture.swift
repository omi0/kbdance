import CoreAudio
import Foundation

public struct AudioError: Error, CustomStringConvertible {
    public let description: String
}

/// Runs an IO block on a Core Audio device and hands its input buffers to a handler.
class DeviceCapture {
    let deviceID: AudioObjectID
    let sampleRate: Double
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "kbdance.audio", qos: .userInteractive)

    init(deviceID: AudioObjectID, sampleRate: Double) {
        self.deviceID = deviceID
        self.sampleRate = sampleRate
    }

    /// The handler runs on a private queue for every buffer.
    func start(_ handler: @escaping (UnsafePointer<AudioBufferList>) -> Void) throws {
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, queue) { _, input, _, _, _ in
            handler(input)
        }, "Creating the audio IO proc")
        procID = proc
        try check(AudioDeviceStart(deviceID, proc), "Starting audio capture")
    }

    func stop() {
        guard let proc = procID else { return }
        procID = nil
        AudioDeviceStop(deviceID, proc)
        AudioDeviceDestroyIOProcID(deviceID, proc)
    }

    /// The device's name, like "MacBook Air Microphone".
    var name: String? {
        var address = propertyAddress(kAudioObjectPropertyName)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var name: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

/// The default input device: the built-in mic, unless another one is picked in Sound settings.
final class MicCapture: DeviceCapture {
    init() throws {
        let device = try getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice,
                                     initial: AudioObjectID(kAudioObjectUnknown))
        guard device != kAudioObjectUnknown else { throw AudioError(description: "No microphone or other input device found.") }

        // Small buffers keep the pulse tight. Best effort: the device may pick its own size.
        var frames: UInt32 = 512
        var address = propertyAddress(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        let rate = try getProperty(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(48_000))
        super.init(deviceID: device, sampleRate: rate)
    }
}

/// Everything the Mac is playing, through a Core Audio process tap (macOS 14.2+).
///
/// The tap sits alone in a private aggregate device, so no real device's microphone gets
/// opened. (Opening one would, for example, switch AirPods into low-quality call mode.)
final class SystemAudioCapture: DeviceCapture {
    private let tapID: AudioObjectID
    private var destroyed = false

    init() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "kbdance"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "Creating the system audio tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "kbdance",
            kAudioAggregateDeviceUIDKey: "kbdance-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            throw AudioError(description: "Creating the capture device failed (OSStatus \(status)).")
        }

        let format = try? getProperty(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        let rate = format?.mSampleRate ?? 0
        tapID = tap
        super.init(deviceID: device, sampleRate: rate > 0 ? rate : 48_000)
    }

    override func stop() {
        super.stop()
        guard !destroyed else { return }
        destroyed = true
        AudioHardwareDestroyAggregateDevice(deviceID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}

// MARK: - Core Audio helpers

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw AudioError(description: "\(what) failed (OSStatus \(status)).") }
}

private func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

private func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
    var address = propertyAddress(selector)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    try withUnsafeMutablePointer(to: &value) { pointer in
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer), "Reading an audio property")
    }
    return value
}
