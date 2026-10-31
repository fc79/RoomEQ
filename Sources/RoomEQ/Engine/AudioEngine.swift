// Runs engine sessions on a dedicated serial queue.
//
// Threads involved:
//   - main thread: the controller; calls the public methods below, receives
//     completions and events (always delivered on main);
//   - engine queue (serial): ALL Core Audio setup/teardown. These calls can
//     block for a while (creating aggregates, starting IO, the ~0.7 s
//     warm-up), so they never run on the main thread;
//   - listener queue (serial): Core Audio property listeners. They never
//     block: they only forward a signal to the engine queue;
//   - HAL real-time IO threads (capture aggregate and output device): only
//     the capture/output kernels and the overload counters (RoomEQCore).
//
// Deadlock rule: the engine queue never waits (sync) for the main thread.
// The main thread may wait for the engine queue only in `stopSynchronously`
// (app termination / signals).
//
// Every event carries the ID of the session it refers to, so the controller
// can ignore events from sessions that have already been replaced.

import Foundation
import RoomEQCore

/// Events reported to the controller (on the main thread).
enum EngineEvent {
    /// Sample rate, tap format, stream layout or IO state changed: the
    /// session must be rebuilt. The session keeps running until then.
    case restartNeeded(sessionID: Int, reason: String)
    /// The output device disappeared (e.g. USB unplugged); the session has
    /// already been stopped.
    case deviceLost(sessionID: Int, deviceName: String)
    /// New latency figures (delay increased after underruns, or values that
    /// settled after start).
    case latencyChanged(sessionID: Int, LatencyBreakdown)
}

/// `@unchecked Sendable`: mutable state is only touched on `queue`
/// (enforced with dispatchPrecondition).
final class AudioEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.federicociapi.RoomEQ.engine", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "com.federicociapi.RoomEQ.listeners", qos: .userInitiated)

    // Engine-queue state.
    private var session: EngineSession?
    private var nextSessionID = 1

    /// Receives events on the main thread. Set once before starting.
    var eventHandler: (@MainActor (EngineEvent) -> Void)?

    // MARK: Public API (call from main)

    /// Starts a new session (stopping any current one first). The result
    /// carries the new session's ID.
    func start(_ configuration: EngineConfiguration, completion: @escaping @MainActor (Result<SessionInfo, Error>) -> Void) {
        queue.async { [self] in
            stopSession()
            let session = EngineSession(id: nextSessionID, configuration: configuration)
            nextSessionID += 1
            let sessionID = session.id
            do {
                let info = try session.start(listenerQueue: listenerQueue) { [weak self] signal in
                    self?.queue.async { self?.handle(signal, sessionID: sessionID) }
                }
                self.session = session
                session.lastEmittedLatency = info.latency
                onMain { completion(.success(info)) }
                scheduleMaintenance(for: session)
            } catch {
                Log.engine.error("Start failed: \(error.localizedDescription, privacy: .public)")
                session.teardown()
                onMain { completion(.failure(error)) }
            }
        }
    }

    /// Stops the current session. With `sessionID`, stops it only if it is
    /// still that session (used to discard a start the UI no longer wants
    /// without touching a newer one).
    func stop(sessionID: Int? = nil, completion: @escaping @MainActor () -> Void = {}) {
        queue.async { [self] in
            if sessionID == nil || session?.id == sessionID {
                stopSession()
            }
            onMain { completion() }
        }
    }

    /// Blocks until everything is torn down. For app termination and
    /// SIGINT/SIGTERM only.
    func stopSynchronously() {
        queue.sync { stopSession() }
    }

    /// Recomputes latency (e.g. after the output pair moved to another stream).
    func refreshLatency() {
        queue.async { [self] in
            guard let session else { return }
            emitLatencyIfChanged(session, latency: session.currentLatency(), force: true)
        }
    }

    // MARK: Engine-queue internals

    /// Runs `body` on the main thread, as main-actor code.
    private func onMain(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }

    private func stopSession() {
        dispatchPrecondition(condition: .onQueue(queue))
        session?.teardown()
        session = nil
    }

    private func emit(_ event: EngineEvent) {
        onMain { [weak self] in self?.eventHandler?(event) }
    }

    /// Sends new latency figures to the controller, only if they changed
    /// (unless `force`).
    private func emitLatencyIfChanged(_ session: EngineSession, latency: LatencyBreakdown, force: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard force || latency != session.lastEmittedLatency else { return }
        session.lastEmittedLatency = latency
        emit(.latencyChanged(sessionID: session.id, latency))
    }

    /// Per-session background work on the engine queue (never on the RT
    /// threads), while the session is current:
    /// - every second: grow the delay if underruns happened;
    /// - after 1 s: re-read latency values with everything running;
    /// - first 10 s: log tap input peak vs output peak once per second (debug).
    private func scheduleMaintenance(for session: EngineSession) {
        func tick(_ second: Int) {
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                guard self.session === session else { return }
                if let latency = session.adaptDelayIfNeeded() {
                    emitLatencyIfChanged(session, latency: latency, force: true)
                } else if second == 1 {
                    emitLatencyIfChanged(session, latency: session.currentLatency(), force: false)
                }
                if second <= 10, let state = session.renderState, let link = session.link {
                    let peaks = state.readDiagnosticPeaks()
                    let status = link.status()
                    Log.engine.debug(
                        "Level s=\(second): tap \(String(format: "%.1f", Decibels.decibels(fromLinear: Double(peaks.input))), privacy: .public) dBFS, output \(String(format: "%.1f", Decibels.decibels(fromLinear: Double(peaks.output))), privacy: .public) dBFS; delay \(status.delayFrames), underruns \(status.underrunCycles), discontinuities \(status.discontinuities)"
                    )
                }
                tick(second + 1)
            }
        }
        _ = session.renderState?.readDiagnosticPeaks()  // start a clean window
        tick(1)
    }

    private func handle(_ signal: SessionSignal, sessionID: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Ignore late notifications from a session that no longer exists.
        guard let session, session.id == sessionID else { return }

        switch signal {
        case .configurationMayHaveChanged:
            // Several notifications usually arrive together: check once,
            // shortly after, when the HAL has settled.
            guard !session.configurationCheckScheduled else { return }
            session.configurationCheckScheduled = true
            queue.asyncAfter(deadline: .now() + 0.3) { [self] in
                session.configurationCheckScheduled = false
                guard let current = self.session, current === session, !current.restartRequested else { return }
                if let reason = current.configurationChangeReason() {
                    current.restartRequested = true
                    Log.engine.notice("Restart needed: \(reason, privacy: .public)")
                    emit(.restartNeeded(sessionID: sessionID, reason: reason))
                }
            }

        case .deviceMayBeGone:
            guard !session.outputDeviceIsPresent() else { return }
            let name = session.outputDevice?.name ?? "dispositivo di uscita"
            Log.engine.error("Output device \(name, privacy: .public) disappeared; stopping")
            stopSession()
            emit(.deviceLost(sessionID: sessionID, deviceName: name))

        case .ioStoppedAbnormally:
            guard !session.restartRequested else { return }
            session.restartRequested = true
            Log.engine.error("IO stopped abnormally")
            emit(.restartNeeded(sessionID: sessionID, reason: "l'audio si è interrotto in modo anomalo"))

        case .processListChanged:
            session.handleProcessListChanged()
        }
    }
}
