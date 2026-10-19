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
                let rootPath = source.path.hasSuffix("/") ? source.path : source.path + "/"

                while let child = enumerator?.nextObject() as? URL {
                    let childPath = child.standardizedFileURL.path
                    guard childPath.hasPrefix(rootPath) else { continue }
                    let relative = rootName + "/" + String(childPath.dropFirst(rootPath.count))

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
        plan.directories.sort { $0.components(separatedBy: "/").count < $1.components(separatedBy: "/").count }
        return plan
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
