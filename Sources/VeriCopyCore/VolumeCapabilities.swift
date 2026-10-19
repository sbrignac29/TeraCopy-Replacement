import Foundation
import Darwin
import IOKit
import IOKit.storage

/// What a destination volume can actually store natively.
///
/// This matters because macOS *emulates* extended attributes on filesystems that have no
/// native support for them (ExFAT, FAT32, and most USB media volumes) by writing a separate
/// AppleDouble `._name` file next to every file that carries them. On a large ingest that
/// silently doubles the number of files created on a filesystem whose per-file cost is already
/// the dominant term — measured at ~5.5 ms per file on ExFAT versus ~0.4 ms for a plain
/// permissions-and-timestamps stamp.
public struct VolumeCapabilities: Sendable, Equatable {
    /// The volume stores extended attributes itself, rather than in AppleDouble side files.
    public let nativeExtendedAttributes: Bool
    /// The volume stores ACLs / extended security information.
    public let extendedSecurity: Bool
    /// The volume supports `clonefile(2)` — copy-on-write clones within the same volume.
    public let cloning: Bool
    /// True when the probe could not read the volume's capabilities; callers should then
    /// behave as they did before (copy everything) rather than silently dropping metadata.
    public let unknown: Bool
    /// True for flash media, false for a rotational disk, nil when the device won't say.
    /// Decides whether reads and writes may usefully run against the volume at the same time:
    /// flash handles a mixed queue, a single head has to seek between the two.
    public let solidState: Bool?

    public init(nativeExtendedAttributes: Bool, extendedSecurity: Bool,
                cloning: Bool, unknown: Bool, solidState: Bool? = nil) {
        self.nativeExtendedAttributes = nativeExtendedAttributes
        self.extendedSecurity = extendedSecurity
        self.cloning = cloning
        self.unknown = unknown
        self.solidState = solidState
    }

    /// Asks IOKit what kind of media backs the volume at `url`.
    ///
    /// `statfs` gives the partition's BSD name; the media type lives on an ancestor of that
    /// node in the IOService plane, so the search walks up parents rather than reading the
    /// partition itself. Returns nil rather than guessing — plenty of devices, network mounts
    /// and disk images among them, simply do not report it.
    public static func probeSolidState(at url: URL) -> Bool? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        let devicePath = withUnsafeBytes(of: info.f_mntfromname) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        guard devicePath.hasPrefix("/dev/") else { return nil }
        let bsdName = String(devicePath.dropFirst("/dev/".count))

        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let property = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane,
                kIOPropertyDeviceCharacteristicsKey as CFString,
                kCFAllocatorDefault, options) as? [String: Any],
              let medium = property[kIOPropertyMediumTypeKey] as? String else { return nil }
        return medium == kIOPropertyMediumTypeSolidStateKey
    }

    /// Conservative default: assume the volume carries everything, so nothing is dropped
    /// on a filesystem we failed to interrogate.
    public static let unknownVolume = VolumeCapabilities(nativeExtendedAttributes: true,
                                                         extendedSecurity: true,
                                                         cloning: false,
                                                         unknown: true)

    // getattrlist(2) interface-capability bits. Declared here rather than taken from the
    // Darwin overlay so the types line up without a pile of numeric conversions.
    private static let volCapIntExtendedSecurity: UInt32 = 0x0000_0400
    private static let volCapIntExtendedAttr: UInt32     = 0x0000_4000
    private static let volCapIntClone: UInt32            = 0x0001_0000
    private static let volCapabilitiesInterfaces = 1
    // Written out rather than taken from the Darwin overlay, where these arrive as differently
    // signed types that will not combine without a pile of conversions.
    private static let attrVolInfo: UInt32         = 0x8000_0000
    private static let attrVolCapabilities: UInt32 = 0x0002_0000

    /// Reads the capabilities of the volume containing `url`.
    ///
    /// The reply buffer is `u_int32_t length` followed by `vol_capabilities_attr_t`, which is
    /// two arrays of four `u_int32_t` — `capabilities` then `valid`. A capability only counts
    /// when its matching `valid` bit is set; otherwise the filesystem is not answering the
    /// question and we must not draw a conclusion from a zero.
    public static func probe(at url: URL) -> VolumeCapabilities {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(Self.attrVolInfo | Self.attrVolCapabilities)

        let byteCount = 64
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        defer { buffer.deallocate() }
        memset(buffer, 0, byteCount)

        let path = url.path
        guard getattrlist(path, &request, buffer, byteCount, 0) == 0 else {
            return .unknownVolume
        }

        // offset 0: length · offsets 4…19: capabilities[0…3] · offsets 20…35: valid[0…3]
        func word(_ base: Int, _ index: Int) -> UInt32 {
            buffer.loadUnaligned(fromByteOffset: base + index * 4, as: UInt32.self)
        }
        let capabilities = word(4, volCapabilitiesInterfaces)
        let valid = word(20, volCapabilitiesInterfaces)

        func supports(_ bit: UInt32) -> Bool { (valid & bit) != 0 && (capabilities & bit) != 0 }

        return VolumeCapabilities(nativeExtendedAttributes: supports(volCapIntExtendedAttr),
                                  extendedSecurity: supports(volCapIntExtendedSecurity),
                                  cloning: supports(volCapIntClone),
                                  unknown: false,
                                  solidState: probeSolidState(at: url))
    }
}

/// How much per-file metadata to carry across.
public enum MetadataPolicy: String, CaseIterable, Identifiable, Sendable {
    /// Permissions, timestamps, ACLs and extended attributes, always — even where the
    /// destination can only hold xattrs as AppleDouble `._` side files.
    case full
    /// ACLs and extended attributes where the volume stores them natively; permissions and
    /// timestamps everywhere. The default: it keeps everything a volume can really hold and
    /// stops an ExFAT archive from gaining a `._` twin for every file copied onto it.
    case native
    /// Permissions and timestamps only.
    case basic

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .full: return "Everything"
        case .native: return "What the drive supports"
        case .basic: return "Dates and permissions"
        }
    }

    public var explanation: String {
        switch self {
        case .full:
            return "Copies extended attributes and ACLs even to drives that cannot store them, "
                + "where macOS emulates them as hidden \"._\" companion files. Slowest, and it "
                + "doubles the number of files written to an ExFAT or FAT drive."
        case .native:
            return "The default. Carries tags, Finder info and ACLs to drives that store them "
                + "natively — APFS and HFS+ — and copies just dates and permissions to drives "
                + "that don't, like the ExFAT volumes most external media drives use. Around "
                + "15× faster per file on those drives, with no hidden \"._\" files left behind."
        case .basic:
            return "Copies only modification dates and permissions. Fastest, and it discards "
                + "Finder tags, comments and any other extended attributes."
        }
    }

    /// Whether ACLs and xattrs should be carried to a destination with these capabilities.
    public func carriesExtendedMetadata(to capabilities: VolumeCapabilities) -> Bool {
        switch self {
        case .full: return true
        case .basic: return false
        case .native: return capabilities.nativeExtendedAttributes || capabilities.unknown
        }
    }
}
