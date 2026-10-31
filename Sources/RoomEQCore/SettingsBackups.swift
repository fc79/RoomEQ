// Where unreadable settings data is kept (finding: backups repeated at
// every launch). Pure planning, the controller applies it to UserDefaults.
//
// Keys: "<source key>.backup.<unix timestamp>" (the stage-3 format too).
// A backup is written only if no existing backup has identical content
// (byte-for-byte), at most `maximumCount` are kept (oldest dropped), and
// the UI notice is shown only when a NEW content was saved.

import Foundation

public enum SettingsBackups {
    public static let maximumCount = 5

    public struct Plan: Equatable, Sendable {
        /// Backups to write (key -> data).
        public var writes: [String: Data] = [:]
        /// Old backup keys to remove.
        public var deletions: [String] = []
        /// At least one content not backed up before.
        public var hasNewContent: Bool { !writes.isEmpty }
    }

    public static func key(source: String, timestamp: Int) -> String { "\(source).backup.\(timestamp)" }

    public static func isBackupKey(_ key: String) -> Bool { key.contains(".backup.") }

    /// Unix timestamp in a backup key (0 if unreadable: treated as oldest).
    static func timestamp(of key: String) -> Int {
        guard let range = key.range(of: ".backup.", options: .backwards) else { return 0 }
        let tail = key[range.upperBound...].prefix { $0.isNumber }
        return Int(tail) ?? 0
    }

    /// `existing`: every backup currently stored (key -> data).
    public static func plan(existing: [String: Data], adding: [AppSettingsLoad.Backup], timestamp: Int) -> Plan {
        var plan = Plan()
        var all = existing
        for backup in adding {
            guard !all.values.contains(backup.data) else { continue }  // same content already kept
            var key = key(source: backup.sourceKey, timestamp: timestamp)
            var suffix = 2
            while all[key] != nil {
                key = Self.key(source: backup.sourceKey, timestamp: timestamp) + "-\(suffix)"
                suffix += 1
            }
            all[key] = backup.data
            plan.writes[key] = backup.data
        }
        if all.count > maximumCount {
            let oldestFirst = all.keys.sorted { (Self.timestamp(of: $0), $0) < (Self.timestamp(of: $1), $1) }
            for key in oldestFirst.prefix(all.count - maximumCount) {
                if plan.writes[key] != nil {
                    plan.writes[key] = nil  // never happens with <= 2 new backups, but stay consistent
                } else {
                    plan.deletions.append(key)
                }
            }
        }
        return plan
    }
}
