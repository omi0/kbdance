import Foundation
import os

/// A macOS privacy permission, checked and requested through the private TCC framework.
///
/// Creating a system-audio tap doesn't show the permission dialog by itself (the tap just
/// delivers silence), so callers ask explicitly before starting. macOS files the permission
/// under the *responsible process*: the app itself, or for a command-line tool, whatever
/// launched it (see `relaunchAsOwnResponsibleProcess()` in the CLI).
public enum Permission: String, Sendable {
    case systemAudio = "kTCCServiceAudioCapture"
    case microphone = "kTCCServiceMicrophone"

    public enum Status: Sendable {
        case granted, denied, notDetermined
    }

    /// nil if the private API is unavailable.
    public var status: Status? {
        guard let preflight = Self.function("TCCAccessPreflight", as: Preflight.self) else { return nil }
        switch preflight(rawValue as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the permission dialog. `completion` gets the answer on an arbitrary queue.
    /// Returns false, and never calls `completion`, if the private API is unavailable.
    @discardableResult
    public func request(completion: @escaping (Bool) -> Void) -> Bool {
        guard let request = Self.function("TCCAccessRequest", as: Request.self) else { return false }
        request(rawValue as CFString, nil, completion)
        return true
    }

    /// Blocking version of `request(completion:)`. nil if the private API is unavailable.
    public func requestAndWait() -> Bool? {
        let answered = DispatchSemaphore(value: 0)
        let granted = OSAllocatedUnfairLock(initialState: false)
        let asked = request { answer in
            granted.withLock { $0 = answer }
            answered.signal()
        }
        guard asked else { return nil }
        answered.wait()
        return granted.withLock { $0 }
    }

    /// Opens the System Settings pane where this permission is switched on.
    public var settingsURL: URL {
        let pane = self == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    /// Where to find the switch, in words.
    public var settingsPath: String {
        switch self {
        case .systemAudio:
            return "System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only"
        case .microphone:
            return "System Settings > Privacy & Security > Microphone"
        }
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let framework, let symbol = dlsym(framework, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }
}
