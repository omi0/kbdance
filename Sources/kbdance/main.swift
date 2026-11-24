import Foundation
import KBDanceCore

let usage = """
kbdance: make your MacBook's keyboard backlight dance.

USAGE
  kbdance music [options]    pulse to whatever your Mac is playing
  kbdance mic   [options]    pulse to the microphone
  kbdance wave  [options]    smooth continuous wave, no audio needed
  kbdance status             show the backlight's current state
  kbdance restore            put the backlight back to normal if a run was killed

COMMON OPTIONS
  --min <0-1>        dimmest brightness (default 0)
  --max <0-1>        brightest brightness (default 1)
  --quiet            don't draw the live meter

AUDIO OPTIONS (music, mic)
  --band bass|full   follow just the bass (kick drums) or everything
                     (default: bass for music, full for mic)
  --range <dB>       loudness window. Lower is punchier, higher is subtler (default 18)
  --release <sec>    how long the light takes to fall after a hit (default 0.15)
  --gate <dB>        ignore anything quieter than this (default -60 music, -55 mic)

WAVE OPTIONS
  --period <sec>     seconds per full cycle (default 3)
  --shape sine|triangle|breathe   (default sine)

Press Ctrl-C to stop. Brightness, auto-brightness and idle dimming are put back when you exit.
"""

// MARK: - Shutdown

/// Run in reverse order on Ctrl-C, kill, or a closed terminal.
var cleanup: [() -> Void] = []
var signalSources: [DispatchSourceSignal] = []

func shutdown() -> Never {
    for action in cleanup.reversed() { action() }
    cleanup.removeAll()
    exit(0)
}

func installSignalHandlers() {
    signal(SIGPIPE, SIG_IGN)
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { shutdown() }
        source.resume()
        signalSources.append(source)
    }
}

// MARK: - Commands

func makeEngine(_ settings: DanceSettings) -> DanceEngine {
    do { return try DanceEngine(settings: settings) } catch { fail("\(error)") }
}

/// Runs the engine until a signal arrives, drawing the meter on every frame.
func dance(_ engine: DanceEngine, _ mode: DanceMode, meter: TerminalMeter, header: () -> String) -> Never {
    do { try engine.start(mode) } catch { fail("\(error)") }
    installSignalHandlers()
    cleanup.append { engine.stop() }
    cleanup.append { meter.end() }
    meter.begin(header())
    engine.onFrame = { meter.draw($0) }
    dispatchMain()
}

func runAudio(_ mode: DanceMode, _ arguments: ArraySlice<String>) -> Never {
    relaunchAsOwnResponsibleProcess()
    let mic = mode == .mic
    let options = Options(arguments, valued: ["min", "max", "band", "range", "release", "gate"], flags: ["quiet"])
    var settings = DanceSettings()
    settings.minBrightness = options.number("min", default: 0, in: 0...1)
    settings.maxBrightness = options.number("max", default: 1, in: 0...1)
    settings.band = options.choice("band", default: mic ? Band.full : .bass)
    settings.range = options.number("range", default: 18, in: 3...60)
    settings.release = options.number("release", default: 0.15, in: 0.01...5)
    settings.gate = options.number("gate", default: mic ? -55 : -60, in: -120...0)
    let meter = TerminalMeter(quiet: options.flags.contains("quiet"))
    let engine = makeEngine(settings)

    let permission: Permission = mic ? .microphone : .systemAudio
    let blocked = "macOS is blocking \(mic ? "the microphone" : "system audio") for kbdance.\n"
        + "  Turn kbdance on in \(permission.settingsPath), then run it again."
    switch permission.status {
    case .denied?:
        fail(blocked)
    case .notDetermined?:
        print("Asking macOS for permission to \(mic ? "use the microphone" : "hear system audio"). Look for a dialog…")
        if permission.requestAndWait() == false { fail(blocked) }
    case .granted?, nil:
        break  // If the check isn't available, the silence hint below covers it.
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
        switch engine.audioHealth {
        case .noData?:
            meter.note("No audio is arriving. Try restarting kbdance.")
        case .silent?:
            meter.note(mic
                ? "The microphone is sending pure silence, so macOS is probably blocking it.\n  Check \(permission.settingsPath)."
                : "Not hearing anything yet. Play some music.")
        case .flowing?, nil:
            break
        }
    }

    dance(engine, mode, meter: meter) {
        let following = settings.band == .bass ? "the bass" : "everything"
        return "kbdance · \(engine.sourceName ?? "audio") · following \(following) · Ctrl-C to stop"
    }
}

func runWave(_ arguments: ArraySlice<String>) -> Never {
    let options = Options(arguments, valued: ["min", "max", "period", "shape"], flags: ["quiet"])
    var settings = DanceSettings()
    settings.minBrightness = options.number("min", default: 0, in: 0...1)
    settings.maxBrightness = options.number("max", default: 1, in: 0...1)
    settings.period = Double(options.number("period", default: 3, in: 0.1...600))
    settings.shape = options.choice("shape", default: WaveShape.sine)
    let meter = TerminalMeter(quiet: options.flags.contains("quiet"))

    dance(makeEngine(settings), .wave, meter: meter) {
        "kbdance · \(settings.shape.rawValue) wave · \(String(format: "%g", settings.period))s per cycle · Ctrl-C to stop"
    }
}

func openBacklight() -> Backlight {
    do { return try Backlight() } catch { fail("\(error)") }
}

func runStatus() {
    let light = openBacklight()
    let suppressed = light.isSuppressed ? "yes (the room is bright enough that macOS keeps it off)" : "no"
    print("""
    Keyboard backlight \(light.id)\(light.isBuiltIn ? " (built-in)" : "")
      brightness        \(Int((light.brightness * 100).rounded()))%
      auto-brightness   \(light.autoBrightness ? "on" : "off")
      idle dimming      \(light.idleDimmingSuspended ? "suspended" : "active")
      suppressed        \(suppressed)
    """)
    if StateFile.load() != nil {
        print("\nkbdance is running, or an earlier run didn't exit cleanly. If it isn't running, `kbdance restore` puts things back.")
    }
}

func runRestore() {
    let light = openBacklight()
    if let saved = BacklightSession.recoverLeftover(using: light) {
        print("Restored brightness \(Int((saved.brightness * 100).rounded()))%, auto-brightness \(saved.autoBrightness ? "on" : "off").")
    } else {
        light.idleDimmingSuspended = false
        light.autoBrightness = true
        print("Nothing saved to restore. Turned auto-brightness and idle dimming back on.")
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "music": runAudio(.music, arguments.dropFirst())
case "mic": runAudio(.mic, arguments.dropFirst())
case "wave": runWave(arguments.dropFirst())
case "status": runStatus()
case "restore": runRestore()
case nil, "-h", "--help", "help": print(usage)
case let other?: fail("unknown command '\(other)'. See `kbdance --help`.")
}
