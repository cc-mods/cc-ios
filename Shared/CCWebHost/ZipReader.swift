import Foundation
import Compression

/// Minimal ZIP reader for unpacking `.ccmod` files (which are ZIP archives) into folder
/// mods. Parses the central directory and inflates entries with the Compression framework.
///
/// Supports the only two methods CrossCode mods use: stored (0) and deflate (8). This avoids
/// any third-party dependency and works identically on iOS and macOS.
enum ZipReader {

    struct Entry { let path: String; let data: Data }

    /// Extracts all file entries from ZIP `data`. Directory entries (trailing `/`) are
    /// skipped; their structure is implied by file paths. Returns nil if not a valid ZIP.
    static func extract(_ data: Data) -> [Entry]? {
        let bytes = [UInt8](data)
        guard let eocd = findEOCD(bytes) else { return nil }
        let count = readU16(bytes, eocd + 10)
        var cdOffset = Int(readU32(bytes, eocd + 16))
        var entries: [Entry] = []

        for _ in 0..<count {
            guard cdOffset + 46 <= bytes.count,
                  readU32(bytes, cdOffset) == 0x02014b50 else { break }
            let method = readU16(bytes, cdOffset + 10)
            let compSize = Int(readU32(bytes, cdOffset + 20))
            let uncompSize = Int(readU32(bytes, cdOffset + 24))
            let nameLen = readU16(bytes, cdOffset + 28)
            let extraLen = readU16(bytes, cdOffset + 30)
            let commentLen = readU16(bytes, cdOffset + 32)
            let localOffset = Int(readU32(bytes, cdOffset + 42))
            let nameStart = cdOffset + 46
            guard nameStart + nameLen <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart ..< nameStart + nameLen], as: UTF8.self)

            cdOffset = nameStart + nameLen + extraLen + commentLen

            if name.hasSuffix("/") { continue }   // directory entry

            // Local header: 30-byte fixed + name + extra, then file data.
            guard localOffset + 30 <= bytes.count,
                  readU32(bytes, localOffset) == 0x04034b50 else { continue }
            let lNameLen = readU16(bytes, localOffset + 26)
            let lExtraLen = readU16(bytes, localOffset + 28)
            let dataStart = localOffset + 30 + lNameLen + lExtraLen
            guard dataStart + compSize <= bytes.count else { continue }
            let comp = Data(bytes[dataStart ..< dataStart + compSize])

            let out: Data?
            switch method {
            case 0: out = comp                                  // stored
            case 8: out = inflate(comp, expectedSize: uncompSize) // deflate
            default: out = nil
            }
            if let out = out { entries.append(Entry(path: name, data: out)) }
        }
        return entries.isEmpty ? nil : entries
    }

    /// Extracts a `.ccmod` ZIP into `destDir`, creating subdirectories as needed.
    /// Returns true on success.
    @discardableResult
    static func unzip(_ data: Data, to destDir: URL) -> Bool {
        guard let entries = extract(data) else { return false }
        let fm = FileManager.default
        for entry in entries {
            // Guard against path traversal in archive names.
            let sanitized = entry.path.replacingOccurrences(of: "\\", with: "/")
            if sanitized.contains("../") { continue }
            let dest = destDir.appendingPathComponent(sanitized).standardizedFileURL
            guard dest.path.hasPrefix(destDir.standardizedFileURL.path) else { continue }
            try? fm.createDirectory(at: dest.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? entry.data.write(to: dest)
        }
        return true
    }

    // MARK: - Helpers

    private static func findEOCD(_ b: [UInt8]) -> Int? {
        // EOCD signature 0x06054b50, scanning back from the end (comment may follow).
        guard b.count >= 22 else { return nil }
        var i = b.count - 22
        let minI = max(0, b.count - 22 - 65535)
        while i >= minI {
            if b[i] == 0x50 && b[i+1] == 0x4b && b[i+2] == 0x05 && b[i+3] == 0x06 { return i }
            i -= 1
        }
        return nil
    }

    private static func readU16(_ b: [UInt8], _ o: Int) -> Int {
        guard o + 1 < b.count else { return 0 }
        return Int(b[o]) | (Int(b[o+1]) << 8)
    }
    private static func readU32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 3 < b.count else { return 0 }
        return UInt32(b[o]) | (UInt32(b[o+1]) << 8) | (UInt32(b[o+2]) << 16) | (UInt32(b[o+3]) << 24)
    }

    /// Raw DEFLATE inflate via the Compression framework.
    private static func inflate(_ input: Data, expectedSize: Int) -> Data? {
        if input.isEmpty { return Data() }
        let cap = max(expectedSize, input.count * 4) + 4096
        var dst = Data(count: cap)
        let result: Int = dst.withUnsafeMutableBytes { dstPtr in
            input.withUnsafeBytes { srcPtr in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!, cap,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard result > 0 else { return nil }
        return dst.prefix(result)
    }
}
