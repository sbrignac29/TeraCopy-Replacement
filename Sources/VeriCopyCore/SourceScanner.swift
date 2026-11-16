import Foundation

/// Expands user-selected files/folders into a flat, per-file work list.
/// Safe to run off the main thread; never throws — problems are reported in `scanErrors`.
public enum SourceScanner {

    public static func scan(sources: [URL]) -> TransferPlan {
        var plan = TransferPlan()
        var seenDirectories = Set<String>()
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]

        for source in sources {
            let source = source.standardizedFileURL
            guard let values = try? source.resourceValues(forKeys: keys) else {
                plan.scanErrors.append("Could not read \(source.path)")
                continue
            }

            if values.isSymbolicLink == true {
                appendFile(&plan, source: source, relative: source.lastPathComponent, size: 0, symlink: true)
            } else if values.isDirectory == true {
                let rootName = source.lastPathComponent
                addDirectory(&plan, relative: rootName, source: source, seen: &seenDirectories)

                let enumerator = fm.enumerator(
                    at: source,
                    includingPropertiesForKeys: Array(keys),
                    options: [],
                    errorHandler: { url, error in
                        plan.scanErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                        return true // keep enumerating
                    }
                )
                let rootPath = source.path.utf8.last == UInt8(ascii: "/") ? source.path : source.path + "/"

                while let child = enumerator?.nextObject() as? URL {
                    let childPath = child.standardizedFileURL.path
                    guard let below = pathSuffix(of: childPath, below: rootPath) else {
                        // Never drop an entry quietly: a job that copies less than was selected
                        // must say so.
                        plan.scanErrors.append("Skipped \(childPath): not inside \(source.path)")
                        continue
                    }
                    let relative = rootName + "/" + below

                    guard let childValues = try? child.resourceValues(forKeys: keys) else {
                        plan.scanErrors.append("Could not read \(child.path)")
                        continue
                    }
                    if childValues.isSymbolicLink == true {
                        appendFile(&plan, source: child, relative: relative, size: 0, symlink: true)
                    } else if childValues.isDirectory == true {
                        addDirectory(&plan, relative: relative, source: child, seen: &seenDirectories)
                    } else {
                        appendFile(&plan, source: child, relative: relative,
                                   size: Int64(childValues.fileSize ?? 0), symlink: false)
                    }
                }
            } else {
                appendFile(&plan, source: source, relative: source.lastPathComponent,
                           size: Int64(values.fileSize ?? 0), symlink: false)
            }
        }

        // Create shallow directories before deep ones.
        plan.directories.sort { depth(of: $0) < depth(of: $1) }
        return plan
    }

    /// The part of `path` after `rootPath` (which ends in "/"), or nil if `path` is not below it.
    ///
    /// Compared and sliced byte-for-byte on purpose. `String.hasPrefix` and `dropFirst` work in
    /// grapheme clusters, and a name that starts with a combining mark (U+0338, say) fuses with the
    /// "/" before it into a single `Character` — so "/root/\u{0338}x" does not "have the prefix"
    /// "/root/", and such files and everything under such folders used to vanish from the plan.
    static func pathSuffix(of path: String, below rootPath: String) -> String? {
        let pathBytes = path.utf8
        let rootBytes = rootPath.utf8
        guard pathBytes.count > rootBytes.count, pathBytes.starts(with: rootBytes) else { return nil }
        return String(decoding: pathBytes.dropFirst(rootBytes.count), as: UTF8.self)
    }

    /// Number of path components in a relative path. Counts "/" bytes rather than splitting the
    /// string, so a separator followed by a combining mark is still counted (see `pathSuffix`).
    static func depth(of relativePath: String) -> Int {
        var separators = 0
        for byte in relativePath.utf8 where byte == UInt8(ascii: "/") { separators += 1 }
        return separators + 1
    }

    private static func appendFile(_ plan: inout TransferPlan, source: URL, relative: String, size: Int64, symlink: Bool) {
        plan.items.append(FileItem(sourceURL: source, relativePath: relative, size: size, isSymlink: symlink))
        plan.totalBytes += size
    }

    private static func addDirectory(_ plan: inout TransferPlan, relative: String, source: URL, seen: inout Set<String>) {
        guard seen.insert(relative).inserted else { return }
        plan.directories.append(relative)
        plan.directorySources.append((source: source, relative: relative))
    }
}
