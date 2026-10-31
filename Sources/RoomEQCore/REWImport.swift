// Import of REW "Export filter settings as text" files (pure Swift).
//
// Example (spacing and header lines vary between REW versions):
//
//   Filter Settings file
//   Room EQ V5.31
//   Dated: 31-ott-2026 12.00.00
//   Equaliser: Generic
//   Average 1
//   Filter  1: ON  PK       Fc   58.80 Hz  Gain  -9.90 dB  Q 10.664
//   Filter  5: ON  None
//   Filter  6: OFF PK       Fc   1000 Hz   Gain   0.00 dB  Q  1.000
//
// Rules: "Filter N:" with any spacing; "None" filters ignored; OFF filters
// kept as disabled bands; decimal comma accepted (REW may follow the
// Italian locale); "kHz" accepted; other filter types (LS, HS, LP, …)
// skipped with a warning; at most 16 PK filters; warning if the equaliser
// is not "Generic". Never crashes: anything unreadable becomes a warning.
//
// Note on Q: the bands are later built as RBJ-cookbook peaking filters.
// That REW's "Generic" PK filters use the same Q definition is an
// assumption to be confirmed with a measurement sweep.

import Foundation

public struct REWImportResult: Sendable, Equatable {
    /// PK filters in file order (OFF ones disabled), at most 16.
    public var bands: [EQBand]
    /// Italian messages for everything skipped or suspicious.
    public var warnings: [String]
    /// Value of the "Equaliser:" line (nil if missing).
    public var equaliser: String?
    /// Lines recognised as "Filter N: …" (including None / skipped ones).
    public var filterLineCount: Int
}

public enum REWImportError: LocalizedError, Equatable {
    case unreadable(fileName: String, reason: String)
    case tooLarge(fileName: String)
    case notText(fileName: String)
    /// The file has no usable PK filter; `warnings` explains what was found.
    case noUsableFilters(fileName: String, warnings: [String])

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name, let reason):
            return "Impossibile leggere «\(name)»: \(reason)"
        case .tooLarge(let name):
            return "«\(name)» è troppo grande per essere un file di filtri REW"
        case .notText(let name):
            return "«\(name)» non è un file di testo"
        case .noUsableFilters(let name, _):
            return "«\(name)» non contiene filtri PK utilizzabili: filtri attuali invariati. "
                + "In REW usa «Export filter settings as text» con l'equalizzatore «Generic»."
        }
    }
}

public enum REWImport {
    /// Larger files are refused without being parsed.
    public static let maximumFileSize = 1_000_000

