import SwiftUI
import AppMoverKit

/// One app and all of its data in a single row, expandable to the individual folders.
struct AppRow: View {
    @Environment(AppState.self) private var state
    let group: AppGroup
    let move: () -> Void
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(group.folders) { folder in
                FolderDetailRow(folder: folder)
            }
        } label: {
            HStack(spacing: 10) {
                AppIcon(url: group.appURL, fallback: group.displayName)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName).fontWeight(.medium)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if group.needsAdmin {
                    Image(systemName: "lock.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .help("Not owned by you — moving this needs an administrator.")
                }

                Text(group.totalBytes.asStorage)
                    .font(.callout.monospacedDigit())
                    .frame(width: 72, alignment: .trailing)

                actionButton
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
    }

    private var subtitle: String {
        if group.isFullyMoved { return "Moved · \(group.categorySummary)" }
        if group.isPartiallyMoved { return "Partly moved · \(group.categorySummary)" }
        return group.categorySummary
    }

    @ViewBuilder
    private var actionButton: some View {
        if group.movableFolders.isEmpty {
            Button("Undo") { Task { await state.undoAll(group) } }
                .disabled(!canUndo)
        } else {
            Button(group.isPartiallyMoved ? "Move rest" : "Move", action: move)
        }
    }

    /// Only offer undo for links we created; a hand-made one has no record to restore from.
    private var canUndo: Bool {
        group.folders.contains { state.record(for: $0) != nil }
    }
}

struct FolderDetailRow: View {
    @Environment(AppState.self) private var state
    let folder: FolderSize

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(tint)
                .frame(width: 14).padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(folder.category.rawValue).font(.callout)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                // Where the data actually is right now -- the external path once moved.
                Text(displayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(locationExists ? .secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(folder.currentLocation.path)
            }

            Spacer(minLength: 8)

            Text(folder.bytes.asStorage)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([folder.currentLocation])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!locationExists)
            .help(locationExists
                  ? "Reveal in Finder"
                  : "Not available — connect the drive to see this folder")

            if let record = state.record(for: folder) {
                Button("Undo") { Task { await state.undo(record) } }
                    .controlSize(.small)
                    .disabled(state.health(record) == .volumeMissing)
            }
        }
        .padding(.leading, 26)
        .padding(.vertical, 2)
    }

    private var record: MoveRecord? { state.record(for: folder) }

    /// Home paths read better as ~/Library/… than as /Users/name/Library/…
    private var displayPath: String {
        (folder.currentLocation.path as NSString).abbreviatingWithTildeInPath
    }

    private var locationExists: Bool {
        FileManager.default.fileExists(atPath: folder.currentLocation.path)
    }

    private var icon: String {
        guard folder.isSymlink else { return "internaldrive" }
        guard let record else { return "link" }
        return state.health(record).symbol
    }

    private var tint: Color {
        guard folder.isSymlink else { return .secondary }
        guard let record else { return .secondary }
        return state.health(record).tint
    }

    private var status: String {
        guard folder.isSymlink else { return "on startup disk" }
        guard let record else { return "linked by hand" }
        return state.health(record).explanation.lowercased()
    }
}

/// The real app icon when we found the bundle, otherwise a neutral placeholder.
struct AppIcon: View {
    let url: URL?
    let fallback: String

    var body: some View {
        Group {
            if let url, FileManager.default.fileExists(atPath: url.path) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.quaternary)
                    .overlay(Text(initial).font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary))
            }
        }
        .frame(width: 26, height: 26)
    }

    private var initial: String {
        String(fallback.first.map(String.init)?.uppercased() ?? "?")
    }
}

extension LinkHealth {
    var symbol: String {
        switch self {
        case .healthy:       "checkmark.circle.fill"
        case .volumeMissing: "externaldrive.badge.xmark"
        case .brokenLink:    "exclamationmark.triangle.fill"
        case .orphaned:      "questionmark.folder"
        }
    }

    var tint: Color {
        switch self {
        case .healthy: .green
        case .volumeMissing: .secondary
        case .brokenLink, .orphaned: .orange
        }
    }

    var explanation: String {
        switch self {
        case .healthy:       "Linked and reachable"
        case .volumeMissing: "Drive disconnected"
        case .brokenLink:    "Link is missing or points nowhere"
        case .orphaned:      "Data on the drive, nothing links to it"
        }
    }
}
