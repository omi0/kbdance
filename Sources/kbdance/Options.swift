import Foundation

/// Prints an error and exits.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("kbdance: \(message)\n".utf8))
    exit(1)
}

/// Parses `--name value`, `--name=value` and `--flag` arguments, rejecting anything unknown.
struct Options {
    private var values: [String: String] = [:]
    private(set) var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>, valued: Set<String>, flags allowedFlags: Set<String>) {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else { fail("unexpected argument '\(argument)'. See `kbdance --help`.") }
            var name = String(argument.dropFirst(2))
            var inlineValue: String?
            if let equals = name.firstIndex(of: "=") {
                inlineValue = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            if allowedFlags.contains(name) {
                flags.insert(name)
            } else if valued.contains(name) {
                guard let value = inlineValue ?? iterator.next() else { fail("--\(name) needs a value.") }
                values[name] = value
            } else {
                fail("unknown option --\(name). See `kbdance --help`.")
            }
        }
    }

    func number(_ name: String, default fallback: Float, in range: ClosedRange<Float>) -> Float {
        guard let raw = values[name] else { return fallback }
        guard let value = Float(raw), range.contains(value) else {
            fail("--\(name) must be a number from \(range.lowerBound) to \(range.upperBound).")
        }
        return value
    }

    func choice<T: RawRepresentable & CaseIterable>(_ name: String, default fallback: T) -> T where T.RawValue == String {
        guard let raw = values[name] else { return fallback }
        guard let value = T(rawValue: raw) else {
            fail("--\(name) must be one of: \(T.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return value
    }
}
