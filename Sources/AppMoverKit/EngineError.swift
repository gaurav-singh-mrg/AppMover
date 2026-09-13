import Foundation

public enum EngineError: Error, Equatable, Sendable {
    case notADirectory(URL)
    case alreadyLinked(URL)
    case destinationExists(URL)
    case staleBackup(URL)
    case copyFailed(String)
    case verifyMismatch(source: Manifest, destination: Manifest)
    case symlinkFailed(String)
    case linkDoesNotResolve(URL)
    case notASymlink(URL)
    case notOrphaned(URL)
    case targetMissing(URL)
    case blockedPath(reason: String)
    case volumeUnsuitable(reason: String)
}

extension EngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notADirectory(let u):      String(localized: "Not a directory: \(u.path)")
        case .alreadyLinked(let u):      String(localized: "Already a symlink: \(u.lastPathComponent)")
        case .destinationExists(let u):  String(localized: "Destination already exists: \(u.path)")
        case .staleBackup(let u):        String(localized: "A previous run left a backup at \(u.path). Resolve it manually.")
        case .copyFailed(let m):         String(localized: "Copy failed: \(m)")
        case .verifyMismatch(let s, let d):
            String(localized: "Copy did not match: source \(s.entryCount) entries/\(s.logicalBytes) bytes, copy \(d.entryCount)/\(d.logicalBytes)")
        case .symlinkFailed(let m):      String(localized: "Could not create symlink: \(m)")
        case .linkDoesNotResolve(let u): String(localized: "Symlink does not resolve: \(u.path)")
        case .notASymlink(let u):        String(localized: "Not a moved folder: \(u.lastPathComponent)")
        case .notOrphaned(let u):
            String(localized: "\(u.lastPathComponent) is linked and in use — the copy on the drive is not abandoned.")
        case .targetMissing(let u):      String(localized: "External folder missing: \(u.path). Connect the drive first.")
        case .blockedPath(let r):        r
        case .volumeUnsuitable(let r):   r
        }
    }
}
