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
            if !state.strandedBackups.isEmpty {
                StrandedBackupNotice(backups: state.strandedBackups)
                Divider()
            }
            FilterBar()
            Divider()

            if state.readFailed {
                FullDiskAccessNotice()
            } else {
                if state.arrangedGroups.isEmpty && state.isSearching {
                    ContentUnavailableView.search(text: state.searchText)
                } else {
                    List {
                        if state.isScanning && state.groups.isEmpty {
                            HStack { ProgressView().controlSize(.small); Text("Scanning…") }
                        }
                        ForEach(state.arrangedGroups) { group in
                            AppRow(group: group) { pendingMove = group }
                        }
                    }
                    .listStyle(.inset)
                    .alternatingRowBackgrounds()
                }
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

            While the drive is disconnected \(group.displayName) cannot reach this data. \
            Time Machine does not follow links, so these folders will drop out of your \
            backups — keep a copy somewhere else if you cannot regenerate them.
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
            .disabled(state.isScanning || state.isBusy)
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape")
            }
        }
        .padding(12)
    }
}

struct FilterBar: View {
    @Environment(AppState.self) private var state
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).font(.callout)
                TextField("Search apps and folders", text: $state.searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                if state.isSearching {
                    Button { state.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 320)
            // A plain TextField only accepts clicks on the glyphs themselves; without this
            // clicking the padding around it does nothing and the box feels broken.
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture { isSearchFocused = true }

            Spacer()

            Text(countLabel).font(.caption).foregroundStyle(.secondary)

            Picker("Sort", selection: Binding(
                get: { state.settings.sortOrder },
                set: { state.setSort($0) }
            )) {
                ForEach(GroupSort.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 110)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var countLabel: String {
        let shown = state.arrangedGroups.count
        guard state.isSearching else {
            return "\(shown) app\(shown == 1 ? "" : "s")"
        }
        return "\(shown) of \(state.groups.count)"
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

/// An interrupted run left the original renamed aside and no symlink in its place, so the
/// folder has vanished as far as its app is concerned. The data is intact and one rename
/// away -- but nothing else in the app ever looks for it.
struct StrandedBackupNotice: View {
    let backups: [URL]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("A previous move was interrupted").fontWeight(.medium)
                Text("\(backups.count) recovered folder\(backups.count == 1 ? " is" : "s are") "
                     + "waiting. Its app cannot see it until you rename it back, dropping "
                     + "the \".appmover.bak\" or \".appmover.restore\" suffix.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(backups)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.orange.opacity(0.1))
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
