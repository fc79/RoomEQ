// The Core Audio process tap that captures the system mix.
//
// A DEVICE tap: it receives what every app (except the excluded ones —
// RoomEQ itself, plus the apps the user listed) sends to one output
// stream of the output device, in that stream's own format (no mixdown, no
// sample-rate conversion). It is read through the capture aggregate (see
// AggregateDevice.swift). RoomEQ's own process MUST be excluded: our output
// goes to the very device being tapped, so without the exclusion we would
// capture ourselves (instant feedback).

import CoreAudio
import Foundation
import RoomEQCore

/// Core Audio "process objects" (one per client process connected to the HAL).
enum AudioProcesses {
    static func processObjectIDs() throws -> [AudioObjectID] {
        try AudioObject.readArray(
            AudioObjectID(kAudioObjectSystemObject), AudioObject.address(kAudioHardwarePropertyProcessObjectList),
            element: AudioObjectID(kAudioObjectUnknown), "Lettura elenco processi audio")
    }

    static func bundleID(of process: AudioObjectID) -> String? {
        try? AudioObject.readString(
            process, AudioObject.address(kAudioProcessPropertyBundleID), "Lettura bundle ID processo")
    }

    /// Process object of a PID, or nil if that process isn't a HAL client
    /// (Core Audio returns kAudioObjectUnknown in that case).
    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        let object: AudioObjectID? = try? AudioObject.read(
            AudioObjectID(kAudioObjectSystemObject),
            AudioObject.address(kAudioHardwarePropertyTranslatePIDToProcessObject),
            qualifier: pid, initial: AudioObjectID(kAudioObjectUnknown), "Traduzione PID")
        guard let object, object != kAudioObjectUnknown else { return nil }
        return object
    }

    /// True if `bundleID` is `excluded` or one of its helpers
    /// (e.g. "com.ableton.live.something" for "com.ableton.live"), ignoring
    /// case (see `ExclusionRules.matches`).
    static func bundleID(_ bundleID: String, matches excluded: String) -> Bool {
        ExclusionRules.matches(processBundleID: bundleID, excluded: excluded)
    }

    /// Process objects of currently running processes whose bundle ID
    /// matches one of `bundleIDs`.
    static func processObjects(matching bundleIDs: [String]) -> [(object: AudioObjectID, bundleID: String)] {
        let all = (try? processObjectIDs()) ?? []
        return all.compactMap { object in
            guard let id = bundleID(of: object),
                bundleIDs.contains(where: { bundleID(id, matches: $0) })
            else { return nil }
            return (object, id)
        }
    }
}

/// An owned process tap. Call `destroy()` when done.
final class ProcessTap {
    static let tapName = "RoomEQ Tap"

    let objectID: AudioObjectID
    let uid: String
    let uuid: UUID
    let deviceUID: String
    let stream: UInt
    let muteBehavior: CATapMuteBehavior
    /// Bundle IDs excluded from the tap (including RoomEQ's own).
    private(set) var excludedBundleIDs: [String]
    /// Process objects currently in the tap's exclusion list.
    private(set) var excludedProcesses: [AudioObjectID]

    private var destroyed = false

    private init(
        objectID: AudioObjectID, uid: String, uuid: UUID, deviceUID: String, stream: UInt,
        muteBehavior: CATapMuteBehavior, bundleIDs: [String], processes: [AudioObjectID]
    ) {
        self.deviceUID = deviceUID
        self.stream = stream
        self.muteBehavior = muteBehavior
        self.objectID = objectID
        self.uid = uid
        self.uuid = uuid
        self.excludedBundleIDs = bundleIDs
        self.excludedProcesses = processes
    }

    deinit {
        if !destroyed { Log.tap.fault("ProcessTap released without destroy()") }
    }

