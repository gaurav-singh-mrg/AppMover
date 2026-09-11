import SwiftUI
import AppMoverKit

struct FolderRow: View {
    let folder: FolderSize
    let largest: Int64
    let move: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                Text(folder.parentName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)

            // A plain relative bar: enough to see what is worth moving, nothing more.
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tint.opacity(0.25))
                    .frame(width: max(2, geo.size.width * fraction), height: 6)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 90, height: 16)

            Text(folder.bytes.asStorage)
                .font(.callout.monospacedDigit())
                .frame(width: 70, alignment: .trailing)

            Button("Move", action: move)
        }
        .padding(.vertical, 3)
    }

    private var fraction: Double {
        largest > 0 ? min(1, Double(folder.bytes) / Double(largest)) : 0
    }
}

struct MovedRow: View {
    @Environment(AppState.self) private var state
    let record: MoveRecord

    var body: some View {
        let health = state.health(record)
        HStack(spacing: 12) {
            Image(systemName: health.symbol).foregroundStyle(health.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                Text(health.explanation).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)

            Text(record.sizeBytes.asStorage)
                .font(.callout.monospacedDigit())
                .frame(width: 70, alignment: .trailing)

            Button("Undo") { Task { await state.undo(record) } }
                .disabled(health == .volumeMissing)
        }
        .padding(.vertical, 3)
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
        case .brokenLink: .orange
        case .orphaned: .orange
        }
    }

    var explanation: String {
        switch self {
        case .healthy:       "Linked and reachable"
        case .volumeMissing: "Drive disconnected — reconnect it to use this app"
        case .brokenLink:    "The link is missing or points nowhere"
        case .orphaned:      "Data is on the drive but nothing links to it"
        }
    }
}
