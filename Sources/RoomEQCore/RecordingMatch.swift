// Which processes belong to an app chosen for recording.
//
// The app itself, plus its helper processes: browsers play audio from a
// helper whose bundle ID extends the app's with a ".helper…" component
// ("com.brave.Browser.helper", "com.google.Chrome.helper.renderer"). Other
// apps whose bundle ID merely extends the chosen one are NOT included
// ("com.google.Chrome.canary" is Chrome Canary, not a Chrome helper). Case
// is ignored. (Exclusion from the correction uses the broader rule in
// `ExclusionRules.matches`.)

public enum RecordingMatch {
    public static func belongs(processBundleID: String, toApp app: String) -> Bool {
        let process = processBundleID.lowercased(), app = app.lowercased()
        if process == app { return true }
        guard process.hasPrefix(app + ".") else { return false }
        let rest = process.dropFirst(app.count + 1)
        return rest.hasPrefix("helper")
    }
}
