import Foundation

/// The private CoreBrightness class behind the MacBook keyboard backlight.
/// Selectors and type encodings were checked against macOS 26 with the Objective-C runtime.
@objc private protocol KeyboardBrightnessClientAPI {
    @objc(copyKeyboardBacklightIDs) func copyKeyboardBacklightIDs() -> NSArray?
    @objc(isKeyboardBuiltIn:) func isKeyboardBuiltIn(_ id: UInt64) -> Bool
    @objc(brightnessForKeyboard:) func brightness(forKeyboard id: UInt64) -> Float
    @objc(setBrightness:fadeSpeed:commit:forKeyboard:)
    func setBrightness(_ value: Float, fadeSpeed: Int32, commit: Bool, forKeyboard id: UInt64) -> Bool
    @objc(isAutoBrightnessEnabledForKeyboard:) func isAutoBrightnessEnabled(forKeyboard id: UInt64) -> Bool
    @objc(enableAutoBrightness:forKeyboard:) func enableAutoBrightness(_ on: Bool, forKeyboard id: UInt64) -> Bool
    @objc(isIdleDimmingSuspendedOnKeyboard:) func isIdleDimmingSuspended(onKeyboard id: UInt64) -> Bool
    @objc(suspendIdleDimming:forKeyboard:) func suspendIdleDimming(_ on: Bool, forKeyboard id: UInt64) -> Bool
    @objc(isBacklightSuppressedOnKeyboard:) func isBacklightSuppressed(onKeyboard id: UInt64) -> Bool
}

private let requiredSelectors = [
    "copyKeyboardBacklightIDs", "isKeyboardBuiltIn:", "brightnessForKeyboard:",
    "setBrightness:fadeSpeed:commit:forKeyboard:", "isAutoBrightnessEnabledForKeyboard:",
    "enableAutoBrightness:forKeyboard:", "isIdleDimmingSuspendedOnKeyboard:",
    "suspendIdleDimming:forKeyboard:", "isBacklightSuppressedOnKeyboard:",
]

public enum BacklightError: Error, CustomStringConvertible {
    case unavailable(String)
    case missingSelector(String)
    case noBacklight

    public var description: String {
        switch self {
        case .unavailable(let what):
            return "\(what) is not available on this macOS version."
        case .missingSelector(let selector):
            return "This macOS version changed the private backlight API (missing \(selector))."
        case .noBacklight:
            return "No keyboard backlight found. (External keyboards like the Magic Keyboard have none.)"
        }
    }
}

/// The MacBook's keyboard backlight: one white zone with a brightness from 0 to 1.
public final class Backlight {
    private let api: KeyboardBrightnessClientAPI
    public let id: UInt64
    public let isBuiltIn: Bool
    private var lastSent: Float = -1

    public init() throws {
        let path = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        guard dlopen(path, RTLD_NOW) != nil else { throw BacklightError.unavailable("CoreBrightness.framework") }
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            throw BacklightError.unavailable("KeyboardBrightnessClient")
        }
        let object = cls.init()
        // Check every selector up front: calling a missing one would crash instead of failing politely.
        for selector in requiredSelectors where !object.responds(to: NSSelectorFromString(selector)) {
            throw BacklightError.missingSelector(selector)
        }
        let client = unsafeBitCast(object, to: KeyboardBrightnessClientAPI.self)

        let ids = (client.copyKeyboardBacklightIDs() as? [NSNumber])?.map(\.uint64Value) ?? []
        guard let chosen = ids.first(where: { client.isKeyboardBuiltIn($0) }) ?? ids.first else {
            throw BacklightError.noBacklight
        }
        api = client
        id = chosen
        isBuiltIn = client.isKeyboardBuiltIn(chosen)
    }

    public var brightness: Float { api.brightness(forKeyboard: id) }

    public var autoBrightness: Bool {
        get { api.isAutoBrightnessEnabled(forKeyboard: id) }
        set { _ = api.enableAutoBrightness(newValue, forKeyboard: id) }
    }

    public var idleDimmingSuspended: Bool {
        get { api.isIdleDimmingSuspended(onKeyboard: id) }
        set { _ = api.suspendIdleDimming(newValue, forKeyboard: id) }
    }

    /// True when the room is bright enough that macOS keeps the backlight off.
    public var isSuppressed: Bool { api.isBacklightSuppressed(onKeyboard: id) }

    /// The animation path: instant, and not saved as the user's preferred brightness.
    /// Skips changes too small to see.
    public func drive(_ value: Float) {
        let v = min(max(value, 0), 1)
        guard abs(v - lastSent) >= 0.001 else { return }
        lastSent = v
        _ = api.setBrightness(v, fadeSpeed: 0, commit: false, forKeyboard: id)
    }

    /// A one-off change, optionally saved as the user's preferred brightness.
    public func set(_ value: Float, commit: Bool) {
        let v = min(max(value, 0), 1)
        lastSent = v
        _ = api.setBrightness(v, fadeSpeed: 0, commit: commit, forKeyboard: id)
    }
}
