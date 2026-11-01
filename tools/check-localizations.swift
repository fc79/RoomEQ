// Checks that every text the code localizes has its English translation.
//
// Usage (run by ./build.sh after the release build):
//   swift tools/check-localizations.swift <directory of .stringsdata files>
//
// The .stringsdata files are written by the Swift compiler itself
// (`-emit-localized-strings`, one per source file): they list every key the
// code passes to String(localized:), to a `String.LocalizationValue`
// parameter or to SwiftUI as a LocalizedStringKey (Text("…"), Button("…"),
// .help("…")…), with interpolations already turned into format specifiers
// (%@, %lld…). So the list is exactly what the app will look up at runtime.
//
// Fails (exit 1) when:
//   - a key has no English text in Resources/en.lproj/Localizable.strings, or
//     the English text is empty;
//   - the format specifiers of key and English text differ (count, type or
//     order; numbered ones like %2$@ may be reordered);
//   - a key appears twice in the English table;
//   - a source file has no .stringsdata: the build did not extract it (fix:
//     `swift package clean`, then ./build.sh). The compiler rewrites a
//     .stringsdata only when its content changes, so dates are not compared;
//     after a build every file is current. Only the sources under Sources/
//     count: a .stringsdata left over from a file deleted or moved elsewhere
//     is ignored;
//   - two source files have the same name (e.g. in RoomEQ and RoomEQCore):
//     their .stringsdata would have the same name too, and one would
//     overwrite the other in the shared directory;
//   - a usage description of Info.plist has no English text in
//     Resources/en.lproj/InfoPlist.strings;
//   - Resources/it.lproj/InfoPlist.strings does not repeat exactly the
//     Italian texts of Info.plist.
// English texts no longer used by the code are only reported (warning).

import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sourcesDir = root.appendingPathComponent("Sources")
let englishTable = root.appendingPathComponent("Resources/en.lproj/Localizable.strings")
let englishInfoPlist = root.appendingPathComponent("Resources/en.lproj/InfoPlist.strings")
let italianInfoPlist = root.appendingPathComponent("Resources/it.lproj/InfoPlist.strings")
let infoPlist = root.appendingPathComponent("Resources/Info.plist")

guard CommandLine.arguments.count == 2 else {
    print("usage: swift tools/check-localizations.swift <stringsdata directory>")
    exit(2)
}
let stringsDataDir = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default
var errors: [String] = []
var warnings: [String] = []

// MARK: Keys used by the code

struct Use {
    let file: String
    let line: Int
}

var keys: [String: [Use]] = [:]
var extractedSources: Set<String> = []  // source paths

/// The Swift sources of the package (standardized paths), all under Sources/.
var packageSources: [String] = []
if let enumerator = fileManager.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) {
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        packageSources.append(url.standardizedFileURL.path)
    }
}
let packageSourceSet = Set(packageSources)

// The compiler names each .stringsdata after its source file, all in one
// directory: two sources with the same name would overwrite each other's.
let sourcesByName = Dictionary(grouping: packageSources) { URL(fileURLWithPath: $0).lastPathComponent }
for (name, paths) in sourcesByName.sorted(by: { $0.key < $1.key }) where paths.count > 1 {
    let places = paths.sorted().map { $0.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "") }
    errors.append(
        "\(places.joined(separator: " and ")): same file name \"\(name)\" in more than one place: "
            + "their .stringsdata would overwrite each other, so some texts would go unchecked. Rename one of them.")
}

