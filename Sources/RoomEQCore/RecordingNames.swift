// File names for recordings: "<app> <yyyy-MM-dd HH.mm.ss>.wav", named after
// the moment the file starts (so files never overwrite each other and sort
// in time order), in ~/Music/RoomEQ.

import Foundation

public enum RecordingNames {
    /// "Spotify 2026-11-18 00.35.12.wav". Characters that are not allowed or
    /// confusing in a file name ("/" and ":") become "-"; leading dots are
    /// dropped and long names cut to 80 characters and 150 bytes of UTF-8 (a
    /// file name may have 255 bytes; 80 characters of Chinese or Japanese
    /// are 240).
    public static func fileName(app: String, date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let cleaned = app.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        // No hidden files (leading dot), and well within the 255-byte limit.
        var name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 80 { name = String(name.prefix(80)) }
        while name.utf8.count > 150 { name.removeLast() }  // whole characters
        name = name.trimmingCharacters(in: .whitespaces)
        return "\(name.isEmpty ? "App" : name) \(formatter.string(from: date)).wav"
    }

    /// `fileName` in `folder`, with " 2", " 3"… before the extension when a
    /// file with that name already exists.
    public static func uniqueURL(
        in folder: URL, app: String, date: Date, timeZone: TimeZone = .current,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = fileName(app: app, date: date, timeZone: timeZone)
        var url = folder.appendingPathComponent(base)
        var counter = 2
        while exists(url) {
            let stem = String(base.dropLast(4))
            url = folder.appendingPathComponent("\(stem) \(counter).wav")
            counter += 1
        }
        return url
    }

    /// ~/Music/RoomEQ (not created here).
    public static func defaultFolder() -> URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("RoomEQ", isDirectory: true)
    }
}
