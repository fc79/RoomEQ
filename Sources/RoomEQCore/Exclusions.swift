// Rules for the list of apps excluded from the tap.
//
// RoomEQ itself is ALWAYS excluded (the engine adds it, see ProcessTap) and
// never appears in the list. REW is not excluded by default (its sweeps must
// go through RoomEQ to measure the corrected system); excluding it is
// allowed, with a warning.

import Foundation

public enum ExclusionError: LocalizedError, Equatable, Sendable {
    case invalidBundleID
    case ownApp
    case alreadyExcluded(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBundleID: return "Identificativo dell'app non valido."
        case .ownApp: return "RoomEQ è sempre escluso automaticamente."
        case .alreadyExcluded(let name): return "«\(name)» è già esclusa."
        }
    }
}

public enum ExclusionRules {
    /// Excluded on first launch.
    public static let defaultApps = [ExcludedAppRecord(bundleID: "com.ableton.live", name: "Ableton Live")]

    public static let rewWarning = "Escludendo REW, le misure non passeranno da RoomEQ"

    /// Trimmed bundle ID if it looks like one (letters, digits, '.', '-',
    /// '_', at most 255 characters), else nil.
    public static func normalize(_ bundleID: String) -> String? {
        let text = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 255,
            text.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) }),
            text.contains(where: { $0.isLetter || $0.isNumber })
        else { return nil }
        return text
    }

    /// Bundle IDs are case-insensitive in practice.
    public static func same(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }

    /// RoomEQ itself, or one of its helpers.
    public static func isOwn(_ bundleID: String, ownBundleID: String) -> Bool {
        let id = bundleID.lowercased(), own = ownBundleID.lowercased()
        return id == own || id.hasPrefix(own + ".")
    }

    /// REW (Room EQ Wizard; its bundle IDs start with "roomeqwizard").
    public static func isREW(_ bundleID: String) -> Bool {
        bundleID.lowercased().hasPrefix("roomeqwizard")
    }

    /// Warning to show for an excluded app, if any.
    public static func warning(forBundleID bundleID: String) -> String? {
        isREW(bundleID) ? rewWarning : nil
    }

    /// The bundle ID to add, or why it can't be added.
    public static func validateNew(
        _ bundleID: String, existing: [ExcludedAppRecord], ownBundleID: String
    ) throws -> String {
        guard let id = normalize(bundleID) else { throw ExclusionError.invalidBundleID }
        guard !isOwn(id, ownBundleID: ownBundleID) else { throw ExclusionError.ownApp }
        if let present = existing.first(where: { same($0.bundleID, id) }) {
            throw ExclusionError.alreadyExcluded(present.name)
        }
        return id
    }

    /// Valid, without duplicates (case-insensitive), without RoomEQ.
    public static func cleaned(_ apps: [ExcludedAppRecord], ownBundleID: String) -> [ExcludedAppRecord] {
        var result: [ExcludedAppRecord] = []
        for app in apps {
            guard let id = normalize(app.bundleID), !isOwn(id, ownBundleID: ownBundleID),
                !result.contains(where: { same($0.bundleID, id) })
            else { continue }
            let name = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(ExcludedAppRecord(bundleID: id, name: name.isEmpty ? id : name))
        }
        return result
    }
}
