import KBDanceCore
import ServiceManagement
import SwiftUI

struct MenuBarIcon: View {
    let dancer: Dancer
    @AppStorage("pulseIcon") private var pulseIcon = true

    var body: some View {
        let lit = dancer.isRunning && (!pulseIcon || dancer.iconLit)
        Image(systemName: lit ? "keyboard.fill" : "keyboard")
    }
}

struct Panel: View {
    @Bindable var dancer: Dancer
    @AppStorage("pulseIcon") private var pulseIcon = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            modes
            if let problem = dancer.problem {
                ProblemNote(problem: problem)
            }
            Divider()
            options
            Divider()
            settings
        }
        .padding(14)
        .frame(width: 270)
    }

    private var header: some View {
        HStack(spacing: 10) {
            GlowingIcon(dancer: dancer)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(dancer.isRunning ? "Dancing" : "Off").font(.headline)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if dancer.isRunning {
                Button("Stop", action: dancer.stop).controlSize(.small)
            }
        }
    }

    private var status: String {
        switch dancer.mode {
        case nil:
            return "Pick a mode"
        case .wave?:
            return "\(dancer.shape.title) wave · \(seconds(Dancer.period(speed: dancer.speed))) per cycle"
        case .music?:
            return dancer.waitingForSound ? "Waiting for sound…" : "Pulsing to system audio"
        case .mic?:
            return dancer.waitingForSound ? "Waiting for sound…" : "Pulsing to the microphone"
        }
    }

    private var modes: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(DanceMode.allCases, id: \.self) { mode in
                    Button { dancer.toggle(mode) } label: {
                        Label(mode.title, systemImage: mode.symbol)
                    }
                    .buttonStyle(Chip(active: dancer.mode == mode, current: dancer.selectedMode == mode))
                    .help(dancer.mode == mode ? "Stop" : mode.help)
                }
            }
            LevelBar(dancer: dancer)
        }
    }

    private var options: some View {
        VStack(spacing: 9) {
            switch dancer.selectedMode {
            case .music, .mic:
                PickerRow(title: "Follow", selection: band, options: Band.allCases, label: \.title)
                SliderRow(title: "Punch", value: $dancer.punch,
                          caption: "\(Int(Dancer.range(punch: dancer.punch).rounded())) dB")
                SliderRow(title: "Fade", value: $dancer.fade,
                          caption: milliseconds(Dancer.release(fade: dancer.fade)))
            case .wave:
                PickerRow(title: "Shape", selection: $dancer.shape, options: WaveShape.allCases, label: \.title)
                SliderRow(title: "Speed", value: $dancer.speed,
                          caption: seconds(Dancer.period(speed: dancer.speed)))
            }
            SliderRow(title: "Dimmest", value: $dancer.dimmest, caption: percent(dancer.dimmest))
            SliderRow(title: "Brightest", value: $dancer.brightest, caption: percent(dancer.brightest))
        }
    }

    /// The band of whichever audio mode is selected.
    private var band: Binding<Band> {
        Binding(
            get: { dancer.selectedMode == .mic ? dancer.micBand : dancer.musicBand },
            set: { if dancer.selectedMode == .mic { dancer.micBand = $0 } else { dancer.musicBand = $0 } }
        )
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Pulse menu bar icon", isOn: $pulseIcon)
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, enable in
                    try? enable ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    openAtLogin = SMAppService.mainApp.status == .enabled
                }
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .controlSize(.small)
            }
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - Pieces

/// Glows along with the keyboard. A separate view, so only it redraws on every frame.
struct GlowingIcon: View {
    let dancer: Dancer

    var body: some View {
        Image(systemName: dancer.isRunning ? "keyboard.fill" : "keyboard")
            .font(.title2)
            .foregroundStyle(dancer.isRunning ? Color.orange : Color.secondary)
            .opacity(dancer.isRunning ? 0.3 + 0.7 * Double(dancer.level) : 1)
    }
}

struct LevelBar: View {
    let dancer: Dancer

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Color.primary.opacity(0.07))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.orange.gradient)
                        .frame(width: geometry.size.width * CGFloat(dancer.level))
                }
        }
        .frame(height: 5)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let caption: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: $value, in: 0...1).controlSize(.mini)
            Text(caption)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

struct PickerRow<Option: Hashable>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 64, alignment: .leading)
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }
}

struct ProblemNote: View {
    let problem: Problem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .symbolRenderingMode(.multicolor)
                .fixedSize(horizontal: false, vertical: true)
            if let url = problem.settingsURL {
                Button("Open Privacy Settings") { NSWorkspace.shared.open(url) }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// An equal-width button that fills with the accent color while its mode runs. The mode whose
/// options are showing gets a softer highlight when nothing runs.
struct Chip: ButtonStyle {
    let active: Bool
    let current: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 26)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(fill(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }

    private func fill(pressed: Bool) -> Color {
        if active { return .accentColor }
        return Color.primary.opacity(pressed ? 0.18 : current ? 0.13 : 0.07)
    }
}

// MARK: - Labels

extension DanceMode {
    var title: String {
        switch self {
        case .music: return "Music"
        case .mic: return "Mic"
        case .wave: return "Wave"
        }
    }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .mic: return "mic.fill"
        case .wave: return "water.waves"
        }
    }

    var help: String {
        switch self {
        case .music: return "Pulse to whatever your Mac is playing"
        case .mic: return "Pulse to the microphone"
        case .wave: return "A smooth continuous wave"
        }
    }
}

extension Band {
    var title: String { self == .bass ? "Bass" : "Everything" }
}

extension WaveShape {
    var title: String { rawValue.capitalized }
}

/// "3.0s", "12s"
private func seconds(_ value: Double) -> String {
    value < 10 ? String(format: "%.1fs", value) : "\(Int(value.rounded()))s"
}

/// "150 ms", "1.0 s"
private func milliseconds(_ value: Float) -> String {
    value < 0.995 ? "\(Int((value * 1000).rounded())) ms" : String(format: "%.1f s", value)
}

/// "40%"
private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}
