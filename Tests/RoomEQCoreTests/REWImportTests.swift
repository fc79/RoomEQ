import Foundation
import Testing
@testable import RoomEQCore

private let exampleFile = """
    Filter Settings file

    Room EQ V5.31
    Dated: 31-ott-2026 12.00.00

    Notes:

    Equaliser: Generic
    Average 1
    Filter  1: ON  PK       Fc   58.80 Hz  Gain  -9.90 dB  Q 10.664
    Filter  2: ON  PK       Fc   76.60 Hz  Gain  -6.80 dB  Q 14.316
    Filter  3: ON  PK       Fc   140.0 Hz  Gain -15.90 dB  Q  4.267
    Filter  4: ON  PK       Fc   192.0 Hz  Gain  -5.40 dB  Q  3.628
    Filter  5: ON  None
    Filter  6: OFF PK       Fc   1000 Hz   Gain   0.00 dB  Q  1.000
    """

private func values(_ bands: [EQBand]) -> [[Double]] { bands.map { [$0.frequency, $0.gain, $0.q] } }

@Suite("REW import")
struct REWImportTests {
    @Test func exactExample() {
        let result = REWImport.parse(exampleFile)
        #expect(result.warnings.isEmpty)
        #expect(result.equaliser == "Generic")
        #expect(result.filterLineCount == 6)
        #expect(values(result.bands) == [
            [58.80, -9.90, 10.664], [76.60, -6.80, 14.316], [140.0, -15.90, 4.267], [192.0, -5.40, 3.628],
            [1000, 0, 1],
        ])
        #expect(result.bands.map(\.isEnabled) == [true, true, true, true, false])
        // The first four are exactly the REW fixture used by the other tests.
        #expect(values(Array(result.bands.prefix(4))) == values(REWFixture.bands()))
        #expect(Set(result.bands.map(\.id)).count == 5)
    }

    @Test func decimalCommaAndOtherSpacing() {
        let text = """
            Equaliser: Generic
            Filter 1: ON PK Fc 58,80 Hz Gain -9,90 dB Q 10,664
            Filter\t2:\tON\tPK\tFc\t76,6\tHz\tGain\t+3,5\tdB\tQ\t14,316
            filter 3 : on pk fc 1,25 kHz gain -2 db q 2
            Filter 4: ON PK Fc 58.8Hz Gain -1.5dB Q 1.0
            Filter 5: ON PK Fc 2.5kHz Gain -1 dB Q 0,7
            Filter 6: ON PK Fc 1.000,5 Hz Gain -1 dB Q 1
            """
        let result = REWImport.parse(text)
        #expect(result.warnings.isEmpty)
        #expect(values(result.bands) == [
            [58.80, -9.90, 10.664], [76.6, 3.5, 14.316], [1250, -2, 2], [58.8, -1.5, 1], [2500, -1, 0.7],
            [1000.5, -1, 1],
        ])
    }

    @Test func windowsLineEndings() {
        let result = REWImport.parse(exampleFile.replacingOccurrences(of: "\n", with: "\r\n"))
        #expect(result.bands.count == 5)
        #expect(result.warnings.isEmpty)
    }

    @Test func offFiltersAreKeptDisabled() {
        let result = REWImport.parse("Equaliser: Generic\nFilter 1: OFF PK Fc 100 Hz Gain -3 dB Q 2\n")
        #expect(result.bands.count == 1)
        #expect(result.bands[0].isEnabled == false)
        #expect(values(result.bands) == [[100, -3, 2]])
    }

    @Test func noneFiltersAreIgnoredSilently() {
        let result = REWImport.parse("Equaliser: Generic\nFilter 1: ON None\nFilter 2: OFF None\nFilter 3: None\n")
        #expect(result.bands.isEmpty)
        #expect(result.warnings.isEmpty)
        #expect(result.filterLineCount == 3)
    }

    @Test func unsupportedTypesAreSkippedWithAWarningEach() {
        let text = """
            Equaliser: Generic
            Filter  1: ON  PK       Fc   58.80 Hz  Gain  -9.90 dB  Q 10.664
            Filter  7: ON  LS       Fc   100.0 Hz  Gain   5.00 dB
            Filter  8: ON  HS       Fc   8000 Hz   Gain  -2.00 dB
            Filter  9: ON  LSC 12dB Fc   100.0 Hz  Gain   3.00 dB  Q  0.707
            Filter 10: ON  HP       Fc   20.0 Hz
            Filter 11: ON  LPQ      Fc   20000 Hz  Q  0.707
            Filter 12: OFF NO       Fc   50.0 Hz
            Filter 13: ON  AP       Fc   300 Hz    Q  1.0
            Filter 14: ON  BP       Fc   300 Hz    Q  1.0
            """
        let result = REWImport.parse(text)
        #expect(result.bands.count == 1)
        #expect(result.warnings == [
            "Filtro 7: tipo LS non supportato, ignorato",
            "Filtro 8: tipo HS non supportato, ignorato",
            "Filtro 9: tipo LSC non supportato, ignorato",
            "Filtro 10: tipo HP non supportato, ignorato",
            "Filtro 11: tipo LPQ non supportato, ignorato",
            "Filtro 12: tipo NO non supportato, ignorato",
            "Filtro 13: tipo AP non supportato, ignorato",
            "Filtro 14: tipo BP non supportato, ignorato",
        ])
    }

    @Test func moreThan16PKFiltersKeepsTheFirst16() {
        var text = "Equaliser: Generic\n"
        for number in 1...20 {
            text += "Filter \(number): ON  PK  Fc \(100 + number) Hz  Gain -1.00 dB  Q 2.0\n"
        }
        let result = REWImport.parse(text)
        #expect(result.bands.count == 16)
        #expect(result.bands.map(\.frequency) == (1...16).map { Double(100 + $0) })
        #expect(result.warnings == ["Più di 16 filtri PK: importati 16 (i primi 16 attivi), ignorati gli altri 4 (17, 18, 19, 20)"])
    }

    /// Over the limit, OFF filters are dropped before any ON one.
    @Test func moreThan16PKFiltersDropsOffOnesFirst() {
        var text = "Equaliser: Generic\n"
        for number in 1...18 {
            let state = [2, 5, 17].contains(number) ? "OFF" : "ON"
            text += "Filter \(number): \(state)  PK  Fc \(100 + number) Hz  Gain -1.00 dB  Q 2.0\n"
        }
        let result = REWImport.parse(text)
        #expect(result.bands.count == 16)
        // All 15 ON filters plus the first OFF one (2), in file order.
        #expect(result.bands.map(\.frequency) == ([1, 2, 3, 4] + Array(6...16) + [18]).map { Double(100 + $0) })
        #expect(result.bands.filter { !$0.isEnabled }.map(\.frequency) == [102])
        #expect(result.warnings == ["Più di 16 filtri PK: importati 16 (tutti quelli attivi), ignorati 2 filtri disattivati (5, 17)"])
    }

    @Test func equaliserOtherThanGenericGivesAWarning() {
        let other = REWImport.parse("Equaliser: MiniDSP 2x4 HD\nFilter 1: ON PK Fc 100 Hz Gain -3 dB Q 2\n")
        #expect(other.equaliser == "MiniDSP 2x4 HD")
        #expect(other.bands.count == 1)
        #expect(other.warnings.count == 1)
        #expect(other.warnings[0].hasPrefix("Equalizzatore «MiniDSP 2x4 HD» invece di «Generic»"))

        let missing = REWImport.parse("Filter 1: ON PK Fc 100 Hz Gain -3 dB Q 2\n")
        #expect(missing.equaliser == nil)
        #expect(missing.warnings.count == 1)
        #expect(missing.warnings[0].hasPrefix("Riga «Equaliser:» assente"))

        #expect(REWImport.parse("Equaliser: generic\nFilter 1: ON PK Fc 100 Hz Gain -3 dB Q 2").warnings.isEmpty)
    }

    @Test func malformedFilterLinesBecomeWarnings() {
        let text = """
            Equaliser: Generic
            Filter 1: ON PK Fc abc Hz Gain -3 dB Q 2
            Filter 2: ON PK Fc 100 Hz Gain -3 dB
            Filter 3: ON PK Fc 100 Hz Gain -3 dB Q 0
            Filter 4: ON PK Fc -100 Hz Gain -3 dB Q 2
            Filter 5: ON PK Fc nan Hz Gain -3 dB Q 2
            Filter 6: ON PK Fc 1e5 Hz Gain -3 dB Q 2
            Filter 7:
            Filter 8 ON PK Fc 100 Hz Gain -3 dB Q 2
            Filter 9: ON PK Fc 100 Hz Gain -3 dB Q 2
            Filter Settings file
            Filtered nonsense
            """
        let result = REWImport.parse(text)
        #expect(values(result.bands) == [[100, -3, 2]])
        #expect(result.warnings == [
            "Filtro 1: valori non leggibili, ignorato",
            "Filtro 2: valori non leggibili, ignorato",
            "Filtro 3: frequenza o Q non validi, ignorato",
            "Filtro 4: frequenza o Q non validi, ignorato",
            "Filtro 5: valori non leggibili, ignorato",
            "Filtro 6: valori non leggibili, ignorato",
            "Filtro 7: valori non leggibili, ignorato",
            "Riga 9 non riconosciuta, ignorata: «Filter 8 ON PK Fc 100 Hz Gain -3 dB Q 2»",
        ])
    }

    @Test func garbageNeverCrashes() {
        #expect(REWImport.parse("").bands.isEmpty)
        #expect(REWImport.parse("\n\n\r\n").bands.isEmpty)
        let nonsense = REWImport.parse("hello world\n🎛️ Filter ⚠️: ∞\n\u{0}\u{1}\u{2}")
        #expect(nonsense.bands.isEmpty)
        #expect(nonsense.warnings == ["Nessuna riga «Filter N: …» trovata: non sembra un file di filtri di REW"])
        let long = REWImport.parse("Filter 1: ON PK Fc " + String(repeating: "9", count: 5000) + " Hz Gain 1 dB Q 1")
        #expect(long.bands.isEmpty)
        #expect(REWImport.parse("Filter 99999999999999999999999: ON PK Fc 100 Hz Gain -3 dB Q 2").bands.isEmpty)

        // Fuzz: random lines made of REW-like tokens and junk.
        let tokens = [
            "Filter", "Filter 1:", "Filter  12:", ":", "ON", "OFF", "PK", "LS", "None", "Fc", "Gain", "Q", "Hz", "kHz",
            "dB", "58.80", "-9,90", "1.000,5", "0", "-0", "nan", "inf", "1e300", "+", "-", ",", ".", "🎚", "\t", "",
            "Equaliser:", "Generic",
        ]
        var generator = SeededGenerator(state: 42)
        for _ in 0..<300 {
            var text = ""
            for _ in 0..<Int.random(in: 1...25, using: &generator) {
                let count = Int.random(in: 0...12, using: &generator)
                text += (0..<count).map { _ in tokens.randomElement(using: &generator)! }.joined(separator: " ") + "\n"
            }
            let result = REWImport.parse(text)
            #expect(result.bands.count <= 16)
            #expect(result.bands.allSatisfy { $0.isFinite && $0.frequency > 0 && $0.q > 0 })
        }
    }

    @Test func numbers() {
        #expect(REWImport.parseNumber("58.80") == 58.8)
        #expect(REWImport.parseNumber("58,80") == 58.8)
        #expect(REWImport.parseNumber("-9,90") == -9.9)
        #expect(REWImport.parseNumber("+3") == 3)
        #expect(REWImport.parseNumber("1.000,5") == 1000.5)
        #expect(REWImport.parseNumber("1,000.5") == 1000.5)
        // Documented rule: a lone separator is always decimal, so "1.000"
        // (Italian thousands notation) reads as 1,0. REW never writes
        // thousands separators ("Fc 1000 Hz").
        #expect(REWImport.parseNumber("1.000") == 1)
        #expect(REWImport.parseNumber("1,000") == 1)
        for bad in ["", "abc", "nan", "inf", "-", "1e5", "0x10", ".", "--1", "1-", "1 2"] {
            #expect(REWImport.parseNumber(bad) == nil, "\(bad)")
        }
    }

    // MARK: Files

    func temporaryFile(_ data: Data, name: String = "filters.txt") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func loadsUTF8Latin1AndUTF16Files() throws {
        let utf8 = try REWImport.load(url: temporaryFile(Data(exampleFile.utf8)))
        #expect(utf8.bands.count == 5)

        // Latin-1 / Windows-1252 with accented characters in the notes.
        let latin = exampleFile.replacingOccurrences(of: "Notes:", with: "Notes: misura è più bassa")
        let latinData = try #require(latin.data(using: .windowsCP1252))
        #expect(String(data: latinData, encoding: .utf8) == nil)  // really not UTF-8
        #expect(try REWImport.load(url: temporaryFile(latinData)).bands.count == 5)

        let utf16 = try #require(exampleFile.data(using: .utf16))  // with BOM
        #expect(try REWImport.load(url: temporaryFile(utf16)).bands.count == 5)

        let bom = Data([0xEF, 0xBB, 0xBF]) + Data(exampleFile.utf8)
        #expect(try REWImport.load(url: temporaryFile(bom)).bands.count == 5)
    }

    @Test func loadErrorsAreItalian() throws {
        let missing = URL(fileURLWithPath: "/nonexistent/folder/filtri.txt")
        #expect(throws: REWImportError.self) { try REWImport.load(url: missing) }
        do {
            _ = try REWImport.load(url: missing)
        } catch {
            #expect(error.localizedDescription.hasPrefix("Impossibile leggere «filtri.txt»"))
        }

        let onlyShelves = try temporaryFile(Data("Equaliser: Generic\nFilter 1: ON LS Fc 100 Hz Gain 3 dB\n".utf8))
        do {
            _ = try REWImport.load(url: onlyShelves)
            Issue.record("should have thrown")
        } catch let error as REWImportError {
            guard case .noUsableFilters(let name, let warnings) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(name == "filters.txt")
            #expect(warnings == ["Filtro 1: tipo LS non supportato, ignorato"])
            #expect(error.localizedDescription.contains("non contiene filtri PK utilizzabili"))
        }

        let binary = try temporaryFile(Data([0x00, 0x01, 0xFF, 0x00, 0x42]))
        #expect(throws: REWImportError.notText(fileName: "filters.txt")) { try REWImport.load(url: binary) }

        let huge = try temporaryFile(Data(repeating: 0x41, count: REWImport.maximumFileSize + 1))
        #expect(throws: REWImportError.tooLarge(fileName: "filters.txt")) { try REWImport.load(url: huge) }
        // A file without a usable size (endless): only limit + 1 bytes are read.
        #expect(throws: REWImportError.tooLarge(fileName: "zero")) { try REWImport.load(url: URL(fileURLWithPath: "/dev/zero")) }
    }
}
