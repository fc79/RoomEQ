// Application lifecycle: owns the controller and guarantees clean shutdown.
//
// Clean shutdown = AudioDeviceStop + destroy both IOProcs, the capture
// aggregate and the tap, so tapped apps are immediately audible again.
// It happens on:
//   - Quit (applicationWillTerminate, i.e. NSApplication.willTerminateNotification);
//   - SIGINT (Ctrl-C in Terminal), SIGTERM (kill, logout) and SIGHUP (the
//     Terminal window it was started from closed).
// On a crash or SIGKILL nothing can run: we rely on the HAL destroying the
// private tap/aggregate when the process dies (see AggregateDevice.swift);
// our IOProc on the output device dies with the process.
//
// Only one copy runs: a second one (e.g. a fresh build while the installed
// app is open) would rewrite the same settings and play the corrected audio
// a second time. It says so and quits before touching audio or settings.

import AppKit
import RoomEQCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// nil in a second copy, which only says it is not needed and quits.
    let controller: AudioEngineController?
    let recorder = RecordingController()
    /// The menu bar icon and its panel (StatusItemController.swift).
    private var statusItemController: StatusItemController?
    private var signalSources: [DispatchSourceSignal] = []

    override init() {
        // Numbers in texts follow the user's language and region from now on;
        // first, because the controller already writes some on loading.
        TextLocale.current = .autoupdatingCurrent
        // Before the controller: it loads (and may tidy) the settings.
        controller = Self.anotherCopyIsRunning() ? nil : AudioEngineController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let controller else {
            Log.app.notice("Another copy of RoomEQ is running (pid \(ProcessInfo.processInfo.processIdentifier)): quitting")
            showAlreadyRunning()
            NSApplication.shared.terminate(nil)
            return
        }
        Log.app.info("RoomEQ launched (pid \(ProcessInfo.processInfo.processIdentifier))")
        installSignalHandlers()
        controller.prepare()
        statusItemController = StatusItemController(controller: controller, recorder: recorder)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Settings to disk first (instant), then the recording files
        // (headers written), then the engine.
        controller?.flushPendingSave()
        recorder.stopForQuit()
        controller?.shutdown()
    }

    /// Another running app with our bundle ID (any location: installed or
    /// a fresh build). Not checked without a bundle ID (bare executable).
    private static func anotherCopyIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let own = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != own && !$0.isTerminated }
    }

    private func showAlreadyRunning() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "RoomEQ è già aperto")
        alert.informativeText = String(
            localized: "Un'altra copia di RoomEQ è in funzione: la trovi nella barra dei menu. Questa copia si chiude, così non tocca l'audio e le impostazioni dell'altra. Per usare questa, esci prima dall'altra (pannello › Esci).")
        alert.addButton(withTitle: String(localized: "Chiudi"))
        alert.runModal()
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {  // SIGHUP: its Terminal window closed
            // Ignore the default action (immediate exit) and handle the signal
            // on the main queue instead, where we can shut down properly.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    Log.app.notice("Signal \(signalNumber) received, shutting down")
                    self?.controller?.flushPendingSave()
                    self?.recorder.stopForQuit()
                    self?.controller?.shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
