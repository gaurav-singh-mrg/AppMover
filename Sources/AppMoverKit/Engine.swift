import Foundation

public enum MovePhase: String, Sendable {
    case copying = "Copying"
    case verifying = "Verifying"
    case linking = "Linking"
    case cleaningUp = "Cleaning up"
}

/// Moves a folder to another volume and leaves a symlink behind.
///
/// Safety model: the original is renamed aside, never deleted, until the copy has been
/// verified AND the symlink resolves. The dangerous window is a rename, not a delete.
/// Validated on real data: feishin, 559MB / 4558 entries, byte-identical roundtrip.
public struct Engine: Sendable {
    public typealias ProgressHandler = @Sendable (MovePhase) -> Void

    private let allowlist: Allowlist
    public init(allowlist: Allowlist = Allowlist()) { self.allowlist = allowlist }

    // MARK: - Move

    public func move(
        source: URL,
        toVolume volume: Volume,
        subpath: String,
        progress: ProgressHandler = { _ in }
    ) throws -> MoveRecord {
        let fm = FileManager.default
        let destination = volume.mountPoint.appending(path: subpath)
        let backup = URL(filePath: source.path + ".appmover.bak")

        // Order matters: an already-moved folder must report as such before the allowlist
        // sees it, otherwise the user gets a misleading "not allowed" for their own move.
        guard !isSymlink(source) else { throw EngineError.alreadyLinked(source) }
        guard isDirectory(source) else { throw EngineError.notADirectory(source) }
        try allowlist.check(source)
        // `subpath` is built from a user-editable setting. A ".." component standardizes the
        // destination off the chosen volume entirely -- "/Volumes/MicroSD" + "../Caches/x"
        // lands on the boot disk -- so the free-space check, the copy and the abort path's
        // nuke would every one of them act on the wrong drive.
        guard !subpath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw EngineError.blockedPath(
                reason: "The folder name on the drive cannot contain \"..\" or \".\".")
        }
        // fileExists follows symlinks, so a link to a real directory already trips this.
        // The explicit isSymlink check also catches a *dangling* link, which fileExists
        // reports as absent, and fails it with a clear message rather than a ditto error.
        guard !fm.fileExists(atPath: destination.path), !isSymlink(destination) else {
            throw EngineError.destinationExists(destination)
        }
        guard !fm.fileExists(atPath: backup.path) else { throw EngineError.staleBackup(backup) }

        let expected = try Manifest.scan(source)
        try volume.validateAsDestination(
            source: Volume.containing(source), requiredBytes: expected.logicalBytes)

        // 1. copy
        progress(.copying)
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        do {
            try runDitto(from: source, to: destination)
        } catch {
            nuke(destination)
            throw error
        }

        // 2. verify before touching the original
        progress(.verifying)
        let copied = try Manifest.scan(destination)
        guard copied == expected else {
            nuke(destination)
            throw EngineError.verifyMismatch(source: expected, destination: copied)
        }

        // 3. rename aside -- NOT a delete
        progress(.linking)
        try fm.moveItem(at: source, to: backup)

        // 4. link, restoring the original if anything goes wrong
        do {
            try fm.createSymbolicLink(at: source, withDestinationURL: destination)
        } catch {
            try? fm.moveItem(at: backup, to: source)
            nuke(destination)
            throw EngineError.symlinkFailed(error.localizedDescription)
        }

        // 5. the link must actually resolve to a directory
        guard isDirectory(source),
              (try? fm.destinationOfSymbolicLink(atPath: source.path)) == destination.path else {
            try? fm.removeItem(at: source)          // removes the LINK only
            try? fm.moveItem(at: backup, to: source)
            nuke(destination)
            throw EngineError.linkDoesNotResolve(source)
        }

        // 6. only now is it safe to drop the original
        progress(.cleaningUp)
        nuke(backup)