    /// RoomEQ's own Core Audio process object. Retries briefly (the HAL may
    /// register us as a client with a small delay), then throws.
    static func ownProcessObject(attempts: Int = 20) throws -> AudioObjectID {
        let pid = ProcessInfo.processInfo.processIdentifier
        for attempt in 1...max(1, attempts) {
            if let own = AudioProcesses.processObject(forPID: pid) {
                if attempt > 1 { Log.tap.info("Own process object found after \(attempt) attempts") }
                return own
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Log.tap.error("Own process object (pid \(pid)) not found; refusing to create the tap")
        throw EngineError(
            "Core Audio non riconosce ancora RoomEQ come processo audio: avvio annullato per evitare che RoomEQ catturi il proprio suono (effetto eco/feedback). Riprova tra qualche secondo.")
    }

    /// Builds the tap description. Kept in one place so creation and later
    /// updates (new excluded processes) produce identical settings.
    private static func makeDescription(
        uuid: UUID, deviceUID: String, stream: UInt, muteBehavior: CATapMuteBehavior,
        excludedProcesses: [AudioObjectID], excludedBundleIDs: [String]
    ) -> CATapDescription {
        // "Mix all process audio destined for the selected device stream
        // except the given processes" (exclusive). Format = that stream's.
        let description = CATapDescription(excludingProcesses: excludedProcesses, deviceUID: deviceUID, stream: stream)
        description.isExclusive = true
        description.isMono = false
        description.isMixdown = false
        description.name = tapName
        description.uuid = uuid
        // Only visible to this process; Core Audio removes it when we exit.
        description.isPrivate = true
        // Apps are silenced only while we read the tap: if RoomEQ stops or
        // crashes, their audio goes back to the speakers directly. (The
        // engine always uses the default, `.mutedWhenTapped`.)
        description.muteBehavior = muteBehavior
        if #available(macOS 26.0, *) {
            // Excluded by bundle ID, so apps launched later should be excluded
            // too. The process-list fallback in EngineSession covers the case
            // where this doesn't work as hoped (see log "exclusion-check").
            description.bundleIDs = excludedBundleIDs
            description.isProcessRestoreEnabled = true
        }
        return description
    }

    /// The user's exclusions plus RoomEQ's own bundle ID, sorted, unique
    /// (ignoring case).
    static func bundleIDList(_ userExcluded: [String]) -> [String] {
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.federicociapi.RoomEQ"
        var result: [String] = []
        for id in userExcluded + [ownBundleID] where !result.contains(where: { ExclusionRules.same($0, id) }) {
            result.append(id)
        }
        return result.sorted()
    }

    /// Creates the tap.
    /// - Parameters:
    ///   - excludedBundleIDs: bundle IDs to exclude (RoomEQ's own is added).
    ///   - deviceUID / stream: the output stream to tap.
    ///   - muteBehavior: `.mutedWhenTapped` (apps silenced only while we read).
    static func create(
        excludedBundleIDs userExcluded: [String], deviceUID: String, stream: UInt,
        muteBehavior: CATapMuteBehavior = .mutedWhenTapped
    ) throws -> ProcessTap {
        let bundleIDs = bundleIDList(userExcluded)

        // Process objects: ourselves (essential, or we would tap our own
        // output and create a feedback loop) + running excluded apps.
        // Without our own process object we refuse to create the tap: the
        // bundle-ID exclusion alone is not proven to work.
        var processes = [try ownProcessObject()]
        for match in AudioProcesses.processObjects(matching: bundleIDs) where !processes.contains(match.object) {
            processes.append(match.object)
            Log.tap.info("Excluding running process \(match.bundleID, privacy: .public) (object \(match.object))")
        }

        let uuid = UUID()
        let description = makeDescription(
            uuid: uuid, deviceUID: deviceUID, stream: stream, muteBehavior: muteBehavior,
            excludedProcesses: processes, excludedBundleIDs: bundleIDs)
        var tapID = AudioObjectID(kAudioObjectUnknown)
        try AudioObject.check(AudioHardwareCreateProcessTap(description, &tapID), "Creazione del tap audio")

        let uid: String
        do {
            uid = try AudioObject.readString(tapID, AudioObject.address(kAudioTapPropertyUID), "Lettura UID del tap")
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
        Log.tap.info(
            "Tap created: id \(tapID), uid \(uid, privacy: .public), device \(deviceUID, privacy: .public) stream \(stream), excluded bundle IDs \(bundleIDs, privacy: .public), processes \(processes, privacy: .public)"
        )
        return ProcessTap(
            objectID: tapID, uid: uid, uuid: uuid, deviceUID: deviceUID, stream: stream, muteBehavior: muteBehavior,
            bundleIDs: bundleIDs, processes: processes)
    }

    /// The tap's audio format (`kAudioTapPropertyFormat`).
    func format() throws -> AudioStreamBasicDescription {
        try AudioObject.read(
            objectID, AudioObject.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription(),
            "Lettura formato del tap")
    }

    /// Adds process objects to the exclusion list by replacing the tap's
    /// description (`kAudioTapPropertyDescription` is settable). Same UUID,
    /// name and options; only the process list changes. RoomEQ's own process
    /// object is always kept.
    /// Throws (without touching the tap) if our own process object can't be
    /// resolved, so the update can never drop RoomEQ's self-exclusion.
    func replaceExcludedProcesses(_ processes: [AudioObjectID]) throws {
        var list = [try Self.ownProcessObject(attempts: 3)]
        for process in processes where !list.contains(process) { list.append(process) }
        guard list != excludedProcesses else {
            Log.tap.debug("Tap exclusion list unchanged (\(list, privacy: .public))")
            return
        }
        Log.tap.info(
            "Replacing tap description: excluded processes \(self.excludedProcesses, privacy: .public) -> \(list, privacy: .public)"
        )

        try writeDescription(processes: list, bundleIDs: excludedBundleIDs)
    }

    /// Replaces the whole exclusion set (user's bundle IDs; RoomEQ's own is
    /// added and its process object always kept): the matching running
    /// processes are excluded and, on macOS 26, the bundle IDs too. Used to
    /// apply a changed exclusion list without rebuilding the session.
    /// Throws without touching the tap if RoomEQ's own process object can't
    /// be resolved.
    func updateExclusions(bundleIDs userExcluded: [String]) throws {
        let bundleIDs = Self.bundleIDList(userExcluded)
        var list = [try Self.ownProcessObject(attempts: 3)]
        for match in AudioProcesses.processObjects(matching: bundleIDs) where !list.contains(match.object) {
            list.append(match.object)
        }
        guard list != excludedProcesses || bundleIDs != excludedBundleIDs else { return }
        Log.tap.info(
            "Updating tap exclusions: bundle IDs \(self.excludedBundleIDs, privacy: .public) -> \(bundleIDs, privacy: .public), processes \(self.excludedProcesses, privacy: .public) -> \(list, privacy: .public)"
        )
        try writeDescription(processes: list, bundleIDs: bundleIDs)
        excludedBundleIDs = bundleIDs
    }

    /// Sets `kAudioTapPropertyDescription` (same UUID, name and options).
    private func writeDescription(processes list: [AudioObjectID], bundleIDs: [String]) throws {
        var description = Self.makeDescription(
            uuid: uuid, deviceUID: deviceUID, stream: stream, muteBehavior: muteBehavior,
            excludedProcesses: list, excludedBundleIDs: bundleIDs)
        var address = AudioObject.address(kAudioTapPropertyDescription)
        let status = withUnsafeMutablePointer(to: &description) {
            AudioObjectSetPropertyData(
                objectID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        try AudioObject.check(status, "Aggiornamento esclusioni del tap")
        excludedProcesses = list
        Log.tap.info(
            "Tap description updated, excluded processes now \(self.excludedProcesses, privacy: .public); stored: \(self.currentDescriptionSummary(), privacy: .public)"
        )
    }

    /// Reads back the tap's current description, for diagnostics only.
    /// Note: we take the object unretained. If Core Audio returns it +1 this
    /// leaks one small object per call (rare), which is safer than risking
    /// an over-release crash; the header does not document ownership.
    func currentDescriptionSummary() -> String {
        var address = AudioObject.address(kAudioTapPropertyDescription)
        var value: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let description = value?.takeUnretainedValue() else {
            return "unavailable (\(status))"
        }
        var text = "processes \(description.processes)"
        if #available(macOS 26.0, *) { text += ", bundleIDs \(description.bundleIDs)" }
        return text
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        let status = AudioHardwareDestroyProcessTap(objectID)
        if status == noErr {
            Log.tap.info("Tap \(self.objectID) destroyed")
        } else {
            Log.tap.error("Destroying tap \(self.objectID) failed: \(describeOSStatus(status), privacy: .public)")
        }
    }
}
