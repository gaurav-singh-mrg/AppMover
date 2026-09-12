import Foundation

/// Which processes currently hold a file open inside a folder.
///
/// Name matching alone cannot answer this: `~/Library/Application Support/Code` belongs to
/// Visual Studio Code and says so nowhere. Folder names in Application Support are chosen
/// freely by the app, so identity has to come from the kernel instead of from a string.
public enum OpenFiles {
    /// PIDs with a file open anywhere under any of `paths`.
    ///
    /// ponytail: one system-wide `lsof` and a prefix match, rather than `lsof +D` per folder.
    /// `+D` walks the tree, which is minutes on a ~/Library/Developer; this is a fixed second
    /// or so regardless of folder size. Returns empty when lsof cannot run -- the caller pairs
    /// it with name matching so a failure here is not the only thing standing between a
    /// running app and its data.
    public static func holders(under paths: [String]) -> Set<Int32> {
        // lsof reports fully resolved paths, so the prefixes have to be resolved too, or a
        // folder reached through any symlinked parent matches nothing and this quietly
        // reports "nobody" -- a silent pass on the one check that prevents data loss.
        //
        // realpath(3), NOT URL.resolvingSymlinksInPath(): that one deliberately strips a
        // leading /private, so it maps /var/... to itself while lsof says /private/var/...
        let prefixes = Set(paths.flatMap { [$0, realpath($0)] }
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" })
        guard !prefixes.isEmpty, let output = lsof() else { return [] }

        var holders: Set<Int32> = []
        var pid: Int32?
        // -Fpn emits one field per line: "p<pid>" starts a process, "n<path>" is one of its
        // open files. Anything else is a field we did not ask for and can be ignored.
        for line in output.split(separator: "\n") {
            switch line.first {
            case "p":  pid = Int32(line.dropFirst())
            case "n":
                let path = String(line.dropFirst())
                if let pid, prefixes.contains(where: { path.hasPrefix($0) }) { holders.insert(pid) }
            default:   break
            }
        }
        return holders
    }

    private static func realpath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func lsof() -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/lsof")
        // -n/-P skip DNS and port lookups, which otherwise dominate the runtime.
        // -w suppresses the permission warnings lsof prints for other users' processes.
        process.arguments = ["-Fpn", "-n", "-P", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Read before waiting: lsof outproduces the 64KB pipe buffer and would deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
