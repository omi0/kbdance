import Foundation

/// Read by the signal handler below, which can't capture context.
private var childPID: pid_t = 0

/// Re-launches kbdance as its own *responsible process*, then waits for it and exits with its status.
///
/// macOS files privacy permissions under the responsible process, which for a command-line tool
/// is normally the terminal app. A terminal that never declared a reason to record system audio
/// (`NSAudioCaptureUsageDescription`) is silently denied, with no dialog at all. Disclaiming
/// responsibility makes the child its own responsible process: the dialog then names kbdance,
/// shows the reasons embedded in the binary (Resources/CLI-Info.plist), and works from any terminal.
///
/// Returns only when this isn't possible, and the caller carries on under the terminal's permissions.
func relaunchAsOwnResponsibleProcess() {
    guard ProcessInfo.processInfo.environment["KBDANCE_CHILD"] == nil,
          let executable = Bundle.main.executablePath,
          let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")  // RTLD_DEFAULT
    else { return }
    typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    guard unsafeBitCast(symbol, to: SetDisclaim.self)(&attributes, 1) == 0 else { return }

    var environment = ProcessInfo.processInfo.environment
    environment["KBDANCE_CHILD"] = "1"
    let argv = CommandLine.arguments.map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (argv + envp).forEach { free($0) } }
    guard posix_spawn(&childPID, executable, nil, &attributes, argv, envp) == 0 else { return }

    // Ctrl-C reaches both processes (same process group), and the child restores the backlight,
    // so the parent just waits. Signals sent to the parent alone (kill, a closed terminal) are passed on.
    signal(SIGINT, SIG_IGN)
    for sig in [SIGTERM, SIGHUP] {
        signal(sig) { kill(childPID, $0) }
    }
    var status: Int32 = 0
    while waitpid(childPID, &status, 0) == -1 && errno == EINTR {}
    let terminatingSignal = status & 0x7f
    exit(terminatingSignal == 0 ? (status >> 8) & 0xff : 128 + terminatingSignal)
}
