// 24-bit stereo PCM WAV files for recording.
//
// The header is written at creation with zero sizes and rewritten by
// `updateHeader()` (the writer calls it about once a second) and on close, so
// a file cut short by a crash or power loss is still a valid WAV up to the
// last update. A RIFF file cannot exceed 4 GiB: `canAppend(frames:)` tells
// the writer when to continue in a new file.

import Foundation

public final class WAVWriter {
    public static let channels = 2
    public static let bytesPerSample = 3
    public static let headerSize = 44
    /// Largest data chunk that keeps the RIFF size within UInt32.
    public static let maxDataBytes = Int(UInt32.max) - headerSize - 8

    public let url: URL
    public let sampleRate: Int
    public private(set) var dataBytes = 0
    private let handle: FileHandle
    private var scratch: [UInt8] = []
    private var closed = false

    public var frames: Int { dataBytes / (Self.channels * Self.bytesPerSample) }

    /// Creates the file (fails if it already exists).
    public init(url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        // O_EXCL: never overwrite an existing file.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            throw CocoaError(errno == EEXIST ? .fileWriteFileExists : .fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: 0))
    }

    deinit { if !closed { try? close() } }

    public func canAppend(frames: Int) -> Bool {
        dataBytes + frames * Self.channels * Self.bytesPerSample <= Self.maxDataBytes
    }

    /// Appends interleaved stereo float samples as 24-bit PCM.
    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard !samples.isEmpty else { return }
        let byteCount = samples.count * Self.bytesPerSample
        if scratch.count < byteCount { scratch = [UInt8](repeating: 0, count: byteCount) }
        scratch.withUnsafeMutableBufferPointer { Self.pack24(samples, into: $0.baseAddress!) }
        try handle.write(contentsOf: scratch[0..<byteCount])
        dataBytes += byteCount
    }

    /// Appends `frames` silent frames.
    public func appendSilence(frames: Int) throws {
        guard frames > 0 else { return }
        let byteCount = frames * Self.channels * Self.bytesPerSample
        try handle.write(contentsOf: Data(count: byteCount))
        dataBytes += byteCount
    }

    /// Rewrites the sizes in the header.
    public func updateHeader() throws {
        let position = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: dataBytes))
        try handle.seek(toOffset: position)
    }

    public func close() throws {
        guard !closed else { return }
        closed = true
        try updateHeader()
        try handle.synchronize()
        try handle.close()
    }

    // MARK: - Format

    /// The 44-byte RIFF/WAVE header for 24-bit stereo PCM.
    public static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var data = Data(capacity: headerSize)
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian) { data.append(contentsOf: $0) } }
        let blockAlign = channels * bytesPerSample
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)  // PCM
        u16(channels); u32(sampleRate); u32(sampleRate * blockAlign); u16(blockAlign); u16(bytesPerSample * 8)
        data.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return data
    }

    /// Float in −1…1 to signed 24-bit little endian, rounded and clipped.
    public static func pack24(_ samples: UnsafeBufferPointer<Float>, into bytes: UnsafeMutablePointer<UInt8>) {
        let scale: Float = 8_388_607
        for (index, sample) in samples.enumerated() {
            let clipped = sample.isFinite ? min(max(sample, -1), 1) : 0
            let value = Int32((clipped * scale).rounded())
            bytes[index * 3] = UInt8(truncatingIfNeeded: value)
            bytes[index * 3 + 1] = UInt8(truncatingIfNeeded: value >> 8)
            bytes[index * 3 + 2] = UInt8(truncatingIfNeeded: value >> 16)
        }
    }
}
