import Foundation
import CryptoKit

/// Streaming hash over file chunks. Class-based so it can be threaded through async code without `mutating`.
public protocol StreamingHasher: AnyObject {
    func update(_ data: Data)
    func update(buffer: UnsafeRawBufferPointer)
    func finalizedHex() -> String
}

public enum HashAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case sha256 = "SHA-256"
    case sha512 = "SHA-512"
    case sha1 = "SHA-1"
    case md5 = "MD5"
    case crc32 = "CRC-32"

    public var id: String { rawValue }

    public func makeHasher() -> StreamingHasher {
        switch self {
        case .sha256: return DigestHasher<SHA256>()
        case .sha512: return DigestHasher<SHA512>()
        case .sha1: return DigestHasher<Insecure.SHA1>()
        case .md5: return DigestHasher<Insecure.MD5>()
        case .crc32: return CRC32Hasher()
        }
    }

    /// File extension conventionally used for a checksum manifest of this algorithm.
    public var manifestExtension: String {
        switch self {
        case .sha256: return "sha256"
        case .sha512: return "sha512"
        case .sha1: return "sha1"
        case .md5: return "md5"
        case .crc32: return "sfv"
        }
    }

    /// Short label for the kind of hash (shown next to the name).
    public var kindLabel: String {
        switch self {
        case .sha256: return "256-bit · cryptographic"
        case .sha512: return "512-bit · cryptographic"
        case .sha1: return "160-bit · legacy"
        case .md5: return "128-bit · legacy"
        case .crc32: return "32-bit · checksum"
        }
    }

    /// True for the default, recommended choice.
    public var isRecommended: Bool { self == .sha256 }

    /// One- or two-sentence plain-language explanation for the Settings screen.
    public var explanation: String {
        switch self {
        case .sha256:
            return "The default. A modern, cryptographically strong hash — it's effectively "
                + "impossible for two different files to share a checksum, so a match is a solid "
                + "guarantee the copy is identical. The best all-round choice."
        case .sha512:
            return "Same family as SHA-256 but with a longer, even stronger checksum. On 64-bit "
                + "Macs it can be slightly faster on large files, at the cost of a longer value in "
                + "the manifest. Use it when you want maximum assurance."
        case .sha1:
            return "An older, faster hash. Reliable for catching accidental corruption, but it's "
                + "cryptographically broken — a determined attacker can forge a match — so don't "
                + "rely on it to detect deliberate tampering. Handy for matching older SHA-1 lists."
        case .md5:
            return "Fast and everywhere. Great for spotting accidental corruption and for checking "
                + "against existing MD5 checksums, but cryptographically broken — never use it as "
                + "proof against intentional tampering."
        case .crc32:
            return "A tiny, extremely fast checksum — not a cryptographic hash. It catches most "
                + "accidental corruption and matches .sfv files, but collisions are easy to create, "
                + "so treat it as a quick sanity check rather than a strong guarantee."
        }
    }
}

/// Lowercase hex, two digits per byte.
///
/// A digest used to be rendered with one `String(format: "%02x")` per byte. Every file is hashed
/// twice — once as it is copied, once as it is read back — so a job of small files paid for 64
/// trips through the string formatter per file with SHA-256, 128 with SHA-512, to produce text
/// a table lookup produces directly.
enum HexEncoding {
    private static let digits = Array("0123456789abcdef".utf8)

    static func lowercase(_ bytes: UnsafeRawBufferPointer) -> String {
        let digits = Self.digits
        return String(unsafeUninitializedCapacity: bytes.count * 2) { output in
            var position = 0
            for byte in bytes {
                output[position] = digits[Int(byte >> 4)]
                output[position + 1] = digits[Int(byte & 0x0F)]
                position += 2
            }
            return position
        }
    }
}

final class DigestHasher<H: HashFunction>: StreamingHasher {
    private var hash = H()

    func update(_ data: Data) {
        hash.update(data: data)
    }

    func update(buffer: UnsafeRawBufferPointer) {
        hash.update(bufferPointer: buffer)
    }

    func finalizedHex() -> String {
        hash.finalize().withUnsafeBytes { HexEncoding.lowercase($0) }
    }
}

/// CRC-32 as used by zip, PNG and `.sfv` files, computed eight bytes at a step.
///
/// The textbook form looks one byte up in a 256-entry table, and each step has to wait for the
/// one before it — which held this to a few hundred MB/s, slower than SHA-256 on a Mac with
/// hardware SHA and well under what an internal SSD delivers. So the checksum offered as the
/// fast one was the one that capped the copy.
///
/// "Slicing-by-8" folds eight bytes in at once using eight tables, where table `k` holds what
/// table 0 gives for a byte followed by `k` zero bytes. The eight lookups do not depend on each
/// other, so the processor runs them side by side. Same polynomial, same answer for every input;
/// the selftest checks it against the one-byte form at every length and alignment.
public final class CRC32Hasher: StreamingHasher {
    /// The eight tables end to end: table `k` is entries `k * 256 ..< (k + 1) * 256`.
    private static let tables: [UInt32] = {
        var tables = [UInt32](repeating: 0, count: 8 * 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1 == 1) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            tables[i] = c
        }
        for k in 1..<8 {
            for i in 0..<256 {
                let previous = tables[(k - 1) * 256 + i]
                tables[k * 256 + i] = (previous >> 8) ^ tables[Int(previous & 0xFF)]
            }
        }
        return tables
    }()

    private var crc: UInt32 = 0xFFFFFFFF

    public init() {}

    public func update(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            update(buffer: raw)
        }
    }

    public func update(buffer: UnsafeRawBufferPointer) {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
        let count = buffer.count
        let start = crc
        crc = Self.tables.withUnsafeBufferPointer { tables -> UInt32 in
            // Raw pointer into the tables: the indices below are all a table number times 256
            // plus one byte, so they cannot leave the 2,048 entries, and a bounds check on
            // each of eight lookups per step is most of what this loop would otherwise do.
            let table = tables.baseAddress!
            var value = start
            var offset = 0

            // Eight bytes at a step. The buffer starts wherever the caller's data starts, so
            // the loads must not assume alignment.
            while count - offset >= 8 {
                let low = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) ^ value
                let high = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self))
                let a = table[7 * 256 + Int(low & 0xFF)] ^ table[6 * 256 + Int((low >> 8) & 0xFF)]
                let b = table[5 * 256 + Int((low >> 16) & 0xFF)] ^ table[4 * 256 + Int(low >> 24)]
                let c = table[3 * 256 + Int(high & 0xFF)] ^ table[2 * 256 + Int((high >> 8) & 0xFF)]
                let d = table[1 * 256 + Int((high >> 16) & 0xFF)] ^ table[Int(high >> 24)]
                value = a ^ b ^ c ^ d
                offset += 8
            }

            // Whatever is left, up to seven bytes, one at a time.
            while offset < count {
                let byte = base.load(fromByteOffset: offset, as: UInt8.self)
                value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
                offset += 1
            }
            return value
        }
    }

    public func finalizedHex() -> String {
        String(format: "%08x", crc ^ 0xFFFFFFFF)
    }
}
