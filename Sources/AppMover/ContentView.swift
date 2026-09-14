import SwiftUI
import AppMoverKit

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var pendingMove: (group: AppGroup, folders: [FolderSize], volume: Volume?)?
    @State private var showingSettings = false
    @State private var tab: ListTab = .onThisMac

    var body: some View {
        VStack(spacing: 0) {
            DestinationBar(showingSettings: $showingSettings)
            Divider()
            if let version = state.availableUpdate {
                UpdateNotice(version: version)
                Divider()
            }
            if !state.strandedBackups.isEmpty {
                StrandedBackupNotice(backups: state.strandedBackups)
                Divider()
            }
            FilterBar(shown: state.groups(in: tab).count, total: state.total(in: tab))
            Divider()

            if state.readFailed {
                FullDiskAccessNotice()
            } else {
                tabs
            }

            if let busy = state.busyMessage {
                Divider()
                BusyBar(message: busy, progress: state.moveProgress)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .task { await state.refresh() }
        .task { await state.checkForUpdate() }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .confirmationDialog(
            "Move \(pendingMove?.group.displayName ?? "")?",
            isPresented: .constant(pendingMove != nil),
            presenting: pendingMove
        ) { pending in
            Button("Move \(pending.folders.count) folders") {
                pendingMove = nil
                Task { await state.move(pending.folders, of: pending.group, to: pending.volume) }
            }
            Button("Cancel", role: .cancel) { pendingMove = nil }
        } message: { pending in
            Text(confirmation(for: pending.group, folders: pending.folders, to: pending.volume))
        }
        .alert("Couldn't finish", isPresented: .constant(state.errorMessage != nil)) {
            Button("OK") { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
    }

    private var tabs: some View {
        // Written out rather than looped: a ForEach here builds the tabs dynamically and
        // TabView then ignores the selection binding, opening on the last tab every time.
        TabView(selection: $tab) {
            tabContent(.onThisMac)
            tabContent(.moved)
        }
        .padding(.horizontal, 10).padding(.top, 8)
    }

    private func tabContent(_ item: ListTab) -> some View {
        GroupListView(tab: item, groups: state.groups(in: item)) { pendingMove = ($0, $1, $2) }
            .tabItem { Text("\(item.title) (\(state.total(in: item)))") }
            .tag(item)
    }

    /// Names the folders being moved, not just the app, so the scope is never a surprise.
    private func confirmation(for group: AppGroup, folders: [FolderSize], to volume: Volume?) -> String {
        let list = folders
            .map { "• \($0.category.label) — \($0.bytes.asStorage)" }
            .joined(separator: "\n")
        let drive = volume?.name ?? String(localized: "the drive")
        var text = String(localized: """
            Moving to \(drive):

            \(list)

            While the drive is disconnected \(group.displayName) cannot reach this data. \
            Time Machine does not follow links, so these folders will drop out of your \
            backups — keep a copy somewhere else if you cannot regenerate them.
            """)
        // Here, not only in the top bar: the bar shows the default drive, and this is the one
        // moment the user is looking at the drive they actually picked.
        if let volume, let speed = state.speeds.speed(forVolume: volume.uuid), speed.isSlow {
            text += "\n\n" + speed.warning
        }
        if folders.contains(where: \.needsAdmin) {
            text += "\n\n" + String(localized: "Some of these are not owned by you and will need an administrator.")
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
                Text(state.destination?.name ?? String(localized: "No drive selected"))
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
    let shown: Int
    let total: Int
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
        guard state.isSearching else { return String(localized: "\(shown) apps") }
        return String(localized: "\(shown) of \(total)")
    }
}

/// One line for whatever is in flight. A copy reports real bytes, so the bar is determinate;
/// everything else -- the pre-flight checks, a cleanup -- has nothing to count and spins.
struct BusyBar: View {
    let message: String
    let progress: MoveProgress?

    var body: some View {
        HStack(spacing: 10) {
            if let progress {
                ProgressView(value: progress.fraction)
                    .frame(width: 160)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message).font(.callout)
                    Text("\(progress.phase.label) — \(progress.fraction.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
                Text(message).font(.callout)
            }
            Spacer()
        }
        .padding(10)
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
                Text("""
                    \(backups.count) recovered folders are waiting. Their apps cannot see them \
                    until you rename them back, dropping the ".appmover.bak" or \
                    ".appmover.restore" suffix.
                    """)
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

struct UpdateNotice: View {
    let version: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            Text("AppMover \(version) is available").fontWeight(.medium)
            Spacer(minLength: 8)
            Button("Download") { NSWorkspace.shared.open(UpdateCheck.releasesPage) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.tint.opacity(0.1))
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
