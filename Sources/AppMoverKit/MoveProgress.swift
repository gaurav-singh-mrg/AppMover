import Foundation

public enum MovePhase: String, Sendable {
    case copying = "Copying"
    case verifying = "Verifying"
    case linking = "Linking"
    case cleaningUp = "Cleaning up"

    /// Where this phase sits on the bar. Copying owns nearly all of it because it owns
    /// nearly all of the time; the rest are one walk of the tree and two renames.
    var span: ClosedRange<Double> {
        switch self {
        case .copying:    0.00...0.90
        case .verifying:  0.90...0.97
        case .linking:    0.97...0.99
        case .cleaningUp: 0.99...1.00
        }
    }
}

/// How far along a single folder's move is, as a fraction of the whole operation.
public struct MoveProgress: Equatable, Sendable {
    public let phase: MovePhase
    public let fraction: Double

    public init(phase: MovePhase, within: Double = 0) {
        self.phase = phase
        let span = phase.span
        self.fraction = span.lowerBound
            + (span.upperBound - span.lowerBound) * min(max(within, 0), 1)
    }
}

/// Reads `ditto -V`'s narration.
///
/// ditto has no progress API. `-V` narrates to stderr, and of its four line shapes only
/// "<n> bytes for <path>" carries a number. Those numbers sum to exactly the logical byte
/// count `Manifest` measures -- checked against a tree of files, directories and a symlink --
/// so the bar is measured against the same number verification later compares.
///
/// ponytail: one giant file emits its line only once it is copied, so a single-file folder
/// jumps 0 to 100. Real folders are thousands of files. Switch to `rsync --info=progress2`
/// only if someone actually moves a disk image.
enum DittoLine {
    /// ditto's own narration, which must never end up in an error message.
    private static let narration = [">>> ", "copying ", "linked ", "created "]

    static func bytes(in line: String) -> Int64? {
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, parts[1] == "bytes", parts[2].hasPrefix("for ") else { return nil }
        return Int64(parts[0])
    }

    static func isNarration(_ line: String) -> Bool {
        bytes(in: line) != nil || narration.contains { line.hasPrefix($0) }
    }
}
