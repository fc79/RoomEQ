// The Core Audio process tap that captures the system mix.
//
// The tap is a "stereo global tap excluding some processes": it receives the
// mix of every app's output except the excluded ones (Ableton Live, RoomEQ
// itself, and anything else the user lists). The tap does nothing on its own;
// its audio is read through the aggregate device (see AggregateDevice.swift).

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
    /// (e.g. "com.ableton.live.something" for "com.ableton.live").
    static func bundleID(_ bundleID: String, matches excluded: String) -> Bool {
        bundleID == excluded || bundleID.hasPrefix(excluded + ".")
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
    /// Bundle IDs excluded from the tap (including RoomEQ's own).
    let excludedBundleIDs: [String]
    /// Process objects currently in the tap's exclusion list.
    private(set) var excludedProcesses: [AudioObjectID]

    private var destroyed = false

    private init(objectID: AudioObjectID, uid: String, uuid: UUID, bundleIDs: [String], processes: [AudioObjectID]) {
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
            "Core Audio non riconosce ancora RoomEQ come processo audio: avvio annullato per evitare che "
                + "RoomEQ catturi il proprio suono (effetto eco/feedback). Riprova tra qualche secondo.")
    }

    /// Builds the tap description. Kept in one place so creation and later
    /// updates (new excluded processes) produce identical settings.
    private static func makeDescription(
        uuid: UUID, excludedProcesses: [AudioObjectID], excludedBundleIDs: [String]
    ) -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        description.name = tapName
        description.uuid = uuid
        // Only visible to this process; Core Audio removes it when we exit.
        description.isPrivate = true
        // Apps are silenced only while we read the tap: if RoomEQ stops or
        // crashes, their audio goes back to the speakers directly.
        description.muteBehavior = .mutedWhenTapped
        if #available(macOS 26.0, *) {
            // Excluded by bundle ID, so apps launched later should be excluded
            // too. The process-list fallback in EngineSession covers the case
            // where this doesn't work as hoped (see log "exclusion-check").
            description.bundleIDs = excludedBundleIDs
            description.isProcessRestoreEnabled = true
        }
        return description
    }

    /// Creates the tap.
    /// - Parameters:
    ///   - excludedBundleIDs: bundle IDs to exclude (RoomEQ's own is added).
    static func create(excludedBundleIDs userExcluded: [String]) throws -> ProcessTap {
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.federicociapi.RoomEQ"
        let bundleIDs = Array(Set(userExcluded + [ownBundleID])).sorted()

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
        let description = makeDescription(uuid: uuid, excludedProcesses: processes, excludedBundleIDs: bundleIDs)
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
            "Tap created: id \(tapID), uid \(uid, privacy: .public), excluded bundle IDs \(bundleIDs, privacy: .public), processes \(processes, privacy: .public)"
        )
        return ProcessTap(objectID: tapID, uid: uid, uuid: uuid, bundleIDs: bundleIDs, processes: processes)
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

        var description = Self.makeDescription(
            uuid: uuid, excludedProcesses: list, excludedBundleIDs: excludedBundleIDs)
        var address = AudioObject.address(kAudioTapPropertyDescription)
        let status = withUnsafeMutablePointer(to: &description) {
            AudioObjectSetPropertyData(
                objectID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        try AudioObject.check(status, "Aggiornamento esclusioni del tap")
        excludedProcesses = list
        Log.tap.info("Tap description updated, excluded processes now \(self.excludedProcesses, privacy: .public)")
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