        return MoveRecord(source: source.path, volumeUUID: volume.uuid, relativePath: subpath,
                          movedAt: Date(), sizeBytes: expected.logicalBytes)
    }

    // MARK: - Undo

    public func undo(_ record: MoveRecord, progress: ProgressHandler = { _ in }) throws {
        let fm = FileManager.default
        let source = record.sourceURL
        let restore = URL(filePath: source.path + ".appmover.restore")

        guard isSymlink(source) else { throw EngineError.notASymlink(source) }
        guard let target = record.currentTarget(), isDirectory(target) else {
            throw EngineError.targetMissing(
                record.currentTarget() ?? URL(filePath: record.relativePath))
        }
        guard !fm.fileExists(atPath: restore.path) else { throw EngineError.staleBackup(restore) }

        let expected = try Manifest.scan(target)
        // Undo copies back onto the internal disk -- the disk that was full enough for the
        // user to install this app in the first place. Without the same check the move makes,
        // ditto runs until it fills the disk, fails partway, and leaves a partial restore
        // that makes the *next* undo attempt fail too. The parent, not the source itself:
        // the source is a symlink and resolves to the external volume.
        guard let internalVolume = Volume.containing(source.deletingLastPathComponent()) else {
            throw EngineError.volumeUnsuitable(
                reason: "Could not identify the disk that \(source.lastPathComponent) belongs on.")
        }
        try internalVolume.validateAsDestination(source: nil, requiredBytes: expected.logicalBytes)

        progress(.copying)
        do {
            try runDitto(from: target, to: restore)
        } catch {
            nuke(restore)
            throw error
        }

        progress(.verifying)
        let restored = try Manifest.scan(restore)
        guard restored == expected else {
            nuke(restore)
            throw EngineError.verifyMismatch(source: expected, destination: restored)
        }

        progress(.linking)
        // moveItem will not overwrite, so the link must go first. For the moment between
        // these two calls the path does not exist; if the process dies here the data is
        // intact at `restore`, which is what the error names.
        do {
            try fm.removeItem(at: source)    // the LINK only; never recursive into the target
            try fm.moveItem(at: restore, to: source)
        } catch {
            throw EngineError.copyFailed(
                "\(error.localizedDescription) Your data is safe at \(restore.path) -- "
                + "rename it back to \(source.lastPathComponent).")
        }

        progress(.cleaningUp)
        nuke(target)                         // external copy goes last
        removeIfEmpty(target.deletingLastPathComponent())
    }

    // MARK: - Orphan repair

    /// Deletes the abandoned external copy left when something replaced our symlink with a
    /// real directory -- a Sparkle update, a reinstall, a migration assistant. All of those
    /// write a new folder aside and rename() it over the old path, which destroys the link.
    ///
    /// The live data is the new folder on the internal disk; the external copy is a stale
    /// duplicate that nothing points at and nothing else will ever clean up. Until this runs,
    /// the user is using *more* disk than before they installed AppMover.
    public func discardOrphan(_ record: MoveRecord) throws {
        // Re-checked here rather than trusted from the UI: health is computed when the window
        // opens and the window may have been open for hours. If the symlink is in fact live,
        // the data below is not abandoned, it is the only copy.
        guard Ledger.health(of: record) == .orphaned else {
            throw EngineError.notOrphaned(record.sourceURL)
        }
        guard let target = record.currentTarget(), isDirectory(target) else {
            throw EngineError.targetMissing(
                record.currentTarget() ?? URL(filePath: record.relativePath))
        }
        nuke(target)
        removeIfEmpty(target.deletingLastPathComponent())
    }

    // MARK: - Primitives

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType)
            == .typeSymbolicLink
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// ditto, not FileManager.copyItem: it is the macOS-correct tool for resource forks,
    /// extended attributes and ACLs, and it is what the validated prototype used.
    private func runDitto(from: URL, to: URL) throws {
        let (status, stderr) = try run("/usr/bin/ditto", [from.path, to.path])
        guard status == 0 else {
            throw EngineError.copyFailed(stderr.isEmpty ? "ditto exited \(status)" : stderr)
        }
    }

    /// Delete, defeating ACLs first.
    ///
    /// ditto reproduces source ACLs onto its own .BC.T_* temp files, so a deny-delete ACL
    /// leaves leftovers that resist removal. Observed in testing. The abort path is exactly
    /// where a second failure cannot be afforded, so strip ACLs before removing.
    private func nuke(_ url: URL) {
        _ = try? run("/bin/chmod", ["-N", "-R", url.path])
        try? FileManager.default.removeItem(at: url)
    }

    /// Tidies away an empty AppMover/<root>/ shell.
    ///
    /// Must check emptiness first: removeItem is recursive, so an unconditional call here
    /// would delete every *other* folder moved to the same drive.
    private func removeIfEmpty(_ url: URL) {
        let fm = FileManager.default
        let contents = try? fm.contentsOfDirectory(atPath: url.path)
        guard let contents, contents.filter({ $0 != ".DS_Store" }).isEmpty else { return }
        try? fm.removeItem(at: url)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: errData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, message)
    }
}