    /// Reads and parses `url`. Throws (Italian messages) if the file can't
    /// be read or holds no usable PK filter. Blocking file I/O: call it off
    /// the main thread.
    public static func load(url: URL) throws -> REWImportResult {
        let name = url.lastPathComponent
        let data: Data
        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > maximumFileSize { throw REWImportError.tooLarge(fileName: name) }
            data = try Data(contentsOf: url)
        } catch let error as REWImportError {
            throw error
        } catch {
            throw REWImportError.unreadable(fileName: name, reason: error.localizedDescription)
        }
        if data.count > maximumFileSize { throw REWImportError.tooLarge(fileName: name) }
        guard let text = decode(data) else { throw REWImportError.notText(fileName: name) }
        let result = parse(text)
        guard !result.bands.isEmpty else {
            throw REWImportError.noUsableFilters(fileName: name, warnings: result.warnings)
        }
        return result
    }

    /// Text in UTF-8 (with or without BOM), UTF-16 with BOM, or Windows-1252
    /// / Latin-1 (older REW on Windows). Nil for binary data.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if data.contains(0) { return nil }  // NUL bytes: not a text file
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: Parsing

    /// Parses the text of a REW filter settings file. Never fails: problems
    /// become warnings (an empty `bands` means nothing usable was found).
    public static func parse(_ text: String) -> REWImportResult {
        var bands: [EQBand] = []
        var warnings: [String] = []
        var equaliser: String?
        var filterLines = 0
        var droppedOverLimit = 0

        // `isNewline` also covers "\r\n", which Swift treats as ONE character.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        for (lineIndex, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if equaliser == nil, let value = headerValue(line, key: "equaliser") ?? headerValue(line, key: "equalizer") {
                equaliser = value
                continue
            }

            switch parseFilterLine(line) {
            case .notAFilterLine:
                continue
            case .malformed:
                filterLines += 1
                warnings.append("Riga \(lineIndex + 1) non riconosciuta, ignorata: «\(shortened(line))»")
            case .filter(let number, let body):
                filterLines += 1
                switch parseFilterBody(body) {
                case .none:
                    continue
                case .unsupported(let type):
                    warnings.append("Filtro \(number): tipo \(type) non supportato, ignorato")
                case .unreadable:
                    warnings.append("Filtro \(number): valori non leggibili, ignorato")
                case .invalid:
                    warnings.append("Filtro \(number): frequenza o Q non validi, ignorato")
                case .peaking(let isOn, let frequency, let gain, let q):
                    if bands.count >= EQBand.maximumCount {
                        droppedOverLimit += 1
                    } else {
                        bands.append(EQBand(frequency: frequency, gain: gain, q: q, isEnabled: isOn))
                    }
                }
            }
        }

        if droppedOverLimit > 0 {
            warnings.append(
                "Più di \(EQBand.maximumCount) filtri PK: importati i primi \(EQBand.maximumCount), "
                    + "ignorati gli altri \(droppedOverLimit)")
        }
        if let equaliser {
            if equaliser.lowercased() != "generic" {
                warnings.insert(
                    "Equalizzatore «\(equaliser)» invece di «Generic»: altri modelli possono definire i filtri "
                        + "in modo diverso, verifica la risposta con una misura", at: 0)
            }
        } else if filterLines > 0 {
            warnings.insert(
                "Riga «Equaliser:» assente: verifica che il file sia stato esportato con l'equalizzatore «Generic»",
                at: 0)
        }
        if filterLines == 0 {
            warnings.append("Nessuna riga «Filter N: …» trovata: non sembra un file di filtri di REW")
        }
        return REWImportResult(bands: bands, warnings: warnings, equaliser: equaliser, filterLineCount: filterLines)
    }

    /// "Equaliser: Generic" -> "Generic" (case-insensitive key).
    static func headerValue(_ line: String, key: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard name.lowercased() == key else { return nil }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    enum FilterLine: Equatable {
        case notAFilterLine
        case malformed
        case filter(number: Int, body: [String])
    }

    /// Recognises "Filter <N>:" (any spacing, any case). "Filter Settings
    /// file" and other text are not filter lines.
    static func parseFilterLine(_ line: String) -> FilterLine {
        let scalars = Array(line.unicodeScalars)
        let keyword = Array("filter".unicodeScalars)
        guard scalars.count > keyword.count,
            zip(scalars, keyword).allSatisfy({ Character($0).lowercased() == String($1) })
        else { return .notAFilterLine }
        var index = keyword.count
        while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
        let digitsStart = index
        while index < scalars.count, ("0"..."9").contains(scalars[index]) { index += 1 }
        guard index > digitsStart else { return .notAFilterLine }  // e.g. "Filter Settings file"
        let digits = String(String.UnicodeScalarView(scalars[digitsStart..<index]))
        while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
        guard index < scalars.count, scalars[index] == ":", let number = Int(digits) else { return .malformed }
        let rest = String(String.UnicodeScalarView(scalars[(index + 1)...]))
        return .filter(number: number, body: rest.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    }

    enum FilterBody: Equatable {
        case none
        case unsupported(type: String)
        case unreadable
        case invalid
        case peaking(isOn: Bool, frequency: Double, gain: Double, q: Double)
    }

    /// Parses the tokens after "Filter N:", e.g.
    /// ["ON", "PK", "Fc", "58.80", "Hz", "Gain", "-9.90", "dB", "Q", "10.664"].
    static func parseFilterBody(_ tokens: [String]) -> FilterBody {
        guard !tokens.isEmpty else { return .unreadable }
        var position = 0
        var isOn = true
        switch tokens[0].uppercased() {
        case "ON": position = 1
        case "OFF": isOn = false; position = 1
        default: break
        }
        guard position < tokens.count else { return .unreadable }
        let type = tokens[position].uppercased()
        if type == "NONE" { return .none }
        guard type == "PK" else {
            // Names can carry a slope, e.g. "LSC 12dB": report just the type.
            return .unsupported(type: tokens[position])
        }
        let values = Array(tokens[(position + 1)...])
        guard let frequency = value(after: "Fc", in: values, units: ["hz": 1, "khz": 1000], defaultScale: 1),
            let gain = value(after: "Gain", in: values, units: ["db": 1], defaultScale: 1),
            let q = value(after: "Q", in: values, units: [:], defaultScale: 1)
        else { return .unreadable }
        guard frequency > 0, q > 0 else { return .invalid }
        return .peaking(isOn: isOn, frequency: frequency, gain: gain, q: q)
    }

    /// The number following `key` (case-insensitive), with an optional unit
    /// either glued ("58.8Hz") or as the next token ("58.8 Hz"). Units are
    /// matched case-insensitively and scale the value ("1.2 kHz" -> 1200).
    static func value(after key: String, in tokens: [String], units: [String: Double], defaultScale: Double)
        -> Double?
    {
        let lowerKey = key.lowercased()
        guard let keyIndex = tokens.firstIndex(where: { $0.lowercased() == lowerKey }),
            keyIndex + 1 < tokens.count
        else { return nil }
        var token = tokens[keyIndex + 1]
        var scale = defaultScale
        // Glued unit, longest first ("khz" before "hz").
        for (unit, unitScale) in units.sorted(by: { $0.key.count > $1.key.count })
        where token.lowercased().hasSuffix(unit) && token.count > unit.count {
            token = String(token.dropLast(unit.count))
            scale = unitScale
            break
        }
        guard let number = parseNumber(token) else { return nil }
        if scale == defaultScale, keyIndex + 2 < tokens.count, let unitScale = units[tokens[keyIndex + 2].lowercased()] {
            scale = unitScale
        }
        let result = number * scale
        return result.isFinite ? result : nil
    }

    /// "58.80", "58,80", "-9,90", "+3", "1.000,5" -> Double. The LAST '.' or
    /// ',' is the decimal separator; any other one is a thousands separator.
    static func parseNumber(_ token: String) -> Double? {
        let text = token.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 32 else { return nil }
        guard let lastSeparator = text.lastIndex(where: { $0 == "." || $0 == "," }) else {
            return strictDouble(text)
        }
        var normalized = ""
        for index in text.indices {
            let character = text[index]
            if character == "." || character == "," {
                if index == lastSeparator { normalized.append(".") }
            } else {
                normalized.append(character)
            }
        }
        return strictDouble(normalized)
    }

    /// Plain decimal number only (no "nan", "inf", hex or exponents).
    private static func strictDouble(_ text: String) -> Double? {
        var body = Substring(text)
        if body.first == "-" || body.first == "+" { body = body.dropFirst() }
        guard !body.isEmpty, body.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
            body.contains(where: { $0.isNumber })
        else { return nil }
        guard let value = Double(text.hasPrefix("+") ? String(text.dropFirst()) : text), value.isFinite else {
            return nil
        }
        return value
    }

    private static func shortened(_ line: String) -> String {
        line.count <= 60 ? line : String(line.prefix(57)) + "…"
    }
}