let dataFiles = ((try? fileManager.contentsOfDirectory(at: stringsDataDir, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "stringsdata" }
for file in dataFiles {
    guard let data = try? Data(contentsOf: file),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let source = json["source"] as? String
    else {
        errors.append("\(file.lastPathComponent): unreadable")
        continue
    }
    // Only the package sources count: a file left over from a source deleted
    // or moved out of Sources/ is ignored.
    let sourcePath = URL(fileURLWithPath: source).standardizedFileURL.path
    guard packageSourceSet.contains(sourcePath) else { continue }
    extractedSources.insert(sourcePath)
    let tables = json["tables"] as? [String: [[String: Any]]] ?? [:]
    for (table, entries) in tables {
        for entry in entries {
            guard let key = entry["key"] as? String else { continue }
            let line = (entry["location"] as? [String: Any])?["startingLine"] as? Int ?? 0
            let use = Use(file: URL(fileURLWithPath: source).lastPathComponent, line: line)
            if table != "Localizable" {
                errors.append("\(use.file):\(line): table \"\(table)\" is not shipped (only Localizable): \"\(key)\"")
            }
            keys[key, default: []].append(use)
        }
    }
}

// Every source file must have been extracted.
for path in packageSources.sorted() where !extractedSources.contains(path) {
    errors.append("\(URL(fileURLWithPath: path).lastPathComponent): no .stringsdata (run `swift package clean`, then ./build.sh)")
}

// MARK: English table

func readStrings(_ url: URL) -> [String: String]? {
    guard let data = try? Data(contentsOf: url),
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    else { return nil }
    return plist as? [String: String]
}

/// `text` with its /* … */ and // comments blanked out (same length, so the
/// rest keeps its place); quoted strings are left as they are, even when they
/// contain "/*" or "//".
func withoutComments(_ text: String) -> String {
    var result = "", index = text.startIndex
    var inString = false
    while index < text.endIndex {
        let character = text[index]
        let rest = text[index...]
        if inString {
            result.append(character)
            if character == "\\", text.index(after: index) < text.endIndex {
                index = text.index(after: index)
                result.append(text[index])
            } else if character == "\"" {
                inString = false
            }
            index = text.index(after: index)
        } else if rest.hasPrefix("/*") {
            let end = rest.range(of: "*/")?.upperBound ?? text.endIndex
            // Keep the line breaks, blank everything else.
            result += text[index..<end].map { $0 == "\n" ? "\n" : " " }
            index = end
        } else if rest.hasPrefix("//") {
            let end = rest.firstIndex(of: "\n") ?? text.endIndex
            result += String(repeating: " ", count: text.distance(from: index, to: end))
            index = end
        } else {
            if character == "\"" { inString = true }
            result.append(character)
            index = text.index(after: index)
        }
    }
    return result
}

/// Keys written twice (the parser silently keeps the last one); keys inside
/// comments do not count.
func duplicateKeys(_ url: URL) -> [String] {
    guard let original = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let text = withoutComments(original)
    let pattern = try! NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*="#, options: .anchorsMatchLines)
    var seen: Set<String> = [], duplicates: [String] = []
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let key = String(text[Range(match.range(at: 1), in: text)!])
        if !seen.insert(key).inserted { duplicates.append(key) }
    }
    return duplicates
}

/// Format specifiers of `text` as (argument position, conversion), e.g.
/// "%@ di %lld" -> [(1, "@"), (2, "lld")]; "%%" is not an argument.
func specifiers(_ text: String) -> [String] {
    let pattern = try! NSRegularExpression(
        pattern: #"%(?:(\d+)\$)?[-+ 0#']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaAF%])"#)
    var result: [String] = []
    var next = 1
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        func group(_ index: Int) -> String {
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
        let conversion = group(3)
        if conversion == "%" { continue }
        let position = Int(group(1)) ?? next
        next = position + 1
        result.append("\(position):\(group(2))\(conversion)")
    }
    return result.sorted()
}

if let english = readStrings(englishTable) {
    for duplicate in duplicateKeys(englishTable) {
        errors.append("en.lproj/Localizable.strings: key written twice: \"\(duplicate)\"")
    }
    for key in keys.keys.sorted() {
        let places = keys[key]!.map { "\($0.file):\($0.line)" }.joined(separator: ", ")
        guard let translation = english[key] else {
            errors.append("missing English text for \"\(key)\" (\(places))")
            continue
        }
        if translation.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("empty English text for \"\(key)\" (\(places))")
        } else if specifiers(key) != specifiers(translation) {
            errors.append(
                "format specifiers differ for \"\(key)\" (\(places)): "
                    + "\(specifiers(key)) vs \(specifiers(translation)) in \"\(translation)\"")
        }
    }
    for key in english.keys.sorted() where keys[key] == nil {
        warnings.append("English text no longer used by the code: \"\(key)\"")
    }
} else {
    errors.append("\(englishTable.path): missing or not a valid .strings file")
}

// MARK: Info.plist

if let data = try? Data(contentsOf: infoPlist),
    let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
{
    let english = readStrings(englishInfoPlist) ?? [:]
    for key in info.keys.sorted() where key.hasSuffix("UsageDescription") && english[key]?.isEmpty != false {
        errors.append("en.lproj/InfoPlist.strings: missing English text for \(key)")
    }
    // The Italian table only repeats Info.plist (so that macOS never falls
    // back to English for an Italian user): it must say exactly the same.
    if let italian = readStrings(italianInfoPlist) {
        for key in info.keys.sorted() where key.hasSuffix("UsageDescription") {
            if let text = info[key] as? String, italian[key] != text {
                errors.append(
                    "it.lproj/InfoPlist.strings: \(key) differs from Info.plist "
                        + "(copy the text of Info.plist: \"\(text)\")")
            }
        }
        for key in italian.keys.sorted() where info[key] == nil {
            errors.append("it.lproj/InfoPlist.strings: \(key) is not in Info.plist")
        }
    } else {
        errors.append("\(italianInfoPlist.path): missing or not a valid .strings file")
    }
} else {
    errors.append("\(infoPlist.path): unreadable")
}

// MARK: Report

for warning in warnings { print("warning: \(warning)") }
for error in errors { print("error: \(error)") }
if keys.isEmpty && errors.isEmpty {
    print("error: no localized keys found in \(stringsDataDir.path)")
    exit(1)
}
if !errors.isEmpty {
    print("Localization check FAILED: \(errors.count) problem(s).")
    exit(1)
}
print("Localization check passed: \(keys.count) texts, all with an English translation.")
