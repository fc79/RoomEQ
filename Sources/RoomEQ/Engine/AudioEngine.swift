// Runs engine sessions on a dedicated serial queue.
//
// Threads involved:
//   - main thread: the controller; calls the public methods below, receives
//     completions and events (always delivered on main);
//   - engine queue (serial): ALL Core Audio setup/teardown. These calls can
//     block for a while (creating aggregates, starting IO), so they never
//     run on the main thread;
//   - listener queue (serial): Core Audio property listeners. They never
//     block: they only forward a signal to the engine queue. (Keeping them
//     off the engine queue avoids any risk of deadlock when listeners are
//     removed from the engine queue.)
//   - HAL real-time IO thread: only the render kernel and the overload
//     counter (see EngineSession / RoomEQCore).
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
    /// Buffer size changed (by us or by another app): new latency figures.
    case latencyChanged(sessionID: Int, LatencyBreakdown, bufferFrames: Int)
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
                onMain { completion(.success(info)) }
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

    /// Changes the buffer size of the running session (live).
    func setBufferSize(
        _ frames: Int, completion: @escaping @MainActor (Result<(LatencyBreakdown, bufferFrames: Int), Error>) -> Void
    ) {
        queue.async { [self] in
            let result: Result<(LatencyBreakdown, bufferFrames: Int), Error>
            if let session {
                result = Result { try session.setBufferSize(frames) }
            } else {
                result = .failure(EngineError("Motore non avviato"))
            }
            onMain { completion(result) }
        }
    }

    /// Recomputes latency (e.g. after the output pair moved to another stream).
    func refreshLatency() {
        queue.async { [self] in
            guard let session else { return }
            let (latency, frames) = session.currentLatency()
            emit(.latencyChanged(sessionID: session.id, latency, bufferFrames: frames))
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

        case .bufferSizeChanged:
            let (latency, frames) = session.currentLatency()
            emit(.latencyChanged(sessionID: sessionID, latency, bufferFrames: frames))

        case .processListChanged:
            session.handleProcessListChanged()
        }
    }
}
