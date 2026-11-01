// Application lifecycle: owns the controller and guarantees clean shutdown.
//
// Clean shutdown = AudioDeviceStop + destroy both IOProcs, the capture
// aggregate and the tap, so tapped apps are immediately audible again.
// It happens on:
//   - Quit (applicationWillTerminate, i.e. NSApplication.willTerminateNotification);
//   - SIGINT (Ctrl-C in Terminal) and SIGTERM (kill, logout).
// On a crash or SIGKILL nothing can run: we rely on the HAL destroying the
// private tap/aggregate when the process dies (see AggregateDevice.swift);
// our IOProc on the output device dies with the process.

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AudioEngineController()
    /// The menu bar icon and its panel (StatusItemController.swift).
    private var statusItemController: StatusItemController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("RoomEQ launched (pid \(ProcessInfo.processInfo.processIdentifier))")
        installSignalHandlers()
        controller.prepare()
        statusItemController = StatusItemController(controller: controller)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM] {
            // Ignore the default action (immediate exit) and handle the signal
            // on the main queue instead, where we can shut down properly.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    Log.app.notice("Signal \(signalNumber) received, shutting down")
                    self?.controller.shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
