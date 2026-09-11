import SwiftUI
import AppMoverKit

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var pendingMove: AppGroup?
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            DestinationBar(showingSettings: $showingSettings)
            Divider()

            if state.readFailed {
                FullDiskAccessNotice()
            } else {
                List {
                    if state.isScanning && state.groups.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Scanning…") }
                    }
                    ForEach(state.groups) { group in
                        AppRow(group: group) { pendingMove = group }
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }

            if let busy = state.busyMessage {
                Divider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout)
                    Spacer()
                }
                .padding(10)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .task { await state.refresh() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .confirmationDialog(
            "Move \(pendingMove?.displayName ?? "")?",
            isPresented: .constant(pendingMove != nil),
            presenting: pendingMove
        ) { group in
            Button("Move \(group.movableFolders.count) folder\(group.movableFolders.count == 1 ? "" : "s")") {
                let target = group
                pendingMove = nil
                Task { await state.move(target) }
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: { group in
            Text(confirmation(for: group))
        }
        .alert("Couldn't finish", isPresented: .constant(state.errorMessage != nil)) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    /// Names the folders being moved, not just the app, so the scope is never a surprise.
    private func confirmation(for group: AppGroup) -> String {
        let list = group.movableFolders
            .map { "• \($0.category.rawValue) — \($0.bytes.asStorage)" }
            .joined(separator: "\n")
        var text = """
            Moving to \(state.destination?.name ?? "the drive"):

            \(list)

            Quit \(group.displayName) first. While the drive is disconnected it cannot reach \
            this data. Time Machine does not follow links, so these folders will drop out of \
            your backups.
            """
        if group.needsAdmin {
            text += "\n\nSome of these are not owned by you and will need an administrator."
        }
        return text
    }
}

struct DestinationBar: View {
    @Environment(AppState.self) private var state
    @Binding var showingSettings: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.title2).foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.destination?.name ?? "No drive selected")
                    .fontWeight(.medium)
                if let volume = state.destination {
                    Text("\(volume.availableBytes.asStorage) free")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let speed = state.destinationSpeed, speed.isSlow {
                SlowDriveBadge(speed: speed)
            }

            Spacer()

            if state.reclaimedBytes > 0 {
                Text("\(state.reclaimedBytes.asStorage) reclaimed")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button { Task { await state.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(state.isScanning)
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
            }
        }
        .padding(12)
    }
}

struct SlowDriveBadge: View {
    let speed: DriveSpeed

    var body: some View {
        Label(speed.summary, systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.orange.opacity(0.12), in: Capsule())
            .help(speed.warning)
    }
}

struct FullDiskAccessNotice: View {
    var body: some View {
        ContentUnavailableView {
            Label("Can't read your Library", systemImage: "lock.shield")
        } description: {
            Text("Grant AppMover Full Disk Access, then reopen it.")
        } actions: {
            Button("Open Privacy Settings") {
                let path = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                if let url = URL(string: path) { NSWorkspace.shared.open(url) }
            }
        }
    }
}

extension Int64 {
    var asStorage: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
