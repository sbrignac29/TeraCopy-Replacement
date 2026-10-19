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

final class DigestHasher<H: HashFunction>: StreamingHasher {
    private var hash = H()

    func update(_ data: Data) {
        hash.update(data: data)
    }

    func update(buffer: UnsafeRawBufferPointer) {
        hash.update(bufferPointer: buffer)
    }

    func finalizedHex() -> String {
        hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public final class CRC32Hasher: StreamingHasher {
    private static let table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 == 1) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private var crc: UInt32 = 0xFFFFFFFF

    public init() {}

    public func update(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            update(buffer: raw)
        }
    }

    public func update(buffer: UnsafeRawBufferPointer) {
        var value = crc
        for byte in buffer {
            value = Self.table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        crc = value
    }

    public func finalizedHex() -> String {
        String(format: "%08x", crc ^ 0xFFFFFFFF)
    }
}
